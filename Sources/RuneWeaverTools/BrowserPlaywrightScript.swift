// Rune Weaver Tools — Embedded Python Playwright helper source.
//
// Carries the isolated browser program backing `browser.navigate` and
// `browser.act`: fail-closed SSRF gating, ref collection, text distillation,
// login-wall detection, redirect-chain surfacing, opt-in bounded screenshots,
// and the JSON envelope. The program is split into two ordered segments that
// concatenate atomically (`head` then `tail`); keep them adjacent and edit
// them together so the deny set, capture budget, and envelope shape update as
// one. The capture budget and viewport interpolate `BrowserScreenshotPolicy`
// so a Swift budget change updates the helper without a second literal to
// drift, and deny behavior stays pinned by the shared web-safety fixture
// (`Tests/RuneWeaverToolsTests/WebToolsTests.swift` allowlist suite).

import Foundation
import RuneWeaverCore

/// First program segment: imports, failure helper, metadata-host set, and the
/// fail-closed SSRF gate. Concatenated before `BrowserPlaywrightScriptTail`.
enum BrowserPlaywrightScriptHead: Sendable {
    /// Head source text, ending at the close of `_ssrf_deny_reason`.
    static let part = #"""
    import sys, json

    def fail(message):
        sys.stdout.write(json.dumps({"ok": False, "error": message}))
        sys.stdout.flush()

    _BROWSER_METADATA_HOSTS = frozenset([
        "metadata.google.internal",
        "metadata.google",
        "metadata.goog",
        "instance-data.compute.internal",
        "instance-data",
        "metadata.azure.internal",
        "metadata.aws.internal",
        "metadata",
    ])

    def _ssrf_deny_reason(url):
        # Fail-closed SSRF gate for callers that bypass Swift validation,
        # before any navigation. Deny behavior is pinned single-source by the
        # shared web-safety fixture
        # (`Tests/RuneWeaverToolsTests/WebToolsTests.swift` allowlist suite),
        # which pins every range spelling (loopback, link-local, private RFC
        # 1918, 0.0.0.0/8) plus `blockedMetadataHosts`; ranges resolve via the
        # platform `ipaddress` module so no second hand-maintained range table
        # lives here. Deliberate delta: no `searxng_url`/LLM origin exemption
        # is plumbed here, so browser flows stay fail-closed on every loopback
        # and LAN spelling. Fails closed with a denial naming the host, never
        # with page bytes.
        try:
            from urllib.parse import urlparse
        except Exception:
            return None
        try:
            host = (urlparse(url).hostname or "").strip().lower().rstrip(".")
        except Exception:
            return "SSRF denied: unparseable URL host."
        if not host:
            return "SSRF denied: URL has no host."
        if (host in _BROWSER_METADATA_HOSTS or "metadata.google" in host
                or "instance-data" in host or "metadata.azure" in host):
            return "SSRF denied: refusing metadata host '%s'." % host
        if host == "localhost":
            return "SSRF denied: refusing loopback host '%s'." % host
        try:
            import ipaddress as _ipaddress
        except Exception:
            _ipaddress = None
        if _ipaddress is not None:
            try:
                addr = _ipaddress.ip_address(host)
            except Exception:
                addr = None
            if addr is not None:
                if addr.is_loopback or addr.is_unspecified:
                    return "SSRF denied: refusing loopback host '%s'." % host
                if addr.is_link_local:
                    return "SSRF denied: refusing link-local address '%s'." % host
                if addr.is_multicast or addr.is_reserved or addr.is_private:
                    return "SSRF denied: refusing private-network host '%s'." % host
                return None
        # Compact integer forms browsers still dial as IPv4.
        number = None
        try:
            if host.startswith("0x"):
                number = int(host, 16)
            elif host.isdigit():
                number = int(host, 10)
        except Exception:
            number = None
        if number is not None and 0 <= number <= 0xFFFFFFFF:
            first = (number >> 24) & 0xFF
            second = (number >> 16) & 0xFF
            if (first in (127, 10, 0) or (first == 169 and second == 254)
                    or (first == 192 and second == 168)
                    or (first == 172 and 16 <= second <= 31)):
                return "SSRF denied: refusing encoded private-network address '%s'." % host
            if "." not in host:
                return None
        # Obscured dotted spellings (hex or octal parts, short forms):
        # public DNS never serves them, so anything number-shaped fails
        # closed while hostnames that merely look adjacent pass through.
        if "." in host:
            hexdigits = set("0123456789abcdefABCDEFxX.")
            if all(ch in hexdigits for ch in host):
                numeric = True
                for part in host.split("."):
                    lowered_part = part.lower()
                    try:
                        if lowered_part.startswith("0x"):
                            int(part, 16)
                        elif len(part) > 1 and part.startswith("0") and part.isdigit():
                            int(part, 8)
                        elif part.isdigit():
                            int(part, 10)
                        else:
                            numeric = False
                    except Exception:
                        numeric = False
                if numeric:
                    return "SSRF denied: refusing numeric host '%s'." % host
        return None
    """#
}

/// Second program segment: ref collection, text distillation, login-wall and
/// redirect helpers, bounded screenshot capture, and the `main` dispatcher.
/// Concatenated after `BrowserPlaywrightScriptHead`.
enum BrowserPlaywrightScriptTail: Sendable {
    /// Tail source text, from `collect_refs` through the `main()` call.
    static let part = #"""

