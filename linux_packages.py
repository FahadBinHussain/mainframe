#!/usr/bin/env python3
"""Plan and, only when explicitly requested, restore allowlisted packages on Linux.

The default operation is a read-only plan.  This is a conservative Debian/Ubuntu
adapter; it does not claim parity with a Windows installation and never reads
secret archive payloads.
"""
from __future__ import annotations
import argparse
import http.client
import json
import os
import platform
import re
import subprocess
import zipfile
import tarfile
import shutil
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Iterable

import android_commandline_tools as android_tools
import anydesk_linux as anydesk_tools
import bitwarden_cli_linux as bitwarden_tools
import bun_linux as bun_tools
import github_native_linux as github_native_tools
import node_lts_linux as node_lts_tools
import opencode2_linux as opencode2_tools
import pnpm_global_plan as pnpm_global_tools
import google_workspace_cli_linux as gws_tools
import ngrok_linux as ngrok_tools
import pwsh_linux as pwsh_tools
import tor_browser_linux as tor_browser_tools
import windscribe_linux as windscribe_tools
import wakatime_desktop_linux as wakatime_desktop_tools
import wacli_go_plan as wacli_go_tools

NATIVE_PACKAGES = {"bun", "cloudflared", "deno", "nodejs-lts", "opencode2", "pnpm", "uv", "yq"}


def _native_adapter(name: str) -> Any:
    if name not in NATIVE_PACKAGES:
        raise RuntimeError(f"Unknown native package: {name}")
    return {"bun": bun_tools, "nodejs-lts": node_lts_tools,
            "opencode2": opencode2_tools}.get(name, github_native_tools)


def _native_release(name: str, architecture: str) -> dict[str, str]:
    adapter = _native_adapter(name)
    if adapter is github_native_tools:
        return adapter.resolve_release(name, architecture)
    return adapter.resolve_release(architecture)

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
    "alist", "gcloud", "ngrok", "parsec", "pwsh", "steam",
    "tor-browser", "discord", "nuget",
}
NATIVE_REVIEW_REASONS = {
    "discord": "Scoop Extras currently points to the portapps/discord-portable Windows build; Discord's public Linux page exposes no exact matching Linux package version/checksum, so no validated version-pinned adapter. No Snap/Flatpak substitution.",
    "gcloud": "Official Linux CLI exists, but matching bundled-runtime archive/checksum and non-mutating installer are not validated; no initialization or credential migration.",
    "herdr": "Repo-local Windows manifest selects a preview fork/channel; upstream stable Linux is not a verified same-variant replacement.",
    "mpv-git": "Requested git variant is not distro stable mpv; no validated matching commit/build/checksum adapter.",
    "ngrok": "The explicit metadata-only plan can match current Windows/Linux version and checksum metadata; Linux archive layout and a bounded installer remain unvalidated, with no repository, service, or account setup inferred.",
    "nuget": "Requested nuget.exe has no equivalent native Linux command surface; Mono and dotnet nuget are not silent substitutes.",
    "parsec": "Official Linux app is client-only, without hosting; Windows role/state and a pinned checksum/install adapter are unresolved.",
    "pwsh": "Official Linux PowerShell exists, but supported distro/runtime dependencies and pinned package/checksum installation are not validated; Windows modules are not ported.",
    "steam": "The allowlist has no Steam version pin; Valve's Linux steam_latest.deb URL is an unversioned bootstrapper with a self-updating client and udev rules, and no top-level checksum is published there, so no same-version bounded install route is validated.",
    "tor-browser": "The opt-in metadata-only plan can compare same-version Scoop and Tor release/checksum metadata; OpenPGP signature/key trust, archive layout/safe extraction, and isolated activation remain unvalidated, and no profile state is imported.",
    "vscode": "Official Microsoft Linux VS Code exists with checksums, but download/use requires separately scoped vendor terms acceptance and a validated native adapter; consent is not inferred.",
}
WINGET_REVIEW_REASONS = {
    "GPSoftware.DirectoryOpus": "Windows-only Directory Opus; no same-product native Linux build or Windows-state adapter.",
    "Windscribe.Windscribe": "Official Linux desktop builds exist, but no validated install/activation adapter is available. GPG signature/key trust, package contents, privileged VPN service/routing/firewall effects, account activation, and Windows-state handling remain unvalidated.",
    "StartIsBack.StartAllBack": "Windows shell/Explorer customization; no same-product native Linux equivalent.",
    "Tonec.InternetDownloadManager": "Vendor explicitly does not support Linux; no same-product native Linux build.",
    "Wakatime.DesktopWakatime": "The exact publisher tag named by the WinGet installer URL can be checked for Linux AppImage metadata, but AppImage/runtime/desktop integration and account activation are unvalidated; WakaTime Desktop state is excluded from backup and CLI is not a substitute.",
}
VARIANT_DRIFT = {"mpv-git"}
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
    archive: dict[str, Any] | None = None
    sdk_layout: str | None = None
    acceptance_required: bool = False
    dry_plan: dict[str, Any] | None = None

