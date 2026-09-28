// Rune Weaver Tools — Embedded persistent read-only IMAP session helper source.
//
// Purpose: carries the piped python3 imaplib program backing the persistent session so
// repeated status, search, and fetch turns reuse one connection instead of redialing.
// Scope: newline-delimited JSON framing over stdin and stdout with read-only BODY.PEEK
// selects, covering the open, status, search, fetch, and close ops. Architectural role:
// session wire-protocol owner composing the shared parsing prelude and single-sourced
// search bound; EmailIMAPSession drives this source verbatim via python3 -c while
// EmailBridgeParsing decodes its envelopes.

import Foundation

/// Embedded `python3 imaplib` helper for a persistent read-only session.
///
/// The session speaks newline-delimited JSON, one document per line each way,
/// reusing the one-shot response envelopes so `EmailBridgeParsing` decodes
/// session output verbatim. The connection stays open across `status`,
/// `search`, and `fetch` turns; every read uses `BODY.PEEK` and selects
/// through the shared quoter. The first command opens the connection.
/// Embedded Python source executed via `python3 -c` with piped JSON lines.
private let imapSessionImports = #"""
import sys, json, imaplib, email, re, ssl, os, time, socket
from email import policy
from email.header import decode_header

# Persistent IMAP session: one JSON doc per line each way.
# Ops: open, status, search, fetch, close. Reads use BODY.PEEK.
# Shared quoter guards spaced names; CR/LF rejected before dial.
# First command opens; early commands fail fast; EOF ends session.
# Helper narration rides stderr with flush; stdout stays one envelope per line.
"""#

/// Session-specific framing plus the open/status/search/fetch/close dispatch.
///
/// Composes the shared wire-parsing prelude ahead of this body so header, body,
/// attachment, snippet, and quoter parsing stays single-sourced with the one-shot helper.
/// The search clamp below interpolates the single-sourced bound.
private let imapSessionBody = #"""
def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()

def fail(message):
    send({"ok": False, "error": message})

def _marker(text):
    try:
        sys.stderr.write(text + "\n")
        sys.stderr.flush()
    except Exception:
        pass

def _helper_now():
    try:
        return time.time()
    except Exception:
        return 0

def _helper_pid():
    try:
        return os.getpid()
    except Exception:
        return 0

def _safe_op(value):
    try:
        text = str(value or "")
    except Exception:
        return "unknown"
    cleaned = re.sub(r"[^A-Za-z0-9._-]", "", text)[:32]
    if not cleaned:
        return "unknown"
    return cleaned

