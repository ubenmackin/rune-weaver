# Monarch Money plugin — JSON-RPC bridge to monarchmoneycommunity.

import asyncio
import json
import os
import stat
import sys
from typing import Any, Dict, Optional

try:
    from monarchmoney import (
        MonarchMoney,
        LoginFailedException,
        RequireMFAException,
    )
except ImportError:
    # Allow running for syntax checking or mock testing even if package not yet installed in system python
    MonarchMoney = None
    LoginFailedException = Exception
    RequireMFAException = Exception


# Plugin-local cache stays under the Seatbelt write root and hash-ignored .mm.
_SESSION_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".mm")
_SESSION_NAME = "runeweaver-monarch-session.pickle"


def _default_session_file() -> str:
    return os.path.join(_SESSION_DIR, _SESSION_NAME)


def _ensure_secure_dir(path: str) -> None:
    # lstat sees the link itself so a planted .mm symlink cannot escape.
    # Unlink-or-fail keeps the cache under the Seatbelt write root.
    try:
        existing = os.lstat(path)
    except OSError:
        existing = None
    if existing is not None:
        if stat.S_ISLNK(existing.st_mode):
            try:
                os.unlink(path)
            except OSError as exc:
                raise RuntimeError(f"Refusing symlinked session directory: {exc}")
            existing = None
        elif not stat.S_ISDIR(existing.st_mode):
            raise RuntimeError("Session cache path is not a directory.")
        else:
            try:
                if existing.st_uid != os.geteuid():
                    raise RuntimeError("Session cache directory has unexpected owner.")
            except AttributeError:
                pass
            if existing.st_mode & 0o077 != 0:
                try:
                    os.chmod(path, 0o700)
                except OSError:
                    pass
    try:
        os.makedirs(path, mode=0o700, exist_ok=True)
    except OSError as exc:
        raise RuntimeError(f"Cannot create secure session directory: {exc}")
    try:
        os.chmod(path, 0o700)
    except OSError:
        pass
    try:
        verified = os.lstat(path)
    except OSError as exc:
        raise RuntimeError(f"Cannot verify secure session directory: {exc}")
    if stat.S_ISLNK(verified.st_mode) or not stat.S_ISDIR(verified.st_mode):
        raise RuntimeError("Session cache directory failed verification.")


def _is_temp_path(path: str) -> bool:
    # Predictable world-shared locations must never hold the session cache.
    candidates = [os.environ.get("TMPDIR", "/tmp"), "/tmp", "/var/tmp"]
    resolved = os.path.realpath(path)
    for candidate in candidates:
        try:
            base = os.path.realpath(candidate)
        except OSError:
            continue
        if resolved == base or resolved.startswith(base + os.sep):
            return True
    return False


def _session_file_is_trusted(path: str) -> bool:
    # lstat inspects the link itself so a planted symlink fails closed.
    # Only regular files qualify so a directory never passes as cache.
    try:
        st = os.lstat(path)
    except OSError:
        return False
    if stat.S_ISLNK(st.st_mode):
        return False
    if not stat.S_ISREG(st.st_mode):
        return False
    try:
        if st.st_uid != os.geteuid():
            return False
    except AttributeError:
        pass
    if st.st_mode & 0o077 != 0:
        return False
    resolved = os.path.realpath(path)
    if _is_temp_path(resolved):
        return False
    base = os.path.realpath(_SESSION_DIR)
    if resolved == base or resolved.startswith(base + os.sep):
        return True
    return False


def _validated_session_file_override(raw: Optional[str]) -> Optional[str]:
    # Mirror Swift containment so only cache-contained paths reach the client.
    # Untrusted, temp, or linked values fall back to the secure default.
    if raw is None:
        return None
    trimmed = raw.strip()
    if not trimmed or "\0" in trimmed or "\n" in trimmed or "\r" in trimmed:
        return None
    if not trimmed.startswith("/"):
        return None
    try:
        mm_base = os.path.realpath(_SESSION_DIR)
        resolved = os.path.realpath(trimmed)
    except OSError:
        return None
    prefix = mm_base if mm_base.endswith(os.sep) else mm_base + os.sep
    if resolved == mm_base or not resolved.startswith(prefix):
        return None
    if _is_temp_path(resolved):
        return None
    try:
        exists = os.path.lexists(trimmed)
    except OSError:
        return None
    if exists:
        try:
            st = os.lstat(trimmed)
        except OSError:
            return None
        if stat.S_ISLNK(st.st_mode) or not stat.S_ISREG(st.st_mode):
            return None
    else:
        try:
            parent = os.path.realpath(os.path.dirname(trimmed))
        except OSError:
            return None
        if parent != mm_base:
            return None
    return trimmed


def _resolve_session_file() -> str:
    # Honour the Swift-validated override; untrusted values use the default.
    _ensure_secure_dir(_SESSION_DIR)
    override = _validated_session_file_override(os.environ.get("MONARCH_SESSION_FILE"))
    if override is not None:
        return override
    return _default_session_file()


