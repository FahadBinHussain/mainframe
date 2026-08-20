param(
  [Parameter(Position = 0)]
  [string] $Command = "help",

  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]] $Remaining
)

$ErrorActionPreference = "Stop"

$Root = Join-Path $env:APPDATA "mainframe\accounts\telegram"
$CurrentFile = Join-Path $Root "current.txt"
$RuntimeRoot = Join-Path $env:APPDATA "mainframe\runtimes\telegram-python"
$BridgePath = Join-Path $env:TEMP "mainframe-telegram-bridge.py"

function Show-Help {
  @"
mainframe Telegram personal account helper

Usage:
  telegram-account.ps1 deps
  telegram-account.ps1 login <phone> [--api-id id] [--api-hash hash] [--owner-email email]
  telegram-account.ps1 use <phone>
  telegram-account.ps1 current
  telegram-account.ps1 list
  telegram-account.ps1 status [phone]
  telegram-account.ps1 status-all
  telegram-account.ps1 path [phone]
  telegram-account.ps1 env [phone]
  telegram-account.ps1 run [phone] [capabilities|status|me|dialogs|messages|send-text|mark-read|archive|unarchive|mute|unmute|block|unblock|leave|delete-dialog|sessions] [bridge args]
  telegram-account.ps1 logout [phone]

Examples:
  telegram-account.ps1 deps
  telegram-account.ps1 login +8801XXXXXXXXX
  telegram-account.ps1 run status
  telegram-account.ps1 run dialogs --limit 20
  telegram-account.ps1 run dialogs --query crypto --type channel --with-links
  telegram-account.ps1 run messages --chat "Saved Messages" --limit 10
  telegram-account.ps1 run send-text --chat "Saved Messages" --text "hi"
  telegram-account.ps1 run archive --chat "Some Channel"
  telegram-account.ps1 run leave --chat "Some Channel" --confirm "Some Channel"

Telegram personal accounts are keyed by phone number. This uses Telegram
MTProto through Telethon, not Bot API. First login needs an api_id/api_hash from
https://my.telegram.org plus the Telegram login code and 2FA password if enabled.

This helper stores a local Telethon session file and API app credentials inside
the profile path. It never prints session files, API hashes, or auth codes.
"@
}

function Ensure-Root {
  New-Item -ItemType Directory -Force -Path $Root | Out-Null
}

function Test-PhoneLike {
  param([string] $Value)
  if (-not $Value) { return $false }
  return [bool] ($Value.Trim() -match "^(?:\+|00)\d[\d\s().-]{6,24}$")
}

function Normalize-Phone {
  param([string] $Phone)
  if (-not $Phone) {
    throw "Phone is required. Telegram profiles are keyed by phone number."
  }

  $Normalized = $Phone.Trim() -replace "[\s().-]", ""
  if ($Normalized.StartsWith("00")) {
    $Normalized = "+" + $Normalized.Substring(2)
  }

  if (-not ($Normalized -match "^\+\d{7,15}$")) {
    throw "Invalid phone: $Phone. Use E.164 format, for example +8801XXXXXXXXX."
  }

  return $Normalized
}

function Test-EmailLike {
  param([string] $Value)
  return [bool] ($Value -match "^[^@\s]+@[^@\s]+\.[^@\s]+$")
}

function Normalize-OwnerEmail {
  param([string] $Email)
  if (-not $Email) { return $null }
  $Normalized = $Email.Trim().ToLowerInvariant()
  if (-not (Test-EmailLike $Normalized)) {
    throw "Invalid owner email: $Email"
  }
  return $Normalized
}

function Convert-SecureStringToPlainText {
  param([securestring] $Secure)
  if (-not $Secure) { return "" }
  $Ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
  try {
    return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($Ptr)
  } finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($Ptr)
  }
}

function Get-ProfilePath {
  param([string] $Phone)
  return Join-Path $Root (Normalize-Phone $Phone)
}

function Get-MetadataPath {
  param([string] $Phone)
  return Join-Path (Get-ProfilePath $Phone) "mainframe-telegram.json"
}

