/**
 * Storage-backed LLM tool definitions — drop-in replacement for the local-FS
 * sandboxed tools in `llm-runner.ts`.
 *
 * Used in service mode (COS) so that L2/L3 LLM agents read/write files via
 * StorageAdapter instead of the local filesystem.
 *
 * Tool names and schemas are **identical** to `createSandboxedTools`, so
 * LLM prompts work unchanged.
 */

import { tool, jsonSchema } from "ai";
import type { StorageAdapter } from "../../core/storage/adapter.js";

const TAG = "[memory-tdai] [storage-tools]";

interface Logger {
  debug?: (message: string) => void;
  info?: (message: string) => void;
  warn: (message: string) => void;
  error: (message: string) => void;
}

/**
 * Resolve a relative path within a storage prefix boundary (sandbox).
 *
 * Returns the full storage key (prefix + normalized path), or null if the
 * path escapes the prefix boundary (e.g. "../" traversal).
 */
function resolveStorageKey(prefix: string, relativePath: string): string | null {
  // Normalize: strip leading ./ , convert backslashes, collapse //
  const normalized = relativePath
    .replace(/\\/g, "/")
    .replace(/^\.\//, "")
    .replace(/\/+/g, "/");

  // Block absolute paths and parent traversal
  if (normalized.startsWith("/") || normalized.startsWith("..")) return null;

  // After join, verify the result still starts with prefix
  const key = `${prefix}${normalized}`;

  // Double-check: split and reject any ".." segment
  if (normalized.split("/").includes("..")) return null;

  return key;
}

/**
 * 2026-09-10 local hotfix (read-cap): cap the payload of a single `read` tool result.
 *
 * 背景：L2 场景抽取走的是这一套 storage-backed 工具（日志实证
 * `Using storage-backed tools (prefix="scene_blocks/")`）。单个场景块已涨到
 * 14 万字符以上，模型一次 read 就会把 ~4 万 token 塞进上下文；而 agent 工具
 * 循环每一步都会重发「提示词 + 之前所有工具结果」，实测 L2 单次 run 因此达到
 * 30~48 万 input tokens（占 MemoryHub LLM 消耗的 ~85%）。
 *
 * 这里把单次读取上限设为 6 万字符 —— 对绝大多数 <20KB 的场景文件完全无影响，
 * 只截断病态大文件；同时给 read 增加 offset/limit 让模型可以分页续读。
 */
const MAX_READ_CHARS = 60_000;

/**
 * Create storage-backed read/write/edit tools.
 *
 * @param storage    - StorageAdapter instance (COS or local backend)
 * @param prefix     - Key prefix acting as sandbox root (e.g. "scene_blocks/")
 * @param logger     - Optional logger for diagnostics
 */
export function createStorageTools(
  storage: StorageAdapter,
  prefix: string,
  logger?: Logger,
) {
  return {
    read: tool({
      description:
        "Read the contents of a file at the given relative path. A single call returns at most 60000 characters; " +
        "when a file is larger, the result begins with a `[chars A-B of N]` header and you can continue with `offset`.",
      inputSchema: jsonSchema<{ path: string; offset?: number; limit?: number }>({
        type: "object",
        properties: {
          path: { type: "string", description: "Relative file path to read." },
          offset: { type: "number", description: "0-based character offset to start from (default 0)." },
          limit: { type: "number", description: "Max characters to return (default and hard cap: 60000)." },
        },
        required: ["path"],
      }),
      execute: (async (args: { path: string; offset?: number; limit?: number }) => {
        const key = resolveStorageKey(prefix, args.path);
        if (!key) return JSON.stringify({ error: `Path "${args.path}" escapes workspace boundary.` });
        try {
          const content = await storage.readFile(key);
          if (content === null) {
            logger?.debug?.(`${TAG} read: "${args.path}" → not found`);
            return JSON.stringify({ error: `File not found: ${args.path}` });
          }
          const total = content.length;
          const rawOffset = Number(args.offset ?? 0);
          const offset = Number.isFinite(rawOffset) && rawOffset > 0 ? Math.floor(rawOffset) : 0;
          const rawLimit = Number(args.limit ?? MAX_READ_CHARS);
          const limit = Number.isFinite(rawLimit) && rawLimit > 0
            ? Math.min(MAX_READ_CHARS, Math.floor(rawLimit))
            : MAX_READ_CHARS;
          if (total > 0 && offset >= total) {
            return `[chars ${offset}-${offset} of ${total}: offset is past end of file]`;
          }
          const slice = content.slice(offset, offset + limit);
          const end = offset + slice.length;
          logger?.debug?.(
            `${TAG} read: "${args.path}" → ${total} chars (returning ${offset}-${end}${end < total ? ", truncated" : ""})`,
          );
          if (offset === 0 && end >= total) return content;
          const note = end < total
            ? `\n\n[... 文件共 ${total} 字符，本次仅返回 ${offset}-${end}；如需后续内容，请用 offset=${end} 再次读取 ...]`
            : "";
          return `[chars ${offset}-${end} of ${total}]\n${slice}${note}`;
        } catch (err) {
          const msg = err instanceof Error ? err.message : String(err);
          logger?.warn(`${TAG} read failed (key=${key}): ${msg}`);
          return JSON.stringify({ error: msg });
        }
      }) as any,
    }),

    write: tool({
      description: "Write content to a file at the given relative path. Creates or overwrites.",
      inputSchema: jsonSchema<{ path: string; content: string }>({
        type: "object",
        properties: {
          path: { type: "string", description: "Relative file path to write." },
          content: { type: "string", description: "Content to write." },
        },
        required: ["path", "content"],
      }),
      execute: (async (args: { path: string; content: string }) => {
        const key = resolveStorageKey(prefix, args.path);
        if (!key) return JSON.stringify({ error: `Path "${args.path}" escapes workspace boundary.` });
        try {
          await storage.writeFile(key, args.content);
          logger?.debug?.(`${TAG} write: "${args.path}" → ${Buffer.byteLength(args.content, "utf8")} bytes`);
          return JSON.stringify({ success: true });
        } catch (err) {
          const msg = err instanceof Error ? err.message : String(err);
          logger?.warn(`${TAG} write failed (key=${key}): ${msg}`);
          return JSON.stringify({ error: msg });
        }
      }) as any,
    }),

    edit: tool({
      description: "Apply one or more text replacements to a file. Each edit replaces an exact substring.",
      inputSchema: jsonSchema<{ path: string; edits: Array<{ oldText: string; newText: string }> }>({
        type: "object",
        properties: {
          path: { type: "string", description: "Relative file path." },
          edits: {
            type: "array",
            description: "Array of replacements to apply sequentially.",
            items: {
              type: "object",
              properties: {
                oldText: { type: "string", description: "Exact string to find." },
                newText: { type: "string", description: "Replacement string." },
              },
              required: ["oldText", "newText"],
            },
          },
        },
        required: ["path", "edits"],
      }),
      execute: (async (args: { path: string; edits: Array<{ oldText: string; newText: string }> }) => {
        const key = resolveStorageKey(prefix, args.path);
        if (!key) return JSON.stringify({ error: `Path "${args.path}" escapes workspace boundary.` });
        if (!args.edits || args.edits.length === 0) return JSON.stringify({ error: "edits array cannot be empty." });
        try {
          const existing = await storage.readFile(key);
          if (existing === null) {
            logger?.debug?.(`${TAG} edit: "${args.path}" → not found`);
            return JSON.stringify({ error: `File not found: ${args.path}` });
          }
          let content = existing;
          for (const edit of args.edits) {
            if (!edit.oldText) return JSON.stringify({ error: "oldText cannot be empty." });
            if (!content.includes(edit.oldText)) {
              return JSON.stringify({ error: `oldText not found in file "${args.path}": ${edit.oldText.slice(0, 80)}` });
            }
            // Pass a replacer function so `$&`, `$'`, "$`", `$1`, `$$` in newText are
            // inserted literally. A plain string replacement would expand them as
            // special patterns -- `$'` (matched substring's suffix) duplicates the rest
            // of the file on every edit, growing scene blocks exponentially.
            content = content.replace(edit.oldText, () => edit.newText);
          }
          await storage.writeFile(key, content);
          logger?.debug?.(
            `${TAG} edit: "${args.path}" → ${args.edits.length} replacement(s), ${Buffer.byteLength(content, "utf8")} bytes`,
          );
          return JSON.stringify({ success: true });
        } catch (err) {
          const msg = err instanceof Error ? err.message : String(err);
          logger?.warn(`${TAG} edit failed (key=${key}): ${msg}`);
          return JSON.stringify({ error: msg });
        }
      }) as any,
    }),
  };
}

/** Read-only subset for storage tools (mirrors createReadOnlyTools). */
export function createStorageReadOnlyTools(
  storage: StorageAdapter,
  prefix: string,
  logger?: Logger,
) {
  const all = createStorageTools(storage, prefix, logger);
  return { read: all.read };
}
