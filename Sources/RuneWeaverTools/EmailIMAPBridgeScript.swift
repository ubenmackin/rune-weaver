// Rune Weaver Tools — Embedded Python IMAP subprocess script source.

import Foundation

/// Embedded `python3 imaplib` helper.
enum EmailIMAPBridgeScript {
    /// Python source executed via `python3 -c`.
    static let source = EmailIMAPBridgeScriptHead.text + "\n" + EmailIMAPBridgeScriptMiddle.text + "\n" + EmailIMAPBridgeScriptTail.text
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
        delimiter = None
        name = ""
        if rest.endswith('"'):
            quoted = re.findall(r'"([^"]*)"', rest)
            if quoted:
                if len(quoted) >= 2:
                    raw_delim = quoted[0]
                    delimiter = raw_delim if raw_delim else None
                    name = quoted[-1]
                else:
                    if re.match(r'(?i)^NIL\b', rest.strip()):
                        delimiter = None
                        name = quoted[-1]
                    else:
                        name = quoted[-1]
            else:
                name = rest.strip().strip('"')
        else:
            parts = rest.split()
            if parts:
                if len(parts) >= 2 and parts[0].upper() == "NIL":
                    delimiter = None
                    name = parts[-1].strip().strip('"')
                elif len(parts) >= 2:
                    raw_delim = parts[0].strip().strip('"').strip("'")
                    if raw_delim.upper() == "NIL" or raw_delim == "":
                        delimiter = None
                    else:
                        delimiter = raw_delim
                    name = parts[-1].strip().strip('"')
                else:
                    name = parts[-1].strip().strip('"')
        return (flags, delimiter, name.strip())

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
        elif op == "move":
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
            early_dest = str(req.get("destination") or req.get("dest") or "")
            if not early_dest.strip():
                fail("Invalid destination: destination must not be empty")
                return
            if "\r" in early_dest or "\n" in early_dest:
                fail("Invalid destination: destination must not contain CR or LF")
                return
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

/// Middle segment of the embedded `python3 imaplib` helper (login through move).
private enum EmailIMAPBridgeScriptMiddle {
    /// Middle Python source.
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
                delims = []
                for line in (ldata or []):
                    if line is None:
                        continue
                    flags, delimiter, name = parse_list_entry(line)
                    if not name:
                        continue
                    if not is_selectable(flags):
                        continue
                    boxes.append(name)
                    if delimiter:
                        delims.append(delimiter)
                common = None
                if delims:
                    uniq = sorted(set(delims))
                    if len(uniq) == 1:
                        common = uniq[0]
                sys.stdout.write(json.dumps({"ok": True, "mailboxes": boxes, "delimiter": common, "commonDelimiter": common}))
                sys.stdout.flush()
                return
            if op == "move":
                src_box = str(req.get("mailbox") or "INBOX").strip()
                dest_box = str(req.get("destination") or req.get("dest") or "").strip()
                mid = str(req.get("messageID") or req.get("messageId") or req.get("id") or req.get("uid") or "").strip()
                mark_raw = req.get("markAsRead")
                if mark_raw is None:
                    mark_raw = req.get("mark_as_read")
                if mark_raw is None:
                    mark_raw = req.get("markedAsRead")
                if mark_raw is None:
                    mark_raw = req.get("marked_as_read")
                if isinstance(mark_raw, bool):
                    mark_read = mark_raw
                elif mark_raw is None or mark_raw == "":
                    mark_read = False
                else:
                    mark_read = str(mark_raw).lower() in ("1", "true", "yes")
                if not mid:
                    fail("Missing message id")
                    return
                if not re.fullmatch(r"[0-9][0-9:,]*", mid):
                    fail("Invalid message id")
                    return
                if "\r" in src_box or "\n" in src_box:
                    fail("Invalid mailbox")
                    return
                if not dest_box:
                    fail("Invalid destination: destination must not be empty")
                    return
                if "\r" in dest_box or "\n" in dest_box:
                    fail("Invalid destination: destination must not contain CR or LF")
                    return
                def quote_mailbox(name):
                    esc = name.replace("\\", "\\\\").replace('"', '\\"')
                    return '"%s"' % esc
                try:
                    typ, _ = conn.select(src_box, readonly=False)
                except Exception as exc:
                    fail("Could not open mailbox %s: %s" % (src_box, exc))
                    return
                if typ != "OK":
                    fail("Could not open mailbox %s" % src_box)
                    return
                if src_box.lower() == dest_box.lower():
                    marked = False
                    if mark_read:
                        try:
                            styp, _ = conn.uid("STORE", mid, "+FLAGS", "(\\Seen)")
                            if styp == "OK":
                                marked = True
                        except Exception:
                            marked = False
                    sys.stdout.write(json.dumps({"ok": True, "mailbox": src_box, "destination": dest_box, "moved": False, "markedAsRead": marked}))
                    sys.stdout.flush()
                    return
                moved = False
                dest_uid = None
                def dest_uid_of(resp):
                    try:
                        if resp is None:
                            return None
                        chunks = []
                        if isinstance(resp, (list, tuple)):
                            for item in resp:
                                if item is None:
                                    continue
                                if isinstance(item, bytes):
                                    try:
                                        chunks.append(item.decode("utf-8", errors="replace"))
                                    except Exception:
                                        chunks.append(str(item))
                                else:
                                    chunks.append(str(item))
                        else:
                            chunks.append(str(resp))
                        blob = " ".join(chunks)
                        found = re.search(r"COPYUID\s+\d+\s+[\d:,]+\s+([\d:,]+)", blob, re.IGNORECASE)
                        if not found:
                            return None
                        token = (found.group(1) or "").strip()
                        first = re.split(r"[:,]", token)[0].strip() if token else ""
                        return first or None
                    except Exception:
                        return None
                try:
                    try:
                        mtyp, mdata = conn.uid("MOVE", mid, quote_mailbox(dest_box))
                    except Exception:
                        mtyp, mdata = "NO", None
                    if mtyp == "OK":
                        moved = True
                        dest_uid = dest_uid_of(mdata)
                    else:
                        try:
                            ctyp, cdata = conn.uid("COPY", mid, quote_mailbox(dest_box))
                        except Exception as exc:
                            fail("IMAP move failed: %s" % exc)
                            return
                        if ctyp != "OK":
                            fail("IMAP move to %s failed" % dest_box)
                            return
                        dest_uid = dest_uid_of(cdata)
                        try:
                            conn.uid("STORE", mid, "+FLAGS", "(\\Deleted)")
                        except Exception as exc:
                            fail("IMAP move failed: %s" % exc)
                            return
                        try:
                            conn.expunge()
                        except Exception as exc:
                            fail("IMAP move failed: %s" % exc)
                            return
                        moved = True
                except Exception as exc:
                    fail("IMAP move failed: %s" % exc)
                    return
                marked = False
                if mark_read and moved and dest_uid:
                    try:
                        try:
                            conn.select(dest_box, readonly=False)
                        except Exception:
                            dest_uid = None
                        else:
                            styp, _ = conn.uid("STORE", dest_uid, "+FLAGS", "(\\Seen)")
                            if styp == "OK":
                                marked = True
                    except Exception:
                        marked = False
                sys.stdout.write(json.dumps({"ok": True, "mailbox": src_box, "destination": dest_box, "moved": moved, "markedAsRead": marked}))
                sys.stdout.flush()
                return
    """#
}

/// Final segment of the embedded `python3 imaplib` helper (append through `main()`).
private enum EmailIMAPBridgeScriptTail {
    /// Final Python source.
    static let text = #"""
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
                    has_att_filter = req.get("hasAttachment")
                    if has_att_filter is None:
                        has_att_filter = req.get("hasAttachments")
                    if has_att_filter is None:
                        has_att_filter = req.get("has_attachment")
                    if has_att_filter is None:
                        has_att_filter = req.get("has_attachments")
                    if isinstance(has_att_filter, bool):
                        pass
                    elif isinstance(has_att_filter, str):
                        lowered = has_att_filter.strip().lower()
                        if lowered in ("true", "1", "yes"):
                            has_att_filter = True
                        elif lowered in ("false", "0", "no"):
                            has_att_filter = False
                        else:
                            has_att_filter = None

