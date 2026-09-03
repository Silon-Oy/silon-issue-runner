#!/usr/bin/env python3
# lib/action-service.py — the Ohjaamo action service's HTTP + auth core (#77).
#
# This process owns ONLY the socket, the HTTP parse and the authentication /
# CSRF gates. It NEVER touches gh, labels or the orchestrator: every accepted
# request is handed to action-dispatch.sh via a plain argv exec (no shell), and
# that bash layer does the delegation. The lifecycle, host gate, bind address,
# log rotation and every environment default are owned by action-server.sh —
# this file trusts the environment it is launched with.
#
# THREE THINGS AUTHENTICATE A MUTATION, all fail-closed:
#   1. Device — `tailscale whois --json <peer-ip>` on the SOCKET peer IP (never a
#      forwarded header; the service must not sit behind a reverse proxy, which
#      would replace the peer IP with the proxy's and make whois a tautology).
#      The resolved LoginName must be in the allowed-users set.
#   2. Page origin — the request's Origin header must be in the allowlist. A
#      custom header (X-Run-Issues-Action) is ALSO required, which forces the
#      browser through a CORS preflight that only an allowlisted origin passes.
#      Content-Type must be application/json (again, not a CORS "simple" request).
#   3. Shared token — X-Run-Issues-Token must equal the secret the status page
#      embedded (lib/action-token.sh). A caller that cannot READ the page cannot
#      forge this, so a whois-passing device on a hostile web page still fails.
#
# Every accepted AND denied mutation is written to the audit log as one JSON
# line (rotated by size, open-append-close per line so a long-lived daemon still
# honours the cap). The token NEVER appears in the log, in status.json, or in a
# response body.
#
# Python 3.9 stdlib only (the interpreter macOS ships): no third-party packages.

import hmac
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# ---------------------------------------------------------------------------
# Configuration, all from the environment action-server.sh exports.
# ---------------------------------------------------------------------------
BIND = os.environ.get("RUN_ISSUES_ACTION_BIND", "127.0.0.1")
PORT = int(os.environ.get("RUN_ISSUES_ACTION_PORT", "8081"))
DISPATCH = os.environ.get("RUN_ISSUES_ACTION_DISPATCH", "")
TAILSCALE_BIN = os.environ.get("RUN_ISSUES_TAILSCALE_BIN", "")
TOKEN_FILE = os.environ.get("RUN_ISSUES_ACTION_TOKEN_FILE", "")
LOG_DIR = os.environ.get("RUN_ISSUES_LOG_DIR", os.path.expanduser("~/Library/Logs"))
LOG_MAX_BYTES = int(os.environ.get("RUN_ISSUES_LOG_MAX_BYTES", "10485760") or "0")
AUDIT_LOG = os.path.join(LOG_DIR, "run-issues-action.audit.log")

CUSTOM_HEADER = "x-run-issues-action"      # forces the CORS preflight
TOKEN_HEADER = "x-run-issues-token"
MAX_BODY = 64 * 1024

NODE = socket.gethostname().split(".")[0]


def _csv_set(name):
    """Env CSV -> a set of trimmed non-empty values."""
    return {p.strip() for p in os.environ.get(name, "").split(",") if p.strip()}


ALLOWED_USERS = _csv_set("RUN_ISSUES_ACTION_ALLOWED_USERS")
ALLOWED_ORIGINS = _csv_set("RUN_ISSUES_ACTION_ORIGIN")


def load_token():
    """Read the shared token from disk. Returns '' if unreadable/empty."""
    if not TOKEN_FILE:
        return ""
    try:
        with open(TOKEN_FILE, "r") as fh:
            return fh.readline().strip()
    except OSError:
        return ""


TOKEN = load_token()

_audit_lock = threading.Lock()


def audit(**fields):
    """Append one JSON line to the audit log (open-append-close), rotating by
    size first. The token is never a field here. Best-effort: an audit write
    failure must not crash a request, but it is the only durable record so we
    try hard (create the dir, rotate, then append)."""
    with _audit_lock:
        try:
            os.makedirs(LOG_DIR, exist_ok=True)
            # Size-based rotation, one generation — mirrors lib/log-rotate.sh so a
            # daemon that never restarts still honours the cap (AC4).
            if LOG_MAX_BYTES > 0:
                try:
                    if os.path.getsize(AUDIT_LOG) > LOG_MAX_BYTES:
                        shutil.move(AUDIT_LOG, AUDIT_LOG + ".1")
                except OSError:
                    pass
            with open(AUDIT_LOG, "a") as fh:
                fh.write(json.dumps(fields, ensure_ascii=False, sort_keys=True) + "\n")
        except OSError:
            pass


