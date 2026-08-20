param(
  [Parameter(Position = 0)]
  [string] $Command = "help",

  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]] $Remaining
)

$ErrorActionPreference = "Stop"

$Root = Join-Path $env:APPDATA "mainframe\accounts\whatsapp"
$CurrentFile = Join-Path $Root "current.txt"
$LegacyWacliStore = Join-Path $env:USERPROFILE ".wacli"

# --- helpers ---

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
    throw "Phone is required. WhatsApp profiles are keyed by phone number."
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

function Get-ProfilePath {
  param([string] $Phone)
  return Join-Path $Root (Normalize-Phone $Phone)
}

function Get-MetadataPath {
  param([string] $Phone)
  return Join-Path (Get-ProfilePath $Phone) "mainframe-whatsapp.json"
}

function Get-StorePath {
  param([string] $Phone)
  return Join-Path (Get-ProfilePath $Phone) "store"
}

function Get-CurrentPhone {
  if (Test-Path $CurrentFile) {
    $Value = (Get-Content $CurrentFile -Raw).Trim()
    if ($Value) {
      try { return (Normalize-Phone $Value) } catch { return $null }
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
  if (-not (Test-Path $Path)) { return $null }
  try { return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json } catch { return $null }
}

function Write-WacliMetadata {
  param([string] $Phone, [string] $OwnerEmail, [string] $StorePath)
  $ProfilePath = Get-ProfilePath $Phone
  $ProfileStore = Get-StorePath $Phone
  New-Item -ItemType Directory -Force -Path $ProfileStore | Out-Null
  $Metadata = [ordered] @{
    phone      = Normalize-Phone $Phone
    kind       = "wacli"
    ownerEmail = Normalize-OwnerEmail $OwnerEmail
    storePath  = if ($StorePath) { $StorePath } else { $ProfileStore }
    binary     = "wacli"
    updatedAt  = (Get-Date).ToUniversalTime().ToString("o")
  }
  $Metadata | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Get-MetadataPath $Phone) -Encoding UTF8
}

function Resolve-WacliStore {
  param([string] $Phone)
  $ProfileStore = Get-StorePath $Phone
  if (Test-Path $ProfileStore) {
    $sessionDb = Join-Path $ProfileStore "session.db"
    if (Test-Path $sessionDb) { return $ProfileStore }
  }
  $Meta = Read-Metadata $Phone
  if ($Meta -and $Meta.storePath) {
    if (Test-Path $Meta.storePath) { return $Meta.storePath }
  }
  if (Test-Path $LegacyWacliStore) {
    $sessionDb = Join-Path $LegacyWacliStore "session.db"
    if (Test-Path $sessionDb) {
      Write-Host "Migrating legacy wacli store to profile..."
      New-Item -ItemType Directory -Force -Path $ProfileStore | Out-Null
      Copy-Item -Path (Join-Path $LegacyWacliStore "*") -Destination $ProfileStore -Force -ErrorAction SilentlyContinue
      Write-WacliMetadata -Phone $Phone -OwnerEmail $(if ($Meta) { $Meta.ownerEmail } else { $null }) -StorePath $ProfileStore
      return $ProfileStore
    }
  }
  return $ProfileStore
}

function Get-ProfileStatus {
  param([string] $Phone)
  $NormalizedPhone = Normalize-Phone $Phone
  $ProfilePath = Get-ProfilePath $NormalizedPhone
  $Metadata = Read-Metadata $NormalizedPhone
  $Current = Get-CurrentPhone
  [pscustomObject] @{
    phone      = $NormalizedPhone
    ownerEmail = if ($Metadata) { $Metadata.ownerEmail } else { $null }
    current    = ($Current -eq $NormalizedPhone)
    exists     = (Test-Path $ProfilePath)
    profilePath = $ProfilePath
    kind       = if ($Metadata) { $Metadata.kind } else { $null }
    storePath  = if ($Metadata) { $Metadata.storePath } else { $null }
    updatedAt  = if ($Metadata) { $Metadata.updatedAt } else { $null }
  }
}

function List-Profiles {
  Ensure-Root
  Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue |
    Where-Object { Test-PhoneLike $_.Name } |
    ForEach-Object { Get-ProfileStatus $_.Name }
}

# --- preserved legacy code (wa-js, baileys) ---
# The functions below are kept for reference but are not exposed in the switch.
# Remove this section once wa-js / baileys are fully retired.

<#
$BridgeScript = Join-Path (Split-Path -Parent $PSScriptRoot) "automata\whatsapp.com\wa-js-bridge.mjs"
$BaileysBridgeScript = Join-Path (Split-Path -Parent $PSScriptRoot) "automata\whatsapp.com\baileys-bridge.mjs"

function Write-Metadata { param($Phone,$Port,$OwnerEmail) ... }
function Write-BaileysMetadata { param($Phone,$OwnerEmail) ... }
function Start-WhatsAppBrowser { param($Phone,$Port,$BrowserPath,$OwnerEmail,$Minimized) ... }
function Resolve-BrowserPath { param($BrowserPath) ... }
function Invoke-Bridge { param($Phone,$Port,$BridgeArgs) ... }
function Invoke-BaileysBridge { param($Phone,$BridgeArgs) ... }
#>

# --- main ---

function Show-Help {
  @"
mainframe WhatsApp account helper (wacli)

Usage:
  whatsapp-account.ps1 login <phone> [--owner-email email] [--store path]
  whatsapp-account.ps1 use <phone>
  whatsapp-account.ps1 current
  whatsapp-account.ps1 list
  whatsapp-account.ps1 status [phone]
  whatsapp-account.ps1 status-all
  whatsapp-account.ps1 path [phone]
  whatsapp-account.ps1 env [phone]
  whatsapp-account.ps1 run [phone] [wacli args...]

Examples:
  whatsapp-account.ps1 login +8801XXXXXXXXX
  whatsapp-account.ps1 status
  whatsapp-account.ps1 run send text --to +8801XXXXXXXXX --message "hello"
  whatsapp-account.ps1 run messages search "hello" --chat +8801XXXXXXXXX

WhatsApp profiles are keyed by phone number. Each profile stores its
wacli auth and message DB inside the profile directory. Legacy ~/.wacli
data is auto-migrated on first use.
"@
}

function Parse-PhoneArgs {
  param([string[]] $Items, [bool] $RequirePhone = $false)
  $Phone = $null
  $OwnerEmail = $null
  $StorePath = $null
  $Rest = New-Object System.Collections.Generic.List[string]

  for ($i = 0; $i -lt $Items.Count; $i++) {
    $Token = $Items[$i]
    if ($Token -eq "--owner-email") { $i++; if ($i -ge $Items.Count) { throw "--owner-email requires a value" }; $OwnerEmail = Normalize-OwnerEmail $Items[$i] }
    elseif ($Token -like "--owner-email=*") { $OwnerEmail = Normalize-OwnerEmail $Token.Substring("--owner-email=".Length) }
    elseif ($Token -eq "--store") { $i++; if ($i -ge $Items.Count) { throw "--store requires a value" }; $StorePath = $Items[$i] }
    elseif ($Token -like "--store=*") { $StorePath = $Token.Substring("--store=".Length) }
    elseif (-not $Phone -and (Test-PhoneLike $Token)) { $Phone = Normalize-Phone $Token }
    else { $Rest.Add($Token) }
  }

  if (-not $Phone) { $Phone = Get-CurrentPhone }
  if ($RequirePhone -and -not $Phone) { throw "Phone is required." }

  return [pscustomobject]@{ Phone = $Phone; OwnerEmail = $OwnerEmail; StorePath = $StorePath; Rest = [string[]]$Rest.ToArray() }
}

try {
  switch ($Command.ToLowerInvariant()) {
    "help" { Show-Help }

    "login" {
      $P = Parse-PhoneArgs -Items $Remaining -RequirePhone $true
      $store = if ($P.StorePath) { $P.StorePath } else { Get-StorePath $P.Phone }
      New-Item -ItemType Directory -Force -Path $store | Out-Null
      Write-WacliMetadata -Phone $P.Phone -OwnerEmail $P.OwnerEmail -StorePath $store
      Set-CurrentPhone $P.Phone
      Write-Host "Opening wacli auth for $(Normalize-Phone $P.Phone) in a new window. Scan the QR code with your phone."
      Start-Process -WindowStyle Normal -FilePath "pwsh" -ArgumentList "-NoExit", "-Command", "wacli auth --store `"$store`""
    }

    "use" {
      $P = Parse-PhoneArgs -Items $Remaining -RequirePhone $true
      $pp = Get-ProfilePath $P.Phone
      if (-not (Test-Path $pp)) { throw "No WhatsApp profile for $($P.Phone). Run login first." }
      Set-CurrentPhone $P.Phone
      Get-ProfileStatus $P.Phone
    }

    "current" {
      $p = Get-CurrentPhone
      if ($p) { Get-ProfileStatus $p } else { "No current WhatsApp profile." }
    }

    "list" { List-Profiles }

    "status" {
      $P = Parse-PhoneArgs -Items $Remaining -RequirePhone $false
      if ($P.Phone) { Get-ProfileStatus $P.Phone } else { "No WhatsApp profile." }
    }

    "status-all" { List-Profiles }

    "path" {
      $P = Parse-PhoneArgs -Items $Remaining -RequirePhone $true
      Get-ProfilePath $P.Phone
    }

    "env" {
      $P = Parse-PhoneArgs -Items $Remaining -RequirePhone $true
      $store = Resolve-WacliStore $P.Phone
      $Meta = Read-Metadata $P.Phone
      [pscustomObject]@{
        MAINFRAME_WHATSAPP_PHONE = (Normalize-Phone $P.Phone)
        MAINFRAME_WHATSAPP_OWNER_EMAIL = if ($Meta -and $Meta.ownerEmail) { $Meta.ownerEmail } else { if ($P.OwnerEmail) { $P.OwnerEmail } else { $null } }
        MAINFRAME_WHATSAPP_STORE = $store
        MAINFRAME_WHATSAPP_BINARY = "wacli"
      }
    }

    "run" {
      $P = Parse-PhoneArgs -Items $Remaining -RequirePhone $false
      if (-not $P.Phone) { throw "No current WhatsApp profile." }
      $store = Resolve-WacliStore $P.Phone
      $env:MAINFRAME_WHATSAPP_PHONE = (Normalize-Phone $P.Phone)
      $env:MAINFRAME_WHATSAPP_STORE = $store
      $allArgs = @("--store", $store) + $P.Rest
      & wacli $allArgs
    }

    default { throw "Unknown command: $Command. Run 'help' for usage." }
  }
} catch {
  Write-Error $_.Exception.Message
  exit 1
}
