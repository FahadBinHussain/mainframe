#!/usr/bin/env python3
"""Real Linux machine setup: the Windows `irm` flow, for Linux.

One command installs the machine's tools and restores its state into the
LIVE home directory. This is deliberately different from the staging-only
tools next to it:

* ``restore.sh`` / ``linux_restore.py`` never touch live HOME; they stage.
* ``linux_packages.py`` without ``--execute`` only plans.
* This driver runs the plan, installs the current Linux-native builds of
  the proven tools, downloads the latest mainframe-production release via
  the vault, syncs the private repo with that same vault token (the Linux
  counterpart of the Windows ``Sync-AutomataPrivateRepo``), and ACTIVATES the
  portable restore into live HOME.

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
import hashlib
import json
import os
import secrets
import shlex
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

RELEASE_REPO = "FahadBinHussain/mainframe-production"

# Extras installed directly (outside the pinned plan) with the route that
# was proven by hand on Ubuntu 24.04. Each returns (ok, note).
EXTRA_ORDER = ("pwsh", "vscode", "discord", "ngrok", "node", "pnpm",
               "gcloud", "steam")


def log(msg: str) -> None:
    print(f"mainframe-real: {msg}", flush=True)


def fail(msg: str) -> "SystemExit":
    raise SystemExit(f"mainframe-real: FATAL: {msg}")


def run(cmd: list[str], *, env: dict[str, str] | None = None,
        check: bool = True, input_text: str | None = None,
        timeout: float | None = None) -> subprocess.CompletedProcess:
    merged = dict(os.environ)
    # a freshly installed pwsh initialises on its first start and would open a
    # connection to Microsoft's telemetry endpoint (dc.services.visualstudio.com).
    # this runner drives pwsh for the vault flow on a machine whose egress is
    # governed, so telemetry is off for every child - the flow should never
    # raise an approval card for something nobody asked for.
    merged["POWERSHELL_TELEMETRY_OPTOUT"] = "1"
    merged["POWERSHELL_UPDATECHECK"] = "Off"
    if env:
        merged.update(env)
    try:
        proc = subprocess.run(cmd, env=merged, input=input_text,
                              capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired as exc:
        # Without a bound, a hung child (an apt-get update waiting on a lock
        # or an unreachable mirror) blocks the whole run forever - a headless
        # container just sits there. Name the command and the budget instead.
        raise RuntimeError(f"{cmd[0]} timed out after {timeout:g}s: "
                           f"{' '.join(cmd[:5])}") from exc
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
#
# There is ONE vault flow now: vault-flow.ps1 (powershell). windows runs it
# through the module, linux runs it through that cli. the approval, the
# unseal, the session cache, the TTL and the item parsing all live in the
# powershell implementation - there is no second python copy, so the two
# platforms cannot drift apart.
#
# what linux still owns: making sure a pwsh and a bw CLI exist, and handing
# the flow its arguments.

VAULT_FLOW_TIMEOUT_SECONDS = 1800
PWSH_ROOT = Path("tools") / "pwsh"
VAULT_RESULT_FILE = "vault-flow.json"
# apt must not be able to stall the whole run (see the prereqs leg).
APT_UPDATE_TIMEOUT_SECONDS = 120
APT_INSTALL_TIMEOUT_SECONDS = 300


def pwsh_executable(work_root: Path) -> str | None:
    """The pwsh this run may use: PATH first, then the local install."""
    found = shutil.which("pwsh")
    if found:
        return found
    local = work_root / PWSH_ROOT / "pwsh"
    if local.is_file():
        return str(local)
    return None


def ensure_pwsh(work_root: Path) -> str:
    """Make sure a pwsh exists; install the official linux build if not.

    The installer is pwsh_linux: the archive is bounded, pinned to two
    independently published digests, extracted into an isolated tree and
    published into a destination that must not exist yet.
    """
    existing = pwsh_executable(work_root)
    if existing:
        return existing
    import pwsh_linux as pwsh_tools
    destination = work_root / PWSH_ROOT
    if destination.exists():
        raise RuntimeError(
            f"the PowerShell install root {destination} exists but has no usable pwsh - "
            "remove it by hand and run again")
    mkdirs(destination.parent)
    log("installing the official PowerShell linux build for the vault step ...")
    release = pwsh_tools.resolve_release("x86_64")
    result = pwsh_tools.install_release(release, destination)
    log(f"PowerShell {result['pwsh_version']} installed at {destination} (sha256 verified)")
    return str(destination / "pwsh")


def bw_executable(work_root: Path) -> str | None:
    """The bw CLI this run may use: PATH first, then the local install."""
    found = shutil.which("bw")
    if found:
        return found
    local = work_root / "vault" / "bitwarden-cli" / "bw"
    if local.is_file():
        return str(local)
    return None


def ensure_bw(work_root: Path) -> str:
    """Make sure the bw CLI exists; install the official linux build if not."""
    existing = bw_executable(work_root)
    if existing:
        return existing
    import bitwarden_cli_linux as bw_tools
    destination = work_root / "vault" / "bitwarden-cli"
    mkdirs(destination.parent)
    log("installing the official Bitwarden CLI for the vault step ...")
    release = bw_tools.resolve_release("x86_64")
    bw_tools.install_release(release, destination)
    return str(destination / "bw")


def vault_flow_command(checkout: Path, pwsh: str, bw: str, *,
                       ntfy_topic: str | None = None,
                       ntfy_server: str | None = None,
                       pages_base: str | None = None,
                       output_path: Path | None = None,
                       lock: bool = False,
                       lock_if_stale: bool = False) -> list[str]:
    """The argv that runs the ONE vault flow."""
    flow = Path(checkout) / "vault-flow.ps1"
    if not flow.is_file():
        raise RuntimeError(f"the vault flow cli is missing: {flow}")
    cmd = [pwsh, "-NoLogo", "-NoProfile", "-NonInteractive", "-File", str(flow),
           "-Json", "-Checkout", str(checkout), "-BwPath", bw]
    if ntfy_topic:
        cmd += ["-NtfyTopic", ntfy_topic]
    if ntfy_server:
        cmd += ["-Server", ntfy_server]
    if pages_base:
        cmd += ["-PagesBase", pages_base]
    if output_path is not None:
        cmd += ["-OutputPath", str(output_path)]
    if lock:
        cmd += ["-Lock"]
    if lock_if_stale:
        cmd += ["-LockIfStale"]
    return cmd


def vault_session(work_root: Path, checkout: Path,
                  ntfy_topic: str | None = None,
                  ntfy_server: str | None = None,
                  pages_base: str | None = None) -> tuple[str, str]:
    """Run the vault flow and return (github_token, secrets_password).

    A fresh cached session means no phone approval and no master password -
    the flow decides that, exactly like it does on windows.
    """
    pwsh = ensure_pwsh(work_root)
    bw = ensure_bw(work_root)
    result_file = work_root / "tmp" / VAULT_RESULT_FILE
    mkdirs(result_file.parent)
    if result_file.exists():
        result_file.unlink()
    cmd = vault_flow_command(checkout, pwsh, bw, ntfy_topic=ntfy_topic,
                              ntfy_server=ntfy_server, pages_base=pages_base,
                              output_path=result_file)
    log("running the vault flow (vault-flow.ps1) ...")
    run(cmd, timeout=VAULT_FLOW_TIMEOUT_SECONDS)
    if not result_file.is_file():
        raise RuntimeError("the vault flow produced no result document")
    try:
        payload = json.loads(result_file.read_text(encoding="utf-8-sig"))
    except (ValueError, OSError) as exc:
        raise RuntimeError(f"the vault flow result could not be read: {exc}") from exc
    if not isinstance(payload, dict):
        raise RuntimeError("the vault flow result is not a JSON object")
    token = str(payload.get("githubToken") or "")
    password = str(payload.get("secretsPassword") or "")
    if not token:
        raise RuntimeError("no GitHub token found in the vault; "
                           "cannot download the release")
    log(f"github token found; mainframe-production secrets password "
        f"{'found' if password else 'MISSING'}")
    return token, password


TOOL_REPO = "FahadBinHussain/mainframe"


def prereqs_present() -> list[str]:
    """Return the prerequisites that are missing ([] when all are there).

    The apt leg used to run on every single invocation, so a container whose
    package mirror is unreachable sat on apt-get update for two minutes before
    anything else happened - the windows side does not reinstall what it
    already has, and neither should this.
    """
    missing = [tool for tool in ("git", "curl", "python3", "openssl")
               if shutil.which(tool) is None]
    if not Path("/etc/ssl/certs/ca-certificates.crt").is_file():
        missing.append("ca-certificates")
    return missing


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
    """Current PowerShell on linux, installed by pwsh_linux.

    The installer is the same one the vault leg uses: the archive is bounded,
    pinned to two independently published digests, extracted into an isolated
    tree that refuses links and traversal, and published atomically into a
    destination that must not exist yet. It never touches PATH, profiles or
    credentials - the bin link is the only visible change.
    """
    import pwsh_linux as pwsh_tools
    destination = work_root / PWSH_ROOT
    if pwsh_tools.is_installed(destination):
        ensure_bin_link(bin_dir, destination / "pwsh", "pwsh")
        return True, f"already installed at {destination}"
    if destination.exists():
        return False, (f"the PowerShell install root {destination} exists but has no "
                       "usable pwsh - remove it by hand and run again")
    try:
        release = pwsh_tools.resolve_release("x86_64")
        result = pwsh_tools.install_release(release, destination)
    except Exception as exc:
        return False, f"the official PowerShell linux install failed: {exc}"
    ensure_bin_link(bin_dir, destination / "pwsh", "pwsh")
    return True, f"{result['version']} (sha256 verified, pwsh {result['pwsh_version']})"


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


# The private repo holds the per-domain scripts and the patchers. Windows
# quick and full restore both sync it (restore.ps1 Sync-AutomataPrivateRepo)
# and the Linux live flow does the same, so both platforms end up with the
# same checkout in the same place: the Downloads root.
PRIVATE_REPO = "FahadBinHussain/automata-private"
PRIVATE_REPO_URL = f"https://github.com/{PRIVATE_REPO}.git"
PRIVATE_REPO_NAME = "automata-private"

CREDENTIAL_HELPER_SOURCE = """#!/usr/bin/env python3
# git credential helper for the private repo clone (mainframe linux_real.py).
#
# The vault token is read from the environment, so it never lands in argv, in a
# git config file, or on disk. git calls this with the credential operation as
# the only argument; only "get" answers, "store" and "erase" are ignored so
# nothing is persisted.
import os
import sys

