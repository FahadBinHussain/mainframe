#!/usr/bin/env bash
# muse/restore.sh backup + extract steps: --no-preserve=ownership +
# completion marker, and -m + --overwrite + the IDENTITY.md stdout step.
# regression tests for the maru 2026-11-22 failures:
#   1. plain `cp -a` died on the root-owned memory dir ("failed to preserve
#      ownership: Operation not permitted") because the destination vm's
#      mount refuses chown even as root, and set -e aborted the restore
#      before extracting anything.
#   2. plain `tar -xzf` died on the pre-existing root-owned files: the
#      sticky home dir gives "Cannot open: File exists", and with
#      --overwrite the metadata restore gives "Cannot utime / Cannot change
#      mode: Operation not permitted" (tar is not the owner). -m skips the
#      utime, tar skips a chmod whose mode already matches, and IDENTITY.md
#      (0644 in the pack vs 0660 on disk) rides through stdout instead.
#
# the mock cp below reproduces that vm: plain `cp -a` fails, and only
# --no-preserve=ownership passes through to the real cp. case D runs the
# whole restore as nobody:nogroup against a sticky home of root-owned
# files — the full squash reproduction.
#
# the verify-pack.py in the test pack is a small double of
# muse.ai/verify-pack.py's local mode (same checks over the same manifest
# keys); the real one lives in automata-private, which mainframe CI does
# not have.
set -euo pipefail
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
mkdir -p "$root/bin"
REAL_CP=$(command -v cp)
checks=0
pass() { checks=$((checks + 1)); }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# mock cp: plain -a fails the way maru's vm fails it; --no-preserve passes.
cat > "$root/bin/cp" <<EOF
#!/usr/bin/env bash
has_a=0; has_no_preserve=0
for a in "\$@"; do
  case "\$a" in
    -a) has_a=1 ;;
    --no-preserve=ownership) has_no_preserve=1 ;;
  esac
done
if [ "\$has_a" -eq 1 ] && [ "\$has_no_preserve" -eq 0 ]; then
  echo "cp: failed to preserve ownership for '\$2': Operation not permitted" >&2
  exit 1
fi
exec "$REAL_CP" "\$@"
EOF
chmod 0755 "$root/bin/cp"
# mock git: pull-conventions.sh runs `git pull --ff-only`; the test clone
# is already current, so a no-op success is the honest double.
cat > "$root/bin/git" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 0755 "$root/bin/git"
# 0755, not +x: this shell's umask is 007, so +x leaves 771 — case D runs
# as nobody, and a script needs world READ to execute, not just +x.
export PATH="$root/bin:$PATH"

# prove the mock cp is wired: plain -a must fail through it.
mkdir -p "$root/probe"
if cp -a "$root/probe" "$root/probe2" 2>/dev/null; then
  fail "mock cp did not fail plain -a (mock not wired?)"
fi
pass

# --- fake home: a maru-like fresh account -------------------------------
make_home() {
  local home="$1"
  mkdir -p "$home/config" "$home/memory/bank" "$home/memory/people" "$home/memory/groups"
  for f in MEMORY.md SOUL.md AGENTS.md USER.md TOOLS.md HEARTBEAT.md PROACTIVE_PREFERENCES.md; do
    printf '# %s (original)\n' "$f" > "$home/$f"
  done
  printf -- '- **Name:** Maru\n' > "$home/IDENTITY.md"
  printf 'skills: {}\n' > "$home/config/skills.yaml"
  printf 'bank note\n' > "$home/memory/bank/note.md"
  printf 'person note\n' > "$home/memory/people/note.md"
  printf 'group note\n' > "$home/memory/groups/note.md"
  # root-owned setgid memory dir, like the real vm (best effort: CI runs
  # as a non-root user, where chown fails and the mock cp above still
  # carries the regression).
  chown -R root:nogroup "$home/memory" 2>/dev/null || true
  chmod 2770 "$home/memory" "$home/memory/bank" "$home/memory/people" "$home/memory/groups" 2>/dev/null || true
}

# --- minimal valid pack ---------------------------------------------------
pack_src="$root/pack-src"
mkdir -p "$pack_src/workspace/goals/g1" "$pack_src/workspace/custom-skills/s1" \
  "$pack_src/workspace/muse-migration/tools"
