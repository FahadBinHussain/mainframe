#!/usr/bin/env python3
"""Decrypt and map the Windows secrets archive into a Linux home-staging tree.

`tool-secrets.zip` is the portable auth/config archive: the same 8 manifest
items that `restore-secrets.ps1` copies into a Windows profile. The archive
travels inside `mainframe-quick.zip` as the AES-256 blob
`mainframe-secrets.zip`, so a quick restore on either platform carries it.

This module is the LINUX counterpart of `restore-secrets.ps1`. It does the same
four things and refuses to improvise anything the manifest does not name:

  1. decrypt the AES-256 blob (WinZip AE-2, which 7-Zip writes for
     `-mem=AES256`) using only the stdlib plus the `openssl` CLI - no
     third-party crypto dependency, and the password never reaches argv.
     each non-empty line of the vault notes is tried against the AES
     verifier in turn, so the `[secrets archive password]` header line
     does not break the restore;
  2. read the PUBLIC manifest (`tool-secrets.manifest.json`) for the item list,
     the same file Windows reads;
  3. resolve each manifest item's `archivePath` to a Linux home path, refusing
     anything that is not an explicit, reviewed mapping;
  4. stage the result into `<staging>/secrets-staging/` - NEVER into the live
     home. `linux_real.activate()` is the only thing that writes HOME.

The mapping is deliberately narrow. A Windows profile path is not a Linux path,
so `{AppData}\\mainframe\\accounts` cannot become `~/.config/mainframe/accounts`
by substitution: this module maps only the items whose Linux destination is
already the documented one (`mainframe-paths.psm1`), and reports every other
item as blocked with the reason. That is the same contract the rest of the
linux flow follows - unproven state is preserved, never silently activated.
"""
from __future__ import annotations

import hashlib
import hmac
import json
import os
import shutil
import struct
import subprocess
import tempfile
import zipfile
import zlib
from pathlib import Path, PurePosixPath

VERSION = 1

# The blob's own name inside mainframe-quick.zip (publish-backup.ps1 stores the
# archive under exactly this entry name).
SECRETS_BLOB_NAME = "mainframe-secrets.zip"
DEFAULT_BLOB_NAME = "mainframe-secrets.zip"
# Name of the file the outer archive gives the inner archive.
INNER_ARCHIVE_NAME = "tool-secrets.zip"

SIG_LOCAL = b"PK\x03\x04"
SIG_CENTRAL = b"PK\x01\x02"
SIG_EOCD = b"PK\x05\x06"

MAX_BLOB_BYTES = 512 * 1024 * 1024
MAX_MEMBER_BYTES = 256 * 1024 * 1024
MAX_EXPANDED_BYTES = 2 * 1024 * 1024 * 1024
MAX_MANIFEST_BYTES = 1024 * 1024


class SecretsError(RuntimeError):
    """A loud, named failure - never a silent skip."""


class PasswordVerifierError(SecretsError):
    """The AES password verifier did not match - this password line is wrong.

    kept distinct from the other SecretsError failures so read_zip can retry
    the next password line on a verifier mismatch only: a MAC failure after a
    verifier match means the password was right and the data is corrupt, and
    retrying would mask the corruption.
    """


# ---------------------------------------------------------------- winzip aes

def _openssl_ecb_encrypt(key: bytes, data: bytes) -> bytes:
    """AES-ECB encrypt `data` with the openssl CLI. `openssl` is a hard
    prereq of the linux flow (linux_real.prereqs_present), so this adds no
    dependency - and unlike `7z` it can read the key from a pipe."""
    if len(data) % 16:
        raise SecretsError("AES input must be block aligned")
    executable = shutil.which("openssl")
    if not executable:
        raise SecretsError(
            "openssl is required to decrypt the secrets archive but was not found on PATH")
    proc = subprocess.run(
        [executable, "enc", "-aes-256-ecb", "-K", key.hex(), "-nopad"],
        input=data, capture_output=True, timeout=120)
    if proc.returncode != 0:
        detail = (proc.stderr or b"").decode("utf-8", "replace").strip()[:300]
        raise SecretsError(f"openssl could not run the AES block cipher: {detail}")
    if len(proc.stdout) != len(data):
        raise SecretsError("openssl returned a truncated AES keystream")
    return proc.stdout


