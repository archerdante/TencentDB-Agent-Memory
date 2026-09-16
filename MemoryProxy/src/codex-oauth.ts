/**
 * Codex（ChatGPT 订阅）上游 OAuth 凭据管理。
 *
 * 背景：ChatGPT 的 Codex 后端（`https://chatgpt.com/backend-api/codex/responses`）
 * 不认静态 API key —— 它要的是 ChatGPT/Codex 登录流程签发的**短期 OAuth access
 * token**，外加该 token 归属的 `chatgpt-account-id`。因此一个把上游指向该端点的
 * proxy 容器，自己必须持有并维护这套凭据。
 *
 * 本模块负责：
 *   1. 从挂载进来的 `auth.json`（Codex 客户端自己写的那份）读取凭据；
 *   2. 在 access token 过期前用标准 OAuth refresh-token grant 换新；
 *   3. **把轮换后的凭据写回同一个文件** —— 这样整条刷新链只有一个，不会出现
 *      「proxy 刷一次、客户端刷一次，互相把对方的 refresh token 作废」。
 *
 * 安全与降级约定：
 *   - 任何分支都不打印 token / refresh token（含错误路径），只打长度与尾号。
 *   - 文件不可写（只读挂载）时，退化为「仅在内存里刷新」，而不是让请求失败。
 *   - 并发请求只触发一次刷新（single-flight）。
 */

import { readFileSync, writeFileSync, renameSync, statSync } from "node:fs";
import { randomBytes } from "node:crypto";

import { log } from "./report/log.js";
import type { CodexOAuthConfig } from "./types.js";

/** 解析出来的凭据快照。字段缺失时对应值为 undefined，不抛错。 */
export interface CodexAuthTokens {
  accessToken?: string;
  refreshToken?: string;
  accountId?: string;
}

/** 交给调用方的最终结果：能拿到的、可直接放进上游请求头的东西。 */
export interface CodexAuthResult {
  accessToken: string;
  accountId?: string;
}

/** 一次成功刷新后的凭据；此时两个 token 都必然存在。 */
interface RefreshedTokens {
  accessToken: string;
  refreshToken: string;
  accountId?: string;
}

interface CacheEntry {
  tokens: CodexAuthTokens;
  /** access token 的绝对过期时间（ms since epoch）；无法判定时为 undefined。 */
  expiresAtMs?: number;
  /** auth.json 的 mtime，用于发现外部（客户端自己）刷新过的文件。 */
  fileMtimeMs?: number;
}

let cache: CacheEntry | null = null;
/** single-flight：并发调用共享同一个刷新 Promise。 */
let inFlightRefresh: Promise<RefreshedTokens> | null = null;

/** 仅用于日志的脱敏形式：不泄露内容，只留可对账的长度与尾 4 位。 */
function maskSecret(value: string | undefined): string {
  if (!value) return "<none>";
  const tail = value.length > 4 ? value.slice(-4) : "";
  return `len=${value.length}…${tail}`;
}

/**
 * 从 JWT 的 payload 段读出 `exp`（秒）并换算成毫秒。
 * 失败一律返回 undefined —— 过期时间只是刷新时机优化，读不出来不影响正确性。
 */
function readJwtExpiryMs(token: string | undefined): number | undefined {
  if (!token) return undefined;
  const parts = token.split(".");
  if (parts.length !== 3) return undefined;
  try {
    const payload = JSON.parse(Buffer.from(parts[1] ?? "", "base64url").toString("utf8")) as {
      exp?: number;
    };
    return typeof payload.exp === "number" && Number.isFinite(payload.exp)
      ? payload.exp * 1000
      : undefined;
  } catch {
    return undefined;
  }
}

/** auth.json 的 mtime（ms）；读不到就返回 undefined，用于发现外部刷新过的文件。 */
function readMtimeMs(authFile: string): number | undefined {
  try {
    return statSync(authFile).mtimeMs;
  } catch {
    return undefined;
  }
}

