#!/usr/bin/env python3
"""Fake `bw` for the bootstrap/rotate tests (mock-bw.py).

Implements only the subcommands windows/mainframe.ps1 vault bootstrap-link and
vault rotate-topic use, against a JSON file in
MF_MOCK_BW_STATE. No network, no real vault, obvious fake values only.

State: $MF_MOCK_BW_STATE/items.json (a JSON array of vault items).
Calls are appended to $MF_CALL_LOG as "BW <cmd> <sub>" - the first two
tokens only, never a --session value or item content.
MF_MOCK_BW_LOCKED=1 makes `status` report a locked vault.
"""
import json
import os
import sys

STATE = os.environ.get("MF_MOCK_BW_STATE", "")
ITEMS_FILE = os.path.join(STATE, "items.json") if STATE else ""
CALL_LOG = os.environ.get("MF_CALL_LOG", "")


def log_call(argv):
    if not CALL_LOG:
        return
    with open(CALL_LOG, "a", encoding="utf-8") as f:
        f.write("BW " + " ".join(argv[:2]) + "\n")


def load_items():
    if not ITEMS_FILE or not os.path.exists(ITEMS_FILE):
        return []
    with open(ITEMS_FILE, encoding="utf-8") as f:
        raw = f.read().strip()
    if not raw:
        return []
    return json.loads(raw)


def save_items(items):
    tmp = ITEMS_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(items, f)
    os.replace(tmp, ITEMS_FILE)


def strip_session(argv):
    out = []
    i = 0
    while i < len(argv):
        if argv[i] == "--session":
            i += 2
            continue
        out.append(argv[i])
        i += 1
    return out


def main(argv):
    if not STATE:
        print("fake bw: MF_MOCK_BW_STATE is not set", file=sys.stderr)
        return 1
    os.makedirs(STATE, exist_ok=True)
    log_call(argv)
    args = strip_session(argv)
    if not args:
        print("fake bw: no command", file=sys.stderr)
        return 1
    cmd = args[0]
    if cmd == "status":
        if os.environ.get("MF_MOCK_BW_LOCKED") == "1":
            print(json.dumps({"status": "locked"}))
        else:
            print(json.dumps({"status": "unlocked", "userEmail": "test@example.invalid", "userId": "mock-user"}))
        return 0
    if cmd == "list":
        # list items --search <name>: substring match, like the real bw.
        search = ""
        if "--search" in args:
            search = args[args.index("--search") + 1]
        items = [it for it in load_items() if search in it.get("name", "")]
        print(json.dumps(items))
        return 0
    if cmd == "get":
        if len(args) >= 3 and args[1] == "item":
            for it in load_items():
                if it.get("id") == args[2]:
                    print(json.dumps(it))
                    return 0
            print("fake bw: item not found: %s" % args[2], file=sys.stderr)
            return 1
        print("fake bw: unknown get: %s" % " ".join(args), file=sys.stderr)
        return 1
    if cmd == "encode":
        raw = sys.stdin.read()
        try:
            obj = json.loads(raw)
        except ValueError:
            print("fake bw: encode got invalid json", file=sys.stderr)
            return 1
        print(json.dumps(obj, separators=(",", ":")))
        return 0
    if cmd == "create":
        raw = sys.stdin.read()
        try:
            obj = json.loads(raw)
        except ValueError:
            print("fake bw: create got invalid json", file=sys.stderr)
            return 1
        items = load_items()
        obj["id"] = "mock-id-%d" % (len(items) + 1)
        items.append(obj)
        save_items(items)
        print(json.dumps(obj))
        return 0
    if cmd == "edit":
        if len(args) < 3 or args[1] != "item":
            print("fake bw: unknown edit: %s" % " ".join(args), file=sys.stderr)
            return 1
        raw = sys.stdin.read()
        try:
            obj = json.loads(raw)
        except ValueError:
            print("fake bw: edit got invalid json", file=sys.stderr)
            return 1
        items = load_items()
        for i, it in enumerate(items):
            if it.get("id") == args[2]:
                obj["id"] = args[2]
                items[i] = obj
                save_items(items)
                print(json.dumps(obj))
                return 0
        print("fake bw: edit: item not found: %s" % args[2], file=sys.stderr)
        return 1
    print("fake bw: unknown command %s" % cmd, file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