def _keystream(key: bytes, length: int) -> bytes:
    """WinZip AES-CTR: 16-byte blocks holding a LITTLE-endian counter from 1."""
    blocks = (length + 15) // 16
    counters = b"".join(struct.pack("<QQ", i, 0) for i in range(1, blocks + 1))
    return _openssl_ecb_encrypt(key, counters)[:length]


def decrypt_winzip_aes(payload: bytes, password: str, strength: int) -> bytes:
    """Decrypt one WinZip AE-2 payload: salt + 2-byte verifier + data + 10-byte mac.

    strength 1/2/3 = AES-128/192/256. The verification order matters and is
    the part that is easy to get wrong: PBKDF2 yields
    (encryption key | mac key | 2-byte verifier), NOT key/verifier/mac.
    """
    if strength not in (1, 2, 3):
        raise SecretsError(f"unsupported WinZip AES strength {strength}")
    key_len = {1: 16, 2: 24, 3: 32}[strength]
    salt_len = {1: 8, 2: 12, 3: 16}[strength]
    if len(payload) <= salt_len + 2 + 10:
        raise SecretsError("AES entry is too short to be a valid payload")
    salt = payload[:salt_len]
    verifier = payload[salt_len:salt_len + 2]
    body = payload[salt_len + 2:-10]
    auth = payload[-10:]
    derived = hashlib.pbkdf2_hmac("sha1", password.encode("utf-8"), salt, 1000,
                                  key_len * 2 + 2)
    aes_key = derived[:key_len]
    mac_key = derived[key_len:key_len * 2]
    if derived[key_len * 2:key_len * 2 + 2] != verifier:
        raise PasswordVerifierError("the secrets archive password is wrong (AES password verifier mismatch)")
    if not hmac.compare_digest(
            hmac.new(mac_key, body, hashlib.sha1).digest()[:10], auth):
        raise SecretsError("the secrets archive failed its AES authentication code (corrupt or truncated)")
    stream = _keystream(aes_key, len(body))
    return bytes(a ^ b for a, b in zip(body, stream))


def _aes_extra(extra: bytes) -> tuple[int | None, int | None]:
    """Read header id 0x9901: version(2) vendor(2) strength(1) method(2)."""
    index = 0
    while index + 4 <= len(extra):
        header_id, size = struct.unpack("<HH", extra[index:index + 4])
        if header_id == 0x9901 and size >= 7:
            return extra[index + 8], struct.unpack("<H", extra[index + 9:index + 11])[0]
        index += 4 + size
    return None, None


def _password_lines(password: str) -> list[str]:
    """One candidate per non-empty line, in order.

    vault-flow hands over the mainframe-production notes verbatim, and the
    notes are two lines - the `[secrets archive password]` header, then the
    password. a single-line password is the normal case and behaves exactly
    as before; a multi-line one is tried line by line, so the notes layout
    can change without the restore breaking.
    """
    lines = [line.strip() for line in password.splitlines() if line.strip()]
    return lines or [password]


def read_zip(path: Path, password: str) -> dict[str, dict]:
    """Return {member name: {'data': bytes, 'mode': int|None}}.

    python's `zipfile` refuses WinZip AES entries (compress_type 99), so the
    central directory is walked directly: the raw ciphertext only exists in the
    local file header, and `zipfile` will not hand it over.

    each non-empty line of `password` is tried in turn against the archive's
    AES verifier, and the first line that verifies wins. only a verifier
    mismatch moves to the next line - a MAC failure means the password was
    right and the data is corrupt, so it fails loudly instead of masking the
    corruption behind a retry.
    """
    candidates = _password_lines(password)
    last: PasswordVerifierError | None = None
    for candidate in candidates:
        try:
            return _read_zip_single(path, candidate)
        except PasswordVerifierError as exc:
            last = exc
    tried = len(candidates)
    raise SecretsError(
        "the secrets archive password is wrong (AES password verifier "
        f"mismatch; tried {tried} password line{'s' if tried != 1 else ''})"
    ) from last