def _prepare_session_file(path: str) -> None:
    # Reserve the cache exclusively so creation never follows a planted link.
    try:
        same_dir = os.path.realpath(os.path.dirname(path)) == os.path.realpath(_SESSION_DIR)
    except OSError:
        return
    if not same_dir:
        return
    _ensure_secure_dir(_SESSION_DIR)
    try:
        st = os.lstat(path)
    except OSError:
        st = None
    if st is not None and not _session_file_is_trusted(path):
        try:
            os.unlink(path)
        except OSError:
            return
        st = None
    if st is None:
        try:
            fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
        except OSError:
            return
        try:
            os.close(fd)
        except OSError:
            pass
        try:
            os.chmod(path, 0o600)
        except OSError:
            pass


def _harden_saved_session(path: str) -> None:
    try:
        if stat.S_ISLNK(os.lstat(path).st_mode):
            return
        os.chmod(path, 0o600)
    except OSError:
        pass


async def get_monarch_client() -> Any:
    if MonarchMoney is None:
        raise RuntimeError(
            "monarchmoneycommunity package is not installed in the Python environment. "
            "Please ensure the plugin .venv is provisioned."
        )

    token = os.environ.get("MONARCH_TOKEN")
    cookie = os.environ.get("MONARCH_COOKIE")
    email = os.environ.get("MONARCH_EMAIL")
    password = os.environ.get("MONARCH_PASSWORD")
    mfa_secret = os.environ.get("MONARCH_MFA_SECRET")

    session_file = _resolve_session_file()
    _prepare_session_file(session_file)

    # 1. Bearer Token Auth (Recommended — bypasses CAPTCHA & 2FA prompts)
    if token and token.strip():
        mm = MonarchMoney(token=token.strip(), session_file=session_file)
        _harden_saved_session(session_file)
        return mm

    # 2. Cookie Header Auth
    if cookie and cookie.strip():
        mm = MonarchMoney(session_file=session_file)
        await mm.login_with_cookies(cookie.strip(), save_session=True)
        _harden_saved_session(session_file)
        return mm

    # 3. Cached Session
    if _session_file_is_trusted(session_file):
        mm = MonarchMoney(session_file=session_file)
        try:
            mm.load_session(session_file)
            return mm
        except Exception:
            pass  # Fall through to credentials if session expired/invalid

    # 4. Email + Password Credentials Auth
    if email and password:
        mm = MonarchMoney(session_file=session_file)
        try:
            await mm.login(
                email=email,
                password=password,
                save_session=True,
                use_saved_session=True,
                mfa_secret_key=mfa_secret,
            )
            _harden_saved_session(session_file)
            return mm
        except RequireMFAException:
            raise RuntimeError(
                "Monarch Money requires MFA. Provide MONARCH_MFA_SECRET (TOTP key) "
                "or use MONARCH_TOKEN."
            )
        except LoginFailedException as e:
            raise RuntimeError(f"Monarch Money login failed: {e}")

    raise RuntimeError(
        "Missing Monarch Money credentials. Please set MONARCH_TOKEN (recommended), "
        "MONARCH_COOKIE, or MONARCH_EMAIL + MONARCH_PASSWORD in RuneWeaver Secrets."
    )


async def handle_accounts(mm: Any, params: Dict[str, Any]) -> Dict[str, Any]:
    result = await mm.get_accounts()
    account_id = params.get("account_id")
    include_holdings = params.get("include_holdings", False)

    if include_holdings or account_id:
        try:
            if account_id:
                holdings = await mm.get_account_holdings(account_id)
            else:
                holdings = await mm.get_all_holdings()
            result["holdings"] = holdings
        except Exception as e:
            result["holdings_error"] = str(e)

    try:
        refresh_complete = await mm.is_accounts_refresh_complete()
        result["is_refresh_complete"] = refresh_complete
    except Exception:
        pass

    return result


async def handle_transactions(mm: Any, params: Dict[str, Any]) -> Dict[str, Any]:
    if params.get("list_categories"):
        categories = await mm.get_transaction_categories()
        tags = await mm.get_transaction_tags()
        return {
            "categories": categories,
            "tags": tags,
        }

    txn_id = params.get("transaction_id")
    if txn_id:
        details = await mm.get_transaction_details(txn_id)
        try:
            splits = await mm.get_transaction_splits(txn_id)
        except Exception:
            splits = None
        return {
            "transaction": details,
            "splits": splits,
        }

    # Query transaction list
    search = params.get("search")
    start_date = params.get("start_date")
    end_date = params.get("end_date")
    category_ids = params.get("category_ids")
    account_ids = params.get("account_ids")
    try:
        limit = int(params.get("limit", 50))
    except (TypeError, ValueError):
        raise ValueError("Parameter 'limit' must be an integer between 1 and 200.")
    if limit < 1:
        raise ValueError("Parameter 'limit' must be an integer between 1 and 200.")
    limit = min(limit, 200)

    txns = await mm.get_transactions(
        search=search,
        start_date=start_date,
        end_date=end_date,
        category_ids=category_ids,
        account_ids=account_ids,
        limit=limit,
    )
    return txns


