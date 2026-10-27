#!/usr/bin/env python3
"""Real Linux machine setup: the Windows `irm` flow, for Linux.

One command installs the machine's tools and restores its state into the
LIVE home directory. This is deliberately different from the staging-only
tools next to it:

* ``restore.sh`` / ``linux_restore.py`` never touch live HOME; they stage.
* ``linux_packages.py`` without ``--execute`` only plans.
* This driver runs the plan, installs the current Linux-native builds of
  the proven tools, downloads the latest mainframe-production release via
  the vault, and ACTIVATES the portable conversions into live HOME.

Philosophy difference, stated plainly: the plan pins restores to the exact
Windows build versions, so most products stay "blocked" forever (no Linux
build can equal a Windows build byte-for-byte). Windows setup does not
work that way either -- winget installs the current build. Real mode
therefore installs current Linux-native builds, verifies a hash or
signature wherever the vendor publishes one, and says so wherever it
cannot (ngrok publishes no checksum; its install is HTTPS-only).

What real mode does NOT do:
* No Windows-only product is faked (rufus, ditto, sysinternals, ...).
  They are reported as skipped with the plan's reason.
* No terms are inferred: AnyDesk and the Android SDK stay skipped until
  the user accepts their terms explicitly (a future flag).
* No signature-trust decision is inferred: Tor Browser, Windscribe and
  WakaTime Desktop stay skipped (privileged service / account activation
  / desktop integration unvalidated).
* No secrets archive is decrypted or activated yet: the vault password
  for mainframe-production secrets is fetched and its presence reported,
  but the secrets zip is a Windows-layout archive and its Linux mapping
  is not validated. That is the next step, not this one.
* The vault leg (Bitwarden login, release download) needs the user's
  master password at runtime. It is prompted once via the terminal, never
  stored, and only ever passed to `bw` through the environment of that
  one child process.

Usage (from a checkout):
    python3 linux_real.py [--skip-vault] [--backup-root DIR] [--yes]
                          [--skip-packages] [--work-root DIR]

Via the one-liner (same shape as Windows):
    curl -fsSL https://raw.githubusercontent.com/FahadBinHussain/mainframe/main/bootstrap.sh \
        | bash -s -- -- --real
    # boot.sh --real clones the checkout if needed, then runs this driver.
"""

from __future__ import annotations

import argparse
import base64
import getpass
import hashlib
import hmac
import http.client
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

BW_SERVER = "https://vaultwardenn.onrender.com"
RELEASE_REPO = "FahadBinHussain/mainframe-production"
GH_TOKEN_RE = re.compile(r"gh[pousr]_[A-Za-z0-9_]{20,}")

# Extras installed directly (outside the pinned plan) with the route that
# was proven by hand on Ubuntu 24.04. Each returns (ok, note).
EXTRA_ORDER = ("pwsh", "vscode", "discord", "ngrok", "node", "pnpm",
               "gcloud", "steam")


def log(msg: str) -> None:
    print(f"mainframe-real: {msg}", flush=True)


def fail(msg: str) -> "SystemExit":
    raise SystemExit(f"mainframe-real: FATAL: {msg}")


def run(cmd: list[str], *, env: dict[str, str] | None = None,
        check: bool = True, input_text: str | None = None) -> subprocess.CompletedProcess:
    merged = dict(os.environ)
    if env:
        merged.update(env)
    proc = subprocess.run(cmd, env=merged, input=input_text,
                          capture_output=True, text=True)
    if check and proc.returncode != 0:
        raise RuntimeError(f"{cmd[0]} failed ({proc.returncode}): "
                           f"{(proc.stderr or proc.stdout or '').strip()[-400:]}")
    return proc


def sudo_prefix() -> list[str]:
    return [] if os.geteuid() == 0 else ["sudo"]


def apt_runner(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
    """subprocess runner for the plan executor: sudo only apt-get."""
    if cmd and cmd[0] == "apt-get":
        cmd = sudo_prefix() + cmd
    return subprocess.run(cmd, **kwargs)


def download(url: str, dest: Path, *, headers: dict[str, str] | None = None,
             attempts: int = 3) -> Path:
    """Download with retries, via curl. Python's urllib stalls on some
    CDNs from this network (discord.com: urllib times out at 30 s while
    curl finishes in ~1 s, any User-Agent), so urllib is not the
    transport here. A partial file is deleted, never kept: a timed-out
    discord deb once sat in /tmp looking complete."""
    last: Exception | None = None
    for _ in range(attempts):
        cmd = ["curl", "-fsSL", "--max-time", "600",
               "-A", "mainframe-real/1.0", "-o", str(dest)]
        for key, value in (headers or {}).items():
            cmd += ["-H", f"{key}: {value}"]
        cmd.append(url)
        proc = run(cmd, check=False)
        if proc.returncode == 0 and dest.exists() and dest.stat().st_size > 0:
            return dest
        last = RuntimeError(f"curl exit {proc.returncode}: "
                            f"{(proc.stderr or '').strip()[-200:]}")
        if dest.exists():
            dest.unlink()
        time.sleep(5)
    raise last  # type: ignore[misc]


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 256), b""):
            digest.update(chunk)
    return digest.hexdigest()


def github_json(url: str, token: str | None = None) -> dict:
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "mainframe-real/1.0",
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.load(resp)


def mkdirs(path: Path) -> None:
    """Create a directory tree never group-writable: the installer
    modules refuse destinations under a group-writable ancestor, and a
    default umask of 007 would otherwise make every driver-created
    parent fail their check (observed: 770 fake HOME). Mode 0o755 masked
    by umask 007 still yields 750, which passes (no group write).
    NOTE: os.makedirs applies the mode to the leaf only -- intermediate
    directories get 0o777 masked by umask (770 under umask 007) -- so
    each missing level is created explicitly."""
    path = Path(path)
    missing: list[Path] = []
    cur = path
    while not cur.exists():
        missing.append(cur)
        cur = cur.parent
    for directory in reversed(missing):
        directory.mkdir(mode=0o755)


