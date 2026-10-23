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
import zipfile
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Iterable

import android_commandline_tools as android_tools
import anydesk_linux as anydesk_tools
import bitwarden_cli_linux as bitwarden_tools
import bun_linux as bun_tools
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
# Scoop's pinned extractor helper is covered by the native extractor, not a
# Linux 19.00 version pin or a second package installation.
PACKAGE_COVERAGE = {"7zip19.00-helper": "7zip"}
# These are known to be Windows-oriented in this inventory.  They are not
# silently omitted: each becomes an explicit blocker.
WINDOWS_ONLY = {
    "autohotkey", "bulk-crap-uninstaller", "dark",
    "ditto", "innounp", "micmute", "rufus", "sysinternals",
    "vcredist-aio", "windows-terminal", "winfsp-np",
}
# A Linux package may exist, but this adapter deliberately has no validated,
# pinned source/translation for it.
UNVALIDATED_NATIVE = {
    "alist", "gcloud", "cloudflared",
    "deno", "bun", "ngrok", "yq", "parsec", "pwsh", "steam",
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
    covered_by: str | None = None
    archive: dict[str, str] | None = None
    sdk_layout: str | None = None
    acceptance_required: bool = False

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

def _anydesk_action(architecture: str, blockers: list[str], source: str) -> Action:
    """Resolve package intent only; never import Windows identity or service state."""
    try:
        release = anydesk_tools.resolve_release(architecture)
    except (RuntimeError, OSError, ValueError) as exc:
        reason = f"Cannot resolve official Linux AnyDesk: {exc}"
        blockers.append(reason)
        return _blocked("anydesk-deb", "anydesk", reason, source)
    return Action("anydesk-deb", "anydesk", version=release["version"], source=source,
                  archive=release, acceptance_required=True,
                  reason="Official AnyDesk Linux DEB; Linux and Windows versions are independent. "
                         "Installation requires explicit AnyDesk terms acceptance and permission for the "
                         "vendor package to install/start its service. Xorg is required for incoming "
                         "sessions; Wayland supports outgoing only. No Windows identity, credentials, "
                         "unattended password or service configuration is imported. Runtime is untested.")

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
        elif name in PACKAGE_COVERAGE:
            target = PACKAGE_COVERAGE[name]
            actions.append(Action("apt", name, source="scoop", status="covered", covered_by=target,
                                  reason=f"Extractor helper covered by native {target}; the Windows helper version pin does not apply on Linux."))
        elif name in WINDOWS_ONLY:
            reason = f"Windows-only package: {name}"; blockers.append(reason); actions.append(_blocked("apt", name, reason, "scoop"))
        elif name == "anydesk":
            actions.append(_anydesk_action(architecture, blockers, "scoop"))
        elif name == "android-clt":
            try:
                release = android_tools.resolve_release(architecture)
            except (RuntimeError, OSError, ValueError) as exc:
                reason = f"Cannot resolve official Linux Android Command-Line Tools: {exc}"
                blockers.append(reason)
                actions.append(_blocked("android-sdk-archive", name, reason, "scoop"))
            else:
                actions.append(Action("android-sdk-archive", name, version=release["version"],
                                      source="scoop", archive=release,
                                      sdk_layout="<explicit-sdk-root>/cmdline-tools/latest",
                                      acceptance_required=True,
                                      reason="Same SDK Command-Line Tools build as current Scoop android-clt; includes sdkmanager. "
                                             "Requires explicit SDK root and user acceptance of Google SDK terms before download/use. "
                                             "Set ANDROID_HOME to that root and add cmdline-tools/latest/bin and platform-tools to PATH manually. "
                                             "No adb/platform packages, licenses, Java runtime, or shell configuration are installed."))
        elif name == "bitwarden-cli":
            if architecture != "x86_64":
                reason = f"Bitwarden CLI adapter conservatively supports x86_64 only, not {architecture}"
                blockers.append(reason); actions.append(_blocked("bitwarden-cli", name, reason, "scoop"))
            else:
                try:
                    release = bitwarden_tools.resolve_release(architecture)
                except (RuntimeError, OSError, ValueError) as exc:
                    reason = f"Cannot resolve official Linux Bitwarden CLI: {exc}"
                    blockers.append(reason); actions.append(_blocked("bitwarden-cli", name, reason, "scoop"))
                else:
                    actions.append(Action("bitwarden-cli", name, version=release["version"], source="scoop",
                                          archive=release,
                                          reason="Official Bitwarden CLI Linux x86_64 OSS archive. Install requires explicit "
                                                 "--bitwarden-cli-root pointing to a new directory; no profile, PATH, or "
                                                 "credential state is migrated. The native binary is not executed during install."))
        elif name == "bun":
            try:
                release = bun_tools.resolve_release(architecture)
            except (RuntimeError, OSError, ValueError) as exc:
                reason = f"Cannot resolve official Linux Bun: {exc}"
                blockers.append(reason); actions.append(_blocked("bun-archive", name, reason, "scoop"))
            else:
                actions.append(Action("bun-archive", name, version=release["version"], source="scoop", archive=release,
                                      reason="Official Bun Linux x64 baseline archive matching current Scoop Bun version; "
                                             "requires explicit new --bun-root. No profile, PATH, package installation, "
                                             "Windows state migration or native binary execution. Source mapping is not runtime validation."))
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
    # A helper-only allowlist still needs its canonical native action. Reuse an
    # existing one regardless of declaration order, never install the helper.
    for target in dict.fromkeys(a.covered_by for a in actions if a.status == "covered"):
        if not any(a.name == target for a in actions):
            elevate = [] if os.geteuid() == 0 else ["sudo", "-n"]
            actions.append(Action("apt", target, [*elevate, "apt-get", "install", "-y", APT_MAP[target]], source="package-coverage"))
    for pkg in winget.get("packages", []):
        ident = pkg.get("id", "") if isinstance(pkg, dict) else pkg
        if not isinstance(ident, str) or not ident.strip():
            reason = f"Invalid WinGet package ID: {ident!r}"
            blockers.append(reason)
            actions.append(_blocked("winget", str(ident), reason, "winget"))
        elif ident == "AnyDesk.AnyDesk":
            if not any(a.name == "anydesk" for a in actions):
                actions.append(_anydesk_action(architecture, blockers, "winget"))
            actions.append(Action("winget", ident, source="winget", status="covered", covered_by="anydesk",
                                  reason="Duplicate AnyDesk package intent covered by official Linux AnyDesk; "
                                         "Windows identity and service state remain preserved, not migrated."))
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

class PackageExecutionError(RuntimeError):
    def __init__(self, message: str, report: dict[str, Any]):
        super().__init__(message)
        self.report = report

def execute(plan: Plan, selected: Iterable[str] | None = None, runner=subprocess.run,
            *, android_sdk_root: Path | None = None, android_sdk_terms_accepted: bool = False,
            anydesk_terms_accepted: bool = False, anydesk_service_allowed: bool = False,
            bitwarden_cli_root: Path | None = None, bun_root: Path | None = None) -> dict[str, Any]:
    if not plan.supported: raise RuntimeError("Unsupported host; no restore commands are permitted")
    actual = host_info()
    if actual != (plan.distro, plan.architecture):
        raise RuntimeError(f"Plan host declaration does not match actual host: plan={plan.distro}/{plan.architecture}, actual={actual[0]}/{actual[1]}")
    selected_set = set(selected) if selected else set()
    known = {a.name for a in plan.actions}
    unknown = selected_set - known
    if unknown: raise RuntimeError("Unknown --select action name(s): " + ", ".join(sorted(unknown)))
    covered = [a for a in plan.actions if a.status == "covered" and
               (not selected_set or a.name in selected_set or a.covered_by in selected_set)]
    for action in covered:
        if not any(a.name == action.covered_by and a.status == "planned" and
                   ((a.kind == "apt" and a.command) or (a.kind == "anydesk-deb" and a.archive)) for a in plan.actions):
            raise RuntimeError(f"Missing planned native coverage target for: {action.name}")
    coverage_targets = {a.covered_by for a in covered}
    if not selected_set and plan.blockers:
        raise RuntimeError('Plan contains unresolved manifest or package blockers; no full execution is permitted.')
    unresolved = [a for a in plan.actions if a.status == "blocked" and (not selected_set or a.name in selected_set)]
    if unresolved: raise RuntimeError("Unresolved blockers prevent full restore: " + "; ".join(a.reason for a in unresolved))
    chosen = [a for a in plan.actions if a.status == "planned" and
              (not selected_set or a.name in selected_set or
               (a.kind in {"apt", "anydesk-deb"} and a.name in coverage_targets))]
    for action in (a for a in chosen if a.kind == "anydesk-deb"):
        anydesk_tools.validate_install(action.archive, accepted_terms=anydesk_terms_accepted,
                                       allow_service=anydesk_service_allowed)
    for action in (a for a in chosen if a.kind == "android-sdk-archive"):
        if not android_sdk_terms_accepted:
            raise RuntimeError("Read Google Android SDK terms and explicitly pass --android-sdk-terms-accepted before download/use")
        if android_sdk_root is None:
            raise RuntimeError("Android SDK installation requires --android-sdk-root pointing to a new directory")
        android_tools.validate_install(action.archive, android_sdk_root, accepted_terms=android_sdk_terms_accepted)
    for action in (a for a in chosen if a.kind == "bitwarden-cli"):
        if bitwarden_cli_root is None:
            raise RuntimeError("Bitwarden CLI installation requires --bitwarden-cli-root pointing to a new directory")
        bitwarden_tools.validate_install(action.archive, bitwarden_cli_root)
    for action in (a for a in chosen if a.kind == "bun-archive"):
        if bun_root is None:
            raise RuntimeError("Bun installation requires --bun-root pointing to a new directory")
        bun_tools.validate_install(action.archive, bun_root)
    if any(a.kind == "bun-archive" for a in chosen):
        allowed = {"apt", "bun-archive", "bitwarden-cli", "anydesk-deb", "android-sdk-archive"}
        if any(a.kind not in allowed for a in chosen):
            raise RuntimeError("Bun cannot be combined with commands lacking isolated runtime/destination preflight")
        roots = [Path(root).expanduser().resolve(strict=False) for root in
                 (bun_root, bitwarden_cli_root if any(a.kind == "bitwarden-cli" for a in chosen) else None,
                  android_sdk_root if any(a.kind == "android-sdk-archive" for a in chosen) else None) if root is not None]
        if len(roots) != len(set(roots)):
            raise RuntimeError("Bun and other selected archives require distinct installation roots")
    if any(a.kind == "pip-venv" and (Path(".linux-restore-venv").exists() or Path(".linux-restore-venv").is_symlink()) for a in chosen):
        raise RuntimeError("Refusing to overwrite existing .linux-restore-venv; choose a new working directory")
    _apt_preflight([a for a in chosen if a.kind == "apt"], runner)
    report = {"executed": [], "failed": None, "covered": {a.name: a.covered_by for a in covered}, "skipped": [a.name for a in plan.actions if a not in chosen and a not in covered], "partial": bool(selected_set), "note": "Explicit selection is a partial restore; it does not claim full parity." if selected_set else "Full planned restore."}
    for action in chosen:
        try:
            if action.kind == "android-sdk-archive":
                android_tools.install_release(action.archive, android_sdk_root, accepted_terms=android_sdk_terms_accepted)
            elif action.kind == "anydesk-deb":
                anydesk_tools.install_release(action.archive, accepted_terms=anydesk_terms_accepted,
                                              allow_service=anydesk_service_allowed, runner=runner)
            elif action.kind == "bitwarden-cli":
                bitwarden_tools.install_release(action.archive, bitwarden_cli_root)
            elif action.kind == "bun-archive":
                bun_tools.install_release(action.archive, bun_root)
            else:
                result = runner(action.command, check=False, shell=False, timeout=300)
                code = getattr(result, "returncode", result if isinstance(result, int) else 0)
                if code != 0:
                    raise RuntimeError(f"{action.name} failed with exit code {code}")
        except subprocess.TimeoutExpired as exc:
            report["failed"] = {"name": action.name, "error": f"timed out after {exc.timeout}s"}
            raise PackageExecutionError(f"{action.name} timed out", report) from exc
        except (RuntimeError, OSError, ValueError, zipfile.BadZipFile) as exc:
            report["failed"] = {"name": action.name, "error": str(exc)}
            raise PackageExecutionError(str(exc), report) from exc
        report["executed"].append(action.name)
    return report

def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--repo", type=Path, default=Path(__file__).parent)
    ap.add_argument("--backup-root", type=Path)
    ap.add_argument("--execute", action="store_true", help="execute reviewed planned commands; default is dry plan")
    ap.add_argument("--select", action="append", default=[])
    ap.add_argument("--android-sdk-root", type=Path, help="new SDK directory; no default home location or existing SDK overwrite")
    ap.add_argument("--android-sdk-terms-accepted", action="store_true",
                    help="user attests acceptance of Google Android SDK terms for this download/use; never inferred from --execute")
    ap.add_argument("--anydesk-terms-accepted", action="store_true",
                    help="user attests acceptance of AnyDesk terms for this download/use, not other products")
    ap.add_argument("--anydesk-service-allowed", action="store_true",
                    help="explicitly permit vendor DEB installation including its service and possible automatic start")
    ap.add_argument("--bitwarden-cli-root", type=Path,
                    help="new explicit Bitwarden CLI directory; no default home location or overwrite")
    ap.add_argument("--bun-root", type=Path,
                    help="new explicit Bun directory; no default home location, PATH edit or binary execution")
    ap.add_argument("--distro"); ap.add_argument("--arch", dest="architecture")
    args = ap.parse_args(argv)
    plan = build_plan(args.repo, args.backup_root, args.distro, args.architecture)
    if args.execute:
        if plan.blockers and not args.select:
            print(json.dumps({"plan": plan.to_dict(), "error": "blockers present; use --select for an explicitly partial restore"}, indent=2)); return 2
        try:
            report = execute(plan, args.select, android_sdk_root=args.android_sdk_root,
                             android_sdk_terms_accepted=args.android_sdk_terms_accepted,
                             anydesk_terms_accepted=args.anydesk_terms_accepted,
                             anydesk_service_allowed=args.anydesk_service_allowed,
                             bitwarden_cli_root=args.bitwarden_cli_root, bun_root=args.bun_root)
            output = {"plan": plan.to_dict(), "report": report}
        except PackageExecutionError as exc:
            print(json.dumps({"plan": plan.to_dict(), "error": str(exc), "report": exc.report}, indent=2)); return 1
        except subprocess.TimeoutExpired as exc:
            detail = f"command timed out after {exc.timeout}s"
            print(json.dumps({"plan": plan.to_dict(), "error": detail}, indent=2)); return 1
        except (RuntimeError, OSError, ValueError, zipfile.BadZipFile) as exc:
            print(json.dumps({"plan": plan.to_dict(), "error": str(exc)}, indent=2)); return 1
    else:
        output = plan.to_dict()
        # A dry plan is still useful output, but blockers must be visible to
        # automation rather than reported as a successful restore.
        exit_code = 3 if (plan.blockers or not plan.supported) else 0
    print(json.dumps(output, indent=2)); return exit_code if not args.execute else 0
if __name__ == "__main__": raise SystemExit(main())
