#!/usr/bin/env python3
"""Plan and, only when explicitly requested, restore allowlisted packages on Linux.

The default operation is a read-only plan.  This is a conservative Debian/Ubuntu
adapter; it does not claim parity with a Windows installation and never reads
secret archive payloads.
"""
from __future__ import annotations
import argparse
import json
import os
import platform
import subprocess
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Iterable

APT_MAP = {
    "7zip": "7zip", "cacert": "ca-certificates", "cmake": "cmake",
    "coreutils": "coreutils", "curl": "curl", "fd": "fd-find", "ffmpeg": "ffmpeg",
    "findutils": "findutils", "gawk": "gawk", "gcc": "gcc", "gh": "gh",
    "git": "git", "git-filter-repo": "git-filter-repo", "grep": "grep", "go": "golang-go",
    "make": "make", "nodejs-lts": "nodejs", "openjdk21": "openjdk-21-jdk",
    "php": "php", "postgresql": "postgresql", "python": "python3",
    "python312": "python3.12", "ripgrep": "ripgrep", "sed": "sed",
    "unzip": "unzip", "vlc": "vlc", "wget": "wget", "which": "which",
    "zip": "zip", "scrcpy": "scrcpy", "obs-studio": "obs-studio",
    "flameshot": "flameshot", "qbittorrent": "qbittorrent", "mpv-git": "mpv",
    "rclone": "rclone", "yt-dlp": "yt-dlp", "syncplay": "syncplay", "rustup": "rustup",
}
# These are known to be Windows-oriented in this inventory.  They are not
# silently omitted: each becomes an explicit blocker.
WINDOWS_ONLY = {
    "7zip19.00-helper", "autohotkey", "bulk-crap-uninstaller", "dark",
    "ditto", "innounp", "micmute", "rufus", "sysinternals",
    "vcredist-aio", "windows-terminal", "winfsp-np",
}
# A Linux package may exist, but this adapter deliberately has no validated,
# pinned source/translation for it.
UNVALIDATED_NATIVE = {
    "android-clt", "alist", "bitwarden-cli", "gcloud", "cloudflared",
    "deno", "bun", "ngrok", "yq", "anydesk", "parsec", "pwsh", "steam",
    "tor-browser", "discord", "opencode2", "nuget",
}
VARIANT_DRIFT = {"nodejs-lts", "mpv-git"}
WINDOWS_WINGET = {
    "AnyDesk.AnyDesk", "AutoHotkey.AutoHotkey", "GPSoftware.DirectoryOpus",
    "Windscribe.Windscribe", "StartIsBack.StartAllBack", "Tonec.InternetDownloadManager",
    "Wakatime.DesktopWakatime",
}
MANIFESTS = ("scoop-allowed.json", "winget-allowed.json", "pnpm-allowed.json", "uv-allowed.json", "go-allowed.json")

@dataclass
class Action:
    kind: str
    name: str
    command: list[str] | None = None
    version: str | None = None
    tags: list[str] = field(default_factory=list)
    source: str = ""
    status: str = "planned"
    reason: str = ""

@dataclass
class Plan:
    supported: bool
    distro: str
    architecture: str
    actions: list[Action]
    blockers: list[str] = field(default_factory=list)
    def to_dict(self) -> dict[str, Any]:
        return {"supported": self.supported, "distro": self.distro,
                "architecture": self.architecture, "actions": [asdict(a) for a in self.actions],
                "blockers": self.blockers}

def _load(path: Path, default: Any) -> Any:
    if not path.is_file():
        return default
    with path.open(encoding="utf-8") as fh:
        return json.load(fh)

def host_info() -> tuple[str, str]:
    distro = ""
    try:
        for line in Path("/etc/os-release").read_text(encoding="utf-8").splitlines():
            if line.startswith("ID="):
                distro = line.split("=", 1)[1].strip().strip('"').lower()
                break
    except OSError:
        pass
    arch = {"amd64": "x86_64", "arm64": "aarch64"}.get(platform.machine().lower(), platform.machine().lower())
    return distro, arch

def _safe_arg(value: Any) -> bool:
    return isinstance(value, str) and bool(value) and not value.startswith("-") and not any(c in value for c in "\x00\r\n")