function Get-SessionBasePath {
  param([string] $Phone)
  return Join-Path (Get-ProfilePath $Phone) "telegram"
}

function Get-SessionFilePath {
  param([string] $Phone)
  return "$(Get-SessionBasePath $Phone).session"
}

function Get-ApiIdPath {
  param([string] $Phone)
  return Join-Path (Get-ProfilePath $Phone) "api-id.txt"
}

function Get-ApiHashPath {
  param([string] $Phone)
  return Join-Path (Get-ProfilePath $Phone) "api-hash.txt"
}

function Get-CurrentPhone {
  if (Test-Path $CurrentFile) {
    $Value = (Get-Content $CurrentFile -Raw).Trim()
    if ($Value) {
      try {
        return (Normalize-Phone $Value)
      } catch {
        return $null
      }
    }
  }
  return $null
}

function Set-CurrentPhone {
  param([string] $Phone)
  Ensure-Root
  Set-Content -LiteralPath $CurrentFile -Value (Normalize-Phone $Phone) -Encoding UTF8
}

function Read-Metadata {
  param([string] $Phone)
  $Path = Get-MetadataPath $Phone
  if (-not (Test-Path $Path)) {
    return $null
  }

  try {
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
  } catch {
    return $null
  }
}

function Write-Metadata {
  param(
    [string] $Phone,
    [string] $OwnerEmail
  )

  $NormalizedPhone = Normalize-Phone $Phone
  $ProfilePath = Get-ProfilePath $NormalizedPhone
  New-Item -ItemType Directory -Force -Path $ProfilePath | Out-Null

  $Metadata = [ordered] @{
    phone = $NormalizedPhone
    kind = "telegram-mtproto-telethon"
    ownerEmail = Normalize-OwnerEmail $OwnerEmail
    profilePath = $ProfilePath
    sessionFile = Get-SessionFilePath $NormalizedPhone
    updatedAt = (Get-Date).ToUniversalTime().ToString("o")
  }

  $Metadata | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Get-MetadataPath $NormalizedPhone) -Encoding UTF8
}

function Get-PythonExe {
  $VenvPython = Join-Path $RuntimeRoot "Scripts\python.exe"
  if (Test-Path $VenvPython) {
    return $VenvPython
  }

  $Python = Get-Command python -ErrorAction SilentlyContinue
  if ($Python -and $Python.Source) {
    return $Python.Source
  }

  $Py = Get-Command py -ErrorAction SilentlyContinue
  if ($Py -and $Py.Source) {
    return $Py.Source
  }

  throw "Python was not found. Install Python or run this from a machine with python on PATH."
}

function Install-Deps {
  $Python = Get-PythonExe
  if (-not (Test-Path (Join-Path $RuntimeRoot "Scripts\python.exe"))) {
    & $Python -m venv $RuntimeRoot
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to create Telegram helper venv at $RuntimeRoot"
    }
  }

  $VenvPython = Join-Path $RuntimeRoot "Scripts\python.exe"
  & $VenvPython -m pip install --upgrade pip telethon
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to install Telethon in $RuntimeRoot"
  }

  Write-Host "Telegram helper dependencies are ready: $RuntimeRoot"
}

function Test-TelethonInstalled {
  $Python = Get-PythonExe
  & $Python -c "import telethon" 2>$null
  return ($LASTEXITCODE -eq 0)
}

function Ensure-TelethonInstalled {
  if (-not (Test-TelethonInstalled)) {
    throw "Telethon is not installed for the selected Python. Run .\telegram-account.ps1 deps first."
  }
}