    def collect_refs(page, cap=200):
        try:
            els = page.query_selector_all("a, button, input, select, textarea, [role=button], [role=link], [role=textbox], [role=checkbox]")
        except Exception:
            return []
        refs = []
        for index, el in enumerate(els[:cap], start=1):
            try:
                role = el.get_attribute("role") or ""
                if not role:
                    try:
                        role = el.evaluate("e => e.tagName ? e.tagName.toLowerCase() : ''") or ""
                    except Exception:
                        role = ""
            except Exception:
                role = ""
            name = ""
            for getter in ("aria-label", "value", "placeholder"):
                try:
                    candidate = el.get_attribute(getter) or ""
                except Exception:
                    candidate = ""
                if candidate and candidate.strip():
                    name = candidate.strip()
                    break
            if not name:
                try:
                    candidate = el.inner_text() or ""
                except Exception:
                    candidate = ""
                if candidate and candidate.strip():
                    name = " ".join(candidate.split())
            refs.append({"ref": "e%d" % index, "role": (role or "").strip().lower()[:40], "name": (name or "")[:80]})
        return refs

    def page_text(page, cap=20000):
        try:
            body = page.query_selector("body")
            text = body.inner_text() if body else ""
        except Exception:
            text = ""
        text = (text or "").strip()
        if len(text) > cap:
            text = text[:cap]
        return text

    def is_auth_wall(page):
        try:
            return page.query_selector('input[type="password"]') is not None
        except Exception:
            return False

    def redirect_chain_for(response, initial_url, landed_url):
        # Walks `redirected_from` back to the initial request so the Swift
        # envelope can render finalUrl plus a collapsed chain and count.
        # Falls back to a single-step chain when the goto returns no
        # response (e.g. same-document navigation) so the UI never sees a
        # dead count.
        try:
            steps = []
            node = response.request if response is not None and getattr(response, "request", None) is not None else None
            trail = []
            seen = 0
            while node is not None and seen < 8:
                try:
                    trail.append(node.url or "")
                except Exception:
                    trail.append("")
                try:
                    node = node.redirected_from
                except Exception:
                    node = None
                seen += 1
            trail = [u for u in trail if u]
            trail.reverse()
            for entry in trail:
                steps.append({"url": entry})
            if not steps:
                if initial_url:
                    steps.append({"url": initial_url})
                if landed_url and (not steps or steps[-1].get("url") != landed_url):
                    steps.append({"url": landed_url})
            elif landed_url and steps[-1].get("url") != landed_url:
                steps.append({"url": landed_url})
            return steps
        except Exception:
            return [{"url": landed_url or initial_url or ""}]