                    if has_att_filter is None:
                        wanted = [u.decode("utf-8", errors="replace") for u in uids[-limit:]]
                        wanted.reverse()
                        scan_uids = wanted
                    else:
                        reversed_uids = [u.decode("utf-8", errors="replace") for u in reversed(uids)]
                        # Intent: bound filtered-search fetch cost. Candidate scan stays capped at
                        # max(limit*5, 50), i.e. worst-case 250 UIDs per mailbox (limit <= 50), with a
                        # cheap BODYSTRUCTURE probe per candidate and a full BODY.PEEK[] fetch only
                        # for probe matches (at most `limit` full fetches). All reads stay read-only
                        # (BODYSTRUCTURE + BODY.PEEK) so no \Seen flag is set.
                        scan_uids = reversed_uids[:min(len(reversed_uids), max(limit * 5, 50))]

                    messages = []
                    for uid in scan_uids:
                        try:
                            if has_att_filter is not None:
                                try:
                                    styp, sdata = conn.uid("fetch", uid, "(BODYSTRUCTURE)")
                                except Exception:
                                    styp, sdata = "NO", None
                                if styp == "OK" and sdata:
                                    try:
                                        if isinstance(sdata, bytes):
                                            s_blob = sdata.decode("utf-8", errors="replace").lower()
                                        else:
                                            s_chunks = []
                                            for s_item in sdata:
                                                if s_item is None:
                                                    continue
                                                if isinstance(s_item, tuple):
                                                    for s_sub in s_item:
                                                        if isinstance(s_sub, bytes):
                                                            s_chunks.append(s_sub.decode("utf-8", errors="replace"))
                                                        elif s_sub is not None:
                                                            s_chunks.append(str(s_sub))
                                                elif isinstance(s_item, bytes):
                                                    s_chunks.append(s_item.decode("utf-8", errors="replace"))
                                                else:
                                                    s_chunks.append(str(s_item))
                                            s_blob = " ".join(s_chunks).lower()
                                        # Empty probe response is inconclusive: fall through to the
                                        # authoritative full fetch below instead of skipping.
                                        if s_blob.strip():
                                            probe_has = ("attachment" in s_blob or "filename" in s_blob or '"name"' in s_blob)
                                            if probe_has != bool(has_att_filter):
                                                continue
                                    except Exception:
                                        pass
                            ftyp, fdata = conn.uid("fetch", uid, "(BODY.PEEK[])")
                            if ftyp != "OK" or not fdata:
                                continue
                            raw = None
                            for chunk in fdata:
                                if isinstance(chunk, tuple) and len(chunk) >= 2 and isinstance(chunk[1], bytes):
                                    raw = chunk[1]
                                    break
                            if not raw:
                                continue
                            # Skip malformed message so single bad MIME does not fail entire search
                            msg = email.message_from_bytes(raw, policy=policy.default)
                            atts = attachment_parts(msg)
                            has_atts = bool(atts)
                            if has_att_filter is not None and has_atts != bool(has_att_filter):
                                continue
                            text = body_text(msg)
                            messages.append({
                                "id": uid,
                                "subject": decode_value(msg["Subject"]),
                                "from": decode_value(msg["From"]),
                                "date": str(msg["Date"] or ""),
                                "snippet": snippet_of(text),
                                "mailbox": mailbox,
                                "hasAttachments": has_atts,
                                "attachmentCount": len(atts),
                            })
                            if len(messages) >= limit:
                                break
                        except Exception:
                            continue
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
