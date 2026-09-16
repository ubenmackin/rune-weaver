// Rune Weaver Tools — Embedded Python IMAP subprocess script source.

import Foundation

/// Embedded `python3 imaplib` helper.
enum EmailIMAPBridgeScript {
    /// Python source executed via `python3 -c`.
    static let source = EmailIMAPBridgeScriptHead.text + "\n" + EmailIMAPBridgeScriptTail.text
}

/// First half of the embedded `python3 imaplib` helper (imports through connect).
private enum EmailIMAPBridgeScriptHead {
    /// First half of the Python source.
    static let text = #"""
    import sys, json, imaplib, email, re, ssl, base64
    from email import policy
    from email.header import decode_header
    from email.utils import getaddresses

    def decode_value(raw):
        if raw is None:
            return ""
        parts = []
        for text, charset in decode_header(raw):
            if isinstance(text, bytes):
                try:
                    parts.append(text.decode(charset or "utf-8", errors="replace"))
                except Exception:
                    parts.append(text.decode("utf-8", errors="replace"))
            else:
                parts.append(text)
        return "".join(parts)

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
        parts = []
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
                    parts.append((name, ctype, payload))
        return parts

    def attachments_of(msg):
        found = []
        for (name, ctype, payload) in attachment_parts(msg):
            found.append({"filename": name, "contentType": ctype, "sizeBytes": len(payload)})
        return found

    def attachment_index_of(req):
        raw = req.get("attachmentIndex")
        if raw is None:
            raw = req.get("attachment_index")
        if raw is None:
            raw = req.get("index")
        if isinstance(raw, bool):
            return None
        try:
            return int(raw)
        except Exception:
            return None

    def snippet_of(text, limit=200):
        single = re.sub(r"\s+", " ", text or "").strip()
        if len(single) > limit:
            return single[:limit]
        return single

    def parse_list_entry(line):
        if isinstance(line, bytes):
            try:
                text = line.decode("utf-8", errors="replace")
            except Exception:
                text = str(line)
        else:
            text = str(line)
        flags = ""
        m = re.search(r"\(([^)]*)\)", text)
        if m:
            flags = m.group(1) or ""
            rest = text[m.end():].strip()
        else:
            rest = text.strip()
        name = ""
        if rest.endswith('"'):
            quoted = re.findall(r'"([^"]*)"', rest)
            if quoted:
                name = quoted[-1]
            else:
                name = rest.strip().strip('"')
        else:
            parts = rest.split()
            if parts:
                name = parts[-1].strip().strip('"')
        return (flags, name.strip())

    def is_selectable(flags):
        lowered = (flags or "").lower()
        return ("noselect" not in lowered) and ("nonexistent" not in lowered)

    def fail(message):
        sys.stdout.write(json.dumps({"ok": False, "error": message}))
        sys.stdout.flush()