def _read_zip_single(path: Path, password: str) -> dict[str, dict]:
    """One attempt at the whole archive with one password line."""
    path = Path(path)
    if path.stat().st_size > MAX_BLOB_BYTES:
        raise SecretsError(f"the secrets archive is larger than {MAX_BLOB_BYTES} bytes")
    blob = path.read_bytes()
    eocd = blob.rfind(SIG_EOCD)
    if eocd < 0:
        raise SecretsError("the secrets archive is not a zip (no end-of-central-directory)")
    total, _cd_size, cd_offset = struct.unpack("<HII", blob[eocd + 10:eocd + 20])
    out: dict[str, dict] = {}
    position = cd_offset
    expanded = 0
    for _ in range(total):
        if blob[position:position + 4] != SIG_CENTRAL:
            raise SecretsError("the secrets archive central directory is malformed")
        (flags, method, _time, _date, _crc, compressed, uncompressed, name_len,
         extra_len, comment_len, _disk, _iattr, external_attr, offset) = struct.unpack(
            "<HHHHIIIHHHHHII", blob[position + 8:position + 46])
        name = blob[position + 46:position + 46 + name_len].decode("utf-8", "replace")
        extra = blob[position + 46 + name_len:position + 46 + name_len + extra_len]
        position += 46 + name_len + extra_len + comment_len

        if blob[offset:offset + 4] != SIG_LOCAL:
            raise SecretsError(f"{name}: local file header is missing")
        local_name_len, local_extra_len = struct.unpack(
            "<HH", blob[offset + 26:offset + 30])
        start = offset + 30 + local_name_len + local_extra_len
        raw = blob[start:start + compressed]
        if len(raw) != compressed:
            raise SecretsError(f"{name}: truncated entry payload")

        strength, actual_method = _aes_extra(extra)
        if method == 99:
            if strength is None:
                raise SecretsError(f"{name}: AES entry without its 0x9901 extra field")
            plain = decrypt_winzip_aes(raw, password, strength)
        else:
            if flags & 0x1:
                raise SecretsError(
                    f"{name}: uses legacy ZipCrypto encryption, which is not supported "
                    "(the mainframe archive is written with -mem=AES256)")
            plain = raw
        if (actual_method if method == 99 else method) == 8:
            try:
                plain = zlib.decompress(plain, -15)
            except zlib.error as exc:
                raise SecretsError(f"{name}: could not decompress: {exc}") from None
        if uncompressed != 0xFFFFFFFF and len(plain) != uncompressed:
            raise SecretsError(f"{name}: size mismatch after extraction")
        expanded += len(plain)
        if len(plain) > MAX_MEMBER_BYTES or expanded > MAX_EXPANDED_BYTES:
            raise SecretsError("the secrets archive expands past the configured safety limits")
        # a unix-mode entry records its permissions in the high 16 bits; a
        # windows-made archive leaves 0 there, which means "no mode recorded"
        unix_mode = (external_attr >> 16) & 0o7777
        out[name] = {"data": plain, "mode": unix_mode or None}
    return out


# ---------------------------------------------------------------- manifest

def load_manifest(path: Path) -> list[dict]:
    """The PUBLIC manifest - the same file Windows reads."""
    path = Path(path)
    if not path.is_file():
        raise SecretsError(f"the secrets manifest is missing: {path}")
    if path.stat().st_size > MAX_MANIFEST_BYTES:
        raise SecretsError("the secrets manifest is larger than expected")
    try:
        document = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError) as exc:
        raise SecretsError(f"the secrets manifest is not readable JSON: {exc}") from None
    items = document.get("items")
    if not isinstance(items, list):
        raise SecretsError("the secrets manifest has no items list")
    disabled = set()
    for key in ("disabled", "disabled_items"):
        value = document.get(key)
        if isinstance(value, list):
            disabled.update(str(entry) for entry in value)
    enabled = [item for item in items
               if isinstance(item, dict)
               and not item.get("disabled")
               and item.get("name") not in disabled]
    if not enabled:
        raise SecretsError("the secrets manifest has no enabled items")
    return enabled


def safe_archive_path(value: str) -> str:
    """The manifest's archivePath, normalised, refusing traversal."""
    if not isinstance(value, str) or not value.strip():
        raise SecretsError("a secrets manifest item has an empty archivePath")
    relative = value.replace("\\", "/").lstrip("/")
    parts = PurePosixPath(relative).parts
    if not parts or any(part in ("", ".", "..") for part in parts):
        raise SecretsError(f"unsafe secrets archivePath: {value!r}")
    return "/".join(parts)


# The mapping is PATH based, not name based, for the same reason
# `linux_restore.classify()` is: a manifest rename must not silently change where
# a secret lands.
#
# `UserProfile/...` maps to the IDENTICAL relative path. That is not laziness -
# it is the same rule `classify()` already applies when the same files arrive
# loose inside mainframe-quick.zip, so a file restored from the encrypted blob
# and the same file restored from the quick tree land in exactly one place.
# `AppData/Roaming/mainframe/accounts` is the one exception, and it is the rule
# `mainframe-paths.psm1` already encodes: the profile root is
# `%APPDATA%\mainframe` on windows and `$XDG_CONFIG_HOME/mainframe` on linux.
USERPROFILE_PREFIX = "UserProfile/"
APPDATA_PROFILE_ITEM = "AppData/Roaming/mainframe/accounts"
LINUX_PROFILE_SUFFIX = "mainframe/accounts"