function Read-ApiCredentials {
  param(
    [string] $Phone,
    [string] $ApiId,
    [string] $ApiHash,
    [bool] $AllowPrompt
  )

  $NormalizedPhone = Normalize-Phone $Phone
  $ProfilePath = Get-ProfilePath $NormalizedPhone
  New-Item -ItemType Directory -Force -Path $ProfilePath | Out-Null

  if (-not $ApiId -and $env:TELEGRAM_API_ID) {
    $ApiId = $env:TELEGRAM_API_ID
  }
  if (-not $ApiHash -and $env:TELEGRAM_API_HASH) {
    $ApiHash = $env:TELEGRAM_API_HASH
  }

  $ApiIdPath = Get-ApiIdPath $NormalizedPhone
  $ApiHashPath = Get-ApiHashPath $NormalizedPhone
  if (-not $ApiId -and (Test-Path $ApiIdPath)) {
    $ApiId = (Get-Content -LiteralPath $ApiIdPath -Raw).Trim()
  }
  if (-not $ApiHash -and (Test-Path $ApiHashPath)) {
    $ApiHash = (Get-Content -LiteralPath $ApiHashPath -Raw).Trim()
  }

  if ($AllowPrompt -and -not $ApiId) {
    $ApiId = Read-Host "Telegram api_id from my.telegram.org"
  }
  if ($AllowPrompt -and -not $ApiHash) {
    $ApiHash = Convert-SecureStringToPlainText (Read-Host "Telegram api_hash from my.telegram.org" -AsSecureString)
  }

  if (-not ($ApiId -match "^\d+$")) {
    throw "Telegram api_id is required and must be numeric. Get it from https://my.telegram.org."
  }
  if (-not $ApiHash) {
    throw "Telegram api_hash is required. Get it from https://my.telegram.org."
  }

  Set-Content -LiteralPath $ApiIdPath -Value $ApiId -Encoding UTF8
  Set-Content -LiteralPath $ApiHashPath -Value $ApiHash -Encoding UTF8

  [pscustomobject] @{
    ApiId = $ApiId
    ApiHash = $ApiHash
  }
}

function Parse-ProfileArgs {
  param(
    [string[]] $Items,
    [bool] $RequirePhone = $false
  )

  $Phone = $null
  $ApiId = $null
  $ApiHash = $null
  $OwnerEmail = $null
  $Rest = New-Object System.Collections.Generic.List[string]

  for ($Index = 0; $Index -lt $Items.Count; $Index++) {
    $Token = $Items[$Index]
    if ($Token -eq "--api-id") {
      $Index += 1
      if ($Index -ge $Items.Count) { throw "$Token requires a value." }
      $ApiId = $Items[$Index]
    } elseif ($Token -like "--api-id=*") {
      $ApiId = $Token.Substring("--api-id=".Length)
    } elseif ($Token -eq "--api-hash") {
      $Index += 1
      if ($Index -ge $Items.Count) { throw "$Token requires a value." }
      $ApiHash = $Items[$Index]
    } elseif ($Token -like "--api-hash=*") {
      $ApiHash = $Token.Substring("--api-hash=".Length)
    } elseif ($Token -eq "--owner-email") {
      $Index += 1
      if ($Index -ge $Items.Count) { throw "$Token requires a value." }
      $OwnerEmail = Normalize-OwnerEmail $Items[$Index]
    } elseif ($Token -like "--owner-email=*") {
      $OwnerEmail = Normalize-OwnerEmail $Token.Substring("--owner-email=".Length)
    } elseif (-not $Phone -and (Test-PhoneLike $Token)) {
      $Phone = Normalize-Phone $Token
    } else {
      $Rest.Add($Token)
    }
  }

  if (-not $Phone) {
    $Phone = Get-CurrentPhone
  }

  if ($RequirePhone -and -not $Phone) {
    throw "Phone is required. Example: telegram-account.ps1 login +8801XXXXXXXXX"
  }

  [pscustomobject] @{
    Phone = $Phone
    ApiId = $ApiId
    ApiHash = $ApiHash
    OwnerEmail = $OwnerEmail
    Rest = [string[]] $Rest.ToArray()
  }
}