def _requirements_actions(root: Path, blockers: list[str], require_pip_freeze: bool = False) -> list[Action]:
    freeze = root / "pip-freeze.txt"
    files = [freeze] if freeze.is_file() else []
    # requirements*.txt remains supported for hand-reviewed development fixtures;
    # an actual backup root must use its canonical pip-freeze.txt manifest.
    if not files and not require_pip_freeze:
        files = [p for p in (root / "requirements.txt", root / "requirements-linux.txt") if p.is_file()]
    if require_pip_freeze and (not freeze.is_file() or not freeze.read_text(encoding="utf-8").strip()):
        reason = f"Required pip-freeze.txt is missing or empty in backup root: {root}"
        blockers.append(reason)
        return [Action("pip-venv", "pip-freeze.txt", status="blocked", reason=reason, source=str(freeze))]
    out: list[Action] = []
    for req in files:
        lines = [x.strip() for x in req.read_text(encoding="utf-8").splitlines()
                 if x.strip() and not x.lstrip().startswith("#")]
        if not any(not line.startswith('-') for line in lines):
            reason = f'No package declarations in {req.name}; refusing an empty environment rebuild.'
            blockers.append(reason)
            out.append(Action('pip-venv', req.name, status='blocked', reason=reason, source=str(req)))
            continue
        bad = []
        for line in lines:
            package = line.split("[", 1)[0].split("==", 1)[0].split(">=", 1)[0].split("<=", 1)[0].strip().lower()
            if package in {"pywin32", "pypiwin32", "windows-curses", "pywin32-ctypes"} or any(marker in line.lower() for marker in ('win_amd64.whl', 'win32.whl', 'file:///c:', 'file:///d:', ' @ c:', ' @ d:')):
                bad.append(line)
        if bad:
            reason = f"Windows-only Python requirements in {req.name}; {len(bad)} declaration(s) need explicit translation (including pywin32 when present)."
            blockers.append(reason)
            out.append(Action("pip-venv", req.name, status="blocked", reason=reason, source=str(req)))
        else:
            out.append(Action("pip-venv", req.name, ["python3.12", "-m", "venv", ".linux-restore-venv"], source=str(req)))
            out.append(Action("pip-install", req.name, [".linux-restore-venv/bin/python", "-m", "pip", "install", "--requirement", str(req)], source=str(req)))
    return out

def _manifest(repo: Path, filename: str, blockers: list[str]) -> dict[str, Any]:
    path = repo / filename
    if not path.is_file():
        blockers.append(f"Required allowlist is missing: {filename}")
        return {}
    try:
        value = _load(path, None)
    except (OSError, ValueError, TypeError) as exc:
        blockers.append(f"Cannot read allowlist {filename}: {exc}")
        return {}
    if not isinstance(value, dict):
        blockers.append(f"Invalid allowlist object: {filename}")
        return {}
    key = 'apps' if filename == 'scoop-allowed.json' else 'packages'
    if not isinstance(value.get(key), list) or not value[key]:
        blockers.append(f"Missing or empty allowlist array: {filename}")
        return {}
    return value

def _blocked(kind: str, name: str, reason: str, source: str) -> Action:
    return Action(kind, name, status="blocked", reason=reason, source=source)

