#!/usr/bin/env bash
# muse/restore.sh — the unified Muse restore. ONE command restores a Muse
# account, always on the quick path. for Muse only — never the full restore.
#
# the three steps, in order:
#   1. muse files: download the migration pack (Drive URL), verify size +
#      sha256, DECRYPT it with the per-pack passphrase (the pack is
#      encrypted because the transfer link is public by necessity — the
#      destination has no auth, so the download must work with no login;
#      the link alone is useless without the passphrase, which travels
#      only in the move-in message), back up this account's own files
#      (.pre-migration), unpack, restore this account's own name, verify
#      with the packed verify-pack.py (local mode).
#   2. mainframe quick restore: clone mainframe if missing, run
#      linux_real.py --skip-packages --yes --muse-skills (quick path only),
#      then re-verify the pack (the restore must not have touched it).
#   3. manager conventions: pull muse/CONVENTIONS.md into
#      ~/workspace/manager/CONVENTIONS.md.
#
# usage (from the move-in message — mainframe is public, no auth needed):
#   curl -sSL https://raw.githubusercontent.com/FahadBinHussain/mainframe/main/muse/restore.sh \
#     | bash -s -- --pack-url URL --pack-name NAME.enc --sha256 SHA --pack-size BYTES --passphrase PASS
# or from a mainframe checkout:
#   ./muse/restore.sh --pack-url URL --sha256 SHA --pack-size BYTES --passphrase PASS
# or with a pack file already on disk (skips the download):
#   ./muse/restore.sh --pack-file PATH --sha256 SHA --pack-size BYTES --passphrase PASS
# the passphrase can also come from the MUSE_PACK_PASSPHRASE env var
# (--passphrase wins when both are set). a pack file that does not end
# in .enc is treated as plaintext (no decryption, no passphrase needed).
#
# every step fails loudly (FATAL + exit 1) — no silent fallback. if any step
# fails, STOP and report exactly what failed.
#
# crons are NOT part of this script: recreating them needs the Muse's own
# cron tools. after this script finishes, the Muse restores the crons from
# ~/CRONS.md per ~/workspace/muse-migration/tools/cron-restore-prompt.md,
# then reports to the user.
set -euo pipefail

PACK_URL=""
PACK_FILE=""
PACK_SHA256=""
PACK_SIZE=""
PACK_NAME=""
PASSPHRASE="${MUSE_PACK_PASSPHRASE:-}"
MAINFRAME_DIR="${HOME}/Downloads/mainframe"
TEST_SKIP_MAINFRAME=0

die() { echo "FATAL: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --pack-url) PACK_URL="$2"; shift 2 ;;
    --pack-file) PACK_FILE="$2"; shift 2 ;;
    --sha256) PACK_SHA256="$2"; shift 2 ;;
    --pack-size) PACK_SIZE="$2"; shift 2 ;;
    --pack-name) PACK_NAME="$2"; shift 2 ;;
    --passphrase) PASSPHRASE="$2"; shift 2 ;;
    --mainframe-dir) MAINFRAME_DIR="$2"; shift 2 ;;
    --test-skip-mainframe) TEST_SKIP_MAINFRAME=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$PACK_SHA256" ] || die "--sha256 is required"
[ -n "$PACK_SIZE" ] || die "--pack-size is required"
if [ -n "$PACK_URL" ] && [ -n "$PACK_FILE" ]; then
  die "pass exactly one of --pack-url / --pack-file"
fi
if [ -z "$PACK_URL" ] && [ -z "$PACK_FILE" ]; then
  die "pass exactly one of --pack-url / --pack-file"
fi
if [ -z "$PACK_NAME" ]; then
  if [ -n "$PACK_FILE" ]; then
    PACK_NAME="$(basename "$PACK_FILE")"
  else
    PACK_NAME="$(basename "${PACK_URL%%\?*}")"
    [ -n "$PACK_NAME" ] && [ "$PACK_NAME" != "/" ] \
      || die "could not derive a pack filename from the URL — pass --pack-name"
  fi
fi

# --- step 1: muse files -------------------------------------------------
PACK_PATH="${HOME}/${PACK_NAME}"
if [ -n "$PACK_URL" ]; then
  echo "downloading the pack from ${PACK_URL} ..."
  curl -L -o "$PACK_PATH" "$PACK_URL" \
    || die "download failed (curl exit $?)"
