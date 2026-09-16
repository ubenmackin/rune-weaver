// Rune Weaver Tools Tests — Markdown-to-HTML rendering with Ink.

import Foundation
@testable import RuneWeaverTools
import Testing

@Suite("Email Markdown Renderer")
struct EmailMarkdownRendererTests {
    @Test
    func `Renders basic markdown elements into HTML`() {
        let markdown = """
        # Heading 1
        ## Heading 2

        This is a paragraph with **bold** and *italic* text, plus a [link](https://example.com).

        - Item 1
        - Item 2

        > A quoted block

        ```swift
        let x = 42
        ```
        """

        let html = EmailMarkdownRenderer.render(markdown: markdown)

        #expect(html.contains("<!DOCTYPE html>"))
        #expect(html.contains("<h1>Heading 1</h1>"))
        #expect(html.contains("<h2>Heading 2</h2>"))
        #expect(html.contains("<strong>bold</strong>"))
        #expect(html.contains("<em>italic</em>"))
        #expect(html.contains("<a href=\"https://example.com\">link</a>"))
        #expect(html.contains("<ul><li>Item 1</li><li>Item 2</li></ul>") || (html.contains("<li>Item 1</li>") && html.contains("<li>Item 2</li>")))
        #expect(html.contains("<blockquote>") && html.contains("A quoted block"))
        #expect(html.contains("<pre><code") && html.contains("let x = 42"))
        #expect(html.contains("font-family: -apple-system"))
    }

    @Test
    func `Renders plain text without markdown markers into paragraphs`() {
        let plain = "Hello there,\n\nJust checking in on the project status."
        let html = EmailMarkdownRenderer.render(markdown: plain)

        #expect(html.contains("<p>Hello there,</p>"))
        #expect(html.contains("<p>Just checking in on the project status.</p>"))
    }
}
