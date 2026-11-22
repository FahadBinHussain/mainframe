#!/usr/bin/env bash
# muse/restore.sh backup step: --no-preserve=ownership + completion marker.
# regression test for the maru 2026-11-22 failure: plain `cp -a` died on
# the root-owned memory dir ("failed to preserve ownership: Operation not
# permitted") because the destination vm's mount refuses chown even as
# root, and set -e aborted the restore before extracting anything.
#
# the mock cp below reproduces that vm: plain `cp -a` fails, and only
# --no-preserve=ownership passes through to the real cp. if restore.sh
# ever regresses to plain `cp -a`, case A fails here instead of on a
# live destination.
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
chmod +x "$root/bin/cp"
# mock git: pull-conventions.sh runs `git pull --ff-only`; the test clone
# is already current, so a no-op success is the honest double.
cat > "$root/bin/git" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$root/bin/git"
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
# the destination vm exports TAR_OPTIONS=-k (keep-old-files), which makes
# tar refuse to replace the standing files; the test env reproduces it so
# a regression to a bare `tar -xzf` fails here instead of on a live
# destination (maru 2026-11-22).
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

echo "muse-restore: $checks checks passed"