def run_session():
    # Order addresses once at startup so the first dial already prefers
    # IPv4; the helper itself never raises, so a bad socket shim cannot
    # fail the session before the first open arrives.
    prefer_ipv4()
    # Named owner for helper narration: main loop plus open handler.
    # Stderr carries lifecycle ink with flush; stdout stays one envelope per line.
    # Only pids, paths, modes, ops, sizes, phases, counts, outcomes ride stderr.
    try:
        _marker("SESSION STARTED pid=%s exe=%s mode=session ts=%s" % (_helper_pid(), sys.executable, _helper_now()))
    except Exception:
        pass
    conn = None
    opened = False
    bye_done = False
    def do_close():
        nonlocal conn, bye_done
        if conn is not None:
            try:
                conn.logout()
            except Exception:
                pass
            conn = None
            if not bye_done:
                bye_done = True
                try:
                    _marker("SESSION BYE pid=%s ts=%s" % (_helper_pid(), _helper_now()))
                except Exception:
                    pass
    try:
        for line in sys.stdin:
            if not line.strip():
                continue
            try:
                _raw_bytes = len(line.rstrip("\r\n").encode("utf-8", errors="replace"))
            except Exception:
                _raw_bytes = 0
            try:
                _probe = json.loads(line)
                _probe_op = _safe_op(_probe.get("op"))
            except Exception:
                _probe_op = "unknown"
            try:
                _marker("SESSION GOT op=%s bytes=%d ts=%s pid=%s" % (_probe_op, _raw_bytes, _helper_now(), _helper_pid()))
            except Exception:
                pass
            try:
                req = json.loads(line)
            except Exception:
                fail("Invalid session request JSON")
                continue
            op = req.get("op") or ""
            if op == "open":
                host = req.get("host") or ""
                try:
                    port = int(req.get("port") or 993)
                except Exception:
                    port = 993
                username = req.get("username") or ""
                password = req.get("password") or ""
                if not host or not username or not password:
                    fail("Missing IMAP connection fields")
                    continue
                if conn is not None:
                    fail("session already open")
                    continue
                # Named owner for open phases: resolve plus connect plus login ink here.
                # Resolve markers stay without a dedicated DNS lookup: the
                # connect below already resolves, so an extra getaddrinfo
                # would double DNS, add an unbounded hang past the Swift
                # budget, and break hermetic runs that never stub the network.
                try:
                    _marker("SESSION PHASE phase=resolve-begin ts=%s pid=%s" % (_helper_now(), _helper_pid()))
                except Exception:
                    pass
                _addr_count = 0
                try:
                    _marker("SESSION PHASE phase=resolve-end addresses=%d ts=%s pid=%s" % (_addr_count, _helper_now(), _helper_pid()))
                except Exception:
                    pass
                try:
                    _marker("SESSION PHASE phase=connect-begin ts=%s pid=%s" % (_helper_now(), _helper_pid()))
                except Exception:
                    pass
                try:
                    ctx = ssl.create_default_context()
                    try:
                        conn = imaplib.IMAP4_SSL(host, port, ssl_context=ctx, timeout=30)
                    except TypeError:
                        conn = imaplib.IMAP4_SSL(host, port, ssl_context=ctx)
                    try:
                        _marker("SESSION PHASE phase=connect-end ok=True ts=%s pid=%s" % (_helper_now(), _helper_pid()))
                    except Exception:
                        pass
                except Exception as exc:
                    try:
                        _marker("SESSION PHASE phase=connect-end ok=False ts=%s pid=%s" % (_helper_now(), _helper_pid()))
                    except Exception:
                        pass
                    conn = None
                    fail("Could not connect: %s" % (exc,))
                    continue
                try:
                    _marker("SESSION PHASE phase=login-begin ts=%s pid=%s" % (_helper_now(), _helper_pid()))
                except Exception:
                    pass
                try:
                    conn.login(username, password)
                    try:
                        _marker("SESSION PHASE phase=login-end ok=True ts=%s pid=%s" % (_helper_now(), _helper_pid()))
                    except Exception:
                        pass
                except Exception as exc:
                    try:
                        _marker("SESSION PHASE phase=login-end ok=False ts=%s pid=%s" % (_helper_now(), _helper_pid()))
                    except Exception:
                        pass
                    try:
                        conn.logout()
                    except Exception:
                        pass
                    conn = None
                    fail("IMAP login failed: %s" % (exc,))
                    continue
                opened = True
                send({"ok": True})
                continue
            if conn is None:
                if op == "close" and opened:
                    send({"ok": True})
                    continue
                fail("session not open")
                continue
            if op == "status":
                status_box = str(req.get("mailbox") or "INBOX").strip()
                if not status_box:
                    fail("Invalid mailbox: mailbox must not be empty")
                    continue
                if "\r" in status_box or "\n" in status_box:
                    fail("Invalid mailbox")
                    continue
                try:
                    styp, sdata = conn.status(quote_mailbox(status_box), "(UIDNEXT UIDVALIDITY)")
                except Exception as exc:
                    fail("IMAP status failed: %s" % exc)
                    continue
                if styp != "OK":
                    fail("IMAP status failed")
                    continue
                try:
                    blobs = []
                    for item in (sdata or []):
                        if item is None:
                            continue
                        if isinstance(item, bytes):
                            blobs = blobs + [item.decode("utf-8", errors="replace")]
                        elif isinstance(item, tuple):
                            for sub in item:
                                if isinstance(sub, bytes):
                                    blobs = blobs + [sub.decode("utf-8", errors="replace")]
                                elif sub is not None:
                                    blobs = blobs + [str(sub)]
                        else:
                            blobs = blobs + [str(item)]
                    blob = " ".join(blobs)
                    m_next = re.search(r"UIDNEXT\s+(\d+)", blob, re.IGNORECASE)
                    m_valid = re.search(r"UIDVALIDITY\s+(\d+)", blob, re.IGNORECASE)
                    if not m_next or not m_valid:
                        fail("IMAP status failed: missing UIDNEXT or UIDVALIDITY")
                        continue
                    uid_next = int(m_next.group(1))
                    uid_valid = int(m_valid.group(1))
                except Exception as exc:
                    fail("IMAP status failed: %s" % exc)
                    continue
                send({"ok": True, "mailbox": status_box, "uidNext": uid_next, "uidValidity": uid_valid})
                continue
            if op == "search":
                mailbox = str(req.get("mailbox") or "INBOX")
                raw_query = req.get("query") or ""
                if "\r" in raw_query or "\n" in raw_query:
                    fail("Invalid search query")
                    continue
                if "\r" in mailbox or "\n" in mailbox:
                    fail("Invalid mailbox")
                    continue
                query = raw_query.strip()
                try:
                    limit = int(req.get("limit") or 10)
                except Exception:
                    limit = 10
                limit = max(1, min(limit, \#(EmailIMAPLimits.maxSearchLimit)))
                since_imap = str(req.get("since") or "").strip()
                until_imap = str(req.get("until") or "").strip()
                date_prefix = ""
                if since_imap and until_imap:
                    date_prefix = "SINCE %s BEFORE %s" % (since_imap, until_imap)
                elif since_imap:
                    date_prefix = "SINCE %s" % since_imap
                elif until_imap:
                    date_prefix = "BEFORE %s" % until_imap
                try:
                    typ, _ = conn.select(quote_mailbox(mailbox), readonly=True)
                except Exception as exc:
                    fail("Could not open mailbox %s: %s" % (mailbox, exc))
                    continue
                if typ != "OK":
                    fail("Could not open mailbox %s" % mailbox)
                    continue
                try:
                    if re.fullmatch(r"UID \d+:\d+", query):
                        if date_prefix:
                            typ, data = conn.uid("search", None, date_prefix + " " + query)
                        else:
                            typ, data = conn.uid("search", None, query)
                    elif not query or query == "*":
                        if date_prefix:
                            typ, data = conn.uid("search", None, date_prefix)
                        else:
                            typ, data = conn.uid("search", None, "ALL")
                    else:
                        esc = query.replace("\\", "\\\\").replace('"', '\\"')
                        if date_prefix:
                            criteria = '%s OR OR SUBJECT "%s" FROM "%s" BODY "%s"' % (date_prefix, esc, esc, esc)
                        else:
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
                        continue
                    uids = (data[0] or b"").split() if data else []
                    wanted = [u.decode("utf-8", errors="replace") for u in uids[-limit:]]
                    wanted.reverse()
                    messages = []
                    for uid in wanted:
                        try:
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
                            msg = email.message_from_bytes(raw, policy=policy.default)
                            atts = attachment_parts(msg)
                            has_atts = bool(atts)
                            text = body_text(msg)
                            messages = messages + [{
                                "id": uid,
                                "subject": decode_value(msg["Subject"]),
                                "from": decode_value(msg["From"]),
                                "date": str(msg["Date"] or ""),
                                "snippet": snippet_of(text),
                                "mailbox": mailbox,
                                "hasAttachments": has_atts,
                                "attachmentCount": len(atts),
                            }]
                        except Exception:
                            continue
                    send({"ok": True, "messages": messages})
                except Exception as exc:
                    fail("IMAP search failed: %s" % exc)
                continue
            if op == "fetch":
                mid = str(req.get("messageID") or req.get("messageId") or req.get("id") or req.get("uid") or "").strip()
                if not mid:
                    fail("Missing message id")
                    continue
                if not re.fullmatch(r"[0-9][0-9:,]*", mid):
                    fail("Invalid message id")
                    continue
                mailbox = str(req.get("mailbox") or "INBOX")
                if "\r" in mailbox or "\n" in mailbox:
                    fail("Invalid mailbox")
                    continue
                try:
                    typ, _ = conn.select(quote_mailbox(mailbox), readonly=True)
                except Exception as exc:
                    fail("Could not open mailbox %s: %s" % (mailbox, exc))
                    continue
                if typ != "OK":
                    fail("Could not open mailbox %s" % mailbox)
                    continue
                try:
                    raw = None
                    ftyp, fdata = conn.uid("fetch", mid, "(BODY.PEEK[])")
                    # UID-only fetch with no sequence fallback: mid is a UID and
                    # conn.fetch would interpret it as a sequence number, returning
                    # the wrong message when UID != seqno. A failed UID fetch falls
                    # through to not-found below. Read stays read-only via BODY.PEEK.
                    if ftyp == "OK" and fdata:
                        for chunk in fdata:
                            if isinstance(chunk, tuple) and len(chunk) >= 2 and isinstance(chunk[1], bytes):
                                raw = chunk[1]
                                break
                    if not raw:
                        fail("Message %s not found" % mid)
                        continue
                    msg = email.message_from_bytes(raw, policy=policy.default)
                    text = body_text(msg)
                    seen = attachments_of(msg)
                    deferred = len(seen) > 0
                    note = None
                    if deferred:
                        if len(seen) == 1:
                            note = "1 attachment available; use email.attachment to download."
                        else:
                            note = "%d attachments available; use email.attachment to download." % len(seen)
                    send({"ok": True, "message": {
                        "id": mid,
                        "subject": decode_value(msg["Subject"]),
                        "from": decode_value(msg["From"]),
                        "to": decode_value(msg["To"]),
                        "date": str(msg["Date"] or ""),
                        "body": text or "",
                        "attachments": seen,
                        "attachmentsDeferred": deferred,
                        "attachmentsNote": note,
                    }})
                except Exception as exc:
                    fail("IMAP fetch failed: %s" % exc)
                continue
            if op == "close":
                do_close()
                send({"ok": True})
                continue
            fail("unknown session op '%s'" % op)
    finally:
        do_close()

run_session()
"""#

/// Embedded `python3 imaplib` helper for a persistent read-only session.
///
/// The session speaks newline-delimited JSON, one document per line each way,
/// reusing the one-shot response envelopes so `EmailBridgeParsing` decodes
/// session output verbatim. The connection stays open across `status`,
/// `search`, and `fetch` turns; every read uses `BODY.PEEK` and selects
/// through the shared quoter. The first command opens the connection.
/// Composes the shared wire-parsing prelude ahead of the session body so parsing
/// and the search bound stay single-sourced with the one-shot helper.
enum EmailIMAPSessionScript {
    /// Python source executed via `python3 -c` with piped JSON lines.
    ///
    /// Named owner for the session protocol: this document defines the
    /// `open`, `status`, `search`, `fetch`, and `close` shapes the host drives.
    static let source = imapSessionImports + "\n" + EmailIMAPSharedPrelude.text + "\n" + imapSessionBody
}
