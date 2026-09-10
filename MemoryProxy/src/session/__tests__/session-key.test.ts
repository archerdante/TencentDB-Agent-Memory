import { describe, expect, it } from "vitest";
import { deriveOpenCodeConversationId } from "../session-key.js";

describe("deriveOpenCodeConversationId", () => {
  it("keeps repeated OpenCode tool-loop requests in one session", () => {
    const first = deriveOpenCodeConversationId(
      [{ role: "user", content: "帮我检查代码" }],
      "/opencode/default/v1/chat/completions",
      "fallback",
    );
    const repeated = deriveOpenCodeConversationId(
      [
        { role: "user", content: "帮我检查代码" },
        { role: "assistant", content: null },
        { role: "user", content: "User has answered your questions: Agent=Kitt" },
      ],
      "/opencode/default/v1/chat/completions",
      "fallback",
    );
    expect(repeated).toBe(first);
  });

  it("does not expose user content and falls back without a user message", () => {
    const id = deriveOpenCodeConversationId(
      [{ role: "system", content: "hidden" }],
      "/opencode/default/v1/chat/completions",
      "fallback",
    );
    expect(id).toBe("fallback");
    expect(id).not.toContain("hidden");
  });
});
