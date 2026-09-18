# ============================================================================
# App Check: list apps + register the reCAPTCHA provider from the command line
#
#   Why: the Firebase Console page for App Check can be unusable in some
#   browsers (e.g. while the page is being auto-translated the inputs stop
#   responding). The same registration can be done through the App Check
#   Admin API, which never needs a click.
#
#   You need a short-lived access token from your own Google account:
#     1. https://developers.google.com/oauthplayground
#     2. "Input your own scopes": https://www.googleapis.com/auth/cloud-platform
#     3. Authorize APIs -> pick the project owner account -> Allow
#     4. Exchange authorization code for tokens -> copy "Access token"
#   The token expires after ~1 hour and is not stored anywhere by this script.
#
#   List the apps only (safe, no changes):
#       powershell -ExecutionPolicy Bypass -File tests/appcheck-register.ps1 -AccessToken ya29... -ListOnly
#   Register every web app in the project:
#       powershell -ExecutionPolicy Bypass -File tests/appcheck-register.ps1 -AccessToken ya29... -SiteSecret 6Let...
#   Register only some apps (match by display name or app id):
#       ... -SiteSecret 6Let... -Match Taxi-App,MyTalkie
#
# ASCII-only output on purpose: PowerShell 5.1 mis-reads Thai literals in .ps1 files.
# The site secret is passed in as a parameter and is never written to disk or echoed.
# Exit code 0 = every targeted app has a secret set, 1 = something still missing.
# ============================================================================
param(
  [Parameter(Mandatory = $true)][string]$AccessToken,
  [string]$SiteSecret = '',
  [string]$ProjectId = 'mytalkie-3955a',
  [string]$ProjectNumber = '97426563170',
  [string[]]$Match = @(),
  [switch]$ListOnly
)

$ErrorActionPreference = 'Continue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
Add-Type -AssemblyName System.Net.Http | Out-Null

$api  = 'https://firebaseappcheck.googleapis.com/v1'
$mgmt = 'https://firebase.googleapis.com/v1beta1'

$client = New-Object System.Net.Http.HttpClient
$client.Timeout = [TimeSpan]::FromSeconds(30)
$client.DefaultRequestHeaders.Authorization =
  New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', $AccessToken)

function Call {
  param([string]$Method, [string]$Url, [string]$Body)
  try {
    # NOTE: HttpMethod.Patch does not exist on .NET Framework, so build from name.
    $req = New-Object System.Net.Http.HttpRequestMessage((New-Object System.Net.Http.HttpMethod($Method)), $Url)
    if ($Body) {
      $req.Content = New-Object System.Net.Http.StringContent($Body, [System.Text.Encoding]::UTF8, 'application/json')
    }
    $resp = $client.SendAsync($req).GetAwaiter().GetResult()
    $text = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    return [pscustomobject]@{ Code = [int]$resp.StatusCode; Text = $text }
  } catch {
    return [pscustomobject]@{ Code = 0; Text = "$($_.Exception.Message)" }
  }
}

Write-Host ''
Write-Host "App Check provider guide - project: $ProjectId ($ProjectNumber)" -ForegroundColor Cyan

# --- 1) list the web apps (Firebase Management API; App Check has no list) ----
$list = Call 'GET' "$mgmt/projects/$ProjectId/webApps"
if ($list.Code -ne 200) {
  Write-Host "Cannot list web apps (HTTP $($list.Code))." -ForegroundColor Red
  Write-Host (($list.Text -split "`n" | Select-Object -First 6) -join "`n") -ForegroundColor DarkGray
  Write-Host 'A 401/403 usually means the token expired - get a fresh one.' -ForegroundColor Yellow
  exit 1
}
$apps = @((ConvertFrom-Json $list.Text).apps)

Write-Host ''
$apps | Select-Object displayName, appId |
  Format-Table -AutoSize | Out-String -Width 200 | Write-Host

if ($ListOnly) {
  Write-Host 'List only - nothing was changed.' -ForegroundColor Green
  exit 0
}
if (-not $SiteSecret) {
  Write-Host 'Missing -SiteSecret (or use -ListOnly).' -ForegroundColor Red
  exit 1
}

# --- 2) pick the targets -----------------------------------------------------
$targets = @($apps | Where-Object {
  $app = $_
  if ($Match.Count -eq 0) { return $true }
  foreach ($m in $Match) {
    if ($app.appId -like "*$m*" -or $app.displayName -like "*$m*") { return $true }
  }
  return $false
})
if ($targets.Count -eq 0) {
  Write-Host 'No app matched the filter.' -ForegroundColor Red
  exit 1
}

# --- 3) register each target -------------------------------------------------
$rows = @()
foreach ($app in $targets) {
  $cfgName = "projects/$ProjectNumber/apps/$($app.appId)"
  $v3Url   = "$api/$cfgName/recaptchaV3Config"
  $oldUrl  = "$api/$cfgName/recaptchaConfig"
  $body    = '{"siteSecret":"' + $SiteSecret + '"}'

  $patch = Call 'PATCH' "$v3Url`?updateMask=siteSecret" $body
  $kind  = 'reCAPTCHA v3'
  if ($patch.Code -ne 200) {
    # Older projects expose the same provider as the legacy recaptchaConfig.
    $patch = Call 'PATCH' "$oldUrl`?updateMask=siteSecret" $body
    $kind  = 'reCAPTCHA (legacy)'
  }

  # --- 4) read back whether the secret is stored (the secret itself is never returned)
  $set = $false
  $verify = Call 'GET' $v3Url
  if ($verify.Code -eq 200) {
    $set = [bool](ConvertFrom-Json $verify.Text).siteSecretSet
  } else {
    $verify = Call 'GET' $oldUrl
    if ($verify.Code -eq 200) { $set = [bool](ConvertFrom-Json $verify.Text).siteSecretSet }
  }

  $rows += [pscustomobject]@{
    App          = $app.displayName
    Provider     = $kind
    HTTP         = $patch.Code
    SecretStored = $set
    Verdict      = if ($set) { 'READY' } else { 'NOT SET' }
  }
}

Write-Host ''
$rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Host

$missing = @($rows | Where-Object { -not $_.SecretStored }).Count
if ($missing -gt 0) {
  Write-Host "RESULT: $missing of $($rows.Count) apps still have no secret stored." -ForegroundColor Red
  Write-Host 'HTTP column: 401/403 = expired token, 400 = the secret key was rejected.' -ForegroundColor Yellow
  exit 1
} else {
  Write-Host "RESULT: all $($rows.Count) apps are registered with the reCAPTCHA provider." -ForegroundColor Green
  Write-Host 'Next: put the site key into index.html (APP_CHECK_SITE_KEY), then run appCheckSelfTest().' -ForegroundColor DarkGray
  exit 0
}
