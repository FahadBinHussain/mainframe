#!/usr/bin/env python3
"""Run every mainframe test suite with one command: python3 run-tests.py.

Suites:
  py        python3 -m unittest discover (tests/test_*.py)
  ps1       every tests/*.Tests.ps1 under pwsh (no Pester dependency)
  sh        every tests/*.Tests.sh under bash
  contract  accounts/account-contract.ps1 under pwsh

One verdict at the end: ALL SUITES PASS, or FAIL naming the suites that
broke. Exit 0 on pass, 1 on any failure.

The python suite has 20 pre-existing failures on this VM (environmental:
windows-only tests, missing tools). They are pinned in
tests/known-failures.txt and the run FAILS if the failure set changes in
either direction - a new failure, or a pinned failure that starts
passing. Re-record the set with --update-baseline (it prints the diff;
review it with git diff before committing).

PowerShell suites run with MAINFRAME_PROFILE_ROOT pointed at a fresh temp
dir, so no ps1 test can ever touch the real vault session: on 2026-11-15
the unisolated ttl test overwrote the live 12-hour session.key with a
fake test key and then deleted it. Tests that need isolation also do it
themselves (see vault-approval-ttl.Tests.ps1); the runner-level temp
profile is the backstop.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
TESTS = ROOT / "tests"
BASELINE = TESTS / "known-failures.txt"

# ps1 tests that only run on windows (they fail on linux for platform
# reasons, not code reasons). skipped loudly anywhere else.
PS1_WINDOWS_ONLY = {
    "mainframe-paths.Tests.ps1": "windows-only: reads $env:APPDATA",
    "vault-approval-lock.Tests.ps1": "windows-only: Start-Process -WindowStyle",
}

# sh tests expected to fail in this environment, with the reason. a pass
# here is a failure of the expectation: remove the entry, don't ignore it.
SH_EXPECTED_FAIL = {
    "linux-real.Tests.sh": "no git credentials in the temp HOME (automata-private sync dies at git exit 128)",
}

FAIL_LINE = re.compile(r"^(FAIL|ERROR): (.+)$")


def die(message: str) -> "SystemExit":
    print(f"FATAL: {message}", file=sys.stderr)
    raise SystemExit(2)


def find_pwsh() -> str:
    found = shutil.which("pwsh")
    if found:
        return found
    tools = Path.home() / ".local" / "share" / "mainframe" / "tools" / "pwsh" / "pwsh"
    if tools.is_file():
        return str(tools)
    die("pwsh not found: install PowerShell 7 (the mainframe restore puts it at "
        "~/.local/share/mainframe/tools/pwsh/pwsh on linux).")
    raise AssertionError("unreachable")


def find_bash() -> str:
    found = shutil.which("bash")
    if found:
        return found
    die("bash not found: the shell suites need it (git bash on windows).")
    raise AssertionError("unreachable")


def run(cmd: list[str], env: dict | None, timeout: int) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(cmd, capture_output=True, text=True, cwd=ROOT, env=env, timeout=timeout)
    except subprocess.TimeoutExpired:
        die(f"timed out after {timeout}s: {' '.join(cmd)}")
        raise AssertionError("unreachable")


def parse_py_failures(output: str) -> tuple[set[str], str]:
    failures = {m.group(0) for line in output.splitlines() if (m := FAIL_LINE.match(line))}
    summary = ""
    for line in output.splitlines():
        if line.startswith("Ran ") or line.startswith(("OK", "FAILED")):
            summary += line + " "
    return failures, summary.strip()


def load_baseline() -> set[str]:
    if not BASELINE.is_file():
        die(f"baseline missing: {BASELINE} does not exist. run with --update-baseline "
            "to record the current failure set, review it, then commit it.")
    return {line.strip() for line in BASELINE.read_text().splitlines() if line.strip()}


def suite_py(update_baseline: bool) -> tuple[bool, str]:
    proc = run([sys.executable, "-m", "unittest", "discover", "-s", "tests", "-p", "test_*.py"],
               env=None, timeout=600)
    failures, summary = parse_py_failures(proc.stdout + proc.stderr)
    if update_baseline:
        old = load_baseline() if BASELINE.is_file() else set()
        BASELINE.write_text("".join(f"{line}\n" for line in sorted(failures)))
        added = sorted(failures - old)
        removed = sorted(old - failures)
        detail = f"baseline rewritten: {len(failures)} failures pinned"
        if added:
            detail += "\n    added: " + ", ".join(added)
        if removed:
            detail += "\n    removed: " + ", ".join(removed)
        return True, f"py: {summary} | {detail}"
    baseline = load_baseline()
    if failures == baseline:
        return True, f"py: {summary} | failures == baseline ({len(baseline)} known)"
    new = sorted(failures - baseline)
    fixed = sorted(baseline - failures)
    detail = f"py: {summary} | FAILURE SET CHANGED (baseline {len(baseline)}, now {len(failures)})"
    if new:
        detail += "\n    NEW FAILURES: " + ", ".join(new)
    if fixed:
        detail += "\n    BASELINE FAILURES NOW PASSING (update the baseline): " + ", ".join(fixed)
    return False, detail


def suite_ps1(pwsh: str) -> list[tuple[bool, str]]:
    results = []
    profile_root = Path(tempfile.mkdtemp(prefix="mainframe-test-profile-"))
    env = dict(os.environ)
    env["MAINFRAME_PROFILE_ROOT"] = str(profile_root)
    try:
        for path in sorted(TESTS.glob("*.Tests.ps1")):
            name = path.name
            if name in PS1_WINDOWS_ONLY and os.name != "nt":
                results.append((True, f"ps1/{name}: SKIP ({PS1_WINDOWS_ONLY[name]})"))
                continue
            proc = run([pwsh, "-NoProfile", "-NonInteractive", "-File", str(path)],
                       env=env, timeout=300)
            tail = (proc.stdout + proc.stderr).strip().splitlines()
            last = tail[-1].strip() if tail else "(no output)"
            if proc.returncode == 0:
                results.append((True, f"ps1/{name}: PASS ({last})"))
            else:
                shown = "\n      ".join(tail[-6:])
                results.append((False, f"ps1/{name}: FAIL (exit {proc.returncode})\n      {shown}"))
    finally:
        shutil.rmtree(profile_root, ignore_errors=True)
    return results


def suite_sh(bash: str) -> list[tuple[bool, str]]:
    results = []
    for path in sorted(TESTS.glob("*.Tests.sh")):
        name = path.name
        proc = run([bash, str(path)], env=None, timeout=300)
        tail = (proc.stdout + proc.stderr).strip().splitlines()
        last = tail[-1].strip() if tail else "(no output)"
        if name in SH_EXPECTED_FAIL:
            if proc.returncode != 0:
                results.append((True, f"sh/{name}: EXPECTED-FAIL ({SH_EXPECTED_FAIL[name]})"))
            else:
                results.append((False, f"sh/{name}: UNEXPECTEDLY PASSED - remove it from SH_EXPECTED_FAIL"))
        elif proc.returncode == 0:
            results.append((True, f"sh/{name}: PASS ({last})"))
        else:
            shown = "\n      ".join(tail[-6:])
            results.append((False, f"sh/{name}: FAIL (exit {proc.returncode})\n      {shown}"))
    return results


def suite_contract(pwsh: str) -> tuple[bool, str]:
    proc = run([pwsh, "-NoProfile", "-NonInteractive", "-File",
                str(ROOT / "accounts" / "account-contract.ps1")],
               env=None, timeout=300)
    tail = (proc.stdout + proc.stderr).strip().splitlines()
    last = tail[-1].strip() if tail else "(no output)"
    if proc.returncode == 0:
        return True, f"contract: PASS ({last})"
    shown = "\n      ".join(tail[-6:])
    return False, f"contract: FAIL (exit {proc.returncode})\n      {shown}"


def main() -> int:
    parser = argparse.ArgumentParser(description="run every mainframe test suite")
    parser.add_argument("--update-baseline", action="store_true",
                        help="re-record tests/known-failures.txt from this run and exit 0")
    args = parser.parse_args()

    pwsh = find_pwsh()
    bash = find_bash()

    results: list[tuple[bool, str]] = []
    ok, detail = suite_py(args.update_baseline)
    results.append((ok, detail))
    print(detail, flush=True)
    if args.update_baseline:
        print("baseline updated - review it with git diff before committing.")
        return 0
    for ok, detail in suite_ps1(pwsh):
        results.append((ok, detail))
        print(detail, flush=True)
    for ok, detail in suite_sh(bash):
        results.append((ok, detail))
        print(detail, flush=True)
    ok, detail = suite_contract(pwsh)
    results.append((ok, detail))
    print(detail, flush=True)

    failed = [d for ok, d in results if not ok]
    print()
    if not failed:
        print(f"ALL SUITES PASS ({len(results)} suites)")
        return 0
    print(f"FAIL: {len(failed)} of {len(results)} suites failed:")
    for detail in failed:
        print(f"  - {detail.splitlines()[0]}")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