/** 读取并解析 auth.json。文件缺失 / 内容不合法都返回空对象，由调用方决定后续。 */
function readAuthFile(authFile: string): { tokens: CodexAuthTokens; mtimeMs?: number } {
  try {
    const raw = readFileSync(authFile, "utf8");
    const parsed = JSON.parse(raw) as Record<string, unknown>;
    const tokens = (parsed.tokens ?? {}) as Record<string, unknown>;
    const pick = (source: Record<string, unknown>, key: string): string | undefined => {
      const value = source[key];
      return typeof value === "string" && value.length > 0 ? value : undefined;
    };
    return {
      tokens: {
        accessToken: pick(tokens, "access_token"),
        refreshToken: pick(tokens, "refresh_token"),
        accountId: pick(tokens, "account_id"),
      },
      mtimeMs: readMtimeMs(authFile),
    };
  } catch (error) {
    log.warn("codex-oauth.readFailed", {
      authFile,
      detail: error instanceof Error ? error.message : String(error),
    });
    return { tokens: {} };
  }
}

/**
 * 用 refresh token 换一组新的凭据（OAuth 2.0 refresh-token grant）。
 * 注意：服务端可能轮换 refresh token，因此返回值里给到新 refresh token 时必须回写。
 */
async function refreshCodexToken(
  cfg: CodexOAuthConfig,
  refreshToken: string,
): Promise<RefreshedTokens> {
  const body = new URLSearchParams({
    grant_type: "refresh_token",
    refresh_token: refreshToken,
    client_id: cfg.clientId,
  });
  const response = await fetch(cfg.tokenUrl, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body,
  });
  const text = await response.text();
  if (!response.ok) {
    throw new Error(`codex token refresh failed (${response.status}): ${text.slice(0, 300)}`);
  }
  let parsed: Record<string, unknown>;
  try {
    parsed = JSON.parse(text) as Record<string, unknown>;
  } catch {
    throw new Error(`codex token refresh returned invalid JSON: ${text.slice(0, 200)}`);
  }
  const accessToken = typeof parsed.access_token === "string" ? parsed.access_token : undefined;
  if (!accessToken) {
    throw new Error("codex token refresh response has no access_token");
  }
  return {
    accessToken,
    // 轮换时给新值；没给就沿用旧的。
    refreshToken:
      typeof parsed.refresh_token === "string" && parsed.refresh_token.length > 0
        ? parsed.refresh_token
        : refreshToken,
    accountId: typeof parsed.account_id === "string" ? parsed.account_id : undefined,
  };
}

/**
 * 把轮换后的凭据原子写回 auth.json，保留文件里其它字段（客户端自己的状态）。
 * 只读挂载 / 权限不足时记一条 warn 后放弃 —— 内存里已经刷新成功，不影响本次请求。
 */
function persistAuthFile(authFile: string, tokens: CodexAuthTokens): void {
  try {
    const raw = readFileSync(authFile, "utf8");
    const parsed = JSON.parse(raw) as Record<string, unknown>;
    const existing = (parsed.tokens ?? {}) as Record<string, unknown>;
    parsed.tokens = {
      ...existing,
      ...(tokens.accessToken ? { access_token: tokens.accessToken } : {}),
      ...(tokens.refreshToken ? { refresh_token: tokens.refreshToken } : {}),
      ...(tokens.accountId ? { account_id: tokens.accountId } : {}),
    };
    parsed.last_refresh = new Date().toISOString();
    const tmp = `${authFile}.tmp-${process.pid}-${randomBytes(4).toString("hex")}`;
    writeFileSync(tmp, `${JSON.stringify(parsed, null, 2)}\n`, "utf8");
    renameSync(tmp, authFile);
    log.info("codex-oauth.persisted", {
      authFile,
      access: maskSecret(tokens.accessToken),
    });
  } catch (error) {
    log.warn("codex-oauth.persistFailed", {
      authFile,
      detail: error instanceof Error ? error.message : String(error),
    });
  }
}