# Items that are deliberately NOT mapped, with the reason the operator sees.
ITEM_BLOCKERS = {
    "opencode sessions, message storage and session diffs": (
        "disabled in the manifest itself (the event log grew past 1.7 GB) and the "
        "sqlite file is a windows-path database; not activated."),
    "wakatime desktop app config and monitored apps": (
        "disabled in the manifest itself: the desktop client is not installed and "
        "opencode tracking uses ~/.wakatime.cfg, which IS mapped."),
}


def _profile_relative(home: Path, environment: dict[str, str]) -> str:
    """The linux profile root, relative to `home`.

    Refuses a root outside `home`: activation copies staging INTO the live home,
    so an absolute XDG_CONFIG_HOME elsewhere could not be honoured - and then the
    account profiles would land somewhere nobody reads.
    """
    xdg = environment.get("XDG_CONFIG_HOME")
    candidate = Path(xdg) if xdg else home / ".config"
    try:
        return candidate.relative_to(home).as_posix()
    except ValueError:
        raise SecretsError(
            f"XDG_CONFIG_HOME={xdg} is outside the live home, so the account "
            "profiles cannot be placed where the helpers look for them. Unset it "
            "or point it inside $HOME and re-run.") from None


def linux_target(archive_path: str, *, home: Path,
                 environment: dict[str, str]) -> tuple[str, str] | None:
    """(relative linux target, note) for a manifest archivePath, or None.

    None means "no reviewed destination" - the caller reports it blocked.
    """
    path = archive_path.rstrip("/")
    if path == APPDATA_PROFILE_ITEM:
        relative = f"{_profile_relative(home, environment)}/{LINUX_PROFILE_SUFFIX}"
        return relative, ("the shared profile root both platforms resolve through "
                          "mainframe-paths.psm1; the vault session itself is not in "
                          "the archive (bitwarden is excluded), so nothing here is a "
                          "live credential store")
    if path.startswith(USERPROFILE_PREFIX):
        relative = path[len(USERPROFILE_PREFIX):]
        if not relative:
            return None
        return relative, "identical relative path under $HOME"
    return None


def plan_items(manifest_items: list[dict], *, home: Path,
               environment: dict[str, str] | None = None) -> list[dict]:
    """Resolve every manifest item to an action: mapped or blocked, with reason."""
    environment = dict(os.environ if environment is None else environment)
    plan: list[dict] = []
    for item in manifest_items:
        name = str(item.get("name") or "").strip()
        archive_path = safe_archive_path(item.get("archivePath") or "")
        resolved = linux_target(archive_path, home=home, environment=environment)
        if resolved is not None:
            target, note = resolved
            plan.append({
                "name": name, "archivePath": archive_path,
                "status": "mapped", "target": target, "note": note,
            })
            continue
        plan.append({
            "name": name, "archivePath": archive_path,
            "status": "blocked",
            "reason": ITEM_BLOCKERS.get(
                name, "no reviewed linux destination for this windows profile path"),
        })
    return plan


# ---------------------------------------------------------------- staging

def _member_matches(members: dict[str, dict], archive_path: str) -> list[str]:
    """Members under one manifest archivePath (exact file or a directory prefix)."""
    wanted = archive_path.rstrip("/") + "/"
    exact = archive_path.rstrip("/")
    return sorted(name for name in members
                  if name == exact or name.startswith(wanted))