function Get-BridgeSource {
@'
import argparse
import asyncio
import getpass
import json
import os
import sys
from datetime import datetime, timedelta, timezone

try:
    from telethon import TelegramClient, functions, types
    from telethon.errors import SessionPasswordNeededError
except ImportError:
    print(json.dumps({"ok": False, "error": "Telethon is not installed. Run telegram-account.ps1 deps first."}))
    sys.exit(2)


def env_required(name):
    value = os.environ.get(name, "").strip()
    if not value:
        raise RuntimeError(f"{name} is required")
    return value


def safe_user(user):
    if not user:
        return None
    return {
        "id": user.id,
        "phone": getattr(user, "phone", None),
        "username": getattr(user, "username", None),
        "firstName": getattr(user, "first_name", None),
        "lastName": getattr(user, "last_name", None),
    }


def entity_title(entity):
    if isinstance(entity, types.User):
        name = " ".join(part for part in [getattr(entity, "first_name", None), getattr(entity, "last_name", None)] if part)
        return name or getattr(entity, "username", None) or str(getattr(entity, "id", ""))
    return getattr(entity, "title", None) or getattr(entity, "username", None) or str(getattr(entity, "id", ""))


def entity_kind(entity):
    if isinstance(entity, types.User):
        return "bot" if getattr(entity, "bot", False) else "user"
    if getattr(entity, "broadcast", False):
        return "channel"
    if getattr(entity, "megagroup", False) or getattr(entity, "gigagroup", False):
        return "group"
    if isinstance(entity, types.Chat):
        return "group"
    return entity.__class__.__name__


def public_link(entity):
    username = getattr(entity, "username", None)
    if username:
        return f"https://t.me/{username}"
    return None


def dialog_row(dialog):
    entity = dialog.entity
    username = getattr(entity, "username", None)
    folder_id = getattr(dialog, "folder_id", None)
    return {
        "peerId": dialog.id,
        "entityId": getattr(entity, "id", None),
        "kind": entity_kind(entity),
        "title": dialog.name,
        "username": username,
        "link": public_link(entity),
        "unreadCount": dialog.unread_count,
        "unreadMentionsCount": getattr(dialog, "unread_mentions_count", None),
        "pinned": bool(getattr(dialog, "pinned", False)),
        "folderId": folder_id,
        "archived": folder_id == 1,
        "date": dialog.date.isoformat() if getattr(dialog, "date", None) else None,
    }


def type_matches(row, wanted):
    if wanted == "all":
        return True
    if wanted == "chat":
        return row["kind"] in {"user", "bot", "group", "channel"}
    return row["kind"] == wanted


def text_matches(row, query):
    if not query:
        return True
    needle = query.casefold()
    haystack = " ".join(str(row.get(key) or "") for key in ("title", "username", "link", "kind")).casefold()
    return needle in haystack


def confirmation_options(entity):
    values = {
        entity_title(entity),
        str(getattr(entity, "id", "")),
    }
    username = getattr(entity, "username", None)
    if username:
        values.add(username)
        values.add("@" + username)
    return {value.strip() for value in values if value and value.strip()}


def require_confirmation(confirm, entity, action):
    options = confirmation_options(entity)
    if not confirm or confirm.strip() not in options:
        expected = sorted(options)[0] if options else str(getattr(entity, "id", ""))
        raise RuntimeError(f"{action} needs --confirm exactly matching the title, username, or id. Example: --confirm {json.dumps(expected, ensure_ascii=False)}")


def seconds_to_mute_until(seconds):
    if seconds <= 0:
        return 0
    return int((datetime.now(timezone.utc) + timedelta(seconds=seconds)).timestamp())


def print_json(value):
    print(json.dumps(value, ensure_ascii=False, default=str))


def make_client():
    api_id = int(env_required("MAINFRAME_TELEGRAM_API_ID"))
    api_hash = env_required("MAINFRAME_TELEGRAM_API_HASH")
    session_base = env_required("MAINFRAME_TELEGRAM_SESSION")
    return TelegramClient(session_base, api_id, api_hash)


async def require_authorized(client):
    await client.connect()
    if not await client.is_user_authorized():
        raise RuntimeError("Telegram session is not authorized. Run telegram-account.ps1 login <phone> first.")


async def cmd_login(args):
    phone = env_required("MAINFRAME_TELEGRAM_PHONE")
    client = make_client()
    try:
        await client.connect()
        if not await client.is_user_authorized():
            await client.disconnect()

            def code_callback():
                return input("Telegram login code: ").strip()

            def password_callback():
                return getpass.getpass("Telegram 2FA password: ")

            client = make_client()
            await client.start(
                phone=phone,
                code_callback=code_callback,
                password=password_callback,
                max_attempts=3,
            )

        me = await client.get_me()
        print_json({"ok": True, "authorized": True, "me": safe_user(me)})
    finally:
        if client.is_connected():
            await client.disconnect()


async def cmd_status(args):
    client = make_client()
    await client.connect()
    authorized = await client.is_user_authorized()
    me = await client.get_me() if authorized else None
    await client.disconnect()
    print_json({"ok": True, "authorized": authorized, "me": safe_user(me)})


async def cmd_capabilities(args):
    print_json({
        "ok": True,
        "service": "telegram",
        "mode": "personal-account-mtproto",
        "safeCommands": [
            "status",
            "me",
            "dialogs",
            "messages",
            "sessions"
        ],
        "mutatingCommands": [
            "send-text",
            "mark-read",
            "archive",
            "unarchive",
            "mute",
            "unmute"
        ],
        "guardedCommands": [
            "block",
            "unblock",
            "leave",
            "delete-dialog"
        ],
        "notes": [
            "public links are available only for peers with usernames",
            "guarded commands require --confirm matching title, username, or id",
            "session files and API hashes are never printed"
        ]
    })


async def cmd_dialogs(args):
    client = make_client()
    await require_authorized(client)
    archived = None
    if args.archived == "yes":
        archived = True
    elif args.archived == "no":
        archived = False

    rows = []
    async for dialog in client.iter_dialogs(limit=args.limit, archived=archived):
        row = dialog_row(dialog)
        if not args.with_links:
            row.pop("link", None)
        if type_matches(row, args.type) and text_matches(row, args.query):
            rows.append(row)
    await client.disconnect()
    print_json({"ok": True, "dialogs": rows})


async def cmd_messages(args):
    client = make_client()
    await require_authorized(client)
    rows = []
    async for message in client.iter_messages(args.chat, limit=args.limit):
        rows.append({
            "id": message.id,
            "date": message.date.isoformat() if message.date else None,
            "senderId": message.sender_id,
            "out": bool(message.out),
            "hasMedia": bool(message.media),
            "text": message.message or "",
        })
    await client.disconnect()
    print_json({"ok": True, "messages": rows})


async def cmd_send_text(args):
    client = make_client()
    await require_authorized(client)
    message = await client.send_message(args.chat, args.text)
    await client.disconnect()
    print_json({"ok": True, "sent": {"id": message.id, "date": message.date.isoformat() if message.date else None}})


async def cmd_mark_read(args):
    client = make_client()
    await require_authorized(client)
    entity = await client.get_entity(args.chat)
    ok = await client.send_read_acknowledge(
        entity,
        max_id=args.max_id,
        clear_mentions=args.clear_mentions,
        clear_reactions=args.clear_reactions,
    )
    await client.disconnect()
    print_json({"ok": True, "markedRead": bool(ok), "chat": entity_title(entity)})


async def cmd_folder(args, folder):
    client = make_client()
    await require_authorized(client)
    entity = await client.get_entity(args.chat)
    await client.edit_folder(entity, folder)
    await client.disconnect()
    print_json({"ok": True, "chat": entity_title(entity), "folderId": folder, "archived": folder == 1})


async def cmd_notify(args, mute):
    client = make_client()
    await require_authorized(client)
    entity = await client.get_entity(args.chat)
    input_entity = await client.get_input_entity(entity)
    mute_until = seconds_to_mute_until(args.seconds) if mute else 0
    await client(functions.account.UpdateNotifySettingsRequest(
        peer=types.InputNotifyPeer(input_entity),
        settings=types.InputPeerNotifySettings(mute_until=mute_until),
    ))
    await client.disconnect()
    print_json({"ok": True, "chat": entity_title(entity), "muted": mute, "muteUntil": mute_until})


async def cmd_block(args, block):
    client = make_client()
    await require_authorized(client)
    entity = await client.get_entity(args.chat)
    require_confirmation(args.confirm, entity, "block" if block else "unblock")
    input_entity = await client.get_input_entity(entity)
    if block:
        result = await client(functions.contacts.BlockRequest(id=input_entity))
    else:
        result = await client(functions.contacts.UnblockRequest(id=input_entity))
    await client.disconnect()
    print_json({"ok": bool(result), "chat": entity_title(entity), "blocked": block})


async def cmd_leave(args):
    client = make_client()
    await require_authorized(client)
    entity = await client.get_entity(args.chat)
    kind = entity_kind(entity)
    if kind not in {"group", "channel"}:
        raise RuntimeError(f"leave only applies to groups/channels. This peer is {kind}. Use delete-dialog if you really mean to remove a private dialog.")
    require_confirmation(args.confirm, entity, "leave")
    await client.delete_dialog(entity, revoke=False)
    await client.disconnect()
    print_json({"ok": True, "left": entity_title(entity), "kind": kind})


async def cmd_delete_dialog(args):
    client = make_client()
    await require_authorized(client)
    entity = await client.get_entity(args.chat)
    require_confirmation(args.confirm, entity, "delete-dialog")
    await client.delete_dialog(entity, revoke=False)
    await client.disconnect()
    print_json({"ok": True, "deletedDialog": entity_title(entity), "kind": entity_kind(entity), "revoke": False})


async def cmd_sessions(args):
    client = make_client()
    await require_authorized(client)
    result = await client(functions.account.GetAuthorizationsRequest())
    rows = []
    for index, auth in enumerate(result.authorizations, start=1):
        rows.append({
            "index": index,
            "current": bool(getattr(auth, "current", False)),
            "officialApp": bool(getattr(auth, "official_app", False)),
            "appName": getattr(auth, "app_name", None),
            "appVersion": getattr(auth, "app_version", None),
            "deviceModel": getattr(auth, "device_model", None),
            "platform": getattr(auth, "platform", None),
            "systemVersion": getattr(auth, "system_version", None),
            "country": getattr(auth, "country", None),
            "region": getattr(auth, "region", None),
            "dateCreated": getattr(auth, "date_created", None),
            "dateActive": getattr(auth, "date_active", None),
            "hashAvailable": getattr(auth, "hash", None) is not None,
        })
    await client.disconnect()
    print_json({"ok": True, "authorizationTtlDays": getattr(result, "authorization_ttl_days", None), "sessions": rows})


async def main():
    parser = argparse.ArgumentParser(prog="mainframe-telegram-bridge")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("login")
    sub.add_parser("capabilities")
    sub.add_parser("status")
    sub.add_parser("me")

    dialogs = sub.add_parser("dialogs")
    dialogs.add_argument("--limit", type=int, default=30)
    dialogs.add_argument("--query", default="")
    dialogs.add_argument("--type", choices=["all", "chat", "user", "bot", "group", "channel"], default="all")
    dialogs.add_argument("--archived", choices=["all", "yes", "no"], default="all")
    dialogs.add_argument("--with-links", action="store_true")

    messages = sub.add_parser("messages")
    messages.add_argument("--chat", required=True)
    messages.add_argument("--limit", type=int, default=20)

    send_text = sub.add_parser("send-text")
    send_text.add_argument("--chat", required=True)
    send_text.add_argument("--text", required=True)

    mark_read = sub.add_parser("mark-read")
    mark_read.add_argument("--chat", required=True)
    mark_read.add_argument("--max-id", type=int, default=None)
    mark_read.add_argument("--clear-mentions", action="store_true")
    mark_read.add_argument("--clear-reactions", action="store_true")

    archive = sub.add_parser("archive")
    archive.add_argument("--chat", required=True)

    unarchive = sub.add_parser("unarchive")
    unarchive.add_argument("--chat", required=True)

    mute = sub.add_parser("mute")
    mute.add_argument("--chat", required=True)
    mute.add_argument("--seconds", type=int, default=31536000)

    unmute = sub.add_parser("unmute")
    unmute.add_argument("--chat", required=True)

    block = sub.add_parser("block")
    block.add_argument("--chat", required=True)
    block.add_argument("--confirm", required=True)

    unblock = sub.add_parser("unblock")
    unblock.add_argument("--chat", required=True)
    unblock.add_argument("--confirm", required=True)

    leave = sub.add_parser("leave")
    leave.add_argument("--chat", required=True)
    leave.add_argument("--confirm", required=True)

    delete_dialog = sub.add_parser("delete-dialog")
    delete_dialog.add_argument("--chat", required=True)
    delete_dialog.add_argument("--confirm", required=True)

    sub.add_parser("sessions")

    args = parser.parse_args()
    if args.command == "login":
        await cmd_login(args)
    elif args.command == "capabilities":
        await cmd_capabilities(args)
    elif args.command in {"status", "me"}:
        await cmd_status(args)
    elif args.command == "dialogs":
        await cmd_dialogs(args)
    elif args.command == "messages":
        await cmd_messages(args)
    elif args.command == "send-text":
        await cmd_send_text(args)
    elif args.command == "mark-read":
        await cmd_mark_read(args)
    elif args.command == "archive":
        await cmd_folder(args, 1)
    elif args.command == "unarchive":
        await cmd_folder(args, 0)
    elif args.command == "mute":
        await cmd_notify(args, True)
    elif args.command == "unmute":
        await cmd_notify(args, False)
    elif args.command == "block":
        await cmd_block(args, True)
    elif args.command == "unblock":
        await cmd_block(args, False)
    elif args.command == "leave":
        await cmd_leave(args)
    elif args.command == "delete-dialog":
        await cmd_delete_dialog(args)
    elif args.command == "sessions":
        await cmd_sessions(args)


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except Exception as exc:
        print_json({"ok": False, "error": str(exc)})
        sys.exit(1)
'@
}