printf '# MEMORY.md (packed)\npacked memory\n' > "$pack_src/MEMORY.md"
printf '# AGENTS.md (packed)\npacked agents\n' > "$pack_src/AGENTS.md"
printf -- '- **Name:** \n' > "$pack_src/IDENTITY.md"
# modes faithful to the real 20261122 pack: standing files 0660, but the
# rewritten IDENTITY.md lands at 0644 (build-pack.py hardcoded it before
# the mode-preserve fix) — the mismatch restore.sh works around.
chmod 0660 "$pack_src/MEMORY.md" "$pack_src/AGENTS.md"
chmod 0644 "$pack_src/IDENTITY.md"
printf 'goal\n' > "$pack_src/workspace/goals/g1/.keep"
printf 'skill\n' > "$pack_src/workspace/custom-skills/s1/.keep"
cat > "$pack_src/workspace/muse-migration/tools/verify-pack.py" <<'PYEOF'
# test double of muse.ai/verify-pack.py local mode (same checks, same keys).
import hashlib, json, os, sys
m = json.load(open(os.environ["MUSE_VERIFY_MANIFEST"], encoding="utf-8"))
home = os.environ.get("MUSE_VERIFY_ROOT", os.environ["HOME"])
fails = []
def check(name, ok, detail=""):
    print(("PASS: " if ok else "FAIL: ") + name + (" - " + detail if detail else ""))
    if not ok:
        fails.append(name)
for path, sk, hk in (("MEMORY.md", "memory_size", "memory_sha256"),
                     ("AGENTS.md", "agents_size", "agents_sha256")):
    p = os.path.join(home, path)
    b = open(p, "rb").read()
    check(path + " size", os.path.getsize(p) == m[sk])
    check(path + " sha256", hashlib.sha256(b).hexdigest() == m[hk])
for path, k in (("workspace/goals", "goals_count"),
                ("workspace/custom-skills", "skills_count")):
    check(path + " count", len(os.listdir(os.path.join(home, path))) == m[k])
standing = ("MEMORY.md", "SOUL.md", "AGENTS.md", "IDENTITY.md", "USER.md",
            "TOOLS.md", "HEARTBEAT.md", "PROACTIVE_PREFERENCES.md",
            "config/skills.yaml")
for p in m["backup_paths"]:
    bp = os.path.join(home, p + ".pre-migration")
    if os.path.exists(bp):
        check("backup " + p + ".pre-migration", True)
    elif p in standing:
        check("backup " + p + ".pre-migration", False, "missing")
    else:
        print("SKIP: backup " + p + ".pre-migration")
if fails:
    print("verify FAILED - %d checks failed" % len(fails))
    sys.exit(1)
print("VERIFY-PASS - unpack confirmed")
PYEOF
python3 - "$pack_src" <<'PYEOF'
import hashlib, json, os, sys
src = sys.argv[1]
def sha(p):
    return hashlib.sha256(open(p, "rb").read()).hexdigest()
def size(p):
    return os.path.getsize(p)
manifest = {
    "pack_filename": "test-pack.tar.gz",
    "pack_size": None,
    "memory_size": size(src + "/MEMORY.md"),
    "agents_size": size(src + "/AGENTS.md"),
    "memory_sha256": sha(src + "/MEMORY.md"),
    "agents_sha256": sha(src + "/AGENTS.md"),
    "goals_count": 1,
    "skills_count": 1,
    "backup_paths": ("MEMORY.md SOUL.md AGENTS.md IDENTITY.md USER.md TOOLS.md "
        "HEARTBEAT.md PROACTIVE_PREFERENCES.md config/skills.yaml "
        ".config/mainframe/mainframe.config.json "
        ".config/mainframe/approval-signing.key "
        ".config/mainframe/bw-email.enc.json memory dreams/alignment "
        "workspace/goals workspace/custom-skills workspace/custom-connectors "
        "workspace/your_files workspace/user workspace/cron.d").split(),
}
json.dump(manifest, open(src + "/pack-manifest.json", "w"), indent=2)
PYEOF
(cd "$pack_src" && tar -czf "$root/test-pack.tar.gz" MEMORY.md AGENTS.md IDENTITY.md pack-manifest.json workspace)
pack_size=$(stat -c%s "$root/test-pack.tar.gz")
pack_sha=$(sha256sum "$root/test-pack.tar.gz" | awk '{print $1}')

run_restore() {
  HOME="$1" bash "$repo/muse/restore.sh" --pack-file "$root/test-pack.tar.gz" \
    --sha256 "$pack_sha" --pack-size "$pack_size" \
    --test-skip-mainframe --mainframe-dir "$repo" > "$root/output" 2>&1
}

# --- case A: fresh restore ----------------------------------------------
# TAR_OPTIONS=-k would make tar refuse to replace the standing files; the
# test env sets it so a regression to a bare `tar -xzf` fails here instead
# of on a live destination. (maru 2026-11-22: its TAR_OPTIONS was actually
# unset — the "File exists" came from the sticky home dir, covered by
# case D below; the clear in restore.sh stays as defence.)
export TAR_OPTIONS=-k
home1="$root/home1"
make_home "$home1"
run_restore "$home1" || { cat "$root/output" >&2; fail "case A: restore exited non-zero"; }
grep -Fq "RESTORE DONE" "$root/output" || { cat "$root/output" >&2; fail "case A: no RESTORE DONE"; }
pass
grep -Fq "# MEMORY.md (packed)" "$home1/MEMORY.md" || fail "case A: MEMORY.md not replaced by the pack"
pass
grep -Fq -- "- **Name:** Maru" "$home1/IDENTITY.md" || fail "case A: own name not restored into IDENTITY.md"
pass
[ -f "$home1/.pre-migration.complete" ] || fail "case A: completion marker missing"
pass
grep -Fq "# MEMORY.md (original)" "$home1/MEMORY.md.pre-migration" || fail "case A: MEMORY.md backup is not the original"
pass
[ -f "$home1/memory.pre-migration/bank/note.md" ] && [ -f "$home1/memory.pre-migration/people/note.md" ] \
  || fail "case A: memory backup incomplete"
