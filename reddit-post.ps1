param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('submit', 'comment')]
    [string]$Action,

    [Parameter(Mandatory = $true, Position = 1)]
    [string]$Profile,

    [Parameter(Mandatory = $true, Position = 2)]
    [string]$Target,

    [Parameter(Mandatory = $true, Position = 3)]
    [string]$TitleOrText,

    [string]$Text,
    [string]$Url,
    [string]$FlairId,
    [string]$FlairText,
    [switch]$Nsfw,
    [switch]$Spoiler,
    [switch]$NoReplies,
    [switch]$ConfirmPost,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$accountRoot = Join-Path $env:APPDATA 'mainframe\accounts\reddit'

function Normalize-ProfileName {
    param([string]$Profile)

    if ([string]::IsNullOrWhiteSpace($Profile)) {
        throw 'Profile name is required.'
    }

    $normalized = $Profile.Trim().ToLowerInvariant()
    if ($normalized.StartsWith('u/')) {
        $normalized = $normalized.Substring(2)
    }

    if ($normalized -notmatch '^[a-z0-9][a-z0-9._%+@_-]*$') {
        throw "Invalid Reddit profile name: $Profile"
    }

    return $normalized
}

function Normalize-SubredditName {
    param([string]$Subreddit)

    if ([string]::IsNullOrWhiteSpace($Subreddit)) {
        throw 'Subreddit is required.'
    }

    $normalized = $Subreddit.Trim()
    if ($normalized.StartsWith('/r/', [StringComparison]::OrdinalIgnoreCase)) {
        $normalized = $normalized.Substring(3)
    } elseif ($normalized.StartsWith('r/', [StringComparison]::OrdinalIgnoreCase)) {
        $normalized = $normalized.Substring(2)
    }

    if ($normalized -notmatch '^[A-Za-z0-9_]{2,21}$') {
        throw "Invalid subreddit name: $Subreddit"
    }

    return $normalized
}

function Get-ProfilePath {
    param([string]$Profile)

    Join-Path $accountRoot (Normalize-ProfileName -Profile $Profile)
}

function Read-ProfileConfig {
    param([string]$Profile)

    $profilePath = Get-ProfilePath -Profile $Profile
    $configPath = Join-Path $profilePath 'profile.json'
    if (-not (Test-Path -LiteralPath $configPath)) {
        throw "Reddit profile does not exist yet: $Profile. Run .\reddit-account.ps1 login -ClientId <client_id> first."
    }

    Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
}

function Get-BasicAuthHeader {
    param(
        [string]$ClientId,
        [AllowNull()][string]$ClientSecret
    )

    $pair = '{0}:{1}' -f $ClientId, $(if ($ClientSecret) { $ClientSecret } else { '' })
    $encoded = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
    return "Basic $encoded"
}

function Save-AccessToken {
    param(
        [string]$Profile,
        [object]$Config,
        [object]$Token
    )

    $profilePath = Get-ProfilePath -Profile $Profile
    $expiresAt = if ($Token.access_token -and $Token.expires_in) { (Get-Date).AddSeconds([Math]::Max(0, [int]$Token.expires_in - 60)).ToString('o') } else { $null }
    $Config.accessToken = [string]$Token.access_token
    $Config.accessTokenExpiresAt = $expiresAt
    $Config.updatedAt = (Get-Date).ToString('o')
    $Config | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $profilePath 'profile.json') -Encoding UTF8
}

function Get-AccessToken {
    param([string]$Profile)

    $normalized = Normalize-ProfileName -Profile $Profile
    $config = Read-ProfileConfig -Profile $normalized
    if ($config.accessToken -and $config.accessTokenExpiresAt) {
        $expiresAt = [datetime]::Parse([string]$config.accessTokenExpiresAt, $null, [Globalization.DateTimeStyles]::RoundtripKind)
        if ($expiresAt -gt (Get-Date)) {
            return [pscustomobject]@{
                Config = $config
                AccessToken = [string]$config.accessToken
            }
        }
    }

    if (-not $config.refreshToken) {
        throw "Reddit profile has no refresh token: $normalized"
    }

    $headers = @{
        Authorization = Get-BasicAuthHeader -ClientId ([string]$config.clientId) -ClientSecret ([string]$config.clientSecret)
        'User-Agent' = [string]$config.userAgent
    }
    $token = Invoke-RestMethod -Method Post -Uri 'https://www.reddit.com/api/v1/access_token' -Headers $headers -Body @{
        grant_type = 'refresh_token'
        refresh_token = [string]$config.refreshToken
    } -ContentType 'application/x-www-form-urlencoded'

    Save-AccessToken -Profile $normalized -Config $config -Token $token
    $config = Read-ProfileConfig -Profile $normalized
    return [pscustomobject]@{
        Config = $config
        AccessToken = [string]$token.access_token
    }
}

