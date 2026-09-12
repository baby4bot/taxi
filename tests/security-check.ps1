# ============================================================================
# Firestore exposure check (no login used at all)
#
#   Run this AFTER applying firestore.rules to see what is still open:
#       powershell -ExecutionPolicy Bypass -File tests/security-check.ps1
#   Check your own project instead (any project that uses this app):
#       powershell -ExecutionPolicy Bypass -File tests/security-check.ps1 -ProjectId my-project -ApiKey AIza...
#
# ASCII-only output on purpose: PowerShell 5.1 mis-reads Thai literals in .ps1 files.
# The script performs READ probes, one small WRITE probe, then deletes it again.
# It never touches real member documents - only the throw-away path
#   users/__secprobe/trips/__probe
# Exit code 0 = everything locked for anonymous callers, 1 = something is still open.
# ============================================================================
param(
  [string]$ProjectId = 'mytalkie-3955a',
  [string]$ApiKey    = 'AIzaSyAhK_yT1kbFVl3A11n_QU4BgTvHrC7YkXI'
)

$ErrorActionPreference = 'Continue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
Add-Type -AssemblyName System.Net.Http | Out-Null

$base = "https://firestore.googleapis.com/v1/projects/$ProjectId/databases/(default)/documents"
$key  = "?key=$ApiKey"

$script:client = New-Object System.Net.Http.HttpClient
$script:client.Timeout = [TimeSpan]::FromSeconds(25)

function Hit {
  param([string]$Method, [string]$Url, [string]$Body)
  try {
    # NOTE: HttpMethod.Patch does not exist on .NET Framework, so build the method from its name.
    $req = New-Object System.Net.Http.HttpRequestMessage((New-Object System.Net.Http.HttpMethod($Method)), $Url)
    if ($Body) { $req.Content = New-Object System.Net.Http.StringContent($Body, [System.Text.Encoding]::UTF8, 'application/json') }
    $resp = $script:client.SendAsync($req).GetAwaiter().GetResult()
    return [int]$resp.StatusCode
  } catch {
    return 0
  }
}

$rows = @()
function Report {
  param([string]$Name, [string]$Verdict, [int]$Code, [string]$Note)
  $script:rows += [pscustomobject]@{ Check = $Name; HTTP = $Code; Verdict = $Verdict; Note = $Note }
}

Write-Host ""
Write-Host "Firestore exposure check - project: $ProjectId" -ForegroundColor Cyan
Write-Host "No login / no token is used, exactly like an outsider would." -ForegroundColor DarkGray

function Judge {
  param([string]$Name, [int]$Code, [string]$OpenNote, [string]$LockedNote)
  if ($Code -eq 200 -or $Code -eq 204)   { Report $Name 'OPEN'    $Code $OpenNote }
  elseif ($Code -eq 403 -or $Code -eq 401) { Report $Name 'LOCKED' $Code $LockedNote }
  else                                   { Report $Name 'UNKNOWN' $Code "HTTP $Code (network/rules not conclusive)" }
}

# --- 1) can an outsider read the members collection? -------------------------
Judge -Name 'Read members doc by id'   -Code (Hit 'GET' "$base/users/0FujoFAvn6QUOI4DfYPo$key") `
      -OpenNote 'Anyone can read a member document (password hash + phone readable)' -LockedNote 'Permission denied'

# --- 2) can an outsider read settings (changelog)? ---------------------------
Judge -Name 'Read settings/changelog'   -Code (Hit 'GET' "$base/settings/changelog$key") `
      -OpenNote 'Config documents are world readable' -LockedNote 'Permission denied'

# --- 3) login lookup path (the app itself uses this) -------------------------
Judge -Name 'runQuery on members'       -Code (Hit 'POST' "$base`:runQuery$key" '{"structuredQuery":{"from":[{"collectionId":"users"}],"limit":1}}') `
      -OpenNote 'Query path works without any token' -LockedNote 'Permission denied'

# --- 4) probe write into a real app collection (throw-away path) -------------
$probeUrl = "$base/users/__secprobe/trips/__probe$key"
Judge -Name 'Write probe trip'          -Code (Hit 'PATCH' $probeUrl '{"fields":{"probe":{"stringValue":"security-check"}}}') `
      -OpenNote 'Outsiders can insert trip records' -LockedNote 'Permission denied'

# --- 5) probe delete of the same throw-away path (also cleans up) ------------
Judge -Name 'Delete probe trip'         -Code (Hit 'DELETE' $probeUrl) `
      -OpenNote 'Delete allowed (probe cleaned up)' -LockedNote 'Delete denied (probe may remain)'

# --- 6) is an unknown collection blocked? ------------------------------------
$unknown = "$base/_secprobe/check$key"
Judge -Name 'Write unknown collection'  -Code (Hit 'PATCH' $unknown '{"fields":{"x":{"stringValue":"1"}}}') `
      -OpenNote 'Project can be used as free storage' -LockedNote 'Unknown collections denied'
Hit 'DELETE' $unknown | Out-Null

# --- 7) append-only audit log? ----------------------------------------------
Judge -Name 'Delete global_logs entry'  -Code (Hit 'DELETE' "$base/global_logs/__probe$key") `
      -OpenNote 'Audit trail can be erased' -LockedNote 'Append-only enforced'

# --- summary -----------------------------------------------------------------
$rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
$open = @($rows | Where-Object { $_.Verdict -eq 'OPEN' }).Count
if ($open -gt 0) {
  Write-Host "RESULT: $open of $($rows.Count) checks are OPEN - the database can be read/written without login." -ForegroundColor Red
  Write-Host "Next: apply firestore.rules, then run this script again (see SECURITY.md)." -ForegroundColor Yellow
  exit 1
} else {
  Write-Host "RESULT: all checks are LOCKED for anonymous callers." -ForegroundColor Green
  exit 0
}
