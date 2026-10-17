// Rune Weaver Dashboard — Parity pins for the engine's system-notice registry.

import { describe, expect, it } from "vitest";
import { isSystemNoticeTool, SYSTEM_NOTICE_TOOL_NAMES } from "./approvalsShared";

describe("SYSTEM_NOTICE_TOOL_NAMES parity", () => {
  it("matches the engine's SystemNoticeTools registry exactly", () => {
    // The engine's closed registry files system notices under exactly these
    // tool names; the web list pins the same spellings so grouping and the
    // shared card key on the registry, never a name prefix or substring rule.
    expect(SYSTEM_NOTICE_TOOL_NAMES).toEqual(["sovereign.mismatch", "security.probe"]);
  });

  it("recognizes only registry names", () => {
    expect(isSystemNoticeTool("sovereign.mismatch")).toBe(true);
    expect(isSystemNoticeTool("security.probe")).toBe(true);
    // A lookalike name is an ordinary approval, not a notice.
    expect(isSystemNoticeTool("sovereign.mismatch.sequel")).toBe(false);
    expect(isSystemNoticeTool("security.probeX")).toBe(false);
    expect(isSystemNoticeTool("email.send")).toBe(false);
  });
});
