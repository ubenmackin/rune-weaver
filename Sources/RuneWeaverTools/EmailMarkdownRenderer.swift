// Rune Weaver Tools — Automatic Markdown to styled HTML renderer for email.send.

import Foundation
import Ink

/// Renders Markdown into email-safe styled HTML.
public enum EmailMarkdownRenderer: Sendable {
    /// Renders Markdown into a full HTML email document with responsive inline styling.
    public static func render(markdown: String) -> String {
        let parser = MarkdownParser()
        let htmlBody = parser.html(from: markdown)
        return wrapInEmailTemplate(htmlBody: htmlBody)
    }

    /// Wraps rendered HTML fragment in a clean, responsive, email-client-safe boilerplate.
    public static func wrapInEmailTemplate(htmlBody: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1.0">
          <style>
            body {
              font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif;
              font-size: 15px;
              line-height: 1.6;
              color: #1a1a1a;
              margin: 0;
              padding: 16px;
            }
            h1, h2, h3, h4 {
              color: #111111;
              margin-top: 1.2em;
              margin-bottom: 0.6em;
              line-height: 1.3;
            }
            h1 { font-size: 1.4em; }
            h2 { font-size: 1.25em; }
            h3 { font-size: 1.1em; }
            p { margin: 0 0 1em 0; }
            ul, ol { margin: 0 0 1em 0; padding-left: 24px; }
            li { margin-bottom: 0.25em; }
            code {
              font-family: ui-monospace, Menlo, Monaco, Consolas, monospace;
              font-size: 0.9em;
              background-color: #f4f4f5;
              padding: 2px 5px;
              border-radius: 4px;
            }
            pre {
              background-color: #f4f4f5;
              padding: 12px;
              border-radius: 6px;
              overflow-x: auto;
              margin: 0 0 1em 0;
            }
            pre code {
              background-color: transparent;
              padding: 0;
            }
            blockquote {
              border-left: 3px solid #cbd5e1;
              margin: 0 0 1em 0;
              padding-left: 12px;
              color: #64748b;
            }
            a {
              color: #2563eb;
              text-decoration: underline;
            }
            table {
              border-collapse: collapse;
              width: 100%;
              margin: 0 0 1em 0;
            }
            th, td {
              border: 1px solid #e2e8f0;
              padding: 8px 12px;
              text-align: left;
            }
            th {
              background-color: #f8fafc;
            }
            hr {
              border: none;
              border-top: 1px solid #e2e8f0;
              margin: 1.5em 0;
            }
          </style>
        </head>
        <body>
        \(htmlBody)
        </body>
        </html>
        """
    }
}