function Write-BridgeScript {
  Get-BridgeSource | Set-Content -LiteralPath $BridgePath -Encoding UTF8
  return $BridgePath
}

function Invoke-TelegramBridge {
  param(
    [string] $Phone,
    [string[]] $BridgeArgs,
    [string] $ApiId,
    [string] $ApiHash,
    [bool] $AllowCredentialPrompt = $false
  )

  Ensure-TelethonInstalled
  if ($BridgeArgs -and $BridgeArgs.Count -gt 0 -and $BridgeArgs[0] -eq "capabilities") {
    $Python = Get-PythonExe
    $Bridge = Write-BridgeScript
    & $Python $Bridge @BridgeArgs
    return
  }

  $NormalizedPhone = Normalize-Phone $Phone
  $ProfilePath = Get-ProfilePath $NormalizedPhone
  New-Item -ItemType Directory -Force -Path $ProfilePath | Out-Null

  $Credentials = Read-ApiCredentials -Phone $NormalizedPhone -ApiId $ApiId -ApiHash $ApiHash -AllowPrompt $AllowCredentialPrompt
  $Python = Get-PythonExe
  $Bridge = Write-BridgeScript

  $env:MAINFRAME_TELEGRAM_PHONE = $NormalizedPhone
  $env:MAINFRAME_TELEGRAM_PROFILE = $ProfilePath
  $env:MAINFRAME_TELEGRAM_SESSION = Get-SessionBasePath $NormalizedPhone
  $env:MAINFRAME_TELEGRAM_API_ID = $Credentials.ApiId
  $env:MAINFRAME_TELEGRAM_API_HASH = $Credentials.ApiHash

  if (-not $BridgeArgs -or $BridgeArgs.Count -eq 0) {
    $BridgeArgs = @("status")
  }

  & $Python $Bridge @BridgeArgs
}

