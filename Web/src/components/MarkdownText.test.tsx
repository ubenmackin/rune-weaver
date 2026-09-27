import { render } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import MarkdownText from "./MarkdownText";

describe("MarkdownText", () => {
  it("renders bold text using strong elements", () => {
    const { container } = render(
      <MarkdownText text="The most recent email is from **Ben Mackin**." />
    );
    const strong = container.querySelector("strong");
    expect(strong).not.toBeNull();
    expect(strong?.textContent).toBe("Ben Mackin");
    expect(container.textContent).toContain("The most recent email is from Ben Mackin.");
  });

  it("renders italic and bold-italic text", () => {
    const { container } = render(
      <MarkdownText text="Here is *italic* and ***bold-italic*** text." />
    );
    const em = container.querySelector("em");
    expect(em).not.toBeNull();
    expect(em?.textContent).toBe("italic");

    const boldItalic = container.querySelector("em strong, strong em");
    expect(boldItalic).not.toBeNull();
    expect(boldItalic?.textContent).toBe("bold-italic");
  });

  it("renders inline code", () => {
    const { container } = render(
      <MarkdownText text="Run `make test` to verify." />
    );
    const code = container.querySelector("code.chat-inline-code");
    expect(code).not.toBeNull();
    expect(code?.textContent).toBe("make test");
  });

  it("renders fenced code blocks", () => {
    const codeSample = "```typescript\nconst greeting = 'hello';\nconsole.log(greeting);\n```";
    const { container } = render(<MarkdownText text={codeSample} />);
    const pre = container.querySelector("pre.chat-code-block");
    expect(pre).not.toBeNull();
    expect(pre?.textContent).toContain("const greeting = 'hello';");
    expect(container.querySelector(".chat-code-lang-tag")?.textContent).toBe("typescript");
  });

  it("renders unordered and ordered lists", () => {
    const listSample = "- Apple\n- Banana\n- Cherry\n\n1. First\n2. Second";
    const { container } = render(<MarkdownText text={listSample} />);
    const ul = container.querySelector("ul.chat-ul");
    expect(ul).not.toBeNull();
    expect(ul?.querySelectorAll("li").length).toBe(3);

    const ol = container.querySelector("ol.chat-ol");
    expect(ol).not.toBeNull();
    expect(ol?.querySelectorAll("li").length).toBe(2);
  });

  it("renders safe links and ignores unsafe ones", () => {
    const linkSample = "Check out [Rune](https://example.com) and [Bad](javascript:alert(1)).";
    const { container } = render(<MarkdownText text={linkSample} />);
    const links = container.querySelectorAll("a");
    expect(links.length).toBe(1);
    expect(links[0].getAttribute("href")).toBe("https://example.com");
    expect(links[0].textContent).toBe("Rune");
    expect(container.querySelector('a[href^="javascript:"]')).toBeNull();
    expect(container.textContent).toContain("[Bad]");
    expect(container.textContent).not.toContain("javascript:");
  });

  it("normalizes safe URLs when rendering anchor hrefs", () => {
    const linkSample = "Visit [Link](https://example.com/test?a=1&amp;b=2).";
    const { container } = render(<MarkdownText text={linkSample} />);
    const link = container.querySelector("a");
    expect(link).not.toBeNull();
    expect(link?.getAttribute("href")).toBe("https://example.com/test?a=1&b=2");
  });

  it("renders headings", () => {
    const { container } = render(
      <MarkdownText text={"# Title\n## Subtitle\n### Section"} />
    );
    expect(container.querySelector("h3")?.textContent).toBe("Title");
    expect(container.querySelector("h4")?.textContent).toBe("Subtitle");
    expect(container.querySelector("h5")?.textContent).toBe("Section");
  });

  it("renders blockquotes", () => {
    const { container } = render(
      <MarkdownText text="> Important note from agent." />
    );
    const bq = container.querySelector("blockquote.chat-blockquote");
    expect(bq).not.toBeNull();
    expect(bq?.textContent?.trim()).toBe("Important note from agent.");
  });

  it("renders horizontal rules (divider lines)", () => {
    const { container } = render(
      <MarkdownText text={"First section\n\n---\n\nSecond section"} />
    );
    const hr = container.querySelector("hr.chat-hr");
    expect(hr).not.toBeNull();
    expect(container.textContent).toContain("First section");
    expect(container.textContent).toContain("Second section");
  });

  it("renders email summary markdown tables and divider lines", () => {
    const tableSample = `---
| Account | Total Unread | VIP / Priority | Flagged |
| -+-+-+- |
| **Volcrypt** (\`bmackin@volcrypt.com\`) | **10** | 0 | 0 |
| **iCloud** (\`bmackin@mac.com\`) | **3** | 0 | 0 |
---`;

    const { container } = render(<MarkdownText text={tableSample} />);

    // Checks divider lines
    const hrs = container.querySelectorAll("hr.chat-hr");
    expect(hrs.length).toBe(2);

    // Checks table structure
    const table = container.querySelector("table.chat-table");
    expect(table).not.toBeNull();

    // Checks table headers
    const ths = container.querySelectorAll("th");
    expect(ths.length).toBe(4);
    expect(ths[0].textContent).toBe("Account");
    expect(ths[1].textContent).toBe("Total Unread");
    expect(ths[2].textContent).toBe("VIP / Priority");
    expect(ths[3].textContent).toBe("Flagged");

    // Checks table rows and data cells
    const rows = container.querySelectorAll("tbody tr");
    expect(rows.length).toBe(2);

    const firstRowCells = rows[0].querySelectorAll("td");
    expect(firstRowCells.length).toBe(4);
    expect(firstRowCells[0].querySelector("strong")?.textContent).toBe("Volcrypt");
    expect(firstRowCells[0].querySelector("code")?.textContent).toBe("bmackin@volcrypt.com");
    expect(firstRowCells[1].querySelector("strong")?.textContent).toBe("10");
    expect(firstRowCells[2].textContent).toBe("0");
    expect(firstRowCells[3].textContent).toBe("0");

    const secondRowCells = rows[1].querySelectorAll("td");
    expect(secondRowCells.length).toBe(4);
    expect(secondRowCells[0].querySelector("strong")?.textContent).toBe("iCloud");
    expect(secondRowCells[0].querySelector("code")?.textContent).toBe("bmackin@mac.com");
    expect(secondRowCells[1].querySelector("strong")?.textContent).toBe("3");
  });

  it("renders GFM table column alignment", () => {
    const alignedSample = `| Left | Center | Right |
| :--- | :---: | ---: |
| Alpha | Beta | Gamma |`;

    const { container } = render(<MarkdownText text={alignedSample} />);
    const ths = container.querySelectorAll("th");
    expect(ths[0].style.textAlign).toBe("left");
    expect(ths[1].style.textAlign).toBe("center");
    expect(ths[2].style.textAlign).toBe("right");

    const tds = container.querySelectorAll("td");
    expect(tds[0].style.textAlign).toBe("left");
    expect(tds[1].style.textAlign).toBe("center");
    expect(tds[2].style.textAlign).toBe("right");
  });

  it("handles null or empty text gracefully", () => {
    const { container } = render(<MarkdownText text="" />);
    expect(container.firstChild).toBeNull();
  });

  it("preserves paragraph node identity across same-text parent re-renders", () => {
    // Same text plus styling skips the subtree so background refreshes keep nodes.
    function Wrapper({ tick }: { tick: number }) {
      void tick;
      return <MarkdownText text={"First line\n\nSecond line"} />;
    }
    const { container, rerender } = render(<Wrapper tick={0} />);
    const before = container.querySelector("p.chat-p");
    expect(before).not.toBeNull();
    rerender(<Wrapper tick={1} />);
    const after = container.querySelector("p.chat-p");
    expect(after).toBe(before);
    rerender(<Wrapper tick={2} />);
    expect(container.querySelector("p.chat-p")).toBe(before);
  });

  it("updates only the changed bubble when one text changes", () => {
    // Changed text re-renders its bubble while the sibling keeps DOM identity.
    const { container, rerender } = render(
      <div>
        <div data-testid="bubble-a">
          <MarkdownText text="Alpha bubble" />
        </div>
        <div data-testid="bubble-b">
          <MarkdownText text="Beta bubble" />
        </div>
      </div>,
    );
    const bubbleB = container.querySelector(
      '[data-testid="bubble-b"] p.chat-p',
    );
    expect(bubbleB?.textContent).toBe("Beta bubble");
    rerender(
      <div>
        <div data-testid="bubble-a">
          <MarkdownText text="Alpha bubble changed" />
        </div>
        <div data-testid="bubble-b">
          <MarkdownText text="Beta bubble" />
        </div>
      </div>,
    );
    const afterA = container.querySelector(
      '[data-testid="bubble-a"] p.chat-p',
    );
    const afterB = container.querySelector(
      '[data-testid="bubble-b"] p.chat-p',
    );
    expect(afterA?.textContent).toBe("Alpha bubble changed");
    expect(afterB?.textContent).toBe("Beta bubble");
    expect(afterB).toBe(bubbleB);
  });

  it("renders all hoisted element types with bubble styling", () => {
    // Each renderer maps to its bubble class without extra wrappers.
    const sample = [
      "# Title",
      "## Subtitle",
      "### Section",
      "",
      "Body paragraph.",
      "",
      "> Quoted note.",
      "",
      "- one",
      "- two",
      "",
      "1. first",
      "2. second",
      "",
      "---",
      "",
      "| A | B |",
      "| --- | --- |",
      "| 1 | 2 |",
      "",
      "[Ok](https://example.com)",
      "",
      "![photo](https://example.com/img.png)",
    ].join("\n");
    const { container } = render(<MarkdownText text={sample} />);
    expect(
      container.querySelector("div.chat-table-wrapper table.chat-table"),
    ).not.toBeNull();
    expect(container.querySelector("hr.chat-hr")).not.toBeNull();
    const link = container.querySelector("a.chat-markdown-link");
    expect(link).not.toBeNull();
    expect(link?.getAttribute("href")).toBe("https://example.com");
    expect(link?.getAttribute("target")).toBe("_blank");
    expect(link?.getAttribute("rel")).toBe("noopener noreferrer");
    const img = container.querySelector(
      "img.chat-markdown-img",
    ) as HTMLImageElement | null;
    expect(img).not.toBeNull();
    expect(img?.getAttribute("src")).toBe("https://example.com/img.png");
    expect(container.querySelector("h3.chat-h3")?.textContent).toBe("Title");
    expect(container.querySelector("h4.chat-h4")?.textContent).toBe(
      "Subtitle",
    );
    expect(container.querySelector("h5.chat-h5")?.textContent).toBe("Section");
    expect(
      container.querySelector("blockquote.chat-blockquote"),
    ).not.toBeNull();
    expect(container.querySelector("ul.chat-ul")).not.toBeNull();
    expect(container.querySelector("ol.chat-ol")).not.toBeNull();
    expect(container.querySelector("p.chat-p")).not.toBeNull();
  });

  it("rejects camouflaged and unsafe schemes with inert fallback", () => {
    // Fail-closed gate blocks hidden javascript, data, vbscript, and relatives.
    const blocked = [
      "[a](javascript:alert(1))",
      "[b](JaVaScRiPt:alert(1))",
      "[c](java\tscript:alert(1))",
      "[d](%6Aavascript:alert(1))",
      "[e](javascript&#58;alert(1))",
      "[f](java/**/script:alert(1))",
      "[g](data:text/html;base64,PGI+) ",
      "[h](vbscript:msgbox(1))",
      "[i](//evil.example.com/x)",
      "[j](\\\\evil.example.com\\x)",
      "[k](http:foo)",
      "[l](mailto:nobody)",
      "[m](mailto:a@b.com<script>)",
    ].join(" ");
    const { container } = render(<MarkdownText text={blocked} />);
    expect(container.querySelectorAll("a").length).toBe(0);
    expect(container.querySelector('a[href^="javascript:"]')).toBeNull();
    expect(container.textContent).not.toContain("javascript:");
    expect(container.textContent).not.toContain("data:text");
    expect(container.textContent).not.toContain("//evil.example.com");
  });

  it("renders blocked links as inert text and blocked images as alt only", () => {
    // Blocked URIs never reach href or src attributes.
    const { container } = render(
      <MarkdownText
        text={'[Bad](javascript:alert(1)) ![alt photo](javascript:alert(1))'}
      />,
    );
    expect(container.querySelectorAll("a").length).toBe(0);
    expect(container.querySelectorAll("img").length).toBe(0);
    expect(container.textContent).toContain("[Bad]");
    expect(container.textContent).toContain("alt photo");
    expect(container.textContent).not.toContain("javascript:");
  });

  it("allows valid mailto and hierarchical http links", () => {
    // Valid contact and web links keep their normalized href.
    const { container } = render(
      <MarkdownText
        text={
          "[Mail](mailto:ops@example.com) [Web](https://example.com/a?b=1)"
        }
      />,
    );
    const links = container.querySelectorAll("a.chat-markdown-link");
    expect(links.length).toBe(2);
    expect(links[0].getAttribute("href")).toBe("mailto:ops@example.com");
    expect(links[1].getAttribute("href")).toBe("https://example.com/a?b=1");
  });
});