def ensure_bin_link(bin_dir: Path, target: Path, name: str) -> None:
    mkdirs(bin_dir)
    link = bin_dir / name
    if link.is_symlink() or link.exists():
        link.unlink()
    link.symlink_to(target)


# ---------------------------------------------------------------- vault

def unseal_email(blob_path: Path, password: str) -> str:
    """Unseal bw-email.enc.json: PBKDF2-HMAC-SHA256 + AES-256-CBC + HMAC.

    Same construction as the PowerShell sealer (boot.ps1) and seal.html.
    AES decryption goes through the openssl CLI so no third-party Python
    package is needed; the key derivation and MAC check are stdlib.
    """
    blob = json.loads(blob_path.read_text())
    if blob.get("v") != 1 or blob.get("kdf") not in ("PBKDF2-SHA256",
                                                  "PBKDF2-HMAC-SHA256"):
        raise ValueError(f"unsupported sealed-email blob (v={blob.get('v')}, "
                         f"kdf={blob.get('kdf')})")
    salt = base64.b64decode(blob["salt"])
    iv = base64.b64decode(blob["iv"])
    ct = base64.b64decode(blob["ct"])
    mac = base64.b64decode(blob["mac"])
    key = hashlib.pbkdf2_hmac("sha256", password.encode(), salt,
                              int(blob["iter"]), dklen=64)
    expect = hmac.new(key[32:], salt + iv + ct, hashlib.sha256).digest()
    if not hmac.compare_digest(expect, mac):
        raise ValueError("sealed-email MAC mismatch: wrong master password "
                         "or a corrupted blob")
    proc = subprocess.run(
        ["openssl", "enc", "-d", "-aes-256-cbc",
         "-K", key[:32].hex(), "-iv", iv.hex()],
        input=ct, capture_output=True)
    if proc.returncode != 0:
        raise ValueError("openssl AES decryption failed: "
                         + proc.stderr.decode(errors="replace")[-200:])
    return proc.stdout.decode().strip()


# ---------------------------------------------------------------- password tab
# The agent running this script has no terminal the user can see, so a
# plain getpass prompt is useless there: the user cannot type into it.
# Instead, when stdin is not a tty, the script generates an ephemeral
# RSA keypair, prints a tab URL for the static page docs/vault-tab.html
# (served by GitHub Pages from this repo's main branch root), and waits
# for the browser to download the encrypted password file into
# ~/Downloads. The page makes no network requests: it encrypts in the
# browser with the one-time public key (passed in the URL fragment) and
# downloads only ciphertext. The private key never leaves this machine,
# the ciphertext file is deleted after decryption, and the password
# itself is never printed, logged, or sent anywhere. A human at a real
# terminal still gets the plain getpass prompt (stdin is a tty there).

TAB_CIPHER_NAME = "mainframe-vault-pass.enc"
TAB_WAIT_SECONDS = 600
DEFAULT_NTFY_SERVER = "https://ntfy.sh"


def load_config(checkout: Path | None = None) -> dict[str, str]:
    """Read mainframe.config.json if present from checkout or standard paths."""
    candidates = []
    if checkout:
        candidates.append(checkout / "mainframe.config.json")
    candidates.append(Path.cwd() / "mainframe.config.json")
    try:
        candidates.append(Path.home() / ".config" / "mainframe" / "mainframe.config.json")
    except Exception:
        pass
    for p in candidates:
        if p.is_file():
            try:
                data = json.loads(p.read_text(encoding="utf-8"))
                if isinstance(data, dict):
                    return data
            except Exception:
                pass
    return {}


def get_ntfy_topic(checkout: Path | None = None, explicit: str | None = None) -> str | None:
    """Resolve ntfy topic: explicit arg > MAINFRAME_NTFY_TOPIC env > mainframe.config.json."""
    if explicit and explicit.strip():
        return explicit.strip()
    from_env = os.environ.get("MAINFRAME_NTFY_TOPIC")
    if from_env and from_env.strip():
        return from_env.strip()
    from_cfg = load_config(checkout).get("ntfyTopic")
    if from_cfg and isinstance(from_cfg, str) and from_cfg.strip():
        return from_cfg.strip()
    return None


