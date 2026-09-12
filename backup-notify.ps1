# backup-notify.ps1 - visible + audible banner for the daily mainframe backup.
# The backup job runs as an S4U task (session 0, no desktop), so it cannot show
# anything itself. Instead it writes a one-line state file and starts the
# MainframeBackupNotify on-demand task, which runs in the logged-on session and
# calls this script (no args -> reads the state file).
# Manual test:  .\backup-notify.ps1 -State done -Message "tag 2026-09-12-0911"
param(
    [ValidateSet('start', 'done', 'fail', 'skip')] [string]$State,
    [string]$Message,
    [string]$StateFile = 'C:\tmp\backup-notify.txt'
)
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not $State -and (Test-Path -LiteralPath $StateFile)) {
    $line = (Get-Content -LiteralPath $StateFile -Raw).Trim()
    $parts = $line -split '\|', 2
    $State = $parts[0]
    if ($parts.Count -gt 1) { $Message = $parts[1] }
}
if (-not $State) { exit 0 }

$cfg = switch ($State) {
    'start' { @{ Title = 'Mainframe backup';        Text = $(if ($Message) { $Message } else { 'running now...' }); Back = [System.Drawing.Color]::FromArgb(31, 68, 110); Fore = [System.Drawing.Color]::White; Sound = [System.Media.SystemSounds]::Asterisk;    Hold = 6000 } }
    'done'  { @{ Title = 'Mainframe backup done';   Text = $(if ($Message) { $Message } else { 'published' });      Back = [System.Drawing.Color]::FromArgb(22, 101, 52);  Fore = [System.Drawing.Color]::White; Sound = [System.Media.SystemSounds]::Exclamation; Hold = 12000 } }
    'skip'  { @{ Title = 'Mainframe backup';        Text = 'already ran today - skipped';                          Back = [System.Drawing.Color]::FromArgb(72, 72, 72);   Fore = [System.Drawing.Color]::White; Sound = $null;                              Hold = 6000 } }
    'fail'  { @{ Title = 'MAINFRAME BACKUP FAILED'; Text = $(if ($Message) { $Message } else { 'check C:\tmp\daily-backup.log' }); Back = [System.Drawing.Color]::FromArgb(150, 16, 16); Fore = [System.Drawing.Color]::White; Sound = [System.Media.SystemSounds]::Hand; Hold = 45000 } }
}

$screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$width = 440
$titleH = 32
$textH = 48
$height = $titleH + $textH

$form = New-Object System.Windows.Forms.Form
$form.FormBorderStyle = 'None'
$form.Topmost = $true
$form.ShowInTaskbar = $false
$form.StartPosition = 'Manual'
$form.Size = New-Object System.Drawing.Size($width, $height)
$form.Location = New-Object System.Drawing.Point(($screen.Right - $width - 16), ($screen.Bottom - $height - 16))
$form.BackColor = $cfg.Back
$form.Opacity = 0.97

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.AutoSize = $false
$titleLabel.Dock = 'Top'
$titleLabel.Height = $titleH
$titleLabel.Text = $cfg.Title
$titleLabel.ForeColor = [System.Drawing.Color]::White
$titleLabel.Font = New-Object System.Drawing.Font('Segoe UI', 10.5, [System.Drawing.FontStyle]::Bold)
$titleLabel.TextAlign = 'MiddleLeft'
$titleLabel.Padding = New-Object System.Windows.Forms.Padding(12, 0, 0, 0)
$form.Controls.Add($titleLabel)

$textLabel = New-Object System.Windows.Forms.Label
$textLabel.AutoSize = $false
$textLabel.Dock = 'Fill'
$textLabel.Text = $cfg.Text
$textLabel.ForeColor = $cfg.Fore
$textLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
$textLabel.TextAlign = 'MiddleLeft'
$textLabel.Padding = New-Object System.Windows.Forms.Padding(12, 0, 12, 0)
$form.Controls.Add($textLabel)

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = $cfg.Hold
$timer.Add_Tick({ $timer.Stop(); $form.Close() })
$sound = $cfg.Sound
$form.Add_Shown({ if ($sound) { $sound.Play() }; $timer.Start() })

[System.Windows.Forms.Application]::Run($form)