def stage_secrets(archive: Path, manifest: Path, password: str,
                  staging: Path, *, home: Path | None = None,
                  environment: dict[str, str] | None = None) -> dict:
    """Decrypt the archive and stage the mapped items under `staging`.

    Returns a report. Nothing here writes the live home: the caller activates
    the tree with the same `activate()` the rest of the restore uses, so
    overwrite backups and symlink refusal apply identically.

    There is deliberately no "copy the unmapped stuff anyway" escape hatch: an
    item with no reviewed destination is reported, not guessed.
    """
    if not password:
        raise SecretsError(
            "the secrets archive password is empty - the vault approval did not "
            "yield a usable mainframe-production password")
    archive = Path(archive)
    if not archive.is_file():
        raise SecretsError(f"the secrets archive is missing: {archive}")
    home = Path(home) if home is not None else Path.home()

    members = read_zip(archive, password)

    # publish-backup.ps1 stores the manifest's own archive (tool-secrets.zip)
    # inside the AES blob, so unwrap one level when that entry is what we got.
    inner_name = next((name for name in members
                       if PurePosixPath(name).name == INNER_ARCHIVE_NAME), None)
    if inner_name is not None:
        holder = Path(staging) / "_inner"
        holder.mkdir(parents=True, exist_ok=True)
        nested = holder / INNER_ARCHIVE_NAME
        nested.write_bytes(members[inner_name]["data"])
        try:
            members = read_zip(nested, password)
        finally:
            shutil.rmtree(holder, ignore_errors=True)

    plan = plan_items(load_manifest(manifest), home=home, environment=environment)
    tree = Path(staging) / "secrets-staging"
    tree.mkdir(parents=True, exist_ok=True)

    report = {"version": VERSION, "archive": str(archive),
              "staged": [], "blocked": [], "missing": [], "members": len(members)}
    for item in plan:
        if item["status"] != "mapped":
            report["blocked"].append({"name": item["name"],
                                      "archivePath": item["archivePath"],
                                      "reason": item["reason"]})
            continue
        matched = _member_matches(members, item["archivePath"])
        if not matched:
            report["missing"].append({"name": item["name"],
                                      "archivePath": item["archivePath"]})
            continue
        prefix = item["archivePath"].rstrip("/")
        for name in matched:
            tail = name[len(prefix):].lstrip("/")
            relative = f"{item['target']}/{tail}" if tail else item["target"]
            record = members[name]
            destination, requested = _write_member(tree, relative, record["data"],
                                                   record["mode"])
            report["staged"].append({
                "name": item["name"], "from": name,
                "target": str(destination.relative_to(tree)),
                "mode": f"{requested:03o}",
            })
    return report


def _write_member(root: Path, relative: str, data: bytes, mode: int | None) -> tuple[Path, int]:
    """Write one decrypted member under `root`, refusing traversal.

    Returns (path, requested_mode). Everything in this archive is secret
    material - ssh keys, an oauth token in a profile, provider api keys in
    configs - so the group/world bits are ALWAYS stripped and 0600 is the floor.
    A narrower mode from the archive (0400) is kept; a wider one (0644) is not,
    because an ssh private key that lands world-readable is one openssh then
    refuses to use, and nothing in here has any business being readable by
    another user. The mode is reported rather than re-read because windows
    rejects chmod beyond the read-only bit, so an on-disk check there would
    measure the platform instead of this code.
    """
    parts = PurePosixPath(relative).parts
    if not parts or any(part in ("", ".", "..") for part in parts):
        raise SecretsError(f"refusing unsafe member path: {relative!r}")
    target = root.joinpath(*parts)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(data)
    requested = ((mode or 0o600) & 0o600) or 0o600
    try:
        target.chmod(requested)
    except OSError:
        pass
    return target, requested


def find_blob(release_dir: Path) -> Path | None:
    """Locate the encrypted secrets blob inside an extracted quick archive."""
    release_dir = Path(release_dir)
    direct = release_dir / DEFAULT_BLOB_NAME
    if direct.is_file():
        return direct
    for candidate in release_dir.rglob(DEFAULT_BLOB_NAME):
        if candidate.is_file():
            return candidate
    return None


def extract_secrets_blob(quick_zip: Path, destination: Path) -> Path:
    """Pull `mainframe-secrets.zip` out of mainframe-quick.zip byte for byte."""
    quick_zip = Path(quick_zip)
    if not quick_zip.is_file():
        raise SecretsError(f"the quick archive is missing: {quick_zip}")
    destination = Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(quick_zip) as archive:
        member = next((info for info in archive.infolist()
                       if PurePosixPath(info.filename).name == DEFAULT_BLOB_NAME), None)
        if member is None:
            raise SecretsError(
                f"{quick_zip} carries no {DEFAULT_BLOB_NAME} - this release cannot "
                "restore secrets; re-publish it with backup.ps1 -Publish")
        if member.file_size > MAX_BLOB_BYTES:
            raise SecretsError("the secrets blob is larger than expected")
        with archive.open(member) as source, open(destination, "wb") as sink:
            shutil.copyfileobj(source, sink)
    return destination
