// Rune Weaver Dashboard — Tests pinning the inline approval banner's allow
// options to the shared trust-duration tiers.

import { describe, expect, it } from "vitest";
import { splitAllowOptions } from "./InlineApprovalBanner";
import { trustDurationOptions } from "../api";

describe("InlineApprovalBanner allow options", () => {
  it("mirrors every shared trust duration in the base option set", () => {
    const base = splitAllowOptions.filter((option) => !option.widen);
    // Base values and labels must come from trustDurationOptions verbatim so a
    // new or renamed tier can never be omitted from the inline banner while
    // the inbox and engine still offer it.
    expect(base.map((option) => option.value)).toEqual(
      trustDurationOptions.map((option) => option.value),
    );
    for (const tier of trustDurationOptions) {
      expect(base.find((option) => option.value === tier.value)?.label).toBe(
        tier.label,
      );
    }
  });

  it("offers an all-targets variant for every non-one-shot tier", () => {
    const widen = splitAllowOptions.filter((option) => option.widen);
    // The one-shot `thisTime` grant persists nothing, so it must never appear
    // as a widenable option; every other tier gets exactly one widen variant.
    const expected = trustDurationOptions.filter(
      (option) => option.value !== "thisTime",
    );
    expect(widen.map((option) => option.value)).toEqual(
      expected.map((option) => option.value),
    );
    for (const tier of expected) {
      expect(widen.find((option) => option.value === tier.value)?.label).toBe(
        `${tier.label} (all targets)`,
      );
    }
  });
});