def build_plan(repo: Path, backup_root: Path | None = None, distro: str | None = None, architecture: str | None = None) -> Plan:
    actual_distro, actual_arch = host_info()
    distro, architecture = distro if distro is not None else actual_distro, architecture if architecture is not None else actual_arch
    supported = distro in {"debian", "ubuntu"} and architecture in {"x86_64", "aarch64"}
    blockers: list[str] = []
    if not supported:
        blockers.append(f"Unsupported Linux host declaration: distro={distro!r}, architecture={architecture!r}; only Debian/Ubuntu x86_64/aarch64 are supported")
        return Plan(False, distro, architecture, [], blockers)
    actions: list[Action] = []
    scoop = _manifest(repo, "scoop-allowed.json", blockers)
    winget = _manifest(repo, "winget-allowed.json", blockers)
    pnpm = _manifest(repo, "pnpm-allowed.json", blockers)
    uv = _manifest(repo, "uv-allowed.json", blockers)
    go = _manifest(repo, "go-allowed.json", blockers)
    for name in scoop.get("apps", []):
        if not _safe_arg(name):
            reason = f"Invalid Scoop package name: {name!r}"; blockers.append(reason); actions.append(_blocked("apt", str(name), reason, "scoop"))
        elif name in WINDOWS_ONLY:
            reason = f"Windows-only package: {name}"; blockers.append(reason); actions.append(_blocked("apt", name, reason, "scoop"))
        elif name in UNVALIDATED_NATIVE:
            reason = f"No validated Linux source/adapter for package: {name}"; blockers.append(reason); actions.append(_blocked("apt", name, reason, "scoop"))
        elif name in VARIANT_DRIFT:
            reason = f"Linux mapping is not the requested variant: {name}"; blockers.append(reason); actions.append(_blocked("apt", name, reason, "scoop"))
        elif name in APT_MAP:
            packages = [APT_MAP[name]]
            if name == 'python312':
                packages.append('python3.12-venv')
            if name == 'go':
                packages.extend(['build-essential', 'libsqlite3-dev'])
            elevate = [] if os.geteuid() == 0 else ["sudo", "-n"]
            actions.append(Action("apt", name, [*elevate, "apt-get", "install", "-y", *packages], source="scoop"))
        else:
            reason = f"No explicit native equivalent for Scoop package: {name}"; blockers.append(reason); actions.append(_blocked("apt", name, reason, "scoop"))
    for pkg in winget.get("packages", []):
        ident = pkg.get("id", "") if isinstance(pkg, dict) else pkg
        if not isinstance(ident, str) or not ident.strip():
            reason = f"Invalid WinGet package ID: {ident!r}"
            blockers.append(reason)
            actions.append(_blocked("winget", str(ident), reason, "winget"))
        else:
            reason = f"Windows WinGet declaration has no validated native package/state adapter: {ident}"
            blockers.append(reason)
            actions.append(_blocked("winget", ident, reason, "winget"))
    for name in pnpm.get("packages", []):
        reason = f"Invalid pnpm package name: {name!r}"
        if not _safe_arg(name): blockers.append(reason); actions.append(_blocked("pnpm", str(name), reason, "pnpm"))
        else: actions.append(Action("pnpm", name, ["pnpm", "add", "--global", "--", name], source="pnpm"))
    for item in uv.get("packages", []):
        name = item.get("name") if isinstance(item, dict) else item
        version = item.get("version") if isinstance(item, dict) else None
        spec = f"{name}=={version}" if version else name
        if not _safe_arg(name) or (version is not None and not _safe_arg(version)):
            reason = f"Invalid uv package or version: {item!r}"; blockers.append(reason); actions.append(_blocked("uv", str(name), reason, "uv"))
        else: actions.append(Action("uv", name, ["uv", "tool", "install", "--", spec], version=version, source="uv"))
    for item in go.get("packages", []):
        if isinstance(item, dict): path, version, tags = item.get("path", ""), item.get("version") or 'latest', item.get("tags", []) or []
        else: path, version, tags = item, 'latest', []
        if not _safe_arg(path) or (version is not None and not _safe_arg(version)) or not isinstance(tags, list) or not all(_safe_arg(x) for x in tags):
            reason = f"Invalid Go package declaration: {item!r}"; blockers.append(reason); actions.append(_blocked("go", str(path), reason, "go")); continue
        cmd = ["go", "install"]
        if tags: cmd.extend(["-tags", ",".join(tags)])
        cmd.append(f"{path}@{version}" if version else path)
        actions.append(Action("go", path, cmd, version=version, tags=tags, source="go"))
    root = backup_root or repo
    actions.extend(_requirements_actions(root, blockers, require_pip_freeze=backup_root is not None))
    return Plan(True, distro, architecture, actions, blockers)

def _apt_preflight(actions: list[Action], runner: Any) -> None:
    for action in actions:
        packages = action.command[action.command.index('install') + 1:] if action.command else []
        for package in (p for p in packages if not p.startswith('-')):
            try:
                result = runner(["apt-cache", "policy", package], check=False, shell=False,
                                capture_output=True, text=True, timeout=30)
            except subprocess.TimeoutExpired as exc:
                raise RuntimeError(f"apt package metadata lookup timed out: {package}") from exc
            if getattr(result, "returncode", 1) != 0:
                raise RuntimeError(f"apt package metadata lookup failed: {package}")
            output = getattr(result, "stdout", "") or ""
            candidate = next((line.split(":", 1)[1].strip() for line in output.splitlines() if line.strip().startswith("Candidate:")), "")
            if not candidate or candidate == "(none)":
                raise RuntimeError(f"No apt candidate available for mapped package: {package}")

