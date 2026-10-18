// Rune Weaver Dashboard — Robust Markdown renderer for chat messages and run audits.

import React, { createContext, useContext } from "react";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";

interface MarkdownTextProps {
  text: string;
  className?: string;
}

const PreContext = createContext(false);

type CodeProps = React.ComponentPropsWithoutRef<"code">;
type PreProps = React.ComponentPropsWithoutRef<"pre">;

// Named components keep hook usage out of the inline `components` map: `MarkdownCode` reads
// `PreContext` to tell fenced blocks apart from inline snippets, and stable identities avoid
// remount churn on every render of the parent message.
function CodeBlock({ className, children, ...props }: CodeProps) {
  return (
    <code className={className} {...props}>
      {children}
    </code>
  );
}

function InlineCode({ children, ...props }: CodeProps) {
  return (
    <code className="chat-inline-code" {...props}>
      {children}
    </code>
  );
}

function MarkdownCode(props: CodeProps) {
  const isInsidePre = useContext(PreContext);
  if (isInsidePre) {
    return <CodeBlock {...props} />;
  }
  return <InlineCode {...props} />;
}

function MarkdownPre({ children, ...props }: PreProps) {
  let lang: string | undefined;
  if (React.isValidElement(children)) {
    const codeProps = children.props as { className?: string };
    const match = /language-([\w#+.-]+)/.exec(codeProps.className || "");
    if (match) {
      lang = match[1];
    }
  }
  return (
    <div className="chat-code-block-wrapper">
      {lang ? <div className="chat-code-lang-tag">{lang}</div> : null}
      <pre className="chat-code-block" {...props}>
        <PreContext.Provider value={true}>{children}</PreContext.Provider>
      </pre>
    </div>
  );
}

/** Normalizes informal table delimiter lines to standard GFM delimiters. */
function normalizeMarkdown(text: string): string {
  // Separate divider lines from tables if directly adjacent to prevent setext heading interpretation
  const separated = text.replace(/(\|[\r\n]+)(---+|\*\*\*+|___+)/g, "$1\n$2");
  const lines = separated.split(/\r?\n/);
  for (let i = 0; i < lines.length - 1; i++) {
    const current = lines[i];
    const next = lines[i + 1];

    if (current.includes("|") && /^[\s|:\-+]+$/.test(next) && /[-+]{2,}/.test(next)) {
      const headerCols = current
        .trim()
        .replace(/^\|/, "")
        .replace(/\|$/, "")
        .split("|").length;

      const nextTrimmed = next.trim();
      const nextCells = nextTrimmed
        .replace(/^\|/, "")
        .replace(/\|$/, "")
        .split("|")
        .map((c) => c.trim());

      if (nextCells.length < headerCols || nextTrimmed.includes("+")) {
        const standardDelim = Array(headerCols).fill("---").join(" | ");
        lines[i + 1] = `| ${standardDelim} |`;
      }
    }
  }
  return lines.join("\n");
}

// Blocked schemes stay blocked even when attackers hide them with tab/newline/null smuggling,
// percent-encoding, HTML entities, or comment splicing, so every check runs on a camouflage-
// stripped copy while the allowlist (secure web, validated mail, local navigation) decides.
function decodeUrlEntities(value: string): string {
  let out = value.replace(/&#x([0-9a-fA-F]+);?/g, (_match: string, hex: string) => {
    const code = parseInt(hex, 16);
    return Number.isNaN(code) ? _match : String.fromCharCode(code);
  });
  out = out.replace(/&#([0-9]+);?/g, (_match: string, dec: string) => {
    const code = parseInt(dec, 10);
    return Number.isNaN(code) ? _match : String.fromCharCode(code);
  });
  out = out.replace(/&(colon|tab|newline|linefeed|sol|slash|semi|amp|lt|gt|quot);?/gi, (entity: string) => {
    switch (entity.toLowerCase().replace(/;$/, "")) {
      case "&colon":
        return ":";
      case "&tab":
        return "\t";
      case "&newline":
      case "&linefeed":
        return "\n";
      case "&sol":
      case "&slash":
        return "/";
      case "&semi":
        return ";";
      case "&amp":
        return "&";
      case "&lt":
        return "<";
      case "&gt":
        return ">";
      case "&quot":
        return '"';
      default:
        return entity;
    }
  });
  return out;
}