pass

# --- case B: re-run keeps the first backups -------------------------------
run_restore "$home1" || { cat "$root/output" >&2; fail "case B: re-run exited non-zero"; }
grep -Fq "KEEP (already backed up): MEMORY.md.pre-migration" "$root/output" \
  || { cat "$root/output" >&2; fail "case B: no KEEP on re-run"; }
pass
grep -Fq "# MEMORY.md (original)" "$home1/MEMORY.md.pre-migration" || fail "case B: re-run overwrote the first backup"
pass

# --- case C: partial backups without a marker are redone ------------------
home2="$root/home2"
make_home "$home2"
mkdir -p "$home2/memory.pre-migration"   # empty: a failed run's partial dir
printf 'stale\n' > "$home2/MEMORY.md.pre-migration"   # wrong content, same story
run_restore "$home2" || { cat "$root/output" >&2; fail "case C: restore exited non-zero"; }
grep -Fq "RESTORE DONE" "$root/output" || fail "case C: no RESTORE DONE"
pass
[ -f "$home2/memory.pre-migration/bank/note.md" ] || fail "case C: partial memory backup was kept, not redone"
pass
grep -Fq "# MEMORY.md (original)" "$home2/MEMORY.md.pre-migration" || fail "case C: stale MEMORY.md backup was kept, not redone"
pass

# --- case D: maru-like squashed mount -------------------------------------
# the destination vm's shell is root in-namespace but its home mount maps
# root to an unprivileged uid: chown fails, home is sticky (plain tar gets
# "File exists"), and tar restoring mtime/mode on the pre-existing
# root-owned files fails "Operation not permitted". reproduce it by
# running the restore as nobody:nogroup against a sticky home holding
# root-owned 0660 files. needs root + setpriv, so it skips on CI.
if [ "$(id -u)" -eq 0 ] && command -v setpriv >/dev/null 2>&1; then
  home4="$root/home4"
  make_home "$home4"
  chown -R root:nogroup "$home4"
  chmod 0660 "$home4"/*.md "$home4/config/skills.yaml"
  chmod 1777 "$home4"
  chmod 0711 "$root"
  chmod 0644 "$root/test-pack.tar.gz"
  chmod 0755 "$root/bin"
  # the repo clone is 770 root:root, unreadable to nobody — stage the
  # script + conventions into the temp tree (copied fresh, so it is the
  # current script under test) with world-readable modes.
  mkdir -p "$root/mf/muse" "$root/mf/.git"
  cp "$repo/muse/restore.sh" "$root/mf/muse/restore.sh"
  cp "$repo/muse/pull-conventions.sh" "$root/mf/muse/pull-conventions.sh"
  cp "$repo/muse/CONVENTIONS.md" "$root/mf/muse/CONVENTIONS.md"
  chmod 0755 "$root/mf" "$root/mf/muse" "$root/mf/.git"
  chmod 0644 "$root/mf/muse/restore.sh" "$root/mf/muse/CONVENTIONS.md"
  chmod 0755 "$root/mf/muse/pull-conventions.sh"
  HOME="$home4" PATH="$root/bin:$PATH" TAR_OPTIONS=-k \
    setpriv --reuid=nobody --regid=nogroup --clear-groups \
    bash "$root/mf/muse/restore.sh" --pack-file "$root/test-pack.tar.gz" \
    --sha256 "$pack_sha" --pack-size "$pack_size" \
    --test-skip-mainframe --mainframe-dir "$root/mf" > "$root/output" 2>&1 \
    || { cat "$root/output" >&2; fail "case D: restore exited non-zero on the squashed mount"; }
  grep -Fq "RESTORE DONE" "$root/output" || { cat "$root/output" >&2; fail "case D: no RESTORE DONE"; }
  pass
  grep -Fq "# MEMORY.md (packed)" "$home4/MEMORY.md" || fail "case D: MEMORY.md not replaced by the pack"
  pass
  grep -Fq -- "- **Name:** Maru" "$home4/IDENTITY.md" || fail "case D: own name not restored into IDENTITY.md"
  pass
  [ -f "$home4/.pre-migration.complete" ] || fail "case D: completion marker missing"
  pass
else
  echo "SKIP: case D (maru-like squash) needs root + setpriv"
fi

echo "muse-restore: $checks checks passed"