function Get-ProfileStatus {
  param([string] $Phone)

  $NormalizedPhone = Normalize-Phone $Phone
  $ProfilePath = Get-ProfilePath $NormalizedPhone
  $Metadata = Read-Metadata $NormalizedPhone
  $Current = Get-CurrentPhone
  $ApiIdPath = Get-ApiIdPath $NormalizedPhone
  $ApiHashPath = Get-ApiHashPath $NormalizedPhone

  [pscustomObject] @{
    phone = $NormalizedPhone
    ownerEmail = if ($Metadata) { $Metadata.ownerEmail } else { $null }
    current = ($Current -eq $NormalizedPhone)
    exists = (Test-Path $ProfilePath)
    sessionExists = (Test-Path (Get-SessionFilePath $NormalizedPhone))
    hasApiCredentials = ((Test-Path $ApiIdPath) -and (Test-Path $ApiHashPath))
    profilePath = $ProfilePath
    updatedAt = if ($Metadata) { $Metadata.updatedAt } else { $null }
  }
}

function List-Profiles {
  Ensure-Root
  Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue |
    Where-Object { Test-PhoneLike $_.Name } |
    ForEach-Object { Get-ProfileStatus $_.Name }
}

function Remove-Profile {
  param([string] $Phone)
  $NormalizedPhone = Normalize-Phone $Phone
  $ProfilePath = Get-ProfilePath $NormalizedPhone
  if (Test-Path $ProfilePath) {
    Remove-Item -LiteralPath $ProfilePath -Recurse -Force
  }
  if ((Get-CurrentPhone) -eq $NormalizedPhone -and (Test-Path $CurrentFile)) {
    Remove-Item -LiteralPath $CurrentFile -Force
  }
  Write-Host "Removed Telegram profile: $NormalizedPhone"
}