@dataclass
class Plan:
    supported: bool
    distro: str
    architecture: str
    actions: list[Action]
    blockers: list[str] = field(default_factory=list)
    protected_roots: tuple[str, ...] = ()
    def to_dict(self) -> dict[str, Any]:
        return {"supported": self.supported, "distro": self.distro,
                "architecture": self.architecture, "actions": [asdict(a) for a in self.actions],
                "blockers": self.blockers, "protected_roots": list(self.protected_roots)}

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

def _requirements_actions(root: Path, blockers: list[str]) -> list[Action]:
    """Plan explicitly curated repository requirements, never legacy snapshots."""
    files = [p for p in (root / "requirements.txt", root / "requirements-linux.txt") if p.is_file()]
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
        windows_api_binding = False
        for line in lines:
            # Inspect only the normalized project name, never include raw
            # requirements (which can contain private URLs/options) in reports.
            match = re.match(r"^([A-Za-z0-9][A-Za-z0-9._-]*)(?=\s*(?:\[|[<>=!~;@#]|$))", line)
            package = re.sub(r"[-_.]+", "-", match[1]).lower() if match else ""
            if package in {"pywin32", "pypiwin32", "windows-curses", "pywin32-ctypes"} or any(marker in line.lower() for marker in ('win_amd64.whl', 'win32.whl', 'file:///c:', 'file:///d:', ' @ c:', ' @ d:')):
                bad.append(line)
                windows_api_binding |= package == "pywin32-ctypes"
        if bad:
            reason = f"Windows-only Python requirements in {req.name}; {len(bad)} declaration(s) need explicit translation (including pywin32 when present)."
            if windows_api_binding:
                reason += (" pywin32-ctypes wraps Windows DLL APIs; its pure-Python/any wheel is not native Linux functionality."
                           " Upstream Unix testing uses Wine, not a Linux backend. A win32 environment marker would omit"
                           " this functionality on Linux, not port it; no exclusion or substitute is approved."
                           " The entire original manifest remains preserved and blocked; see docs/linux-pip-platform-review.md.")
            blockers.append(reason)
            out.append(Action("pip-venv", req.name, status="blocked", reason=reason, source=str(req)))
        else:
            reason = f"{req.name}: Python interpreter, dependency compatibility and explicit isolated venv destination preflight are not validated; original manifest is preserved."
            blockers.append(reason)
            out.append(Action("pip-venv", req.name, ["python3.12", "-m", "venv", ".linux-restore-venv"], status="blocked", reason=reason, source=str(req)))
            out.append(Action("pip-install", req.name, [".linux-restore-venv/bin/python", "-m", "pip", "install", "--requirement", str(req)], status="blocked", reason=reason, source=str(req)))
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