def dispatch_ntfy_unlock(ntfy_topic: str, url: str, hostname: str | None = None) -> bool:
    """Send phone approval push notification via ntfy with clickable link."""
    host = hostname
    if not host:
        try:
            host = os.uname().nodename
        except Exception:
            host = "linux-machine"
    endpoint = ntfy_topic if ntfy_topic.startswith(("http://", "https://")) else f"{DEFAULT_NTFY_SERVER}/{ntfy_topic}"
    body = (f"Headless restore on '{host}' requires Bitwarden vault unlock.\n"
            f"Tap to approve and transmit encrypted password.")
    headers = {
        "Title": f"Mainframe Restore: Vault Unlock ({host})",
        "Priority": "urgent",
        "Tags": "lock,key",
        "Click": url,
        "Actions": f"view, Unlock Vault, {url}, clear=true",
    }
    req = urllib.request.Request(endpoint, data=body.encode("utf-8"), headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status in (200, 201)
    except Exception as exc:
        log(f"WARNING: ntfy dispatch to {ntfy_topic} failed: {exc}")
        return False



# The tab page lives in the public tool repo, NOT the private release store.
TOOL_REPO = "FahadBinHussain/mainframe"


def _pages_base() -> str:
    owner, repo = TOOL_REPO.split("/", 1)
    return f"https://{owner.lower()}.github.io/{repo}"


def generate_tab_key(work_root: Path, *, reply_topic: str | None = None,
                     enable_relay: bool = True) -> tuple[str, Path, str | None]:
    """Generate an ephemeral RSA keypair; return (tab URL, private key path, reply_topic)."""
    tmp = work_root / "tmp"
    mkdirs(tmp)
    priv = tmp / "vault-tab.key"
    if priv.exists():
        priv.unlink()
    proc = subprocess.run(
        ["openssl", "genpkey", "-algorithm", "RSA",
         "-pkeyopt", "rsa_keygen_bits:2048", "-out", str(priv)],
        capture_output=True)
    if proc.returncode != 0:
        raise RuntimeError("openssl key generation failed")
    os.chmod(priv, 0o600)
    proc = subprocess.run(
        ["openssl", "pkey", "-pubout", "-outform", "DER", "-in", str(priv)],
        capture_output=True)
    if proc.returncode != 0:
        raise RuntimeError("openssl public key export failed")
    pub = base64.urlsafe_b64encode(proc.stdout).decode().rstrip("=")
    sid = reply_topic if reply_topic else (f"mf-vault-{secrets.token_hex(12)}" if enable_relay else None)
    fragment = f"k={pub}"
    if sid:
        fragment += f"&sid={sid}"
    return f"{_pages_base()}/docs/vault-tab.html#{fragment}", priv, sid


def try_open_phone_adb(url: str) -> bool:
    """If an Android phone is attached via ADB, wake screen and launch full-screen approval prompt."""
    adb = shutil.which("adb")
    if not adb:
        return False
    try:
        proc = subprocess.run([adb, "devices"], capture_output=True, text=True, timeout=5)
        lines = [line.strip() for line in proc.stdout.splitlines() if line.strip()]
        has_device = any(line.endswith("device") and not line.startswith("List") for line in lines)
        if has_device:
            log("phone attached via adb - popping up full-screen prompt on phone...")
            subprocess.run([adb, "shell", "input", "keyevent", "KEYCODE_WAKEUP"], capture_output=True, timeout=5)
            subprocess.run([adb, "shell", f"am start -a android.intent.action.VIEW -d '{url}'"], capture_output=True, timeout=5)
            return True
    except Exception as exc:
        log(f"adb phone wakeup attempt failed: {exc}")
    return False


def _try_open_tab(url: str) -> None:
    """Best effort: open the tab in a desktop browser. Agent runs ignore
    failure here because the agent opens the printed URL itself."""
    for cmd in (["xdg-open", url], ["open", url]):
        try:
            subprocess.Popen(cmd, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL)
            return
        except Exception:
            continue


def wait_for_tab_password(priv: Path, reply_topic: str | None = None) -> str:
    """Poll for encrypted password from relay or ~/Downloads, decrypt, clean up."""
    target = Path.home() / "Downloads" / TAB_CIPHER_NAME
    if target.exists():
        target.unlink()  # never decrypt a stale submission
    deadline = time.time() + TAB_WAIT_SECONDS
    raw_b64: str | None = None
    source = ""

    if reply_topic:
        log(f"waiting for password via phone approval relay ({reply_topic}) or ~/Downloads/{TAB_CIPHER_NAME} ...")
    else:
        log(f"waiting for password via ~/Downloads/{TAB_CIPHER_NAME} ...")

    while time.time() < deadline:
        if target.exists() and target.stat().st_size > 0:
            try:
                raw_b64 = target.read_text().strip()
                source = f"~/Downloads/{TAB_CIPHER_NAME}"
            finally:
                target.unlink(missing_ok=True)
            break

        if reply_topic:
            try:
                poll_url = f"{DEFAULT_NTFY_SERVER}/{reply_topic}/raw?poll=1"
                req = urllib.request.Request(poll_url)
                with urllib.request.urlopen(req, timeout=5) as resp:
                    if resp.status == 200:
                        body = resp.read().decode("utf-8").strip()
                        if body:
                            raw_b64 = body
                            source = f"ntfy relay ({reply_topic})"
                            break
            except Exception:
                pass

        time.sleep(2)
    else:
        raise RuntimeError(
            "no password arrived in the browser tab within "
            f"{TAB_WAIT_SECONDS // 60} minutes")

    if not raw_b64:
        raise RuntimeError("empty password ciphertext received")

    log(f"vault password ciphertext received via {source}")
    try:
        ct = base64.b64decode(raw_b64)
    except Exception:
        raise RuntimeError("tab password ciphertext was not valid base64")

    proc = subprocess.run(
        ["openssl", "pkeyutl", "-decrypt", "-inkey", str(priv),
         "-pkeyopt", "rsa_padding_mode:oaep",
         "-pkeyopt", "rsa_oaep_md:sha256",
         "-pkeyopt", "rsa_mgf1_md:sha256"],
        input=ct, capture_output=True)
    if proc.returncode != 0:
        raise RuntimeError("tab password decryption failed")
    return proc.stdout.decode()


def obtain_master_password(work_root: Path, checkout: Path,
                           ntfy_topic: str | None = None) -> str:
    """Obtain Bitwarden master password via 1-tap mobile biometric approval (Google-prompt style),
    falling back loudly to terminal input only if phone approval fails or times out."""
    resolved_topic = ntfy_topic or resolve_ntfy_topic(checkout) or DEFAULT_NTFY_TOPIC
    url, priv, reply_topic = generate_tab_key(work_root)
    try:
        log(f"==> 1-tap mobile approval for vault unlock: {url}")
        (work_root / "vault-tab.url").write_text(url)

        # 1. If phone is attached via ADB, wake and launch full screen immediately
        opened_adb = try_open_phone_adb(url)

        # 2. Dispatch urgent push notification via ntfy
        if resolved_topic:
            log(f"dispatching phone approval notification to ntfy topic: {resolved_topic}")
            sent = dispatch_ntfy_unlock(resolved_topic, url)
            if sent:
                log("push notification dispatched to phone successfully.")
            else:
                log("push notification dispatch failed; check topic or open the printed URL manually.")

        # 3. Best-effort open local desktop browser if present
        _try_open_tab(url)

        # 4. Await decrypted password from phone relay or local download
        try:
            return wait_for_tab_password(priv, reply_topic=reply_topic)
        except RuntimeError as exc:
            # Rule 8: surface fallback loudly
            log(f"WARNING: 1-tap mobile approval failed ({exc}). Falling back to MANUAL PASSWORD ENTRY.")
            if sys.stdin.isatty():
                return getpass.getpass("Bitwarden master password (unlocks the "
                                       "sealed email, then the vault): ")
            try:
                # A human piping the one-liner may still have /dev/tty
                with open("/dev/tty") as tty:
                    return getpass.getpass("Bitwarden master password: ", stream=tty)
            except Exception:
                raise RuntimeError("1-tap mobile approval failed and no interactive terminal available") from exc
    finally:
        priv.unlink(missing_ok=True)


def vault_session(work_root: Path, checkout: Path,
                  ntfy_topic: str | None = None) -> tuple[str, str]:
    """Log in to Vaultwarden via bw, return (gh_token, secrets_password).

    The master password is prompted once and reused for login + unlock,
    exactly like the Windows sealed-email flow.
    """
    import bitwarden_cli_linux as bw_tools
    bw = shutil.which("bw")
    if bw is None:
        dest = work_root / "vault" / "bitwarden-cli"
        mkdirs(dest.parent)
        log("installing bw CLI for the vault step ...")
        release = bw_tools.resolve_release("x86_64")
        bw_tools.install_release(release, dest)
        bw = str(dest / "bw")
    else:
        log(f"using existing bw at {bw}")
    status = json.loads(run([bw, "status"]).stdout)
    if status.get("serverUrl") != BW_SERVER:
        if status.get("status") != "unauthenticated":
            run([bw, "logout"], check=False)
        run([bw, "config", "server", BW_SERVER])
        status = json.loads(run([bw, "status"]).stdout)
    email = None
    blob = checkout / "bw-email.enc.json"
    if blob.exists():
        password = obtain_master_password(work_root, checkout, ntfy_topic=ntfy_topic)
        email = unseal_email(blob, password)
        log("email unsealed from bw-email.enc.json")
    else:
        email = os.environ.get("MAINFRAME_BW_EMAIL") or load_config(checkout).get("bitwardenEmail")
        if not email:
            if not sys.stdin.isatty():
                fail("headless run without bw-email.enc.json or bitwardenEmail config")
            email = input("Bitwarden email: ").strip()
        password = obtain_master_password(work_root, checkout, ntfy_topic=ntfy_topic)
    if status.get("status") == "unauthenticated":
        log("bw login ...")
        run([bw, "login", email, "--passwordenv", "BW_PASSWORD"],
            env={"BW_PASSWORD": password})
        run([bw, "lock"])
    log("bw unlock ...")
    session = run([bw, "unlock", "--raw", "--passwordenv", "BW_PASSWORD"],
                  env={"BW_PASSWORD": password}).stdout.strip()
    if not session:
        raise RuntimeError("bw unlock produced no session key")
    try:
        items = json.loads(run([bw, "list", "items", "--session", session]).stdout)
    except Exception:
        items = []
    gh_token = ""
    secrets_password = ""
    repo_owner = RELEASE_REPO.split("/")[0].lower()
    for item in items:
        name = (item.get("name") or "").lower()
        notes = (item.get("notes") or "")
        match = GH_TOKEN_RE.search(notes)
        if "github" in name and repo_owner in name and match and not gh_token:
            gh_token = match.group(0)
        if "mainframe-production" in name and not secrets_password:
            secrets_password = notes.strip()
    if not gh_token:
        for item in items:
            name = (item.get("name") or "").lower()
            notes = (item.get("notes") or "")
            match = GH_TOKEN_RE.search(notes)
            if "github" in name and match and not gh_token:
                gh_token = match.group(0)
                break
    log(f"vault: github token {'found' if gh_token else 'MISSING'}, "
        f"secrets password {'found' if secrets_password else 'MISSING'}")
    if not gh_token:
        raise RuntimeError("no GitHub token found in the vault; "
                           "cannot download the release")
    return gh_token, secrets_password


def download_release(work_root: Path, token: str) -> Path:
    """Download the latest mainframe-production release's quick zip."""
    rel = github_json(
        f"https://api.github.com/repos/{RELEASE_REPO}/releases/latest",
        token)
    tag = rel.get("tag_name", "?")
    log(f"latest release: {tag}")
    dest_dir = work_root / "release" / tag
    dest_dir.mkdir(parents=True, exist_ok=True)
    quick = dest_dir / "mainframe-quick.zip"
    for asset in rel.get("assets", []):
        if asset.get("name") == "mainframe-quick.zip":
            if quick.exists() and quick.stat().st_size == asset.get("size"):
                log("quick zip already downloaded, reusing it")
            else:
                log("downloading mainframe-quick.zip ...")
                download(asset.get("url") or asset["browser_download_url"], quick,
                         headers={"Authorization": f"Bearer {token}",
                                  "Accept": "application/octet-stream"})
            break
    else:
        raise RuntimeError("latest release has no mainframe-quick.zip asset")
    bad = zipfile.ZipFile(quick).testzip()
    if bad is not None:
        raise RuntimeError(f"downloaded quick zip is corrupt at {bad}")
    log(f"quick zip OK ({quick.stat().st_size // 1024 // 1024} MB)")
    return dest_dir


# ---------------------------------------------------------------- packages

def gws_root_for_plan() -> tuple[Path | None, str]:
    """The gws module refuses any destination under $HOME (its layout
    re-roots HOME inside the install dir), so its root lives outside
    home. Returns (root, note); root None means 'skip gws this run'."""
    root = Path("/opt/mainframe/tools/gws")
    if root.exists():
        return None, "already installed under /opt, skipped"
    try:
        if os.geteuid() == 0:
            mkdirs(root.parent)
            # Repair a parent chain left group-writable by an earlier run:
            # this directory tree is managed by real mode itself.
            for directory in (root.parent, root.parent.parent):
                if directory.stat().st_mode & 0o020:
                    os.chmod(directory, 0o755)
        else:
            run(["sudo", "mkdir", "-p", str(root.parent)])
            # The gws installer's own ancestor check refuses group-writable
            # parents, and mkdir under umask 007 makes them 770.
            run(["sudo", "chmod", "755", str(root.parent),
                 str(root.parent.parent)])
            user = os.environ.get("USER") or run(["id", "-un"]).stdout.strip()
            run(["sudo", "chown", user, str(root.parent)])
        return root, "fresh root under /opt"
    except Exception as exc:
        return None, f"no usable non-home root ({exc}); skipped"


def run_planned_packages(work_root: Path) -> dict:
    """Run the plan's own executor for planned actions, minus the ones
    whose executors are known-broken or policy-gated.

    Excluded from the executor selection (handled elsewhere or skipped):
    nodejs-lts (module rejects symlink modes), pnpm (stale member
    allowlist), the go/wacli action (executor refuses go by design),
    android-sdk + anydesk (terms not accepted here), gws when no
    non-home root is available (module refuses $HOME destinations).
    """
    import linux_packages as lp
    mkdirs(work_root / "tools")
    plan = lp.build_plan(HERE)
    kinds = {"apt", "native-archive", "bun-archive", "bitwarden-cli",
             "gws-archive"}
    excluded = {"nodejs-lts", "pnpm", "github.com/openclaw/wacli/cmd/wacli",
                "android-clt", "anydesk"}
    gws_root, gws_note = gws_root_for_plan()
    if gws_root is None:
        excluded.add("@googleworkspace/cli")
    selected = [a.name for a in plan.actions
                if a.status == "planned" and a.kind in kinds
                and a.name not in excluded]
    # The plan executor aborts the whole leg when any selected apt
    # package has no candidate. Some mapped names have no candidate on
    # this distro even though the tool is present (e.g. `which` ships
    # inside debianutils, an essential package). Drop those actions
    # individually and report them instead of failing everything.
    apt_skipped: list[dict] = []
    kept: list[str] = []
    for action in plan.actions:
        if action.name not in selected or action.kind != "apt":
            continue
        cmd = action.command or []
        pkgs = cmd[cmd.index("install") + 1:] if "install" in cmd else []
        missing = []
        for pkg in (p for p in pkgs if not p.startswith("-")):
            proc = subprocess.run(["apt-cache", "policy", pkg],
                                  capture_output=True, text=True, timeout=30)
            candidate = next((ln.split(":", 1)[1].strip()
                              for ln in proc.stdout.splitlines()
                              if ln.strip().startswith("Candidate:")), "")
            if not candidate or candidate == "(none)":
                missing.append(pkg)
        if missing:
            hint = " (already on PATH)" if shutil.which(action.name) else ""
            apt_skipped.append({"name": action.name,
                                "reason": f"no apt candidate for "
                                          f"{', '.join(missing)}{hint}"})
        else:
            kept.append(action.name)
    selected = [n for n in selected
                if n in kept or
                next(a for a in plan.actions if a.name == n).kind != "apt"]
    roots = {a.name: work_root / "tools" / a.name
             for a in plan.actions
             if a.name in selected and a.kind == "native-archive"}
    report = lp.execute(
        plan, selected=selected, runner=apt_runner,
        bitwarden_cli_root=work_root / "tools" / "bitwarden-cli",
        bun_root=work_root / "tools" / "bun",
        gws_root=gws_root,
        native_roots=roots)
    skipped = [{"name": a.name, "reason": (a.reason or "")[:200]}
               for a in plan.actions
               if a.name not in selected and a.status == "blocked"]
    return {"executed": report.get("executed", []),
            "covered": report.get("covered", {}),
            "skipped_blocked": skipped,
            "skipped_no_candidate": apt_skipped,
            "executor_skipped": report.get("skipped", []),
            "gws": gws_note,
            "plan_blockers": list(plan.blockers or [])}


# ---------------------------------------------------------------- extras

def extra_pwsh(work_root: Path, bin_dir: Path) -> tuple[bool, str]:
    """Current PowerShell: GitHub release tarball, hash verified against
    Microsoft's hashes.sha256 (UTF-16LE-encoded -- the gotcha that broke
    the pwsh metadata module)."""
    rel = github_json("https://api.github.com/repos/PowerShell/PowerShell/releases/latest")
    assets = {a["name"]: a for a in rel.get("assets", [])}
    tar_name = "powershell-latest-linux-x64.tar.gz"
    # The release asset is versioned; find the linux-x64 tarball by suffix.
    tar = next((a for n, a in assets.items()
                if n.endswith("-linux-x64.tar.gz")), None)
    hashes = next((a for n, a in assets.items() if n == "hashes.sha256"), None)
    if tar is None or hashes is None:
        return False, "release assets missing tarball or hashes.sha256"
    tmp = Path(tempfile.mkdtemp(prefix="mainframe-pwsh-"))
    tar_path = download(tar["browser_download_url"], tmp / "pwsh.tar.gz")
    raw = download(hashes["browser_download_url"], tmp / "hashes.sha256").read_bytes()
    try:
        text = raw.decode("utf-16")
    except UnicodeDecodeError:
        text = raw.decode("utf-8", errors="replace")
    want = None
    for line in text.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[1].strip("*") == tar["name"]:
            want = parts[0].lower()
    if want is None:
        return False, "tarball not listed in hashes.sha256"
    if sha256_file(tar_path) != want:
        return False, "SHA-256 mismatch for pwsh tarball"
    dest = work_root / "tools" / "pwsh"
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir(parents=True)
    with tarfile.open(tar_path) as tf:
        tf.extractall(dest, filter="data")
    ensure_bin_link(bin_dir, dest / "pwsh", "pwsh")
    return True, f"{rel.get('tag_name', '?')} (hash verified)"


def dpkg_install(deb: Path) -> None:
    proc = run(sudo_prefix() + ["dpkg", "-i", str(deb)], check=False)
    if proc.returncode == 0:
        return
    # Missing dependencies: let apt resolve them, then retry once.
    run(sudo_prefix() + ["apt-get", "install", "-f", "-y"])
    run(sudo_prefix() + ["dpkg", "-i", str(deb)])


def extra_deb(url: str, label: str) -> tuple[bool, str]:
    tmp = Path(tempfile.mkdtemp(prefix="mainframe-deb-"))
    deb = download(url, tmp / f"{label}.deb")
    dpkg_install(deb)
    return True, "deb installed"


def extra_ngrok(work_root: Path, bin_dir: Path) -> tuple[bool, str]:
    """Stable ngrok zip. The vendor publishes NO checksum for it, so this
    install is HTTPS-only -- reported as such, never claimed verified."""
    tmp = Path(tempfile.mkdtemp(prefix="mainframe-ngrok-"))
    zf = download("https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-amd64.zip",
                  tmp / "ngrok.zip")
    dest = work_root / "tools" / "ngrok"
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir(parents=True)
    with zipfile.ZipFile(zf) as z:
        z.extract("ngrok", dest)
    (dest / "ngrok").chmod(0o755)
    ensure_bin_link(bin_dir, dest / "ngrok", "ngrok")
    return True, "stable zip (no vendor checksum: HTTPS-only trust)"


def extra_node(work_root: Path, bin_dir: Path) -> tuple[bool, str]:
    """Current Node LTS tarball, SHA-256 verified against nodejs.org's
    SHASUMS256.txt. (The node_lts module rejects the tarball because its
    only group/world-writable entries are symlinks, whose modes are
    meaningless on extraction -- bypassed here, not papered over.)"""
    req = urllib.request.Request("https://nodejs.org/dist/index.json",
                                 headers={"User-Agent": "mainframe-real/1.0"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        index = json.load(resp)
    entry = next(e for e in index if e.get("lts"))
    version = entry["version"]
    tmp = Path(tempfile.mkdtemp(prefix="mainframe-node-"))
    sums = download(f"https://nodejs.org/dist/{version}/SHASUMS256.txt",
                    tmp / "SHASUMS256.txt").read_text()
    tar_name = f"node-{version}-linux-x64.tar.xz"
    want = next((ln.split()[0] for ln in sums.splitlines()
                 if ln.split()[1:2] == [tar_name]), None)
    if want is None:
        return False, "tarball not listed in SHASUMS256.txt"
    tar_path = download(f"https://nodejs.org/dist/{version}/{tar_name}",
                        tmp / tar_name)
    if sha256_file(tar_path) != want:
        return False, "SHA-256 mismatch for node tarball"
    dest = work_root / "tools" / "node"
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir(parents=True)
    with tarfile.open(tar_path) as tf:
        tf.extractall(dest, filter="data")
    root = next(dest.iterdir())
    for name in ("node", "npm", "npx"):
        ensure_bin_link(bin_dir, root / "bin" / name, name)
    return True, f"{version} (hash verified)"


def extra_pnpm(work_root: Path, bin_dir: Path) -> tuple[bool, str]:
    """Current pnpm standalone tarball. Upstream layout changed (root
    `pnpm` binary + dist/ tree) vs the module's pinned member list, so
    the module route is bypassed: extract the whole tarball, link root."""
    rel = github_json("https://api.github.com/repos/pnpm/pnpm/releases/latest")
    tar = next((a for a in rel.get("assets", [])
                if a["name"].startswith("pnpm-standalone.js")
                or a["name"] == "pnpm-linux-x64"), None)
    asset = next((a for a in rel.get("assets", [])
                  if a["name"] == "pnpm-standalone.js"), None)
    if asset is None:
        # Fall back to the tarball form used by recent releases.
        asset = next((a for a in rel.get("assets", [])
                      if a["name"].endswith("linux-x64.tar.gz")), None)
    if asset is None:
        return False, "no standalone asset in latest pnpm release"
    tmp = Path(tempfile.mkdtemp(prefix="mainframe-pnpm-"))
    path = download(asset["browser_download_url"], tmp / asset["name"])
    dest = work_root / "tools" / "pnpm"
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir(parents=True)
    if path.suffix == ".gz":
        with tarfile.open(path) as tf:
            tf.extractall(dest, filter="data")
        binary = dest / "pnpm"
        if not binary.exists():
            found = [p for p in dest.rglob("pnpm") if p.is_file()]
            binary = found[0] if found else binary
    else:
        binary = dest / "pnpm"
        shutil.copyfile(path, binary)
    binary.chmod(0o755)
    ensure_bin_link(bin_dir, binary, "pnpm")
    return True, f"{rel.get('tag_name', '?')} (no vendor checksum: HTTPS-only trust)"


def extra_gcloud() -> tuple[bool, str]:
    """Google Cloud CLI via Google's signed apt repo (the route diagnosed
    when a silent key-import failure left a NO_PUBKEY repo behind)."""
    tmp = Path(tempfile.mkdtemp(prefix="mainframe-gcloud-"))
    key_raw = download("https://packages.cloud.google.com/apt/doc/apt-key.gpg",
                       tmp / "apt-key.gpg")
    if key_raw.stat().st_size == 0:
        return False, "downloaded apt key is empty"
    keyring = tmp / "cloud.google.gpg"
    run(["gpg", "--dearmor", "-o", str(keyring), str(key_raw)])
    if keyring.stat().st_size == 0:
        return False, "gpg dearmor produced an empty keyring"
    run(sudo_prefix() + ["cp", str(keyring),
                         "/usr/share/keyrings/cloud.google.gpg"])
    # apt downloads as the _apt user: a 660 keyring (umask 007) reads as
    # NO_PUBKEY even though the right key is inside. World-readable is
    # required and intended for a public signing key.
    run(sudo_prefix() + ["chmod", "644",
                         "/usr/share/keyrings/cloud.google.gpg"])
    run(sudo_prefix() + ["tee", "/etc/apt/sources.list.d/google-cloud-sdk.list"],
        input_text="deb [signed-by=/usr/share/keyrings/cloud.google.gpg] "
                   "https://packages.cloud.google.com/apt cloud-sdk main\n")
    run(sudo_prefix() + ["apt-get", "update"])
    run(sudo_prefix() + ["apt-get", "install", "-y", "google-cloud-cli"])
    return True, "apt repo + key verified by install"


def extra_steam() -> tuple[bool, str]:
    run(sudo_prefix() + ["dpkg", "--add-architecture", "i386"])
    run(sudo_prefix() + ["apt-get", "update"])
    run(sudo_prefix() + ["apt-get", "install", "-y", "steam-installer"])
    return True, "steam-installer (i386 enabled)"


def run_extras(work_root: Path, bin_dir: Path) -> dict:
    results: dict[str, dict] = {}
    for name in EXTRA_ORDER:
        try:
            if name == "pwsh":
                ok, note = extra_pwsh(work_root, bin_dir)
            elif name == "vscode":
                ok, note = extra_deb(
                    "https://code.visualstudio.com/sha/download?build=stable&os=linux-deb-x64",
                    "vscode")
            elif name == "discord":
                ok, note = extra_deb(
                    "https://discord.com/api/download?platform=linux&format=deb",
                    "discord")
            elif name == "ngrok":
                ok, note = extra_ngrok(work_root, bin_dir)
            elif name == "node":
                ok, note = extra_node(work_root, bin_dir)
            elif name == "pnpm":
                ok, note = extra_pnpm(work_root, bin_dir)
            elif name == "gcloud":
                ok, note = extra_gcloud()
            elif name == "steam":
                ok, note = extra_steam()
            else:
                ok, note = False, "unknown extra"
        except Exception as exc:  # extras never abort the whole run
            ok, note = False, f"{type(exc).__name__}: {exc}"[:300]
        results[name] = {"ok": ok, "note": note}
        log(f"extra {name}: {'OK' if ok else 'FAILED'} -- {note}")
    # Scratch downloads live under work_root/tmp (see main); drop them so a
    # rerun does not inherit stale partials.
    shutil.rmtree(work_root / "tmp", ignore_errors=True)
    return results


# ---------------------------------------------------------------- restore

def confirm_activation(file_count: int) -> bool:
    try:
        tty = open("/dev/tty", "r+")
    except OSError:
        return False
    with tty:
        tty.write(f"mainframe-real: activate {file_count} file(s) into live "
                  f"$HOME ({Path.home()})? Existing files are backed up "
                  f"first. [y/N] ")
        tty.flush()
        return tty.readline().strip().lower() in ("y", "yes")


def activate(staging: Path, home: Path, work_root: Path,
             only_paths: set[str] | None = None) -> dict:
    """Copy home-staging into live HOME. Overwritten files are backed up
    first; symlinks in staging are refused; symlink targets in HOME are
    recorded, not followed."""
    src_root = staging / "home-staging"
    files = sorted(p for p in src_root.rglob("*") if p.is_file() or p.is_symlink())
    stamp = time.strftime("%Y-%m-%d-%H%M%S")
    backup_root = work_root / "restore-backup" / stamp
    activated: list[str] = []
    backed_up: list[str] = []
    refused: list[str] = []
    for src in files:
        rel = src.relative_to(src_root)
        if only_paths is not None and rel.as_posix() not in only_paths:
            continue
        target = home / rel
        if src.is_symlink():
            refused.append(str(rel))
            continue
        if target.is_symlink():
            (backup_root / "symlink-targets.txt").parent.mkdir(parents=True, exist_ok=True)
            with open(backup_root / "symlink-targets.txt", "a") as fh:
                fh.write(f"{rel} -> {os.readlink(target)}\n")
            target.unlink()
        elif target.exists():
            dest = backup_root / rel
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(target, dest)
            backed_up.append(str(rel))
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, target)
        if rel.as_posix() == "AGENTS.md" and sha256_file(src) != sha256_file(target):
            raise RuntimeError("AGENTS.md activation failed byte-for-byte verification")
        activated.append(str(rel))
    return {"activated": activated, "backed_up": backed_up,
            "refused_symlinks": refused,
            "backup_dir": str(backup_root) if backed_up else ""}


def run_restore(backup_root: Path, work_root: Path, yes: bool,
                restore_global_agents: bool = False) -> dict:
    import linux_restore as lr
    stamp = time.strftime("%Y-%m-%d-%H%M%S")
    staging = work_root / "restore-staging" / stamp
    # copy_recovery refuses to create the destination's parent.
    staging.parent.mkdir(parents=True, exist_ok=True)
    report = lr.copy_recovery(backup_root, staging, apply_portable=True,
                              mode="quick", convert_portable=True,
                              include_global_agents=restore_global_agents)
    staged = sorted(str(p.relative_to(staging / "home-staging"))
                    for p in (staging / "home-staging").rglob("*")
                    if p.is_file() or p.is_symlink()) \
        if (staging / "home-staging").exists() else []
    log(f"staged {len(staged)} portable file(s); "
        f"recovered members kept under {staging / 'recovered'} (not activated: "
        f"Windows paths do not map to Linux home)")
    if restore_global_agents:
        # This explicit option authorizes only the root-level instructions file.
        # Other candidates stay staged unless the existing --yes flag authorizes all.
        selected = None if yes else {"AGENTS.md"}
        activation = activate(staging, Path.home(), work_root,
                              only_paths=selected)
        activated = set(activation["activated"])
        if "AGENTS.md" not in activated:
            raise RuntimeError("Requested global AGENTS restore did not activate HOME/AGENTS.md")
        log("restored exact top-level AGENTS.md to HOME/AGENTS.md; byte-for-byte verification passed")
        remaining = [path for path in staged if path not in activated]
        note = (f"{len(remaining)} other candidate(s) remain staged; use --yes to activate all"
                if remaining and not yes else "")
        if note:
            log(note)
        return {"staged": staged, "activation": activation,
                "staging": str(staging), "status": report.get("operational_status"),
                "note": note}
    if not staged:
        return {"staged": [], "activation": None,
                "note": "no portable conversions; nothing to activate"}
    if not yes and not confirm_activation(len(staged)):
        return {"staged": staged, "activation": None,
                "note": "activation declined or no terminal; staging kept at "
                        f"{staging}"}
    activation = activate(staging, Path.home(), work_root)
    log(f"activated {len(activation['activated'])} file(s) into live HOME; "
        f"backed up {len(activation['backed_up'])} overwritten file(s)")
    return {"staged": staged, "activation": activation,
            "staging": str(staging),
            "status": report.get("operational_status")}


# ---------------------------------------------------------------- main

def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Real Linux machine setup "
        "(live home, like the Windows irm flow).")
    ap.add_argument("--skip-vault", action="store_true",
                    help="skip vault login + release download")
    ap.add_argument("--backup-root", type=Path,
                    help="directory containing mainframe-quick.zip "
                         "(overrides the release download)")
    ap.add_argument("--yes", action="store_true",
                    help="activate into live HOME without asking")
    ap.add_argument("--restore-global-agents", action="store_true",
                    help="restore only the exact top-level AGENTS.md to HOME/AGENTS.md; other staged files remain offline unless --yes is also given")
    ap.add_argument("--skip-packages", action="store_true",
                    help="skip the package leg (restore only)")
    ap.add_argument("--work-root", type=Path,
                    default=Path.home() / ".local" / "share" / "mainframe",
                    help="tool installs, staging and backups live here")
    ap.add_argument("--ntfy-topic", type=str, default=None,
                    help="ntfy.sh topic for phone approval of vault unlock")
    args = ap.parse_args(argv)

    if sys.platform != "linux" or sys.version_info < (3, 10):
        fail("Linux + Python 3.10 or newer required")
    if args.restore_global_agents and args.skip_vault and args.backup_root is None:
        fail("--restore-global-agents requires a backup source; pass --backup-root or allow the vault release download")
    if (args.restore_global_agents and args.backup_root is not None
            and not (args.backup_root / "mainframe-quick.zip").is_file()):
        fail("--restore-global-agents requested but --backup-root has no mainframe-quick.zip")
    work_root: Path = args.work_root
    bin_dir = Path.home() / ".local" / "bin"
    mkdirs(bin_dir)
    mkdirs(work_root / "tools")
    # Scratch downloads must NOT use /tmp: on many machines it is a small
    # tmpfs, and a 100 MB deb plus a 100 MB tarball fills it mid-run
    # (observed: "No space left on device" with 6.5 GB free on /).
    scratch = work_root / "tmp"
    mkdirs(scratch)
    tempfile.tempdir = str(scratch)
    failures: list[str] = []
    report: dict = {"work_root": str(work_root)}

    # Prereqs (same set as --setup-tools, idempotent).
    log("installing prerequisites ...")
    try:
        run(sudo_prefix() + ["apt-get", "update"])
        run(sudo_prefix() + ["apt-get", "install", "-y", "git", "curl",
                             "ca-certificates", "python3", "openssl"])
    except Exception as exc:
        failures.append(f"prereqs: {exc}")
        log(f"prereqs FAILED: {exc}")

    # Vault + release.
    backup_root = args.backup_root
    ntfy_topic = get_ntfy_topic(HERE, explicit=args.ntfy_topic)
    if ntfy_topic and not args.skip_vault:
        log(f"phone approval enabled via ntfy topic: {ntfy_topic}")
    if not args.skip_vault:
        try:
            gh_token, secrets_pw = vault_session(work_root, HERE, ntfy_topic=ntfy_topic)
            report["secrets_password_present"] = bool(secrets_pw)
            backup_root = backup_root or download_release(work_root, gh_token)
        except Exception as exc:
            failures.append(f"vault/release: {exc}")
            log(f"vault/release FAILED: {exc}")
        finally:
            bw = shutil.which("bw")
            if bw:
                run([bw, "lock"], check=False)
    elif backup_root is None:
        log("vault skipped and no --backup-root: restore leg skipped")

    # Packages.
    if args.skip_packages:
        log("package leg skipped (--skip-packages)")
    else:
        try:
            report["packages"] = run_planned_packages(work_root)
            log(f"plan executor: "
                f"{len(report['packages']['executed'])} executed, "
                f"{len(report['packages']['skipped_blocked'])} blocked skipped")
        except Exception as exc:
            failures.append(f"plan executor: {exc}")
            log(f"plan executor FAILED: {exc}")
        report["extras"] = run_extras(work_root, bin_dir)

    # Restore + activation.
    if backup_root is not None and (backup_root / "mainframe-quick.zip").exists():
        try:
            report["restore"] = run_restore(
                backup_root, work_root, args.yes, args.restore_global_agents)
        except Exception as exc:
            failures.append(f"restore: {exc}")
            log(f"restore FAILED: {exc}")
    elif backup_root is not None:
        log(f"restore skipped: no mainframe-quick.zip in {backup_root}")

    report["failures"] = failures
    print(json.dumps(report, indent=2, sort_keys=True, default=str))
    if failures:
        log(f"real mode finished WITH FAILURES: {'; '.join(failures)}")
        return 1
    log("real mode complete.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