/** 判定当前缓存的 token 是否仍然可用。 */
function isFresh(entry: CacheEntry, cfg: CodexOAuthConfig): boolean {
  if (!entry.tokens.accessToken) return false;
  if (entry.expiresAtMs === undefined) {
    // 读不出 exp（非 JWT？）时保守处理：只靠 mtime 变化判断是否外部刷新过。
    return true;
  }
  return Date.now() + cfg.refreshSkewSeconds * 1000 < entry.expiresAtMs;
}

/**
 * 取得一份可用的 Codex 凭据。
 *
 * @returns 有 access token 时返回它（以及能拿到的 accountId）；确实没有凭据时返回 null，
 *          由调用方决定是跳过注入（让上游以 401 明确报错）还是别的处理。
 */
export async function getCodexAuth(cfg: CodexOAuthConfig): Promise<CodexAuthResult | null> {
  // 1) 外部（Codex 客户端自己）刷新过文件时，第一时间换成新凭据。
  const { tokens: onDisk, mtimeMs } = readAuthFile(cfg.authFile);
  if (
    cache === null ||
    (mtimeMs !== undefined && cache.fileMtimeMs !== undefined && mtimeMs !== cache.fileMtimeMs)
  ) {
    cache = {
      tokens: onDisk,
      expiresAtMs: readJwtExpiryMs(onDisk.accessToken),
      fileMtimeMs: mtimeMs,
    };
  }

  // 2) 仍然新鲜就直接用。
  if (isFresh(cache, cfg)) {
    return { accessToken: cache.tokens.accessToken as string, accountId: cache.tokens.accountId };
  }

  // 3) 需要刷新：并发调用共享同一次刷新。
  if (!cache.tokens.refreshToken) {
    // 没有 refresh token。若手上还有 access token 就先发出去（过期的话上游会 401，
    // 那比在本地静默不出请求更好排查）。
    if (cache.tokens.accessToken) {
      log.warn("codex-oauth.noRefreshToken", { authFile: cfg.authFile });
      return { accessToken: cache.tokens.accessToken, accountId: cache.tokens.accountId };
    }
    log.warn("codex-oauth.noCredentials", { authFile: cfg.authFile });
    return null;
  }

  if (!inFlightRefresh) {
    const refreshToken = cache.tokens.refreshToken;
    inFlightRefresh = refreshCodexToken(cfg, refreshToken)
      .then((refreshed) => {
        const merged: RefreshedTokens = {
          accessToken: refreshed.accessToken,
          refreshToken: refreshed.refreshToken ?? refreshToken,
          // 刷新响应没带 account_id 时沿用文件里的。
          accountId: refreshed.accountId ?? cache?.tokens.accountId,
        };
        persistAuthFile(cfg.authFile, merged);
        return merged;
      })
      .finally(() => {
        inFlightRefresh = null;
      });
  }

  let refreshed: RefreshedTokens;
  try {
    refreshed = await inFlightRefresh;
  } catch (error) {
    log.warn("codex-oauth.refreshFailed", {
      authFile: cfg.authFile,
      detail: error instanceof Error ? error.message : String(error),
    });
    // 刷新失败但磁盘上还有 token 时照旧使用它：可能只是网络抖动，
    // 而且过一个请求周期还会再试。
    if (cache.tokens.accessToken) {
      return { accessToken: cache.tokens.accessToken, accountId: cache.tokens.accountId };
    }
    return null;
  }

  cache = {
    tokens: refreshed,
    expiresAtMs: readJwtExpiryMs(refreshed.accessToken),
    fileMtimeMs: cache.fileMtimeMs,
  };
  return { accessToken: refreshed.accessToken, accountId: refreshed.accountId };
}

/** 仅供单测使用：清空内存缓存，避免用例之间相互影响。 */
export function __resetCodexAuthCacheForTests(): void {
  cache = null;
  inFlightRefresh = null;
}