async def handle_finances(mm: Any, params: Dict[str, Any]) -> Dict[str, Any]:
    report = params.get("report")
    start_date = params.get("start_date")
    end_date = params.get("end_date")

    if report == "budgets":
        return await mm.get_budgets(start_date=start_date, end_date=end_date)
    elif report == "cashflow":
        summary = await mm.get_cashflow_summary(start_date=start_date, end_date=end_date)
        cashflow = await mm.get_cashflow(start_date=start_date, end_date=end_date)
        return {
            "summary": summary,
            "cashflow": cashflow,
        }
    elif report == "recurring":
        return await mm.get_recurring_transactions()
    elif report == "goals":
        return await mm.get_savings_goals()
    else:
        raise ValueError(
            f"Unknown report '{report}'. Must be one of: budgets, cashflow, recurring, goals."
        )


async def handle_mutate(
    mm: Any, params: Dict[str, Any], dry_run: bool = False
) -> Dict[str, Any]:
    action = params.get("action")
    if not action:
        raise ValueError("Parameter 'action' is required for monarch.mutate.")

    if dry_run:
        return {
            "dry_run": True,
            "status": "simulated",
            "action": action,
            "preview": params,
        }

    if action == "update_transaction":
        txn_id = params.get("transaction_id")
        if not txn_id:
            raise ValueError("transaction_id is required for update_transaction.")
        return await mm.update_transaction(
            transaction_id=txn_id,
            category_id=params.get("category_id"),
            merchant_name=params.get("merchant_name"),
            amount=params.get("amount"),
            date=params.get("date"),
            notes=params.get("notes"),
        )
    elif action == "create_transaction":
        account_id = params.get("account_id")
        date = params.get("date")
        amount = params.get("amount")
        merchant_name = params.get("merchant_name")
        if not (account_id and date and amount is not None and merchant_name):
            raise ValueError(
                "account_id, date, amount, and merchant_name are required for create_transaction."
            )
        return await mm.create_transaction(
            account_id=account_id,
            date=date,
            amount=amount,
            merchant_name=merchant_name,
            category_id=params.get("category_id"),
            notes=params.get("notes"),
        )
    elif action == "set_transaction_tags":
        txn_id = params.get("transaction_id")
        tag_ids = params.get("tag_ids", [])
        if not txn_id:
            raise ValueError("transaction_id is required for set_transaction_tags.")
        return await mm.set_transaction_tags(transaction_id=txn_id, tag_ids=tag_ids)
    elif action == "set_budget_amount":
        amount = params.get("amount")
        category_id = params.get("category_id")
        date = params.get("date")
        apply_to_future = params.get("apply_to_future", False)
        if amount is None or not category_id or not date:
            raise ValueError(
                "amount, category_id, and date are required for set_budget_amount."
            )
        return await mm.set_budget_amount(
            amount=amount,
            category_id=category_id,
            start_date=date,
            apply_to_future=apply_to_future,
        )
    elif action == "refresh_accounts":
        account_ids = [params["account_id"]] if params.get("account_id") else None
        return await mm.request_accounts_refresh(account_ids=account_ids)
    else:
        raise ValueError(
            f"Unknown action '{action}'. Must be one of: update_transaction, "
            "create_transaction, set_transaction_tags, set_budget_amount, refresh_accounts."
        )


async def main() -> None:
    raw_input = sys.stdin.read().strip()
    if not raw_input:
        sys.stderr.write("Empty JSON-RPC request\n")
        sys.exit(1)

    try:
        rpc_request = json.loads(raw_input)
    except json.JSONDecodeError as err:
        sys.stderr.write(f"Malformed JSON-RPC request: {err}\n")
        sys.exit(1)

    call_id = rpc_request.get("id")
    method = rpc_request.get("method")
    params = rpc_request.get("params", {})
    context = rpc_request.get("context", {})
    dry_run = context.get("dry_run", False)

    try:
        # Mock / dry run for mutate does not require network or credentials
        if dry_run and method == "monarch.mutate":
            result = await handle_mutate(None, params, dry_run=True)
        else:
            mm = await get_monarch_client()
            if method == "monarch.accounts":
                result = await handle_accounts(mm, params)
            elif method == "monarch.transactions":
                result = await handle_transactions(mm, params)
            elif method == "monarch.finances":
                result = await handle_finances(mm, params)
            elif method == "monarch.mutate":
                result = await handle_mutate(mm, params, dry_run=dry_run)
            else:
                raise ValueError(f"Unknown tool method: {method}")

        response = {
            "jsonrpc": "2.0",
            "id": call_id,
            "result": result,
        }
        sys.stdout.write(json.dumps(response))
        sys.stdout.flush()
    except Exception as exc:
        response = {
            "jsonrpc": "2.0",
            "id": call_id,
            "error": {
                "code": -32603,
                "message": str(exc),
            },
        }
        sys.stdout.write(json.dumps(response))
        sys.stdout.flush()


if __name__ == "__main__":
    asyncio.run(main())