def execute(plan: Plan, selected: Iterable[str] | None = None, runner=subprocess.run) -> dict[str, Any]:
    if not plan.supported: raise RuntimeError("Unsupported host; no restore commands are permitted")
    actual = host_info()
    if actual != (plan.distro, plan.architecture):
        raise RuntimeError(f"Plan host declaration does not match actual host: plan={plan.distro}/{plan.architecture}, actual={actual[0]}/{actual[1]}")
    selected_set = set(selected) if selected else set()
    known = {a.name for a in plan.actions}
    unknown = selected_set - known
    if unknown: raise RuntimeError("Unknown --select action name(s): " + ", ".join(sorted(unknown)))
    if not selected_set and plan.blockers:
        raise RuntimeError('Plan contains unresolved manifest or package blockers; no full execution is permitted.')
    unresolved = [a for a in plan.actions if a.status == "blocked" and (not selected_set or a.name in selected_set)]
    if unresolved: raise RuntimeError("Unresolved blockers prevent full restore: " + "; ".join(a.reason for a in unresolved))
    chosen = [a for a in plan.actions if a.status == "planned" and (not selected_set or a.name in selected_set)]
    if any(a.kind == "pip-venv" and (Path(".linux-restore-venv").exists() or Path(".linux-restore-venv").is_symlink()) for a in chosen):
        raise RuntimeError("Refusing to overwrite existing .linux-restore-venv; choose a new working directory")
    _apt_preflight([a for a in chosen if a.kind == "apt"], runner)
    report = {"executed": [], "failed": None, "skipped": [a.name for a in plan.actions if a not in chosen], "partial": bool(selected_set), "note": "Explicit selection is a partial restore; it does not claim full parity." if selected_set else "Full planned restore."}
    for action in chosen:
        try:
            result = runner(action.command, check=False, shell=False, timeout=300)
        except subprocess.TimeoutExpired as exc:
            report["failed"] = {"name": action.name, "error": f"timed out after {exc.timeout}s"}
            raise RuntimeError(f"{action.name} timed out") from exc
        except OSError as exc: report["failed"] = {"name": action.name, "error": str(exc)}; raise
        code = getattr(result, "returncode", result if isinstance(result, int) else 0)
        if code != 0:
            report["failed"] = {"name": action.name, "returncode": code}; raise RuntimeError(f"{action.name} failed with exit code {code}")
        report["executed"].append(action.name)
    return report

def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--repo", type=Path, default=Path(__file__).parent)
    ap.add_argument("--backup-root", type=Path)
    ap.add_argument("--execute", action="store_true", help="execute reviewed planned commands; default is dry plan")
    ap.add_argument("--select", action="append", default=[])
    ap.add_argument("--distro"); ap.add_argument("--arch", dest="architecture")
    args = ap.parse_args(argv)
    plan = build_plan(args.repo, args.backup_root, args.distro, args.architecture)
    if args.execute:
        if plan.blockers and not args.select:
            print(json.dumps({"plan": plan.to_dict(), "error": "blockers present; use --select for an explicitly partial restore"}, indent=2)); return 2
        try: report = execute(plan, args.select); output = {"plan": plan.to_dict(), "report": report}
        except subprocess.TimeoutExpired as exc:
            detail = f"command timed out after {exc.timeout}s"
            print(json.dumps({"plan": plan.to_dict(), "error": detail}, indent=2)); return 1
        except (RuntimeError, OSError) as exc: print(json.dumps({"plan": plan.to_dict(), "error": str(exc)}, indent=2)); return 1
    else:
        output = plan.to_dict()
        # A dry plan is still useful output, but blockers must be visible to
        # automation rather than reported as a successful restore.
        exit_code = 3 if (plan.blockers or not plan.supported) else 0
    print(json.dumps(output, indent=2)); return exit_code if not args.execute else 0
if __name__ == "__main__": raise SystemExit(main())
