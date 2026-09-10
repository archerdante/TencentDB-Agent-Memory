/**
 * Session key resolution & conversation freshness check.
 *
 * Shared between handler.ts and anthropicHandler.ts.
 */
import type { Context } from "hono";
import { createHash } from "node:crypto";

/**
 * Extract conversation ID from request headers. Returns null if no valid ID
 * found. Some clients (notably OpenCode CLI) do not send one; callers may
 * provide a client-specific deterministic fallback after this function.
 */
export function resolveConversationId(c: Context): string | null {
  const id =
    c.req.header("x-conversation-id") ??
    c.req.header("x-session-id") ??
    c.req.header("x-claude-code-session-id") ?? // Claude Code CLI sends this
    c.req.header("x-deepseek-harness-session-id") ?? // dsh (deepseek-harness) CLI/web sends this
    c.req.header("x-chat-id") ??
    c.req.header("x-thread-id") ??
    null;
  return id && id.length > 0 ? id : null;
}

/**
 * Derive a stable, non-sensitive conversation ID for OpenCode CLI requests.
 * OpenCode does not send a session header, but it repeats the initial user
 * message on each tool-loop request. Hashing that message keeps one CLI
 * conversation together without putting user content into storage keys.
 */
export function deriveOpenCodeConversationId(
  messages: unknown[],
  requestPath: string,
  fallback: string,
): string {
  const firstUser = messages.find((message) => {
    const role = (message as Record<string, unknown>)?.role;
    return role === "user";
  }) as Record<string, unknown> | undefined;
  const content = firstUser?.content;
  const seed = typeof content === "string"
    ? content
    : content == null ? "" : JSON.stringify(content);
  if (!seed) return fallback;
  const digest = createHash("sha256")
    .update(`${requestPath}\n${seed}`)
    .digest("hex")
    .slice(0, 32);
  return `opencode-${digest}`;
}

/** Check whether the messages look like a fresh conversation (at most 1 user message, no assistant/tool). */
export function isFreshConversation(
  messages: Array<{ role?: string }>,
): boolean {
  let userCount = 0;
  for (const m of messages) {
    const role = m.role ?? "";
    if (role === "assistant" || role === "tool") return false;
    if (role === "user") userCount++;
    if (userCount > 1) return false;
  }
  return userCount <= 1;
}
