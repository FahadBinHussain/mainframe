"""Shared harness for the relay contract tests.

The relay - topic, server, page base, poll, backoff, expired marker - lives
in vault-approval.psm1. the tests drive THAT module through pwsh, so both
platforms are checked against one implementation instead of two copies.

the module is copied into a temporary directory before it is imported: the
lookup for mainframe.config.json starts in the module's own folder, and the
checkout's own config file would otherwise shadow the test's profile root.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
MODULES = ("vault-approval.psm1", "vault-secret.psm1", "mainframe-paths.psm1", "mainframe-json.psm1")


def pwsh_executable() -> str | None:
    """The pwsh to drive the module with, if there is one."""
    found = shutil.which("pwsh")
    if found:
        return found
    for candidate in ("/usr/bin/pwsh", "/usr/local/bin/pwsh", "/opt/microsoft/powershell/7/pwsh"):
        if Path(candidate).is_file():
            return candidate
    return None


PWSH = pwsh_executable()


def module_dir() -> Path:
    """A temporary copy of the modules, without the checkout's config file."""
    target = Path(tempfile.mkdtemp(prefix="mainframe-relay-modules-"))
    for name in MODULES:
        shutil.copy2(REPO / name, target / name)
    return target


def run_pwsh(script: str, *, env: dict[str, str] | None = None,
             timeout: float = 120, modules: Path | None = None) -> subprocess.CompletedProcess:
    """Run a pwsh script that imports the approval module and prints one JSON line."""
    if PWSH is None:
        raise unittest.SkipTest("pwsh is not available on this machine")
    folder = modules or module_dir()
    body = f"""
$ErrorActionPreference = 'Stop'
$InformationPreference = 'SilentlyContinue'
Import-Module '{folder / 'vault-approval.psm1'}' -Force -DisableNameChecking
{script}
"""
    script_path = folder / "driver.ps1"
    script_path.write_text(body, encoding="utf-8")
    merged = dict(os.environ)
    merged.update(env or {})
    # the config lookup also checks the working directory, so the script runs
    # in a folder without a mainframe.config.json of its own
    workdir = Path(tempfile.mkdtemp(prefix="mainframe-relay-cwd-"))
    try:
        proc = subprocess.run([PWSH, "-NoLogo", "-NoProfile", "-NonInteractive", "-File", str(script_path)],
                              capture_output=True, text=True, env=merged, timeout=timeout, cwd=str(workdir))
    except subprocess.TimeoutExpired as exc:
        # a killed run is a legitimate outcome for the backoff test
        def _as_text(value):
            if value is None:
                return ""
            return value.decode("utf-8", errors="replace") if isinstance(value, bytes) else value
        return subprocess.CompletedProcess(exc.cmd, -9, _as_text(exc.stdout), _as_text(exc.stderr))
    finally:
        shutil.rmtree(workdir, ignore_errors=True)
    return proc


def run_pwsh_json(script: str, **kwargs) -> dict:
    """Run a pwsh script and parse the JSON document it printed."""
    proc = run_pwsh(script, **kwargs)
    if proc.returncode != 0:
        raise AssertionError(f"pwsh failed ({proc.returncode}): {proc.stderr[-800:]}")
    out = proc.stdout.strip()
    if not out:
        raise AssertionError(f"pwsh printed nothing: {proc.stderr[-400:]}")
    return json.loads(out.splitlines()[-1])


class _RelayHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):  # noqa: N802 - http.server api
        self.server.requests.append(("GET", self.path))
        if self.server.rate_limit > 0:
            self.server.rate_limit -= 1
            self.send_response(429)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        body = self.server.body.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):  # noqa: N802 - http.server api
        length = int(self.headers.get("Content-Length") or 0)
        data = self.rfile.read(length) if length else b""
        text = data.decode("utf-8", errors="replace")
        self.server.requests.append(("POST", self.path, text))
        # ntfy keeps every message on the topic: the raw poll returns them all
        self.server.body = (self.server.body + "\n" + text).strip() if self.server.body else text
        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *args):
        pass


class RelayServer:
    """A local ntfy-compatible relay, so the poll path can be tested offline."""

    def __init__(self, body: str = "", rate_limit: int = 0):
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), _RelayHandler)
        self.server.requests = []
        self.server.body = body
        self.server.rate_limit = rate_limit
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    def __enter__(self) -> "RelayServer":
        self.thread.start()
        return self

    def __exit__(self, *exc):
        self.server.shutdown()
        self.server.server_close()

    @property
    def base(self) -> str:
        host, port = self.server.server_address[:2]
        return f"http://{host}:{port}"

    @property
    def requests(self):
        return self.server.requests

    def posts(self):
        return [r for r in self.server.requests if r[0] == "POST"]

    def gets(self):
        return [r for r in self.server.requests if r[0] == "GET"]


def profile_root(tmp: Path, config: dict | None = None) -> Path:
    """An isolated profile root with an optional mainframe.config.json."""
    root = tmp / "profile"
    (root / "accounts" / "bitwarden").mkdir(parents=True, exist_ok=True)
    if config is not None:
        (root / "mainframe.config.json").write_text(json.dumps(config), encoding="utf-8")
    return root