def whois_login(peer_ip):
    """Resolve the tailnet LoginName for <peer-ip> via `tailscale whois --json`.
    Returns the LoginName string, or None on ANY failure (fail-closed: a
    non-zero exit, empty output, parse error or a missing field all deny)."""
    if not TAILSCALE_BIN or not peer_ip:
        return None
    try:
        proc = subprocess.run(
            [TAILSCALE_BIN, "whois", "--json", peer_ip],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            timeout=10, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if proc.returncode != 0 or not proc.stdout:
        return None
    try:
        data = json.loads(proc.stdout.decode("utf-8", "replace"))
    except (ValueError, UnicodeError):
        return None
    login = (data.get("UserProfile") or {}).get("LoginName")
    return login if isinstance(login, str) and login else None


class Handler(BaseHTTPRequestHandler):
    server_version = "run-issues-action/1"

    # Quiet the default stderr access log; the audit log is the record of note.
    def log_message(self, fmt, *args):
        return

    def _peer_ip(self):
        ip = self.client_address[0]
        # Strip an IPv6 zone id (fe80::1%en0) — tailscale whois wants the bare IP.
        return ip.split("%", 1)[0]

    def _origin(self):
        return self.headers.get("Origin", "")

    def _cors_headers(self, origin):
        """Emit CORS headers ONLY for an allowlisted origin, so a non-allowlisted
        page can never read our responses (and its preflight fails)."""
        if origin and origin in ALLOWED_ORIGINS:
            self.send_header("Access-Control-Allow-Origin", origin)
            self.send_header("Vary", "Origin")
            self.send_header("Access-Control-Allow-Methods", "POST, OPTIONS")
            self.send_header(
                "Access-Control-Allow-Headers",
                "Content-Type, X-Run-Issues-Action, X-Run-Issues-Token",
            )
            self.send_header("Access-Control-Max-Age", "600")

    def _json(self, code, payload, origin=""):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self._cors_headers(origin)
        self.end_headers()
        self.wfile.write(body)

    # ---- OPTIONS: the CORS preflight for POST /action ----
    def do_OPTIONS(self):
        origin = self._origin()
        self.send_response(204)
        self._cors_headers(origin)
        self.send_header("Content-Length", "0")
        self.end_headers()

    # ---- GET /healthz: liveness probe the page uses to enable its buttons ----
    def do_GET(self):
        origin = self._origin()
        if self.path.split("?", 1)[0] == "/healthz":
            # No secret is revealed; ACAO lets the allowlisted page read "ok".
            self._json(200, {"ok": True, "service": "run-issues-action"}, origin)
        else:
            self._json(404, {"ok": False, "error": "not found"}, origin)

    # ---- POST /action: the one mutating endpoint ----
    def do_POST(self):
        origin = self._origin()
        peer = self._peer_ip()

        if self.path.split("?", 1)[0] != "/action":
            self._json(404, {"ok": False, "error": "not found"}, origin)
            return

        def deny(reason, login=None):
            audit(ts=_now(), node=NODE, peer_ip=peer, login=login,
                  origin=origin, action=None, target=None,
                  result="denied", reason=reason)
            # A denial gets ACAO only for an allowlisted origin; otherwise the
            # page cannot read it, which is the safe direction.
            self._json(403, {"ok": False, "error": reason}, origin)

        # 1. Device auth (peer IP -> tailnet LoginName), fail-closed.
        login = whois_login(peer)
        if not login:
            deny("caller identity could not be verified via tailscale")
            return
        if login not in ALLOWED_USERS:
            deny("caller '%s' is not an allowed user" % login, login=login)
            return

        # 2. Origin allowlist + forced-preflight header + JSON content type.
        if origin not in ALLOWED_ORIGINS:
            deny("origin not allowed", login=login)
            return
        if not self.headers.get(CUSTOM_HEADER):
            deny("missing action header", login=login)
            return
        ctype = (self.headers.get("Content-Type", "") or "").split(";", 1)[0].strip().lower()
        if ctype != "application/json":
            deny("content-type must be application/json", login=login)
            return

        # 3. Shared token (constant-time compare).
        sent = self.headers.get(TOKEN_HEADER, "")
        if not TOKEN or not sent or not hmac.compare_digest(sent, TOKEN):
            deny("invalid or missing token", login=login)
            return

        # ---- authenticated: parse the body and delegate ----
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = 0
        if length <= 0 or length > MAX_BODY:
            self._json(400, {"ok": False, "error": "bad request body"}, origin)
            return
        raw = self.rfile.read(length)
        try:
            body = json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeError):
            self._json(400, {"ok": False, "error": "body is not valid JSON"}, origin)
            return

        action = body.get("action")
        argv = build_argv(action, body)
        if argv is None:
            self._json(400, {"ok": False, "error": "unknown or malformed action"}, origin)
            return

        target = _target_label(body)
        code, output = run_dispatch(argv)
        result = "ok" if code == 0 else "failed"
        audit(ts=_now(), node=NODE, peer_ip=peer, login=login, origin=origin,
              action=action, target=target, result=result, rc=code)
        self._json(200 if code == 0 else 502,
                   {"ok": code == 0, "code": code, "output": output}, origin)


def _now():
    # UTC ISO-8601 without importing datetime timezone dance twice.
    import datetime
    return datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")


def _s(body, key):
    """A body value coerced to a clean str, or '' — never None/other types into argv."""
    v = body.get(key)
    if v is None:
        return ""
    return str(v)


