// Rune Weaver Dashboard — Robust Markdown renderer for chat messages and run audits.
// Powered by react-markdown and remark-gfm for spec-compliant CommonMark and GitHub Flavored Markdown (GFM)
// with zero unsafe innerHTML.

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

// Named components keep hook usage out of the inline `components` map:
// `MarkdownCode` reads `PreContext` to tell fenced blocks apart from
// inline snippets, and stable identities avoid remount churn on every
// render of the parent message.
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
    const match = /language-(\w+)/.exec(codeProps.className || "");
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

/**
 * Normalizes informal table delimiter lines (e.g. `| -+-+-+- |` or `| -+- |`)
 * to standard GFM `| --- | --- |` delimiters so all LLM table formats render cleanly.
 */
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

// Blocked schemes stay blocked even when attackers hide them with
// tab/newline/null smuggling, percent-encoding, HTML entities, or
// comment splicing, so every check runs on a camouflage-stripped copy
// while the allowlist (secure web, validated mail, local navigation)
// decides. Anything with another scheme stays unlinked.
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

// Strips the hiding layers browsers ignore so `java\tscript:`,
// `%6Aavascript:`, `&#58;`, and `java/**/script:` all surface as the
// same blocked scheme before the allowlist decides. Controls and spaces
// are removed for detection only (legitimate URLs never hide executable
// schemes in whitespace), keeping the decision conservative: camouflage
// can only turn an allowed shape into a denied one, never the reverse.
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

export default function MarkdownText({
  text,
  className = "markdown-content",
}: MarkdownTextProps) {
  if (!text) return null;

  const preparedText = normalizeMarkdown(text);

  return (
    <div className={className}>
      <ReactMarkdown
        remarkPlugins={[remarkGfm]}
        components={{
          table({ children, ...props }) {
            return (
              <div className="chat-table-wrapper">
                <table className="chat-table" {...props}>
                  {children}
                </table>
              </div>
            );
          },
          hr({ ...props }) {
            return <hr className="chat-hr" {...props} />;
          },
          pre: MarkdownPre,
          code: MarkdownCode,
          a({ href, children, ...props }) {
            if (!isSafeUrl(href)) {
              // Blocked links render as inert text without the raw URI so an
              // attacker URI never reaches the DOM or the readable text.
              return <span>[{children}]</span>;
            }
            return (
              <a
                href={href}
                target="_blank"
                rel="noopener noreferrer"
                className="chat-markdown-link"
                {...props}
              >
                {children}
              </a>
            );
          },
          img({ src, alt, ...props }) {
            if (!isSafeUrl(src)) {
              // Blocked images render alt text only so an unsafe source URI
              // never reaches the DOM or the readable text.
              return <span>[Image: {alt || "Blocked image"}]</span>;
            }
            return <img src={src} alt={alt} className="chat-markdown-img" {...props} />;
          },
          h1({ children, ...props }) {
            return <h3 className="chat-h3" {...props}>{children}</h3>;
          },
          h2({ children, ...props }) {
            return <h4 className="chat-h4" {...props}>{children}</h4>;
          },
          h3({ children, ...props }) {
            return <h5 className="chat-h5" {...props}>{children}</h5>;
          },
          blockquote({ children, ...props }) {
            return (
              <blockquote className="chat-blockquote" {...props}>
                {children}
              </blockquote>
            );
          },
          ul({ children, ...props }) {
            return (
              <ul className="chat-ul" {...props}>
                {children}
              </ul>
            );
          },
          ol({ children, ...props }) {
            return (
              <ol className="chat-ol" {...props}>
                {children}
              </ol>
            );
          },
          p({ children, ...props }) {
            return (
              <p className="chat-p" {...props}>
                {children}
              </p>
            );
          },
        }}
      >
        {preparedText}
      </ReactMarkdown>
    </div>
  );
}