def build_plan(repo: Path, backup_root: Path | None = None, distro: str | None = None, architecture: str | None = None,
               *, pnpm_plan_config: dict[str, Any] | None = None,
               ngrok_metadata_plan: bool = False,
               pwsh_metadata_plan: bool = False,
               tor_browser_metadata_plan: bool = False,
               windscribe_metadata_plan: bool = False,
               wakatime_desktop_metadata_plan: bool = False,
               gws_root: Path | None = None) -> Plan:
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
        elif name in NATIVE_PACKAGES:
            kind = "bun-archive" if name == "bun" else "native-archive"
            try:
                release = _native_release(name, architecture)
            except (RuntimeError, OSError, ValueError) as exc:
                reason = f"Cannot resolve official native Linux {name}: {exc}"
                blockers.append(reason); actions.append(_blocked(kind, name, reason, "scoop"))
            else:
                actions.append(Action(kind, name, version=release["version"], source="scoop",
                                      archive=release,
                                      reason="Same-product official Linux artifact matched to the Windows manifest version/variant. "
                                             "Future install requires an explicit new --native-root NAME=PATH; no PATH/profile, "
                                             "service, credentials, or Windows state migration. Metadata/fixture validation is not runtime validation."))
        elif name == "ngrok" and ngrok_metadata_plan:
            try:
                detail = ngrok_tools.build_dry_plan(architecture)
            except (RuntimeError, OSError, ValueError, TypeError, http.client.HTTPException) as exc:
                detail = ("malformed or incomplete HTTP response" if isinstance(exc, http.client.HTTPException)
                          else str(exc))
                reason = f"ngrok: official metadata-only review failed: {detail}"
                blockers.append(reason)
                actions.append(_blocked("ngrok-metadata", name, reason, "scoop"))
            else:
                version = detail["package"]["version"]
                reason = (f"ngrok current Scoop version observation {version} matches the official Linux amd64 archive/checksum metadata; "
                          "this is not a user-selected restore pin, and archive layout, safe extraction, runtime and activation remain unvalidated. "
                          "No archive was downloaded and no token/configuration, service or PATH state was read or changed.")
                blockers.append(reason)
                actions.append(Action("ngrok-metadata", name, version=version, status="blocked",
                                      reason=reason, source="scoop", dry_plan=detail))
        elif name == "tor-browser" and tor_browser_metadata_plan:
            try:
                detail = tor_browser_tools.build_dry_plan(architecture)
            except (RuntimeError, OSError, ValueError, TypeError, http.client.HTTPException) as exc:
                detail = ("malformed or incomplete HTTP response" if isinstance(exc, http.client.HTTPException)
                          else str(exc))
                reason = f"tor-browser: official metadata-only review failed: {detail}"
                blockers.append(reason)
                actions.append(_blocked("tor-browser-metadata", name, reason, "scoop"))
            else:
                version = detail["package"]["version"]
                reason = (f"tor-browser current Scoop version observation {version} matches the publisher's Windows x64 checksum and lists a same-version Linux x86_64 candidate; "
                          "this is not a restore pin, and OpenPGP signature/key trust, archive layout, safe extraction, runtime and activation remain unvalidated. "
                          "No package or signature content was downloaded, and no browser profile/Tor state is imported.")
                blockers.append(reason)
                actions.append(Action("tor-browser-metadata", name, version=version, status="blocked",
                                      reason=reason, source="scoop", dry_plan=detail))
        elif name == "pwsh" and pwsh_metadata_plan:
            try:
                detail = pwsh_tools.build_dry_plan(architecture)
            except (RuntimeError, OSError, ValueError, TypeError, http.client.HTTPException) as exc:
                detail = ("malformed or incomplete HTTP response" if isinstance(exc, http.client.HTTPException)
                          else str(exc))
                reason = f"pwsh: official metadata-only review failed: {detail}"
                blockers.append(reason)
                actions.append(_blocked("pwsh-metadata", name, reason, "scoop"))
            else:
                version = detail["package"]["version"]
                reason = (f"pwsh current Scoop version observation {version} matches the official Linux x64 asset/checksum metadata; "
                          "this is not a user-selected restore pin, and archive layout, safe extraction, runtime and activation remain unvalidated. "
                          "No package archive or manifest script was downloaded or executed; Windows profiles/modules are not imported.")
                blockers.append(reason)
                actions.append(Action("pwsh-metadata", name, version=version, status="blocked",
                                      reason=reason, source="scoop", dry_plan=detail))
        elif name in NATIVE_REVIEW_REASONS:
            reason = f"{name}: {NATIVE_REVIEW_REASONS[name]}"
            blockers.append(reason); actions.append(_blocked("apt", name, reason, "scoop"))
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
        elif ident == "Windscribe.Windscribe" and windscribe_metadata_plan:
            try:
                detail = windscribe_tools.build_dry_plan(architecture)
            except (RuntimeError, OSError, ValueError, TypeError, http.client.HTTPException) as exc:
                detail = ("malformed or incomplete HTTP response" if isinstance(exc, http.client.HTTPException)
                          else str(exc))
                reason = f"Windscribe.Windscribe: official metadata-only review failed: {detail}"
                blockers.append(reason)
                actions.append(_blocked("windscribe-metadata", ident, reason, "winget"))
            else:
                version = detail["package"]["version"]
                reason = (f"Windscribe current WinGet version observation {version} matches the publisher's same-version Windows release digest and identifies a Linux desktop DEB candidate; "
                          "this is not a restore pin. GPG signature/key trust, package contents, privileged VPN service/routing/firewall effects, account activation, and Windows-state migration remain unvalidated. "
                          "No installer, package, or signature content was downloaded or executed.")
                blockers.append(reason)
                actions.append(Action("windscribe-metadata", ident, version=version, status="blocked",
                                      reason=reason, source="winget", dry_plan=detail))
        elif ident == "Wakatime.DesktopWakatime" and wakatime_desktop_metadata_plan:
            try:
                detail = wakatime_desktop_tools.build_dry_plan(architecture)
            except (RuntimeError, OSError, ValueError, TypeError, http.client.HTTPException) as exc:
                detail = ("malformed or incomplete HTTP response" if isinstance(exc, http.client.HTTPException)
                          else str(exc))
                reason = f"Wakatime.DesktopWakatime: official metadata-only review failed: {detail}"
                blockers.append(reason)
                actions.append(_blocked("wakatime-desktop-metadata", ident, reason, "winget"))
            else:
                version = detail["package"]["version"]
                release_tag = detail["official_release"]["tag_name"]
                reason = (f"WakaTime Desktop WinGet version {version} explicitly references publisher release tag {release_tag}; the same-tag Windows installer digest matches and Linux AppImage metadata is recorded. "
                          "This is a live metadata observation, not a restore pin or independent signature check. AppImage contents, runtime compatibility, and desktop integration remain unvalidated; WakaTime Desktop config/API-key/account state is excluded from the backup and is not imported or activated. The CLI is not a substitute. "
                          "No installer, AppImage, or checksum-file content was downloaded or executed.")
                blockers.append(reason)
                actions.append(Action("wakatime-desktop-metadata", ident, version=version, status="blocked",
                                      reason=reason, source="winget", dry_plan=detail))
        else:
            reason = (f"{ident}: {WINGET_REVIEW_REASONS[ident]}" if ident in WINGET_REVIEW_REASONS else
                      f"Windows WinGet declaration has no validated native package/state adapter: {ident}")
            blockers.append(reason)
            actions.append(_blocked("winget", ident, reason, "winget"))
    for name in pnpm.get("packages", []):
        reason = f"Invalid pnpm package name: {name!r}"
        if not _safe_arg(name): blockers.append(reason); actions.append(_blocked("pnpm", str(name), reason, "pnpm"))
        elif name == "@googleworkspace/cli":
            protected = [str(p.resolve()) for p in (repo, backup_root) if p is not None]
            try:
                release = gws_tools.resolve_release(architecture)
                detail = {"route": "official-native-archive", "protected_roots": protected,
                          "layout": None, "runtime_tested": False}
                if gws_root is not None:
                    _gws_protected_root(gws_root, protected)
                    detail["layout"] = gws_tools.layout_plan(release, gws_root)
            except (RuntimeError, OSError, ValueError, TypeError) as exc:
                reason = f"{name}: official isolated Linux archive validation failed: {exc}"
                blockers.append(reason)
                actions.append(_blocked("gws-archive", name, reason, "pnpm"))
            else:
                actions.append(Action("gws-archive", name, version=release["version"],
                                      source="pnpm", archive=release, dry_plan=detail,
                                      reason="Same Google Workspace CLI via its officially recommended Linux archive; "
                                             "npm wrapper, Node/pnpm and lifecycle downloader are not used (not skipped scripts). "
                                             "Future install requires an explicit new --gws-root; no CLI invocation, PATH/profile, "
                                             "credential import or account activation. Metadata/ELF checks are not runtime validation."))
        elif name == "vercel" and pnpm_plan_config is not None:
            runtime = {a.name: a.archive for a in actions if a.kind == "native-archive" and a.status == "planned"}
            try:
                detail = pnpm_global_tools.build_dry_plan(
                    name, pnpm_plan_config, runtime.get("nodejs-lts"), runtime.get("pnpm"),
                    architecture=architecture,
                    protected=tuple(p.resolve() for p in (repo, backup_root) if p is not None))
            except (RuntimeError, OSError, ValueError, TypeError) as exc:
                reason = f"{name}: isolated dry-plan validation failed: {exc}"
                blockers.append(reason)
                actions.append(_blocked("pnpm", name, reason, "pnpm"))
            else:
                review = detail.get("vercel_cli_review", {})
                version = review.get("package_version", detail["package"]["version"])
                engine = review.get("node_engine_requirement") or "unknown"
                native_count = len(review.get("optional_linux_native_packages", []))
                reason = (f"{name}: latest registry metadata observation {version} is not a selected package pin; "
                          f"Node engine requirement {engine}; {native_count} optional Linux native package record(s) are metadata only and native execution is disabled. "
                          + "; ".join(detail["execution_blockers"]))
                blockers.append(reason)
                actions.append(Action("pnpm", name, version=detail["package"]["version"],
                                      status="blocked", reason=reason, source="pnpm", dry_plan=detail))
        else:
            reason = f"{name}: pnpm/Node runtime, required install-script policy and explicit isolated global destination preflight are not validated; no live-home global install."
            if name == "vercel":
                reason = ("vercel: supported Linux Node CLI; no reviewed pnpm-resolved full dependency/build closure "
                          "to finalize exact-version lifecycle approval. Supply --pnpm-plan-config with explicit "
                          "isolated roots for the metadata inventory and future runtime/path/executor gates; "
                          "no package-manager execution or live-home global install.")
            blockers.append(reason)
            actions.append(Action("pnpm", name, ["pnpm", "add", "--global", "--", name], status="blocked", reason=reason, source="pnpm"))
    for item in uv.get("packages", []):
        name = item.get("name") if isinstance(item, dict) else item
        version = item.get("version") if isinstance(item, dict) else None
        spec = f"{name}=={version}" if version else name
        if not _safe_arg(name) or (version is not None and not _safe_arg(version)):
            reason = f"Invalid uv package or version: {item!r}"; blockers.append(reason); actions.append(_blocked("uv", str(name), reason, "uv"))
        else:
            pin_reason = "Unpinned declaration; no exact release is selected. " if not version else ""
            reason = (f"{name}: {pin_reason}Python interpreter provenance/version/ABI and the complete "
                      "marker-resolved dependency wheel set with hashes are not validated for a reviewed target "
                      "Python patch/ABI, architecture and libc; a root wheel "
                      "alone does not exclude dependency builds. Public PyPI/hashed PEP 658 metadata can "
                      "establish a target-specific candidate graph without package execution, but cannot "
                      "verify wheel bytes or interpreter provenance. No metadata observation is an install lock. "
                      "Explicit isolated tool, executable-bin, "
                      "cache, config and Python runtime roots (plus temporary/state routing), missing/overlap "
                      "rejection, effective-path equality checks under a clean child environment and a "
                      "no-build/no-Python-download policy are not implemented. "
                      "Unvalidated destination preflight; no live-home tool install; "
                      "see docs/linux-uv-tool-review.md.")
            blockers.append(reason)
            actions.append(Action("uv", name, ["uv", "tool", "install", "--", spec], version=version, status="blocked", reason=reason, source="uv"))
    for item in go.get("packages", []):
        if isinstance(item, dict): path, version, tags = item.get("path", ""), item.get("version") or 'latest', item.get("tags", []) or []
        else: path, version, tags = item, 'latest', []
        if not _safe_arg(path) or (version is not None and not _safe_arg(version)) or not isinstance(tags, list) or not all(_safe_arg(x) for x in tags):
            reason = f"Invalid Go package declaration: {item!r}"; blockers.append(reason); actions.append(_blocked("go", str(path), reason, "go")); continue
        cmd = ["go", "install"]
        if tags: cmd.extend(["-tags", ",".join(tags)])
        cmd.append(f"{path}@{version}" if version else path)
        reason = f"{path}: pinned Go toolchain, CGO/native build prerequisites and explicit isolated GOBIN/cache destination preflight are not validated; no live-home build/install."
        if path == "github.com/openclaw/wacli/cmd/wacli" and version == "v0.15.0" and tags == ["sqlite_fts5"]:
            reason = (f"{path}@{version}: planned standard Linux Go install proposal only; "
                      "normal GOBIN/~/go/bin and Go module/build caches, not a portable bundle. "
                      "Go >=1.25.12, CGO_ENABLED=1, native C compiler/libc headers and sqlite_fts5; "
                      "CGO_CFLAGS=-Wno-error=missing-braces. Official Go checksums and module/go.sum "
                      "integrity evidence are recorded, not verified local bytes. Build/runtime not tested. "
                      "No executor; --execute still rejects Go before any package preflight or mutation. "
                      "PR #28 state preservation is separate: explicit stopped clean-store encrypted capture "
                      "and offline export only, not live account activation; see docs/linux-wacli-build-review.md.")
            actions.append(Action("go", path, cmd, version=version, tags=tags, source="go",
                                  reason=reason, dry_plan=wacli_go_tools.build_dry_plan(architecture)))
            continue
        blockers.append(reason)
        actions.append(Action("go", path, cmd, version=version, tags=tags, status="blocked", reason=reason, source="go"))
    # Backup roots are data/control metadata, never implicit Python install inputs.
    # Preserve explicit curated repository planning without consuming legacy freezes.
    actions.extend(_requirements_actions(repo, blockers))
    return Plan(True, distro, architecture, actions, blockers,
                tuple(str(p.resolve()) for p in (repo, backup_root) if p is not None)
                if any(a.kind == "gws-archive" for a in actions) else ())