if sys.argv[1:2] == ["get"]:
    token = os.environ.get("MF_GH_TOKEN", "")
    if token:
        sys.stdout.write("username=x-access-token\\npassword=%s\\n" % token)
"""


def private_repo_dir() -> Path:
    """Same Downloads root the public checkout lands in (boot.sh clones
    mainframe to ~/Downloads/mainframe)."""
    return Path.home() / "Downloads" / PRIVATE_REPO_NAME


def write_credential_helper(work_root: Path) -> Path:
    """Write the private credential helper (no secret inside it)."""
    helper = work_root / "private-git-credential.py"
    helper.parent.mkdir(parents=True, exist_ok=True)
    helper.write_text(CREDENTIAL_HELPER_SOURCE, encoding="utf-8")
    helper.chmod(0o700)
    return helper


def git_credential_args(work_root: Path, token: str | None
                         ) -> tuple[list[str], dict[str, str], str]:
    """Credential source for the private clone, named out loud.

    Mirrors the Windows restore: gh's own credential helper (the line
    `gh auth setup-git` writes) scoped to the one command, with
    `credential.helper=` first so no ambient helper can answer as another
    account. A Linux box rarely has gh, so the same vault token is fed through
    a private helper script instead - the token stays in the child's
    environment, never in argv and never on disk.

    Returns (git args, extra env, human name of the credential source).
    """
    if not token:
        if os.environ.get("GH_TOKEN"):
            log("no vault token in this run - using the GH_TOKEN already in this "
                "machine's environment")
            source = "the GH_TOKEN already in this machine's environment"
        else:
            log("no vault token in this run - using this machine's own git "
                "credentials for the private repo")
            source = "this machine's own git credentials"
        return [], {}, source
    if shutil.which("gh"):
        log("authenticating with the GH_TOKEN github profile "
            "(gh auth git-credential)")
        return (["-c", "credential.helper=",
                 "-c", "credential.helper=!gh auth git-credential"],
                {"GH_TOKEN": token}, "the GH_TOKEN github profile")
    helper = write_credential_helper(work_root)
    log("gh not found - authenticating with a private credential helper "
        "(MF_GH_TOKEN)")
    return (["-c", "credential.helper=",
             "-c", f"credential.helper=!{shlex.quote(sys.executable)} "
                   f"{shlex.quote(str(helper))}"],
            {"MF_GH_TOKEN": token}, "a private credential helper")


def sync_automata_private(work_root: Path, token: str | None) -> dict:
    """Clone or fast-forward the private repo, the way Windows restore does.

    Windows quick and full restore both sync it because the ditto/alist/
    opencode patchers live there, and a failed sync aborts the restore there.
    The Linux live flow syncs it for the same reason: the token the vault
    already handed us is what authenticates it, and a restore that ends
    without the private checkout is not the restore that was asked for.
    """
    dest = private_repo_dir()
    args, env, source = git_credential_args(work_root, token)
    if dest.exists() and not (dest / ".git").exists():
        raise RuntimeError(
            f"{dest} exists but is not a git checkout - the private clone "
            "refuses to write over it. move it aside and re-run.")
    dest.parent.mkdir(parents=True, exist_ok=True)
    if (dest / ".git").exists():
        log(f"{PRIVATE_REPO_NAME} repo already exists at {dest}, pulling latest")
        cmd = ["git", *args, "-C", str(dest), "pull", "--ff-only"]
        action = "pulled"
    else:
        log(f"Cloning {PRIVATE_REPO_URL} to {dest}")
        cmd = ["git", *args, "clone", PRIVATE_REPO_URL, str(dest)]
        action = "cloned"
    # GIT_TERMINAL_PROMPT=0: a headless restore must fail fast and loud
    # instead of waiting for a username nobody is there to type.
    proc = run(cmd, env={**env, "GIT_TERMINAL_PROMPT": "0"}, check=False)
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or "").strip()[-400:]
        raise RuntimeError(
            f"{PRIVATE_REPO_NAME} sync failed (git exit {proc.returncode}) at "
            f"{dest} using {source}. the token must be able to read "
            f"{PRIVATE_REPO_URL}. git said: {detail}")
    return {"path": str(dest), "repo": PRIVATE_REPO_URL,
            "credential_source": source, "action": action}


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


def run_restore_leg(backup_root: Path | None, work_root: Path, *,
                    yes: bool, restore_global_agents: bool,
                    skip_private_repo: bool, gh_token: str | None
                    ) -> tuple[dict, list[str]]:
    """Sync the private checkout, then restore. Returns (report, failures).

    The private checkout comes first, the same order the Windows restore uses
    (sync, then the patchers that live in it). A failed sync aborts the
    restore leg: shipping a restored machine without the private repo is the
    "unpatched but reported as success" bug the Windows side already fixed.
    """
    report: dict = {}
    failures: list[str] = []
    if backup_root is None:
        return report, failures
    if not (backup_root / "mainframe-quick.zip").exists():
        log(f"restore skipped: no mainframe-quick.zip in {backup_root}")
        return report, failures
    private_repo_ok = True
    if skip_private_repo:
        log(f"private repo sync skipped (--skip-private-repo): "
            f"{PRIVATE_REPO_NAME} will NOT be cloned")
    else:
        try:
            report["private_repo"] = sync_automata_private(work_root, gh_token)
            log(f"{PRIVATE_REPO_NAME} {report['private_repo']['action']} at "
                f"{report['private_repo']['path']} "
                f"(credential source: "
                f"{report['private_repo']['credential_source']})")
        except Exception as exc:
            private_repo_ok = False
            failures.append(f"private repo: {exc}")
            log(f"private repo FAILED: {exc}")
            log("the restore leg needs the private checkout, so it was not run")
    if not private_repo_ok:
        return report, failures
    try:
        report["restore"] = run_restore(
            backup_root, work_root, yes, restore_global_agents)
    except Exception as exc:
        failures.append(f"restore: {exc}")
        log(f"restore FAILED: {exc}")
    return report, failures


# ---------------------------------------------------------------- main

def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Real Linux machine setup "
        "(live home, like the Windows irm flow).")
    ap.add_argument("--skip-vault", action="store_true",
                    help="skip vault login + release download")
    ap.add_argument("--lock-vault", action="store_true",
                    help="lock the vault and purge the cached session key, then exit "
                         "(the linux twin of vault-lock.ps1). the next run asks the "
                         "phone again")
    ap.add_argument("--backup-root", type=Path,
                    help="directory containing mainframe-quick.zip "
                         "(overrides the release download)")
    ap.add_argument("--yes", action="store_true",
                    help="activate into live HOME without asking")
    ap.add_argument("--restore-global-agents", action="store_true",
                    help="restore only the exact top-level AGENTS.md to HOME/AGENTS.md; other staged files remain offline unless --yes is also given")
    ap.add_argument("--skip-packages", action="store_true",
                    help="skip the package leg (restore only)")
    ap.add_argument("--skip-private-repo", action="store_true",
                    help="skip the private repo clone/pull in the restore leg "
                         "(the checkout is NOT synced, and the run says so)")
    ap.add_argument("--work-root", type=Path,
                    default=Path.home() / ".local" / "share" / "mainframe",
                    help="tool installs, staging and backups live here")
    ap.add_argument("--ntfy-topic", type=str, default=None,
                    help="ntfy.sh topic for phone approval of vault unlock")
    ap.add_argument("--ntfy-server", type=str, default=None,
                    help="approval relay base url (default: ntfy.sh). point this at a "
                         "reachable ntfy-compatible relay when the egress proxy denies ntfy.sh")
    ap.add_argument("--pages-base", type=str, default=None,
                    help="base url serving docs/vault-tab.html (default: the GitHub Pages "
                         "url of the public tool repo). set it to a first-party host to keep "
                         "the tap link off a raw github.io path")
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

    # --lock-vault: the linux twin of vault-lock.ps1. locks the cli and purges
    # the cached session key, so the next run asks the phone again. the rule
    # lives in the ONE vault flow, so linux calls it instead of repeating it.
    if args.lock_vault:
        pwsh = pwsh_executable(work_root)
        if not pwsh:
            fail("no pwsh available to run the vault lock - the vault flow is the "
                 "powershell implementation on both platforms, so install powershell "
                 "first (the vault leg installs the official linux build for you)")
        bw = bw_executable(work_root)
        if not bw:
            fail("no bw CLI found to lock the vault")
        run(vault_flow_command(HERE, pwsh, bw, lock=True), timeout=120)
        log("vault locked and the cached session purged")
        return 0

    # Prereqs (same set as --setup-tools, idempotent).
    missing = prereqs_present()
    if not missing:
        log("prerequisites already present - skipping the apt leg")
    else:
        log(f"installing prerequisites (missing: {', '.join(missing)}) ...")
        try:
            # Bounded: a container without working apt sources (or with another
            # apt holding the lock) otherwise hangs here forever and the vault
            # leg never runs. A failed prereq is recorded and the flow continues.
            run(sudo_prefix() + ["apt-get", "update"], timeout=APT_UPDATE_TIMEOUT_SECONDS)
            run(sudo_prefix() + ["apt-get", "install", "-y", "git", "curl",
                                 "ca-certificates", "python3", "openssl"],
                timeout=APT_INSTALL_TIMEOUT_SECONDS)
        except Exception as exc:
            failures.append(f"prereqs: {exc}")
            log(f"prereqs FAILED: {exc}")

    # Vault + release.
    backup_root = args.backup_root
    gh_token = ""
    if not args.skip_vault:
        # the topic, the relay and the page base are resolved by the ONE vault
        # flow, from the same config file windows reads. python passes only
        # what the operator typed, so the precedence lives in one place and
        # the two machines cannot drift apart.
        try:
            gh_token, secrets_pw = vault_session(work_root, HERE,
                                                 ntfy_topic=args.ntfy_topic,
                                                 ntfy_server=args.ntfy_server,
                                                 pages_base=args.pages_base)
            report["secrets_password_present"] = bool(secrets_pw)
            backup_root = backup_root or download_release(work_root, gh_token)
        except Exception as exc:
            failures.append(f"vault/release: {exc}")
            log(f"vault/release FAILED: {exc}")
        finally:
            # a cached session stays usable - and the cli stays unlocked - until
            # the TTL lapses, exactly like the windows side. only lock when
            # there is no fresh session to reuse - and THAT rule lives in the
            # one vault flow, so linux asks it instead of repeating it.
            pwsh = pwsh_executable(work_root)
            bw = bw_executable(work_root)
            if pwsh and bw:
                run(vault_flow_command(HERE, pwsh, bw, lock_if_stale=True),
                    timeout=120, check=False)
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
    restore_report, restore_failures = run_restore_leg(
        backup_root, work_root, yes=args.yes,
        restore_global_agents=args.restore_global_agents,
        skip_private_repo=args.skip_private_repo, gh_token=gh_token)
    report.update(restore_report)
    failures.extend(restore_failures)

    report["failures"] = failures
    print(json.dumps(report, indent=2, sort_keys=True, default=str))
    if failures:
        log(f"real mode finished WITH FAILURES: {'; '.join(failures)}")
        return 1
    log("real mode complete.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