try {
  switch ($Command.ToLowerInvariant()) {
    "help" {
      Show-Help
    }

    "deps" {
      Install-Deps
    }

    "login" {
      $Parsed = Parse-ProfileArgs -Items $Remaining -RequirePhone $true
      Write-Metadata -Phone $Parsed.Phone -OwnerEmail $Parsed.OwnerEmail
      Invoke-TelegramBridge -Phone $Parsed.Phone -BridgeArgs @("login") -ApiId $Parsed.ApiId -ApiHash $Parsed.ApiHash -AllowCredentialPrompt $true
      Set-CurrentPhone $Parsed.Phone
    }

    "use" {
      $Parsed = Parse-ProfileArgs -Items $Remaining -RequirePhone $true
      $ProfilePath = Get-ProfilePath $Parsed.Phone
      if (-not (Test-Path $ProfilePath)) {
        throw "No Telegram profile exists for $($Parsed.Phone). Run login first."
      }
      Set-CurrentPhone $Parsed.Phone
      Get-ProfileStatus $Parsed.Phone
    }

    "current" {
      $Phone = Get-CurrentPhone
      if ($Phone) {
        Get-ProfileStatus $Phone
      } else {
        "No current Telegram profile."
      }
    }

    "list" {
      List-Profiles
    }

    "status" {
      $Parsed = Parse-ProfileArgs -Items $Remaining -RequirePhone $false
      if ($Parsed.Phone) {
        Get-ProfileStatus $Parsed.Phone
      } else {
        "No Telegram profile. Run login <phone> first."
      }
    }

    "status-all" {
      List-Profiles
    }

    "path" {
      $Parsed = Parse-ProfileArgs -Items $Remaining -RequirePhone $true
      Get-ProfilePath $Parsed.Phone
    }

    "env" {
      $Parsed = Parse-ProfileArgs -Items $Remaining -RequirePhone $true
      $ProfilePath = Get-ProfilePath $Parsed.Phone
      [pscustomobject] @{
        MAINFRAME_TELEGRAM_PHONE = (Normalize-Phone $Parsed.Phone)
        MAINFRAME_TELEGRAM_PROFILE = $ProfilePath
        MAINFRAME_TELEGRAM_SESSION = Get-SessionBasePath $Parsed.Phone
        MAINFRAME_TELEGRAM_BRIDGE = $BridgePath
      }
    }

    "run" {
      $Parsed = Parse-ProfileArgs -Items $Remaining -RequirePhone $false
      if (-not $Parsed.Phone) {
        throw "No current Telegram profile. Run login <phone> first."
      }

      Invoke-TelegramBridge -Phone $Parsed.Phone -BridgeArgs $Parsed.Rest -ApiId $Parsed.ApiId -ApiHash $Parsed.ApiHash -AllowCredentialPrompt $false
    }

    "logout" {
      $Parsed = Parse-ProfileArgs -Items $Remaining -RequirePhone $true
      Remove-Profile $Parsed.Phone
    }

    default {
      throw "Unknown command: $Command"
    }
  }
} catch {
  Write-Error $_.Exception.Message
  exit 1
}