def _gws_protected_root(root: Path, protected: Iterable[str]) -> None:
    """Reject source/backup overlap in addition to adapter HOME/system guards."""
    path = Path(root).absolute()
    for value in (str(Path(__file__).parent.resolve()), *protected):
        other = Path(value).resolve()
        if path == other or path in other.parents or other in path.parents:
            raise ValueError("Google Workspace CLI root overlaps repository or backup source")

def _apt_preflight(actions: list[Action], runner: Any) -> None:
    for action in actions:
        if action.command:
            for executable in (action.command[0], "apt-get", "apt-cache"):
                if shutil.which(executable) is None:
                    raise RuntimeError(f"Required package command is unavailable: {executable}")
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
            bitwarden_cli_root: Path | None = None,
            native_roots: dict[str, Path] | None = None, bun_root: Path | None = None,
            gws_root: Path | None = None) -> dict[str, Any]:
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
    # Planned Go metadata is a proposal, never executor authorization. Reject
    # before even another adapter's preflight can download or mutate anything.
    if any(a.kind == "go" for a in chosen):
        raise RuntimeError("Unvalidated command/runtime/destination: Go dry plan only; no install executor")
    for action in (a for a in chosen if a.kind == "gws-archive"):
        if action.name != "@googleworkspace/cli":
            raise RuntimeError("Google Workspace archive does not match selected product")
        detail = action.dry_plan
        context = plan.protected_roots
        if (not isinstance(context, tuple) or not context or
                any(not isinstance(p, str) or not p.startswith("/") or str(Path(p).resolve()) != p for p in context) or
                not isinstance(detail, dict) or detail.get("route") != "official-native-archive" or
                detail.get("protected_roots") != list(context) or "layout" not in detail or
                not isinstance(action.archive, dict) or action.version != action.archive.get("version")):
            raise RuntimeError("Google Workspace CLI requires complete, matching planner provenance and source protections")
        if gws_root is None:
            raise RuntimeError("Google Workspace CLI installation requires --gws-root pointing to a new directory")
        layout = detail["layout"]
        if layout is not None and (not isinstance(layout, dict) or layout.get("root") != str(Path(gws_root))):
            raise RuntimeError("Google Workspace CLI execution root differs from the preview; re-plan the destination")
        _gws_protected_root(gws_root, context)
        gws_tools.validate_install(action.archive, gws_root)
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
    native_roots = dict(native_roots or {})
    if bun_root is not None:
        if "bun" in native_roots and Path(native_roots["bun"]) != Path(bun_root):
            raise RuntimeError("Conflicting --bun-root and --native-root bun=PATH")
        native_roots["bun"] = Path(bun_root)
    native_destinations = {os.path.normpath(str(Path(root).expanduser())) for root in (
        bitwarden_cli_root if any(a.kind == "bitwarden-cli" for a in chosen) else None,
        android_sdk_root if any(a.kind == "android-sdk-archive" for a in chosen) else None) if root is not None}
    for action in (a for a in chosen if a.kind in {"native-archive", "bun-archive"}):
        if action.name not in native_roots:
            alias = "--bun-root or " if action.name == "bun" else ""
            raise RuntimeError(f"{action.name} installation requires {alias}--native-root {action.name}=PATH pointing to a new directory")
        root = Path(native_roots[action.name])
        normalized = os.path.normpath(str(root.expanduser()))
        if normalized in native_destinations:
            raise RuntimeError("Native packages must use distinct installation roots")
        native_destinations.add(normalized)
        if (_native_adapter(action.name) is github_native_tools and
                (not isinstance(action.archive, dict) or action.archive.get("name") != action.name)):
            raise RuntimeError(f"Native artifact product does not match selected package: {action.name}")
        _native_adapter(action.name).validate_install(action.archive, root)
    if any(a.kind == "gws-archive" for a in chosen):
        gws_path = Path(gws_root).absolute()
        for raw in native_destinations:
            other = Path(raw).absolute()
            if gws_path == other or gws_path in other.parents or other in gws_path.parents:
                raise RuntimeError("Google Workspace CLI and other packages must use non-overlapping installation roots")
    if any(a.kind == "pip-venv" and (Path(".linux-restore-venv").exists() or Path(".linux-restore-venv").is_symlink()) for a in chosen):
        raise RuntimeError("Refusing to overwrite existing .linux-restore-venv; choose a new working directory")
    unsupported_commands = [a.name for a in chosen if a.kind not in {
        "apt", "native-archive", "bun-archive", "bitwarden-cli", "anydesk-deb", "android-sdk-archive", "gws-archive"}]
    if unsupported_commands:
        raise RuntimeError("Unvalidated command/runtime/destination preflight prevents changes: " + "; ".join(unsupported_commands))
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
            elif action.kind in {"native-archive", "bun-archive"}:
                _native_adapter(action.name).install_release(action.archive, native_roots[action.name])
            elif action.kind == "gws-archive":
                gws_tools.install_release(action.archive, gws_root)
            else:
                result = runner(action.command, check=False, shell=False, timeout=300)
                code = getattr(result, "returncode", result if isinstance(result, int) else 0)
                if code != 0:
                    raise RuntimeError(f"{action.name} failed with exit code {code}")
        except subprocess.TimeoutExpired as exc:
            report["failed"] = {"name": action.name, "error": f"timed out after {exc.timeout}s"}
            raise PackageExecutionError(f"{action.name} timed out", report) from exc
        except (RuntimeError, OSError, ValueError, zipfile.BadZipFile, tarfile.TarError) as exc:
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
                    help="new explicit Bun directory; compatible alias for --native-root bun=PATH")
    ap.add_argument("--native-root", action="append", default=[], metavar="NAME=PATH",
                    help="explicit new root for one native package; repeat per product; no default home or PATH edits")
    ap.add_argument("--gws-root", type=Path,
                    help="explicit new Google Workspace CLI root; dry-plans isolated binary/state paths; never invokes npm or gws")
    ap.add_argument("--pnpm-plan-config", type=Path,
                    help="JSON containing explicit isolated roots for Vercel metadata-only planning; never enables installation")
    ap.add_argument("--ngrok-metadata-plan", action="store_true",
                    help="explicitly compare public Scoop and ngrok archive-index metadata only; never downloads a binary or enables installation")
    ap.add_argument("--pwsh-metadata-plan", action="store_true",
                    help="explicitly compare public Scoop and PowerShell release metadata only; never downloads an archive or enables installation")
    ap.add_argument("--tor-browser-metadata-plan", action="store_true",
                    help="explicitly compare public Tor Browser release/checksum metadata only; never downloads packages/signature contents or enables installation")
    ap.add_argument("--windscribe-metadata-plan", action="store_true",
                    help="explicitly compare public WinGet and Windscribe release metadata only; never downloads packages/signatures or enables installation")
    ap.add_argument("--wakatime-desktop-metadata-plan", action="store_true",
                    help="explicitly compare public WinGet and WakaTime Desktop release metadata only; never downloads installers/AppImages or enables installation")
    ap.add_argument("--distro"); ap.add_argument("--arch", dest="architecture")
    args = ap.parse_args(argv)
    if args.pnpm_plan_config and args.execute:
        ap.error("--pnpm-plan-config is dry-only and cannot be combined with --execute")
    if args.ngrok_metadata_plan and args.execute:
        ap.error("--ngrok-metadata-plan is dry-only and cannot be combined with --execute")
    if args.pwsh_metadata_plan and args.execute:
        ap.error("--pwsh-metadata-plan is dry-only and cannot be combined with --execute")
    if args.tor_browser_metadata_plan and args.execute:
        ap.error("--tor-browser-metadata-plan is dry-only and cannot be combined with --execute")
    if args.windscribe_metadata_plan and args.execute:
        ap.error("--windscribe-metadata-plan is dry-only and cannot be combined with --execute")
    if args.wakatime_desktop_metadata_plan and args.execute:
        ap.error("--wakatime-desktop-metadata-plan is dry-only and cannot be combined with --execute")
    if args.ngrok_metadata_plan and args.pnpm_plan_config:
        ap.error("Choose only one explicit metadata review per package-planning run")
    if args.pwsh_metadata_plan and (args.ngrok_metadata_plan or args.pnpm_plan_config):
        ap.error("Choose only one explicit metadata review per package-planning run")
    if args.tor_browser_metadata_plan and (args.ngrok_metadata_plan or args.pwsh_metadata_plan or args.pnpm_plan_config):
        ap.error("Choose only one explicit metadata review per package-planning run")
    if args.windscribe_metadata_plan and (args.ngrok_metadata_plan or args.pwsh_metadata_plan or args.tor_browser_metadata_plan or args.pnpm_plan_config):
        ap.error("Choose only one explicit metadata review per package-planning run")
    if args.wakatime_desktop_metadata_plan and (args.ngrok_metadata_plan or args.pwsh_metadata_plan or args.tor_browser_metadata_plan or args.windscribe_metadata_plan or args.pnpm_plan_config):
        ap.error("Choose only one explicit metadata review per package-planning run")
    native_roots = {}
    for entry in args.native_root:
        name, separator, path = entry.partition("=")
        if not separator or name not in NATIVE_PACKAGES or not path or name in native_roots:
            ap.error("--native-root requires a unique supported NAME=PATH")
        native_roots[name] = Path(path)
    options = {}
    if args.pnpm_plan_config:
        try:
            options["pnpm_plan_config"] = json.loads(args.pnpm_plan_config.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            ap.error(f"Cannot read pnpm dry-plan config: {exc}")
        if not isinstance(options["pnpm_plan_config"], dict):
            ap.error("pnpm dry-plan config must be a JSON object")
    options["ngrok_metadata_plan"] = args.ngrok_metadata_plan
    options["pwsh_metadata_plan"] = args.pwsh_metadata_plan
    options["tor_browser_metadata_plan"] = args.tor_browser_metadata_plan
    options["windscribe_metadata_plan"] = args.windscribe_metadata_plan
    options["wakatime_desktop_metadata_plan"] = args.wakatime_desktop_metadata_plan
    plan = build_plan(args.repo, args.backup_root, args.distro, args.architecture, gws_root=args.gws_root, **options)
    if args.execute:
        if plan.blockers and not args.select:
            print(json.dumps({"plan": plan.to_dict(), "error": "blockers present; use --select for an explicitly partial restore"}, indent=2)); return 2
        try:
            report = execute(plan, args.select, android_sdk_root=args.android_sdk_root,
                             android_sdk_terms_accepted=args.android_sdk_terms_accepted,
                             anydesk_terms_accepted=args.anydesk_terms_accepted,
                             anydesk_service_allowed=args.anydesk_service_allowed,
                             bitwarden_cli_root=args.bitwarden_cli_root,
                             native_roots=native_roots, bun_root=args.bun_root, gws_root=args.gws_root)
            output = {"plan": plan.to_dict(), "report": report}
        except PackageExecutionError as exc:
            print(json.dumps({"plan": plan.to_dict(), "error": str(exc), "report": exc.report}, indent=2)); return 1
        except subprocess.TimeoutExpired as exc:
            detail = f"command timed out after {exc.timeout}s"
            print(json.dumps({"plan": plan.to_dict(), "error": detail}, indent=2)); return 1
        except (RuntimeError, OSError, ValueError, zipfile.BadZipFile, tarfile.TarError) as exc:
            print(json.dumps({"plan": plan.to_dict(), "error": str(exc)}, indent=2)); return 1
    else:
        output = plan.to_dict()
        # A dry plan is still useful output, but blockers must be visible to
        # automation rather than reported as a successful restore.
        exit_code = 3 if (plan.blockers or not plan.supported) else 0
    print(json.dumps(output, indent=2)); return exit_code if not args.execute else 0
if __name__ == "__main__": raise SystemExit(main())