    def main():
        try:
            req = json.loads(sys.stdin.read() or "{}")
        except Exception:
            fail("Invalid IMAP bridge request JSON")
            return
        op = req.get("op") or ""
        if op == "search":
            early_query = req.get("query") or ""
            if "\r" in early_query or "\n" in early_query:
                fail("Invalid search query")
                return
            early_box = str(req.get("mailbox") or "INBOX")
            if "\r" in early_box or "\n" in early_box:
                fail("Invalid mailbox")
                return
        elif op == "fetch":
            early_mid = str(req.get("messageID") or req.get("messageId") or req.get("id") or req.get("uid") or "").strip()
            if not early_mid:
                fail("Missing message id")
                return
            if not re.fullmatch(r"[0-9][0-9:,]*", early_mid):
                fail("Invalid message id")
                return
            early_box = str(req.get("mailbox") or "INBOX")
            if "\r" in early_box or "\n" in early_box:
                fail("Invalid mailbox")
                return
        elif op == "attachment":
            early_mid = str(req.get("messageID") or req.get("messageId") or req.get("id") or req.get("uid") or "").strip()
            if not early_mid:
                fail("Missing message id")
                return
            if not re.fullmatch(r"[0-9][0-9:,]*", early_mid):
                fail("Invalid message id")
                return
            early_idx = attachment_index_of(req)
            if early_idx is None or early_idx < 0:
                fail("Invalid attachment index")
                return
            early_box = str(req.get("mailbox") or "INBOX")
            if "\r" in early_box or "\n" in early_box:
                fail("Invalid mailbox")
                return
        elif op == "list":
            pass
        elif op == "append":
            early_box = str(req.get("mailbox") or "")
            if not early_box.strip():
                fail("Invalid mailbox: mailbox must not be empty")
                return
            if "\r" in early_box or "\n" in early_box:
                fail("Invalid mailbox")
                return
            early_raw = req.get("rawMessageBase64") or req.get("rawMessage") or ""
            if not early_raw:
                fail("Invalid append message: message must not be empty")
                return
        host = req.get("host") or ""
        try:
            port = int(req.get("port") or 993)
        except Exception:
            port = 993
        username = req.get("username") or ""
        password = req.get("password") or ""
        mailbox = req.get("mailbox") or "INBOX"
        if not host or not username or not password:
            fail("Missing IMAP connection fields")
            return
        try:
            ctx = ssl.create_default_context()
            try:
                conn = imaplib.IMAP4_SSL(host, port, ssl_context=ctx, timeout=30)
            except TypeError:
                conn = imaplib.IMAP4_SSL(host, port, ssl_context=ctx)
        except Exception as exc:
            fail("Could not connect to %s@%s:%s: %s" % (username, host, port, exc))
            return
    """#
}

/// Second half of the embedded `python3 imaplib` helper (login through `main()`).
private enum EmailIMAPBridgeScriptTail {
    /// Second half of the Python source.
    static let text = #"""
        try:
            try:
                conn.login(username, password)
            except Exception as exc:
                fail("IMAP login failed for %s@%s:%s: %s" % (username, host, port, exc))
                return
            if op == "list":
                try:
                    ltyp, ldata = conn.list()
                except Exception as exc:
                    fail("IMAP list failed: %s" % exc)
                    return
                if ltyp != "OK":
                    fail("IMAP list failed")
                    return
                boxes = []
                for line in (ldata or []):
                    if line is None:
                        continue
                    flags, name = parse_list_entry(line)
                    if not name:
                        continue
                    if not is_selectable(flags):
                        continue
                    boxes.append(name)
                sys.stdout.write(json.dumps({"ok": True, "mailboxes": boxes}))
                sys.stdout.flush()
                return
            if op == "append":
                append_box = str(req.get("mailbox") or "").strip()
                if not append_box:
                    fail("Invalid mailbox: mailbox must not be empty")
                    return
                if "\r" in append_box or "\n" in append_box:
                    fail("Invalid mailbox")
                    return
                encoded = req.get("rawMessageBase64") or req.get("rawMessage") or ""
                if not encoded:
                    fail("Invalid append message: message must not be empty")
                    return
                try:
                    raw = base64.b64decode(encoded, validate=True)
                except Exception:
                    fail("Invalid append message: expected base64 RFC822 bytes")
                    return
                if not raw:
                    fail("Invalid append message: message must not be empty")
                    return
                try:
                    atyp, _ = conn.append(append_box, "\\Seen", None, raw)
                except Exception as exc:
                    fail("IMAP append failed: %s" % exc)
                    return
                if atyp != "OK":
                    fail("IMAP append to %s failed" % append_box)
                    return
                sys.stdout.write(json.dumps({"ok": True, "mailbox": append_box}))
                sys.stdout.flush()
                return
            mailbox_check = str(mailbox or "INBOX")
            if "\r" in mailbox_check or "\n" in mailbox_check:
                fail("Invalid mailbox")
                return
            try:
                typ, _ = conn.select(mailbox, readonly=True)
            except Exception as exc:
                fail("Could not open mailbox %s: %s" % (mailbox, exc))
                return
            if typ != "OK":
                fail("Could not open mailbox %s" % mailbox)
                return
            if op == "search":
                raw_query = req.get("query") or ""
                if "\r" in raw_query or "\n" in raw_query:
                    fail("Invalid search query")
                    return
                if "\r" in mailbox or "\n" in mailbox:
                    fail("Invalid mailbox")
                    return
                query = raw_query.strip()
                try:
                    limit = int(req.get("limit") or 10)
                except Exception:
                    limit = 10
                limit = max(1, min(limit, 50))
                try:
                    if not query or query == "*":
                        typ, data = conn.uid("search", None, "ALL")
                    else:
                        esc = query.replace("\\", "\\\\").replace('"', '\\"')
                        criteria = 'OR OR SUBJECT "%s" FROM "%s" BODY "%s"' % (esc, esc, esc)
                        ctyp, cdata = None, None
                        try:
                            ctyp, cdata = conn.uid("search", "CHARSET", "UTF-8", criteria)
                        except Exception:
                            ctyp, cdata = None, None
                        if ctyp == "OK" and cdata is not None:
                            typ, data = ctyp, cdata
                        else:
                            typ, data = conn.uid("search", None, criteria)
                    if typ != "OK":
                        fail("IMAP search failed")
                        return
                    uids = (data[0] or b"").split() if data else []
                    wanted = [u.decode("utf-8", errors="replace") for u in uids[-limit:]]
                    wanted.reverse()
                    messages = []
                    for uid in wanted:
                        try:
                            ftyp, fdata = conn.uid("fetch", uid, "(BODY.PEEK[])")
                        except Exception:
                            continue
                        if ftyp != "OK" or not fdata:
                            continue
                        raw = None
                        for chunk in fdata:
                            if isinstance(chunk, tuple) and len(chunk) >= 2 and isinstance(chunk[1], bytes):
                                raw = chunk[1]
                                break
                        if not raw:
                            continue
                        msg = email.message_from_bytes(raw, policy=policy.default)
                        text = body_text(msg)
                        messages.append({
                            "id": uid,
                            "subject": decode_value(msg["Subject"]),
                            "from": decode_value(msg["From"]),
                            "date": str(msg["Date"] or ""),
                            "snippet": snippet_of(text),
                            "mailbox": mailbox,
                        })
                    sys.stdout.write(json.dumps({"ok": True, "messages": messages}))
                    sys.stdout.flush()
                except Exception as exc:
                    fail("IMAP search failed: %s" % exc)
                    return
            elif op == "fetch":
                mid = str(req.get("messageID") or req.get("messageId") or req.get("id") or req.get("uid") or "").strip()
                if not mid:
                    fail("Missing message id")
                    return
                if not re.fullmatch(r"[0-9][0-9:,]*", mid):
                    fail("Invalid message id")
                    return
                try:
                    raw = None
                    ftyp, fdata = conn.uid("fetch", mid, "(BODY.PEEK[])")
                    if ftyp != "OK" or not fdata or fdata == [None]:
                        ftyp, fdata = conn.fetch(mid, "(BODY.PEEK[])")
                    if ftyp == "OK" and fdata:
                        for chunk in fdata:
                            if isinstance(chunk, tuple) and len(chunk) >= 2 and isinstance(chunk[1], bytes):
                                raw = chunk[1]
                                break
                    if not raw:
                        fail("Message %s not found" % mid)
                        return
                    msg = email.message_from_bytes(raw, policy=policy.default)
                    text = body_text(msg)
                    listed = attachments_of(msg)
                    deferred = len(listed) > 0
                    note = None
                    if deferred:
                        if len(listed) == 1:
                            note = "1 attachment listed; use email.attachment to download."
                        else:
                            note = "%d attachments listed; use email.attachment to download." % len(listed)
                    sys.stdout.write(json.dumps({"ok": True, "message": {
                        "id": mid,
                        "subject": decode_value(msg["Subject"]),
                        "from": decode_value(msg["From"]),
                        "to": decode_value(msg["To"]),
                        "date": str(msg["Date"] or ""),
                        "body": text or "",
                        "attachments": listed,
                        "attachmentsDeferred": deferred,
                        "attachmentsNote": note,
                    }}))
                    sys.stdout.flush()
                except Exception as exc:
                    fail("IMAP fetch failed: %s" % exc)
                    return
            elif op == "attachment":
                mid = str(req.get("messageID") or req.get("messageId") or req.get("id") or req.get("uid") or "").strip()
                if not mid:
                    fail("Missing message id")
                    return
                if not re.fullmatch(r"[0-9][0-9:,]*", mid):
                    fail("Invalid message id")
                    return
                idx = attachment_index_of(req)
                if idx is None or idx < 0:
                    fail("Invalid attachment index")
                    return
                try:
                    raw = None
                    ftyp, fdata = conn.uid("fetch", mid, "(BODY.PEEK[])")
                    if ftyp != "OK" or not fdata or fdata == [None]:
                        ftyp, fdata = conn.fetch(mid, "(BODY.PEEK[])")
                    if ftyp == "OK" and fdata:
                        for chunk in fdata:
                            if isinstance(chunk, tuple) and len(chunk) >= 2 and isinstance(chunk[1], bytes):
                                raw = chunk[1]
                                break
                    if not raw:
                        fail("Message %s not found" % mid)
                        return
                    msg = email.message_from_bytes(raw, policy=policy.default)
                    parts = attachment_parts(msg)
                    if idx < 0 or idx >= len(parts):
                        fail("Invalid attachment index %d (message has %d attachments)" % (idx, len(parts)))
                        return
                    name, ctype, payload = parts[idx]
                    if len(payload) > 10485760:
                        sys.stdout.write(json.dumps({"ok": True, "attachment": {
                            "filename": name,
                            "contentType": ctype,
                            "sizeBytes": len(payload),
                            "contentBase64": None,
                            "oversize": True,
                        }}))
                        sys.stdout.flush()
                        return
                    sys.stdout.write(json.dumps({"ok": True, "attachment": {
                        "filename": name,
                        "contentType": ctype,
                        "sizeBytes": len(payload),
                        "contentBase64": base64.b64encode(payload).decode("ascii"),
                    }}))
                    sys.stdout.flush()
                except Exception as exc:
                    fail("IMAP attachment fetch failed: %s" % exc)
                    return
            else:
                fail("Unknown IMAP op '%s'" % op)
                return
        finally:
            try:
                conn.logout()
            except Exception:
                pass

    main()
    """#
}