else
  [ -f "$PACK_FILE" ] || die "--pack-file not found: $PACK_FILE"
  if [ "$PACK_FILE" != "$PACK_PATH" ]; then
    cp "$PACK_FILE" "$PACK_PATH"
  fi
fi

ACTUAL_SIZE="$(stat -c%s "$PACK_PATH")"
[ "$ACTUAL_SIZE" = "$PACK_SIZE" ] \
  || die "size mismatch: got ${ACTUAL_SIZE} bytes, expected ${PACK_SIZE} — do not extract"
ACTUAL_SHA="$(sha256sum "$PACK_PATH" | awk '{print $1}')"
[ "$ACTUAL_SHA" = "$PACK_SHA256" ] \
  || die "sha256 mismatch: got ${ACTUAL_SHA}, expected ${PACK_SHA256} — do not extract"
echo "pack verified: ${PACK_SIZE} bytes, sha256 matches"

# decrypt (encrypted packs end in .enc). a wrong passphrase or a
# corrupted download fails here, loudly, before anything is extracted.
case "$PACK_PATH" in
  *.enc)
    [ -n "$PASSPHRASE" ] \
      || die "this pack is encrypted but no passphrase was given (--passphrase or MUSE_PACK_PASSPHRASE)"
    PLAINTEXT_PATH="${PACK_PATH%.enc}"
    openssl enc -d -aes-256-cbc -salt -pbkdf2 \
      -in "$PACK_PATH" -out "$PLAINTEXT_PATH" \
      -pass "pass:${PASSPHRASE}" \
      || die "decryption failed — wrong passphrase or corrupted download; nothing was extracted"
    echo "pack decrypted"
    PACK_PATH="$PLAINTEXT_PATH"
    ;;
  *)
    echo "plaintext pack (no .enc suffix) - no decryption"
    ;;
esac

# back up this account's own files FIRST (never delete anything). a path
# that already has a .pre-migration backup keeps the first one — but only
# if the backup run that made it COMPLETED. a failed run leaves partial
# backups behind; they are removed and redone, which is safe only when no
# extraction has happened yet — the marker proves the loop completed, and
# pack-manifest.json (carried near the front of the tar) proves a previous
# extraction, so a completed older restore (no marker — it predates the
# marker) still keeps its backups. without either signal the sources are
# untouched, because extraction runs after this loop.
# --no-preserve=ownership: the destination vm's memory dir is root-owned
# and its mount refuses chown even as root (cp -a died there with
# "failed to preserve ownership: Operation not permitted", C 2026-11-22);
# ownership is meaningless for a backup the same user reads back. the
# extract step already uses --no-same-owner for the same reason.
BACKUP_PATHS="MEMORY.md SOUL.md AGENTS.md IDENTITY.md USER.md TOOLS.md HEARTBEAT.md PROACTIVE_PREFERENCES.md config/skills.yaml .config/mainframe/mainframe.config.json .config/mainframe/approval-signing.key .config/mainframe/bw-email.enc.json memory dreams/alignment workspace/goals workspace/custom-skills workspace/custom-connectors workspace/your_files workspace/user workspace/cron.d"
if [ ! -e "${HOME}/.pre-migration.complete" ] && [ ! -e "${HOME}/pack-manifest.json" ]; then
  for rel in $BACKUP_PATHS; do
    rm -rf "${HOME}/${rel}.pre-migration"
  done
fi
for rel in $BACKUP_PATHS; do
  if [ -e "${HOME}/${rel}" ]; then
    if [ -e "${HOME}/${rel}.pre-migration" ]; then
      echo "KEEP (already backed up): ${rel}.pre-migration"
    else
      cp -a --no-preserve=ownership "${HOME}/${rel}" "${HOME}/${rel}.pre-migration"
      echo "backed up: ${rel} -> ${rel}.pre-migration"
    fi
  fi
done
touch "${HOME}/.pre-migration.complete"

echo "extracting the pack ..."
# the destination vm's shell is root in-namespace but its home mount maps
# root to an unprivileged uid (C 2026-11-22, proven by reproduction):
#   - home is sticky, so plain tar refuses existing files with
#     "Cannot open: File exists" -> --overwrite (unlinks first, then the
#     group-write open succeeds; the mapped uid is in nogroup).
#   - tar restoring mtime/mode on the pre-existing root-owned files fails
#     "Operation not permitted" (not the owner) -> -m skips the utime, and
#     tar skips a chmod whose mode already matches.
#   - IDENTITY.md is the one mode mismatch: build-pack.py rewrote it at
#     0644 while the destination's copy is 0660, so it rides separately
#     through stdout — a plain shell redirect writes bytes only, no
#     metadata. (build-pack.py now preserves the source mode, so future
#     packs match; the separate step stays as defence for older packs.)
# TAR_OPTIONS is cleared as defence (it was unset on C — the "File
# exists" came from the sticky dir, not from -k).
TAR_OPTIONS= tar -xzf "$PACK_PATH" -C "$HOME" --no-same-owner --overwrite -m \
  --exclude='IDENTITY.md' \
  || die "tar extract failed"