    def capture_screenshot(page):
        # Opt-in JPEG capture for vision models: viewport-width shot downscaled
        # so the longest edge is 1280px and re-encoded to bounded JPEG under
        # 500KB (mirrors Swift `BrowserScreenshotPolicy`). Returns a data URL,
        # or "" when capture is unavailable so the envelope stays text-only.
        try:
            raw = page.screenshot(type="jpeg", quality=70, full_page=False)
        except Exception:
            return ""
        if not raw:
            return ""
        try:
            bounded = _downscale_to_budget(raw, max_edge=\#(BrowserScreenshotPolicy.maxDimension), max_bytes=\#(BrowserScreenshotPolicy.maxByteCount))
        except Exception:
            bounded = raw
        if not bounded:
            return ""
        try:
            import base64 as _base64
            return "data:image/jpeg;base64," + _base64.b64encode(bounded).decode("ascii")
        except Exception:
            return ""

    def _downscale_to_budget(raw, max_edge=\#(BrowserScreenshotPolicy.maxDimension), max_bytes=\#(BrowserScreenshotPolicy.maxByteCount)):
        # Resizes the longest edge to `max_edge` via PIL when available, then
        # steps quality down until the payload fits `max_bytes`. Falls back to
        # the original bytes when PIL is missing so navigation never fails.
        try:
            import io as _io
        except Exception:
            return raw
        if len(raw) <= max_bytes:
            # Still honor the longest-edge cap even when already under budget.
            try:
                from PIL import Image as _Image
            except Exception:
                return raw
            try:
                img = _Image.open(_io.BytesIO(raw))
                width, height = img.size
                longest = max(width, height)
                if longest <= max_edge:
                    return raw
                scale = float(max_edge) / float(longest)
                target = (max(1, int(round(width * scale))), max(1, int(round(height * scale))))
                img = img.convert("RGB").resize(target)
                out = _io.BytesIO()
                img.save(out, format="JPEG", quality=70, optimize=True)
                return out.getvalue()
            except Exception:
                return raw
        try:
            from PIL import Image as _Image
        except Exception:
            return b"" if len(raw) > max_bytes else raw
        try:
            img = _Image.open(_io.BytesIO(raw))
            width, height = img.size
            longest = max(width, height)
            if longest > max_edge:
                scale = float(max_edge) / float(longest)
                target = (max(1, int(round(width * scale))), max(1, int(round(height * scale))))
                img = img.convert("RGB").resize(target)
            else:
                img = img.convert("RGB")
            for quality in (70, 60, 50, 40, 30):
                out = _io.BytesIO()
                img.save(out, format="JPEG", quality=quality, optimize=True)
                payload = out.getvalue()
                if len(payload) <= max_bytes:
                    return payload
            return b""
        except Exception:
            return b""

    def main():
        try:
            req = json.loads(sys.stdin.read() or "{}")
        except Exception:
            fail("Invalid browser bridge request JSON")
            return
        op = req.get("op") or ""
        url = (req.get("url") or "").strip()
        if op not in ("navigate", "act"):
            fail("Unknown browser op '%s'" % op)
            return
        if not url:
            fail("Missing URL")
            return
        lowered = url.lower()
        if lowered.startswith("javascript:") or lowered.startswith("data:") or lowered.startswith("file:"):
            fail("Unsupported URL scheme")
            return
        reason = _ssrf_deny_reason(url)
        if reason:
            fail(reason)
            return
        try:
            from playwright.sync_api import sync_playwright
        except Exception:
            fail("Playwright is not installed (python3 -m pip install playwright && python3 -m playwright install chromium)")
            return
        action = (req.get("action") or "").strip().lower() if op == "act" else ""
        ref = (req.get("ref") or "").strip() if op == "act" else ""
        text = req.get("text") if op == "act" else None
        want_screenshot = bool(req.get("includeScreenshot") or req.get("screenshot") or req.get("include_screenshot")) if op == "navigate" else False
        if op == "act" and action not in ("click", "fill", "select", "press", "scroll"):
            fail("Invalid browser action")
            return
        if op == "act":
            if not ref or len(ref) < 2 or not ref.startswith("e") or not ref[1:].isdigit() or int(ref[1:]) < 1:
                fail("Invalid ref '%s'" % ref)
                return
        try:
            with sync_playwright() as pw:
                browser = pw.chromium.launch(headless=True)
                try:
                    # Fixed 1280x800 viewport at unit scale keeps opt-in captures
                    # at the 1280px longest edge without device-scale inflation;
                    # PIL downscale plus quality stepping in `capture_screenshot`
                    # enforces the 500KB bound before Swift's fail-closed check.
                    if want_screenshot:
                        vw = \#(BrowserScreenshotPolicy.captureViewportWidth)
                        vh = \#(BrowserScreenshotPolicy.captureViewportHeight)
                        context = browser.new_context(
                            accept_downloads=False,
                            viewport={"width": vw, "height": vh},
                            device_scale_factor=1)
                    else:
                        context = browser.new_context(accept_downloads=False)
                    page = context.new_page()
                    goto_response = page.goto(url, wait_until="domcontentloaded", timeout=30000)
                    landed = page.url or url
                    landed_reason = _ssrf_deny_reason(landed)
                    if landed_reason:
                        fail(landed_reason)
                        return
                    if op == "navigate":
                        refs = collect_refs(page)
                        chain = redirect_chain_for(goto_response, url, page.url or url)
                        shot = capture_screenshot(page) if want_screenshot else ""
                        sys.stdout.write(json.dumps({
                            "ok": True,
                            "url": page.url or url,
                            "title": page.title() or "",
                            "text": page_text(page),
                            "refs": refs,
                            "authRequired": is_auth_wall(page),
                            "downloads": [],
                            "redirectChain": chain,
                            "redirectCount": max(0, len(chain) - 1),
                            "screenshot": shot,
                        }))
                        sys.stdout.flush()
                        return
                    refs = collect_refs(page)
                    wanted = int(ref[1:]) - 1
                    if wanted < 0 or wanted >= len(refs):
                        fail("Unknown ref '%s' for this snapshot" % ref)
                        return
                    els = page.query_selector_all("a, button, input, select, textarea, [role=button], [role=link], [role=textbox], [role=checkbox]")
                    if wanted >= len(els):
                        fail("Unknown ref '%s' for this snapshot" % ref)
                        return
                    el = els[wanted]
                    if action == "click":
                        el.click(timeout=10000)
                    elif action == "fill":
                        el.fill(text or "", timeout=10000)
                    elif action == "select":
                        el.select_option(label=text or "", timeout=10000)
                    elif action == "press":
                        el.press(text or "Enter", timeout=10000)
                    elif action == "scroll":
                        el.scroll_into_view_if_needed(timeout=10000)
                    try:
                        page.wait_for_load_state("domcontentloaded", timeout=5000)
                    except Exception:
                        pass
                    sys.stdout.write(json.dumps({
                        "ok": True,
                        "url": page.url or url,
                        "action": action,
                        "ref": ref,
                        "downloads": [],
                    }))
                    sys.stdout.flush()
                finally:
                    try:
                        browser.close()
                    except Exception:
                        pass
        except Exception as exc:
            fail("Browser automation failed: %s" % exc)
            return

    main()
    """#
}

/// Embedded Python Playwright helper source.
///
/// Single entry point concatenating the ordered head and tail segments above
/// so the deny set, capture budget, and envelope shape still update
/// atomically; the segments stay adjacent in this file in execution order.
public enum BrowserPlaywrightScript: Sendable {
    /// Python source executed via `python3 -c`.
    public static let source = BrowserPlaywrightScriptHead.part + BrowserPlaywrightScriptTail.part
}
