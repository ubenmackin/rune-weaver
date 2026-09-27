// Rune Weaver Dashboard — Live grapheme buffer matrix for streaming Markdown.
//
// Covers split emoji across deltas, ZWJ family holds, Segmenter-absent
// fallback with zero loss, empty text rendering null, and done convergence
// so the live bubble and the terminal bubble agree through MarkdownText.

import React from "react";
import { render } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { appendLiveDelta } from "./liveTextBuffer";
import MarkdownText from "./MarkdownText";

describe("appendLiveDelta", () => {
  it("commits plain prose immediately with empty held and zero loss", () => {
    const before = { committed: "", held: "" };
    const delta = "Hello! What's up?";
    const next = appendLiveDelta(before.committed, before.held, delta);
    expect(next.committed).toBe("Hello! What's up?");
    expect(next.held).toBe("");
    expect(next.committed + next.held).toBe(
      before.committed + before.held + delta,
    );
  });

  it("holds a split emoji across two deltas with zero loss", () => {
    const high = "Hello! What's up? \uD83D";
    const low = "\uDE0A";
    const first = appendLiveDelta("", "", high);
    expect(first.committed).toBe("Hello! What's up? ");
    expect(first.held).toBe("\uD83D");
    expect(first.committed + first.held).toBe(high);
    const second = appendLiveDelta(first.committed, first.held, low);
    expect(second.committed).toBe("Hello! What's up? \uD83D\uDE0A");
    expect(second.held).toBe("");
    expect(second.committed + second.held).toBe(high + low);
  });

  it("holds a ZWJ family prefix ending in a joiner until complete", () => {
    const head = "\uD83D\uDC68\u200D";
    const tail =
      "\uD83D\uDC69\u200D\uD83D\uDC67\u200D\uD83D\uDC66";
    const full = head + tail;
    const first = appendLiveDelta("", "", head);
    expect(first.held.length).toBeGreaterThan(0);
    expect(first.committed + first.held).toBe(head);
    expect(first.committed).not.toBe(full);
    const second = appendLiveDelta(first.committed, first.held, tail);
    expect(second.committed).toBe(full);
    expect(second.held).toBe("");
    expect(second.committed + second.held).toBe(full);
  });

  it("holds a lone regional indicator until its flag partner arrives", () => {
    const firstHalf = "\uD83C\uDDFA";
    const secondHalf = "\uD83C\uDDF8";
    const first = appendLiveDelta("", "", firstHalf);
    expect(first.held).toBe(firstHalf);
    expect(first.committed).toBe("");
    const second = appendLiveDelta(first.committed, first.held, secondHalf);
    expect(second.committed).toBe(firstHalf + secondHalf);
    expect(second.held).toBe("");
    expect(second.committed + second.held).toBe(firstHalf + secondHalf);
  });

  it("falls back to code-point append with empty held when Segmenter is absent", () => {
    const scope = Intl as unknown as { Segmenter?: unknown };
    const original = scope.Segmenter;
    scope.Segmenter = undefined;
    try {
      const delta = "Hello \uD83D";
      const next = appendLiveDelta("", "", delta);
      expect(next.held).toBe("");
      expect(next.committed).toBe(delta);
      expect(next.committed + next.held).toBe(delta);
      const emojiTail = "\uDE0A world";
      const after = appendLiveDelta(next.committed, next.held, emojiTail);
      expect(after.held).toBe("");
      expect(after.committed).toBe(delta + emojiTail);
    } finally {
      scope.Segmenter = original;
    }
  });

  it("keeps held to at most one trailing cluster on prose tails", () => {
    const next = appendLiveDelta("Hi ", "", "there friend");
    expect(next.held).toBe("");
    expect(next.committed).toBe("Hi there friend");
  });

  it("renders empty text as null through MarkdownText", () => {
    const { container } = render(
      React.createElement(MarkdownText, { text: "" }),
    );
    expect(container.firstChild).toBeNull();
  });

  it("shows the partial sentence first and the full sentence plus emoji after the second delta", () => {
    const high = "Hello! What's up? \uD83D";
    const low = "\uDE0A";
    const first = appendLiveDelta("", "", high);
    const partial = render(
      React.createElement(MarkdownText, { text: first.committed }),
    );
    expect(partial.container.textContent).toContain("Hello! What's up?");
    expect(partial.container.textContent).not.toContain("\uD83D\uDE0A");
    const second = appendLiveDelta(first.committed, first.held, low);
    const full = render(
      React.createElement(MarkdownText, { text: second.committed }),
    );
    expect(full.container.textContent).toContain("Hello! What's up?");
    expect(full.container.textContent).toContain("\uD83D\uDE0A");
  });

  it("converges live committed text to the terminal done text", () => {
    const doneText = "Hello! What's up? \uD83D\uDE0A";
    const first = appendLiveDelta("", "", "Hello! What's up? \uD83D");
    const second = appendLiveDelta(first.committed, first.held, "\uDE0A");
    const liveFull = second.committed + second.held;
    expect(liveFull).toBe(doneText);
    const liveRendered = render(
      React.createElement(MarkdownText, { text: second.committed }),
    );
    const doneRendered = render(
      React.createElement(MarkdownText, { text: doneText }),
    );
    expect(liveRendered.container.textContent).toBe(
      doneRendered.container.textContent,
    );
  });
});
