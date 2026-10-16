// Rune Weaver Dashboard — Unit tests for ChatSettingsModal.

import { describe, expect, it, vi } from "vitest";
import { render, screen, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import ChatSettingsModal from "./ChatSettingsModal";
import { DEFAULT_CHAT_SETTINGS, type ChatSettings } from "../chatSettings";

// The thinking and file write sections deliberately share option titles
// ("Collapsed by default" / "Expanded by default"), so tests resolve radios
// through their radiogroup instead of the dialog-wide name query.
function group(name: string): HTMLElement {
  return screen.getByRole("radiogroup", { name });
}

describe("ChatSettingsModal", () => {
  it("does not render when isOpen is false", () => {
    render(
      <ChatSettingsModal
        isOpen={false}
        onClose={vi.fn()}
        settings={DEFAULT_CHAT_SETTINGS}
        onUpdateSettings={vi.fn()}
        onResetSettings={vi.fn()}
      />
    );
    expect(screen.queryByRole("dialog", { name: "Chat Settings" })).toBeNull();
  });

  it("renders when isOpen is true with all options and controls", () => {
    render(
      <ChatSettingsModal
        isOpen={true}
        onClose={vi.fn()}
        settings={DEFAULT_CHAT_SETTINGS}
        onUpdateSettings={vi.fn()}
        onResetSettings={vi.fn()}
      />
    );

    const dialog = screen.getByRole("dialog", { name: "Chat Settings" });
    expect(dialog).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "Chat Settings" })).toBeInTheDocument();

    const thinkingGroup = group("Default thinking process display");
    expect(screen.getByText("Thinking Process")).toBeInTheDocument();
    expect(within(thinkingGroup).getByText("Collapsed by default")).toBeInTheDocument();
    expect(within(thinkingGroup).getByText("Expanded by default")).toBeInTheDocument();

    expect(screen.getByText("File Write Cards")).toBeInTheDocument();
    expect(
      screen.getByText(
        "Control whether files.write diff cards start expanded or collapsed in chat.",
      ),
    ).toBeInTheDocument();
    const fileWriteGroup = group("Default file write card display");
    expect(
      within(fileWriteGroup).getByText("Collapsed by default"),
    ).toBeInTheDocument();
    expect(
      within(fileWriteGroup).getByText("Expanded by default"),
    ).toBeInTheDocument();
    expect(
      within(fileWriteGroup).getByRole("radio", { name: /Collapsed by default/i }),
    ).toBeChecked();

    expect(screen.getByText("Send with Return")).toBeInTheDocument();
    expect(screen.getByText("Auto-scroll during response")).toBeInTheDocument();
  });

  it("calls onUpdateSettings when choosing expanded thinking", async () => {
    const user = userEvent.setup();
    const handleUpdate = vi.fn();

    render(
      <ChatSettingsModal
        isOpen={true}
        onClose={vi.fn()}
        settings={DEFAULT_CHAT_SETTINGS}
        onUpdateSettings={handleUpdate}
        onResetSettings={vi.fn()}
      />
    );

    const expandedRadio = within(
      group("Default thinking process display"),
    ).getByRole("radio", { name: /Expanded by default/i });
    await user.click(expandedRadio);

    expect(handleUpdate).toHaveBeenCalledWith({ thinkingDefault: "expanded" });
  });

  it("calls onUpdateSettings when choosing collapsed thinking", async () => {
    const user = userEvent.setup();
    const handleUpdate = vi.fn();
    const settings: ChatSettings = {
      ...DEFAULT_CHAT_SETTINGS,
      thinkingDefault: "expanded",
    };

    render(
      <ChatSettingsModal
        isOpen={true}
        onClose={vi.fn()}
        settings={settings}
        onUpdateSettings={handleUpdate}
        onResetSettings={vi.fn()}
      />
    );

    const collapsedRadio = within(
      group("Default thinking process display"),
    ).getByRole("radio", { name: /Collapsed by default/i });
    await user.click(collapsedRadio);

    expect(handleUpdate).toHaveBeenCalledWith({ thinkingDefault: "collapsed" });
  });

  it("calls onUpdateSettings when choosing expanded file write cards", async () => {
    const user = userEvent.setup();
    const handleUpdate = vi.fn();

    render(
      <ChatSettingsModal
        isOpen={true}
        onClose={vi.fn()}
        settings={DEFAULT_CHAT_SETTINGS}
        onUpdateSettings={handleUpdate}
        onResetSettings={vi.fn()}
      />
    );

    const expandedRadio = within(
      group("Default file write card display"),
    ).getByRole("radio", { name: /Expanded by default/i });
    await user.click(expandedRadio);

    expect(handleUpdate).toHaveBeenCalledWith({ fileWriteDefault: "expanded" });
  });

  it("calls onUpdateSettings when choosing collapsed file write cards", async () => {
    const user = userEvent.setup();
    const handleUpdate = vi.fn();
    const settings: ChatSettings = {
      ...DEFAULT_CHAT_SETTINGS,
      fileWriteDefault: "expanded",
    };

    render(
      <ChatSettingsModal
        isOpen={true}
        onClose={vi.fn()}
        settings={settings}
        onUpdateSettings={handleUpdate}
        onResetSettings={vi.fn()}
      />
    );

    const collapsedRadio = within(
      group("Default file write card display"),
    ).getByRole("radio", { name: /Collapsed by default/i });
    await user.click(collapsedRadio);

    expect(handleUpdate).toHaveBeenCalledWith({ fileWriteDefault: "collapsed" });
  });

  it("toggles sendOnEnter switch", async () => {
    const user = userEvent.setup();
    const handleUpdate = vi.fn();

    render(
      <ChatSettingsModal
        isOpen={true}
        onClose={vi.fn()}
        settings={DEFAULT_CHAT_SETTINGS}
        onUpdateSettings={handleUpdate}
        onResetSettings={vi.fn()}
      />
    );

    const toggle = screen.getByRole("checkbox", {
      name: "Send message on Return",
    });
    await user.click(toggle);

    expect(handleUpdate).toHaveBeenCalledWith({ sendOnEnter: false });
  });

  it("toggles autoScrollOnStream switch", async () => {
    const user = userEvent.setup();
    const handleUpdate = vi.fn();

    render(
      <ChatSettingsModal
        isOpen={true}
        onClose={vi.fn()}
        settings={DEFAULT_CHAT_SETTINGS}
        onUpdateSettings={handleUpdate}
        onResetSettings={vi.fn()}
      />
    );

    const toggle = screen.getByRole("checkbox", {
      name: "Auto-scroll during response generation",
    });
    await user.click(toggle);

    expect(handleUpdate).toHaveBeenCalledWith({ autoScrollOnStream: false });
  });

  it("triggers onResetSettings when clicking Reset to defaults", async () => {
    const user = userEvent.setup();
    const handleReset = vi.fn();

    render(
      <ChatSettingsModal
        isOpen={true}
        onClose={vi.fn()}
        settings={{
          thinkingDefault: "expanded",
          fileWriteDefault: "expanded",
          sendOnEnter: false,
          autoScrollOnStream: false,
        }}
        onUpdateSettings={vi.fn()}
        onResetSettings={handleReset}
      />
    );

    const resetBtn = screen.getByRole("button", {
      name: "Reset to defaults",
    });
    await user.click(resetBtn);

    expect(handleReset).toHaveBeenCalledTimes(1);
  });

  it("closes modal on Done button or Close icon", async () => {
    const user = userEvent.setup();
    const handleClose = vi.fn();

    const { rerender } = render(
      <ChatSettingsModal
        isOpen={true}
        onClose={handleClose}
        settings={DEFAULT_CHAT_SETTINGS}
        onUpdateSettings={vi.fn()}
        onResetSettings={vi.fn()}
      />
    );

    const doneBtn = screen.getByRole("button", { name: "Close chat settings" });
    await user.click(doneBtn);
    expect(handleClose).toHaveBeenCalledTimes(1);

    rerender(
      <ChatSettingsModal
        isOpen={true}
        onClose={handleClose}
        settings={DEFAULT_CHAT_SETTINGS}
        onUpdateSettings={vi.fn()}
        onResetSettings={vi.fn()}
      />
    );

    const closeIconBtn = screen.getByRole("button", { name: "Close settings" });
    await user.click(closeIconBtn);
    expect(handleClose).toHaveBeenCalledTimes(2);
  });
});
