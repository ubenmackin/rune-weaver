// Rune Weaver Tools — Shared IMAP prelude plus search-limit source.

import Foundation

/// Single source for the bounded email search window. The embedded Python helper clamps through
/// this bound so a future `EmailSearchArgs.maxLimit` change propagates to the one-shot clamp without
/// editing scattered literals.
enum EmailIMAPLimits {
    /// Upper bound for `email.search` limit shared by Swift validation and the one-shot helper.
    static let maxSearchLimit = EmailSearchArgs.maxLimit
}

/// Shared Python wire-parsing prelude for the one-shot IMAP helper. The spelling uses `+`
/// concatenation instead of `append` so the one-shot program keeps its read-only shape without
/// introducing extra operation names.
enum EmailIMAPSharedPrelude {
    /// Shared Python source prepended ahead of each helper-specific body.
    static let text = #"""
    def decode_value(raw):
        if raw is None:
            return ""
        chunks = []
        for text, charset in decode_header(raw):
            if isinstance(text, bytes):
                try:
                    chunks = chunks + [text.decode(charset or "utf-8", errors="replace")]
                except Exception:
                    chunks = chunks + [text.decode("utf-8", errors="replace")]
            else:
                chunks = chunks + [text]
        return "".join(chunks)

    def body_text(msg):
        plain = None
        html = None
        if msg.is_multipart():
            for part in msg.walk():
                if part.is_multipart():
                    continue
                disp = (part.get_content_disposition() or "").lower()
                filename = part.get_filename()
                if disp == "attachment" or filename:
                    continue
                ctype = (part.get_content_type() or "").lower()
                try:
                    payload = part.get_payload(decode=True) or b""
                    charset = part.get_content_charset() or "utf-8"
                    text = payload.decode(charset, errors="replace")
                except Exception:
                    continue
                if ctype == "text/plain" and plain is None:
                    plain = text
                elif ctype == "text/html" and html is None:
                    html = text
            if plain:
                return plain
            if html:
                text = re.sub(r"<[^>]+>", " ", html)
                text = re.sub(r"\s+", " ", text)
                return text.strip()
            return ""
        try:
            payload = msg.get_payload(decode=True)
            if payload is None:
                nested = msg.get_payload()
                return nested if isinstance(nested, str) else ""
            charset = msg.get_content_charset() or "utf-8"
            text = payload.decode(charset, errors="replace")
            if (msg.get_content_type() or "").lower() == "text/html":
                text = re.sub(r"<[^>]+>", " ", text)
                text = re.sub(r"\s+", " ", text)
                return text.strip()
            return text
        except Exception:
            return ""

    def attachment_parts(msg):
        found = []
        if msg.is_multipart():
            for part in msg.walk():
                if part.is_multipart():
                    continue
                disp = (part.get_content_disposition() or "").lower()
                filename = part.get_filename()
                if disp == "attachment" or filename:
                    name = decode_value(filename) if filename else "unnamed-attachment"
                    if not name.strip():
                        name = "unnamed-attachment"
                    ctype = part.get_content_type() or "application/octet-stream"
                    try:
                        payload = part.get_payload(decode=True) or b""
                    except Exception:
                        payload = b""
                    found = found + [(name, ctype, payload)]
        return found

    def attachments_of(msg):
        out = []
        for (name, ctype, payload) in attachment_parts(msg):
            out = out + [{"filename": name, "contentType": ctype, "sizeBytes": len(payload)}]
        return out

    def snippet_of(text, limit=200):
        single = re.sub(r"\s+", " ", text or "").strip()
        if len(single) > limit:
            return single[:limit]
        return single

    def quote_mailbox(name):
        # Single shared quoter for every select so spaced names survive
        # the wire as one quoted atom; backslash and quote are escaped while
        # CR/LF stays rejected by callers before quoting to block injection.
        esc = name.replace("\\", "\\\\").replace('"', '\\"')
        return '"%s"' % esc

    def prefer_ipv4():
        # Dial IPv4 first on dual-stack hosts where IPv6 stalls while IPv4
        # stays reachable; single-family hosts are untouched because the
        # wrapper only reorders. Sorting is a stable partition so relative
        # order inside each family survives, and create_connection still
        # walks all results so a refused IPv4 falls through to IPv6.
        try:
            import socket as _prefer_socket
        except Exception:
            return
        try:
            _orig_getaddrinfo = _prefer_socket.getaddrinfo
        except Exception:
            return
        if getattr(_orig_getaddrinfo, "_runeweaver_ipv4_first", False):
            return
        def _ipv4_first_getaddrinfo(*args, **kwargs):
            results = _orig_getaddrinfo(*args, **kwargs)
            try:
                v4 = [r for r in results if r[0] == _prefer_socket.AF_INET]
                rest = [r for r in results if r[0] != _prefer_socket.AF_INET]
                return v4 + rest
            except Exception:
                return results
        _ipv4_first_getaddrinfo._runeweaver_ipv4_first = True
        _prefer_socket.getaddrinfo = _ipv4_first_getaddrinfo
    """#
}