function Invoke-RedditApi {
    param(
        [string]$Profile,
        [string]$Method,
        [string]$Path,
        [hashtable]$Body
    )

    $auth = Get-AccessToken -Profile $Profile
    $headers = @{
        Authorization = "Bearer $($auth.AccessToken)"
        'User-Agent' = [string]$auth.Config.userAgent
    }
    Invoke-RestMethod -Method $Method -Uri ('https://oauth.reddit.com' + $Path) -Headers $headers -Body $Body -ContentType 'application/x-www-form-urlencoded'
}

function Write-DryRun {
    param([hashtable]$Payload)

    Write-Host 'Dry run only. No Reddit request was sent.'
    $safe = [ordered]@{}
    foreach ($key in $Payload.Keys | Sort-Object) {
        $safe[$key] = $Payload[$key]
    }
    $safe | ConvertTo-Json -Depth 4
}

$normalizedProfile = Normalize-ProfileName -Profile $Profile

switch ($Action) {
    'submit' {
        $subreddit = Normalize-SubredditName -Subreddit $Target
        $kind = if (-not [string]::IsNullOrWhiteSpace($Url)) { 'link' } else { 'self' }
        if ($kind -eq 'self' -and [string]::IsNullOrWhiteSpace($Text)) {
            throw 'Self posts require -Text <body>. For link posts, pass -Url <url>.'
        }
        if ($kind -eq 'link' -and [string]::IsNullOrWhiteSpace($Url)) {
            throw 'Link posts require -Url <url>.'
        }

        $payload = @{
            api_type = 'json'
            kind = $kind
            sr = $subreddit
            title = $TitleOrText
            sendreplies = if ($NoReplies) { 'false' } else { 'true' }
        }
        if ($kind -eq 'self') {
            $payload['text'] = $Text
        } else {
            $payload['url'] = $Url
        }
        if ($Nsfw) {
            $payload['nsfw'] = 'true'
        }
        if ($Spoiler) {
            $payload['spoiler'] = 'true'
        }
        if (-not [string]::IsNullOrWhiteSpace($FlairId)) {
            $payload['flair_id'] = $FlairId
        }
        if (-not [string]::IsNullOrWhiteSpace($FlairText)) {
            $payload['flair_text'] = $FlairText
        }

        if ($DryRun -or -not $ConfirmPost) {
            Write-DryRun -Payload $payload
            if (-not $ConfirmPost) {
                Write-Host 'Pass -ConfirmPost to actually submit this post.'
            }
            return
        }

        $result = Invoke-RedditApi -Profile $normalizedProfile -Method Post -Path '/api/submit' -Body $payload
        if ($result.json.errors -and $result.json.errors.Count -gt 0) {
            $result.json.errors | ConvertTo-Json -Depth 6
            throw 'Reddit rejected the submit request.'
        }

        [pscustomobject]@{
            ok = $true
            id = $result.json.data.id
            name = $result.json.data.name
            url = $result.json.data.url
        } | Format-List
    }

    'comment' {
        $parentFullname = $Target
        if ($parentFullname -notmatch '^t[13]_[A-Za-z0-9]+$') {
            throw 'Comment target must be a Reddit fullname like t3_postid or t1_commentid.'
        }

        $payload = @{
            api_type = 'json'
            thing_id = $parentFullname
            text = $TitleOrText
        }

        if ($DryRun -or -not $ConfirmPost) {
            Write-DryRun -Payload $payload
            if (-not $ConfirmPost) {
                Write-Host 'Pass -ConfirmPost to actually submit this comment.'
            }
            return
        }

        $result = Invoke-RedditApi -Profile $normalizedProfile -Method Post -Path '/api/comment' -Body $payload
        if ($result.json.errors -and $result.json.errors.Count -gt 0) {
            $result.json.errors | ConvertTo-Json -Depth 6
            throw 'Reddit rejected the comment request.'
        }

        [pscustomobject]@{
            ok = $true
            things = $result.json.data.things.Count
        } | Format-List
    }
}