TAR_OPTIONS= tar -xOzf "$PACK_PATH" IDENTITY.md > "${HOME}/IDENTITY.md" \
  || die "IDENTITY.md extract failed"

# restore this account's OWN name: the packed IDENTITY.md has a blank Name
# (the source account's name never rides in a pack). copy the Name line
# from the .pre-migration backup; if it has no name either, leave it blank.
python3 - "$HOME" <<'PYEOF'
import re, sys
home = sys.argv[1]
new = home + "/IDENTITY.md"
old = new + ".pre-migration"
try:
    new_text = open(new, encoding="utf-8").read()
except FileNotFoundError:
    print("FATAL: packed IDENTITY.md missing after extract", file=sys.stderr)
    sys.exit(1)
try:
    old_text = open(old, encoding="utf-8").read()
except FileNotFoundError:
    old_text = ""
m = re.search(r"^- \*\*Name:\*\* (.+)$", old_text, re.M)
if m and m.group(1).strip():
    name = m.group(1).strip()
    new_text, n = re.subn(r"^- \*\*Name:\*\*.*$",
                          "- **Name:** " + name, new_text,
                          count=1, flags=re.M)
    if n == 0:
        print("FATAL: no Name line to restore into IDENTITY.md",
              file=sys.stderr)
        sys.exit(1)
    open(new, "w", encoding="utf-8").write(new_text)
    print("name restored from backup: %s" % name)
else:
    print("no name in the backup — IDENTITY.md Name stays blank "
          "(the user will name this account)")
PYEOF

[ -f "${HOME}/pack-manifest.json" ] \
  || die "pack-manifest.json missing after extract"
echo "verifying the unpack ..."
MUSE_VERIFY_MODE=local MUSE_VERIFY_MANIFEST="${HOME}/pack-manifest.json" \
  python3 "${HOME}/workspace/muse-migration/tools/verify-pack.py" \
  || die "verify-pack.py failed — the unpack does not match the manifest"

# --- step 2: mainframe quick restore (quick path ONLY) ------------------
if [ "$TEST_SKIP_MAINFRAME" -eq 1 ]; then
  echo "TEST ONLY: --test-skip-mainframe set, skipping linux_real.py"
else
  if [ ! -d "${MAINFRAME_DIR}/.git" ]; then
    echo "cloning mainframe (public, no auth needed) ..."
    git clone https://github.com/FahadBinHussain/mainframe.git "$MAINFRAME_DIR" \
      || die "git clone of mainframe failed"
  fi
  echo "running the mainframe quick restore ..."
  python3 "${MAINFRAME_DIR}/linux/linux_real.py" --skip-packages --yes --muse-skills \
    || die "linux_real.py quick restore failed"
  # re-verify after the restore: it must not have touched the pack.
  echo "re-verifying the unpack after the mainframe restore ..."
  MUSE_VERIFY_MODE=local MUSE_VERIFY_MANIFEST="${HOME}/pack-manifest.json" \
    python3 "${HOME}/workspace/muse-migration/tools/verify-pack.py" \
    || die "verify-pack.py failed after the mainframe restore"
fi

# --- step 3: manager conventions ----------------------------------------
echo "pulling the manager conventions ..."
"${MAINFRAME_DIR}/muse/pull-conventions.sh" "$MAINFRAME_DIR" \
  || die "pull-conventions.sh failed"

echo
echo "RESTORE DONE — all three steps passed:"
echo "  1. muse files unpacked + verified (name restored from backup)"
echo "  2. mainframe quick restore done + unpack re-verified"
echo "  3. manager conventions pulled into ~/workspace/manager/CONVENTIONS.md"
echo
echo "NEXT (needs the Muse's own tools, not this script): restore the crons"
echo "from ~/CRONS.md per ~/workspace/muse-migration/tools/cron-restore-prompt.md,"
echo "then report to the user with the verification results + the cron report."
