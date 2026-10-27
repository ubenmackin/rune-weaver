// Rune Weaver Dashboard — Tests for the universal help infotip.

import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it } from "vitest";
import InfoTip from "./InfoTip";

describe("InfoTip", () => {
  afterEach(() => {
    cleanup();
    document.body.innerHTML = "";
  });

  it("shows the bubble on hover with tokenized portal styling", () => {
    render(<InfoTip text="Helper copy" />);
    fireEvent.mouseEnter(screen.getByRole("button"));
    const bubble = document.body.querySelector(".infotip-bubble");
    expect(bubble).not.toBeNull();
    expect(bubble).toHaveTextContent("Helper copy");
    expect(screen.getByRole("button")).toHaveAttribute(
      "aria-describedby",
      bubble?.getAttribute("id"),
    );
  });

  it("shows the bubble on keyboard focus", () => {
    render(<InfoTip text="Helper copy" />);
    fireEvent.focus(screen.getByRole("button"));
    expect(document.body.querySelector(".infotip-bubble")).not.toBeNull();
  });

  it("toggles on click and hides on Escape", () => {
    render(<InfoTip text="Helper copy" />);
    const trigger = screen.getByRole("button");
    fireEvent.click(trigger);
    expect(document.body.querySelector(".infotip-bubble")).not.toBeNull();
    fireEvent.keyDown(document, { key: "Escape" });
    expect(document.body.querySelector(".infotip-bubble")).toBeNull();
  });

  it("renders no native tooltip attribute", () => {
    render(<InfoTip text="Helper copy" />);
    fireEvent.mouseEnter(screen.getByRole("button"));
    expect(screen.getByRole("button").hasAttribute("title")).toBe(false);
    expect(document.body.querySelector(".infotip-bubble")?.hasAttribute("title")).toBe(false);
  });
});