// Strips the hiding layers browsers ignore so `java\tscript:`, `%6Aavascript:`, `&#58;`, and
// `java/**/script:` all surface as the same blocked scheme before the allowlist decides.
function normalizeUrlForCheck(raw: string): string {
  let working = raw.trim().replace(/\/\*.*?\*\//g, "");
  working = decodeUrlEntities(working);
  for (let i = 0; i < 5; i++) {
    let decoded: string;
    try {
      decoded = decodeURIComponent(working);
    } catch {
      break;
    }
    if (decoded === working) break;
    working = decodeUrlEntities(decoded.replace(/\/\*.*?\*\//g, ""));
  }
  return working.replace(/[\u0000-\u0020\u007F]+/g, "");
}

function isSafeUrl(url?: string): boolean {
  if (!url) return false;
  const normalized = normalizeUrlForCheck(url);
  if (!normalized) return false;
  // Browsers normalize backslashes to slashes, so any decoded backslash is a
  // protocol-relative or scheme camouflage and fails closed.
  if (normalized.includes("\\")) return false;
  if (normalized.startsWith("//") || normalized.startsWith("\\\\")) return false;
  const lower = normalized.toLowerCase();
  const schemeMatch = /^[a-zA-Z][a-zA-Z0-9+.-]*:/.exec(normalized);
  // No scheme means local dashboard navigation (`page`, `./page`,
  // `../page`, `?x=1`, `#fragment`, `/path`) with no protocol to abuse.
  if (!schemeMatch) return true;
  const scheme = schemeMatch[0].toLowerCase();
  if (scheme === "http:" || scheme === "https:") {
    // Require the hierarchical form so `http:foo` tricks never pass on
    // scheme prefix alone; the URL parse below confirms a real web origin.
    if (!lower.startsWith("http://") && !lower.startsWith("https://")) return false;
    try {
      const parsed = new URL(normalized);
      return parsed.protocol === "http:" || parsed.protocol === "https:";
    } catch {
      return false;
    }
  }
  if (scheme === "mailto:") {
    // Keep `mailto:` usable for contact links without letting it smuggle
    // another scheme or markup: an address with `@` and no nested scheme
    // or angle-bracket payload.
    const rest = normalized.slice("mailto:".length);
    if (!rest) return false;
    const address = rest.split("?")[0];
    if (!address || !address.includes("@")) return false;
    if (address.includes(":")) return false;
    if (/[<>"']/.test(address) || /[<>"']/.test(rest)) return false;
    return true;
  }
  return false;
}

// Wraps tables so wide content scrolls inside the bubble.
function MarkdownTable({ children, ...props }: React.ComponentPropsWithoutRef<"table"> & { node?: unknown }) {
  void props.node;
  const { node: _node, ...rest } = props as React.ComponentPropsWithoutRef<"table"> & { node?: unknown };
  void _node;
  return (
    <div className="chat-table-wrapper">
      <table className="chat-table" {...rest}>
        {children}
      </table>
    </div>
  );
}

// Renders dividers with bubble styling.
function MarkdownHr(props: React.ComponentPropsWithoutRef<"hr"> & { node?: unknown }) {
  const { node: _node, ...rest } = props;
  void _node;
  return <hr className="chat-hr" {...rest} />;
}

// Renders safe links in a new tab and inert text for blocked URIs.
function MarkdownLink({ href, children, ...props }: React.ComponentPropsWithoutRef<"a"> & { node?: unknown }) {
  const { node: _node, ...rest } = props as React.ComponentPropsWithoutRef<"a"> & { node?: unknown };
  void _node;
  if (!href || !isSafeUrl(href)) {
    // Blocked links render as inert text without the raw URI so an
    // attacker URI never reaches the DOM or the readable text.
    return <span>[{children}]</span>;
  }
  const safeHref = normalizeUrlForCheck(href);
  return (
    <a
      href={safeHref}
      target="_blank"
      rel="noopener noreferrer"
      className="chat-markdown-link"
      {...rest}
    >
      {children}
    </a>
  );
}

// Renders safe images and alt-only fallback for blocked sources.
function MarkdownImage({ src, alt, ...props }: React.ComponentPropsWithoutRef<"img"> & { node?: unknown }) {
  const { node: _node, ...rest } = props as React.ComponentPropsWithoutRef<"img"> & { node?: unknown };
  void _node;
  if (!src || !isSafeUrl(src)) {
    // Blocked images render alt text only so an unsafe source URI
    // never reaches the DOM or the readable text.
    return <span>[Image: {alt || "Blocked image"}]</span>;
  }
  const safeSrc = normalizeUrlForCheck(src);
  return <img src={safeSrc} alt={alt} className="chat-markdown-img" {...rest} />;
}

// Steps headings down so chat titles stay below the app header.
function MarkdownH1({ children, ...props }: React.ComponentPropsWithoutRef<"h1"> & { node?: unknown }) {
  const { node: _node, ...rest } = props as React.ComponentPropsWithoutRef<"h1"> & { node?: unknown };
  void _node;
  return <h3 className="chat-h3" {...rest}>{children}</h3>;
}

// Steps headings down so chat titles stay below the app header.
function MarkdownH2({ children, ...props }: React.ComponentPropsWithoutRef<"h2"> & { node?: unknown }) {
  const { node: _node, ...rest } = props as React.ComponentPropsWithoutRef<"h2"> & { node?: unknown };
  void _node;
  return <h4 className="chat-h4" {...rest}>{children}</h4>;
}

// Steps headings down so chat titles stay below the app header.
function MarkdownH3({ children, ...props }: React.ComponentPropsWithoutRef<"h3"> & { node?: unknown }) {
  const { node: _node, ...rest } = props as React.ComponentPropsWithoutRef<"h3"> & { node?: unknown };
  void _node;
  return <h5 className="chat-h5" {...rest}>{children}</h5>;
}

// Renders quotes with bubble styling.
function MarkdownBlockquote({ children, ...props }: React.ComponentPropsWithoutRef<"blockquote"> & { node?: unknown }) {
  const { node: _node, ...rest } = props as React.ComponentPropsWithoutRef<"blockquote"> & { node?: unknown };
  void _node;
  return (
    <blockquote className="chat-blockquote" {...rest}>
      {children}
    </blockquote>
  );
}

// Renders bulleted lists with bubble styling.
function MarkdownUl({ children, ...props }: React.ComponentPropsWithoutRef<"ul"> & { node?: unknown }) {
  const { node: _node, ...rest } = props as React.ComponentPropsWithoutRef<"ul"> & { node?: unknown };
  void _node;
  return (
    <ul className="chat-ul" {...rest}>
      {children}
    </ul>
  );
}

// Renders numbered lists with bubble styling.
function MarkdownOl({ children, ...props }: React.ComponentPropsWithoutRef<"ol"> & { node?: unknown }) {
  const { node: _node, ...rest } = props as React.ComponentPropsWithoutRef<"ol"> & { node?: unknown };
  void _node;
  return (
    <ol className="chat-ol" {...rest}>
      {children}
    </ol>
  );
}

// Renders paragraphs with bubble styling.
function MarkdownParagraph({ children, ...props }: React.ComponentPropsWithoutRef<"p"> & { node?: unknown }) {
  const { node: _node, ...rest } = props as React.ComponentPropsWithoutRef<"p"> & { node?: unknown };
  void _node;
  return (
    <p className="chat-p" {...rest}>
      {children}
    </p>
  );
}

// Shared renderer map with stable identities so background refreshes keep DOM nodes.
const markdownComponents = {
  table: MarkdownTable,
  hr: MarkdownHr,
  pre: MarkdownPre,
  code: MarkdownCode,
  a: MarkdownLink,
  img: MarkdownImage,
  h1: MarkdownH1,
  h2: MarkdownH2,
  h3: MarkdownH3,
  blockquote: MarkdownBlockquote,
  ul: MarkdownUl,
  ol: MarkdownOl,
  p: MarkdownParagraph,
};

// Skips re-render when text and styling match so selections survive refreshes.
function areMarkdownPropsEqual(prev: MarkdownTextProps, next: MarkdownTextProps): boolean {
  return prev.text === next.text && prev.className === next.className;
}

function MarkdownText({
  text,
  className = "markdown-content",
}: MarkdownTextProps) {
  if (!text) return null;

  const preparedText = normalizeMarkdown(text);

  return (
    <div className={className}>
      <ReactMarkdown
        remarkPlugins={[remarkGfm]}
        components={markdownComponents}
      >
        {preparedText}
      </ReactMarkdown>
    </div>
  );
}

export default React.memo(MarkdownText, areMarkdownPropsEqual);