# Characters that must never appear in a path/identifier we forward to the shell
# layer. The dispatch runs delegates via argv (no shell) and the tmux restart
# uses execvp, so this is defence-in-depth — but a value carrying a quote, a
# shell metacharacter, or a control byte is never a legitimate run_dir/repo_path
# from this package, and rejecting it closes the class outright.
_UNSAFE = set("'\"`$;|&<>\n\r\t\x00") | {chr(c) for c in range(0, 32)}


def _path_ok(value):
    """True when <value> is safe to forward as a path/identifier argument."""
    return not any(ch in _UNSAFE for ch in value)


def _target_label(body):
    parts = []
    if body.get("issue_number") is not None:
        parts.append("#%s" % body.get("issue_number"))
    if body.get("pr_number") is not None:
        parts.append("PR#%s" % body.get("pr_number"))
    if body.get("repo_slug"):
        parts.append(str(body.get("repo_slug")))
    return " ".join(parts) if parts else None


def build_argv(action, body):
    """Map an action + run fields to action-dispatch.sh argv, or None if the
    action is unknown, a required selector is missing, or a path/identifier field
    carries an unsafe character. Values go straight into argv (no shell), so a
    hostile string can only be a bad argument; the _path_ok gate is an extra
    guard against a value that would be dangerous if it ever reached a shell."""
    # Reject any provided path/identifier field that is not shell-safe.
    for key in ("run_dir", "repo_path", "owner_repo", "remote", "repo_slug"):
        val = _s(body, key)
        if val and not _path_ok(val):
            return None

    if action == "stop":
        run_dir = _s(body, "run_dir")
        if not run_dir:
            return None
        return [DISPATCH, "stop", "--run-dir", run_dir]

    # clean and reset are the two teardown verbs. Same selector, same argv shape;
    # the difference (does the issue close?) lives entirely in the poller-side
    # scripts, so this layer stays a pure allowlist (issue #202).
    if action in ("clean", "reset"):
        issue = _s(body, "issue_number")
        if not issue.isdigit():
            return None
        argv = [DISPATCH, action, "--issue", issue]
        _add_repo(argv, body)
        return argv

    if action == "allow-merge":
        pr = _s(body, "pr_number")
        if not pr.isdigit():
            return None
        argv = [DISPATCH, "allow-merge", "--pr", pr]
        _add_repo(argv, body)
        return argv

    if action == "resume":
        issue = _s(body, "issue_number")
        if not issue.isdigit():
            return None
        argv = [DISPATCH, "resume", "--issue", issue]
        _add_repo(argv, body)
        run_dir = _s(body, "run_dir")
        if run_dir:
            argv += ["--run-dir", run_dir]
        remote = _s(body, "remote")
        if remote:
            argv += ["--remote", remote]
        slug = _s(body, "repo_slug")
        if slug:
            argv += ["--repo-slug", slug]
        return argv

    return None


def _add_repo(argv, body):
    repo = _s(body, "repo_path")
    if repo:
        argv += ["--repo", repo]
    owner = _s(body, "owner_repo")
    if owner:
        argv += ["--owner", owner]


def run_dispatch(argv):
    """Exec action-dispatch.sh (no shell). Return (rc, combined-output-tail)."""
    if not argv[0] or not os.access(argv[0], os.X_OK):
        return 3, "action-dispatch.sh is not executable at %r" % (argv[0],)
    try:
        proc = subprocess.run(
            argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            timeout=120, check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return 3, "could not run action: %s" % exc
    out = proc.stdout.decode("utf-8", "replace") if proc.stdout else ""
    # Surface the delegate's message as-is (rule 5), trimmed to a sane size.
    return proc.returncode, out.strip()[-4000:]


def main():
    if not TOKEN:
        sys.stderr.write("action-service: no shared token available (%s) — refusing.\n" % TOKEN_FILE)
        return 4
    if not ALLOWED_USERS:
        sys.stderr.write("action-service: no allowed users configured — refusing (fail-closed).\n")
        return 4
    if not ALLOWED_ORIGINS:
        sys.stderr.write("action-service: no allowed origins configured — refusing (fail-closed).\n")
        return 4
    if not DISPATCH:
        sys.stderr.write("action-service: RUN_ISSUES_ACTION_DISPATCH unset — refusing.\n")
        return 4

    try:
        httpd = ThreadingHTTPServer((BIND, PORT), Handler)
    except OSError as exc:
        sys.stderr.write("action-service: cannot bind %s:%s — %s\n" % (BIND, PORT, exc))
        return 3

    stop = {"flag": False}

    def _terminate(signum, frame):
        stop["flag"] = True
        # Shut the server down from another thread so serve_forever returns.
        threading.Thread(target=httpd.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, _terminate)
    signal.signal(signal.SIGINT, _terminate)

    sys.stderr.write("action-service: listening on %s:%s (users=%d origins=%d)\n"
                     % (BIND, PORT, len(ALLOWED_USERS), len(ALLOWED_ORIGINS)))
    try:
        httpd.serve_forever(poll_interval=0.5)
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
