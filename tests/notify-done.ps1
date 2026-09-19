# ============================================================================
# notify-done.ps1 - pop a Windows notification when a work round is finished
#
#   Why: the owner asked "when the work is done, also send me a notification"
#   so he does not have to keep staring at the screen while a round runs
#   (test suites + pre-push gates can take 10+ minutes).
#
#   Usage (from the project root):
#     powershell -NoProfile -ExecutionPolicy Bypass -File tests/notify-done.ps1 -Kind done
#     ... -Kind ask                     (still waiting for an answer / next order)
#     ... -Kind push                    (web build pushed and verified)
#     ... -Kind fail -Message "ascii only text"
#     ... -Kind done -MessageFile .freebuff/notify-message.txt
#
#   Body text, in order of preference:
#     1) -Message  (ASCII only - see the warning below)
#     2) -MessageFile (UTF-8 file, default .freebuff/notify-message.txt)
#     3) the default line from the config file
#
#   !! ASCII-ONLY SCRIPT ON PURPOSE !!
#   This machine's console code page is 437, so Thai text cannot travel through
#   command-line arguments, and PowerShell 5.1 reads a BOM-less .ps1 as ANSI.
#   All Thai text therefore lives in UTF-8 data files (tests/notify-done.json,
#   the -MessageFile) and is read with [System.Text.Encoding]::UTF8.
#
#   Exit code: 0 = Windows toast shown, 1 = only the fallback balloon/sound.
# ============================================================================
param(
  [ValidateSet('done', 'fail', 'ask', 'push')][string]$Kind = 'done',
  [string]$Message = '',
  [string]$MessageFile = '',
  [string]$ConfigFile = ''
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
if (-not $root) { $root = (Get-Location).Path }
function Resolve-FromRoot([string]$p) { if ([System.IO.Path]::IsPathRooted($p)) { $p } else { Join-Path $root $p } }
function Read-Utf8Text([string]$p) {
  try { if (Test-Path $p) { return ([System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)) } } catch {}
  return ''
}

$cfgPath = if ($ConfigFile) { Resolve-FromRoot $ConfigFile } else { Join-Path $PSScriptRoot 'notify-done.json' }
$title = 'Taxi app - work finished'
$duration = 'short'
$tail = ''
$cfgRaw = Read-Utf8Text $cfgPath
if ($cfgRaw) {
  try {
    $cfg = $cfgRaw | ConvertFrom-Json
    $node = $null
    try { $node = $cfg.kinds.PSObject.Properties[$Kind].Value } catch {}
    if ($node) {
      if ($node.title) { $title = [string]$node.title }
      if ($node.duration) { $duration = [string]$node.duration }
      if ($node.tail) { $tail = [string]$node.tail }
    }
  } catch {}
}

$body = ''
if ($Message) { $body = [string]$Message }
if (-not $body) {
  $msgPath = if ($MessageFile) { Resolve-FromRoot $MessageFile } else { Join-Path $root '.freebuff/notify-message.txt' }
  $body = Read-Utf8Text $msgPath
}
if (-not $body) { $body = 'Work round finished - see the chat for the status line.' }
$body = $body.Trim()
if ($tail) { $body = $body + "`r`n" + $tail.Trim() }
$body = $body + "`r`n(" + (Get-Date -Format 'HH:mm') + ")"

$safeTitle = [System.Security.SecurityElement]::Escape($title)
$safeBody = [System.Security.SecurityElement]::Escape($body)
$scenario = ''
if ($Kind -eq 'ask' -or $Kind -eq 'fail') { $scenario = ' scenario="reminder"' }
$sound = 'Notification.Default'
if ($Kind -eq 'fail') { $sound = 'Notification.Alarm' }
if ($Kind -eq 'ask') { $sound = 'Notification.Reminder' }
$toastXml = '<toast duration="' + $duration + '"' + $scenario + '><visual><binding template="ToastGeneric"><text>' +
            $safeTitle + '</text><text>' + $safeBody + '</text></binding></visual>' +
            '<audio src="ms-winsoundevent:' + $sound + '" loop="false"/></toast>'

$shown = $false
$via = 'none'
try {
  [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
  [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
  $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
  $doc.LoadXml($toastXml)
  $toast = New-Object Windows.UI.Notifications.ToastNotification $doc
  $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
  [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
  $shown = $true
  $via = 'toast'
} catch {
  $via = 'toast-failed: ' + $_.Exception.Message
}

if (-not $shown) {
  # Fallback for machines where the WinRT toast path is blocked: tray balloon + sound.
  try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $ni = New-Object System.Windows.Forms.NotifyIcon
    $ni.Icon = [System.Drawing.SystemIcons]::Information
    $ni.Visible = $true
    $ni.BalloonTipTitle = $title
    $ni.BalloonTipText = $body
    $ni.ShowBalloonTip(12000)
    Start-Sleep -Milliseconds 900
    $ni.Visible = $false
    $ni.Dispose()
    $shown = $true
    $via = 'balloon'
  } catch {
    $via = 'balloon-failed: ' + $_.Exception.Message
  }
  try {
    if ($Kind -eq 'fail') { [System.Media.SystemSounds]::Hand.Play() } else { [System.Media.SystemSounds]::Asterisk.Play() }
  } catch {}
}

# UTF-8 log so the owner (and the next agent) can check what was sent, in Thai.
try {
  $logDir = Join-Path $root '.freebuff'
  if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
  $logPath = Join-Path $logDir 'notify-done-log.txt'
  $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' | ' + $Kind + ' | ' + $title + ' | ' + ($body -replace "`r?`n", ' / ') + ' | ' + $via
  [System.IO.File]::AppendAllText($logPath, $line + "`r`n", [System.Text.Encoding]::UTF8)
} catch {}

Write-Host ('notify-done: kind=' + $Kind + ' via=' + $via + ' chars=' + $body.Length)
if ($shown) { exit 0 } else { exit 1 }
