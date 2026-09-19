# ============================================================================
# Record a passing offline permission suite - the second half of the gate
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests/perm-test-record.ps1 `
#       -Suite tests/speed-alert-perm-offline.html -Pass 8 -Total 8
#
#   ... -Index index.html     the build the suite was run against (default)
#   ... -Note "..."           free text kept inside the record
#   ... -AcceptCount          allow -Total to differ from the registry and update it
#
# tests/perm-test-check.ps1 refuses to pass a round that changed a per-role
# permission unless tests/perm-test-last-run.json holds a passing record for the
# registered suite of that permission, keyed by the md5 of the exact index.html
# being pushed. This script writes that record - it fails loudly instead of
# recording something misleading:
#   * the suite must be registered in tests/perm-test-map.json
#   * the suite file must exist and must mention the permission key(s) it covers
#   * the run must be full (Pass == Total), never a partial run
#   * Total should equal the registry's expect count (edit the registry for a change)
#
# Console output is ASCII-only on purpose (PowerShell 5.1 mis-reads Thai in .ps1).
# ============================================================================
param(
  [Parameter(Mandatory = $true)][string]$Suite,
  [Parameter(Mandatory = $true)][int]$Pass,
  [Parameter(Mandatory = $true)][int]$Total,
  [string]$Index = 'index.html',
  [string]$Map = 'tests/perm-test-map.json',
  [string]$LastRun = 'tests/perm-test-last-run.json',
  [string]$Note = '',
  [switch]$AcceptCount
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $root) { $root = (Get-Location).Path }
function Resolve-FromRoot([string]$p) { if ([System.IO.Path]::IsPathRooted($p)) { $p } else { Join-Path $root $p } }
function Norm-Suite([string]$s) { return (($s -replace '\\', '/')).TrimStart('./').ToLowerInvariant() }

$indexPath = Resolve-FromRoot $Index
if (-not (Test-Path $indexPath)) { Write-Host "index file not found: $indexPath" -ForegroundColor Red; exit 1 }
$suitePath = Resolve-FromRoot $Suite
if (-not (Test-Path $suitePath)) { Write-Host "suite file not found: $Suite" -ForegroundColor Red; exit 1 }
$mapPath = Resolve-FromRoot $Map
if (-not (Test-Path $mapPath)) { Write-Host "registry not found: $Map" -ForegroundColor Red; exit 1 }

if ($Pass -ne $Total) {
  Write-Host ("[FAIL] refusing to record a run that did not pass ($Pass/$Total) - fix the suite first") -ForegroundColor Red
  exit 1
}
if ($Total -le 0) {
  Write-Host '[FAIL] -Total must be at least 1' -ForegroundColor Red
  exit 1
}

# NB: never name this local $map - PowerShell variables are case-insensitive and
# $Map is the (string) parameter, so the JSON object would be cast back to text.
$mapJson = Get-Content $mapPath -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $mapJson.permissions) { Write-Host ("[FAIL] " + $Map + " has no permissions block") -ForegroundColor Red; exit 1 }

$want = Norm-Suite $Suite
$keys = New-Object System.Collections.ArrayList
$expects = New-Object System.Collections.ArrayList
$pseudoKeys = @{}
foreach ($p in $mapJson.permissions.PSObject.Properties) {
  $e = $p.Value
  if ((Norm-Suite ([string]$e.suite)) -ne $want) { continue }
  [void]$keys.Add($p.Name)
  [void]$expects.Add([int]$e.expect)
  if (($e.PSObject.Properties.Name -contains 'pseudo') -and ([bool]$e.pseudo)) { $pseudoKeys[$p.Name] = $true }
}
if ($keys.Count -eq 0) {
  Write-Host ("[FAIL] " + $Suite + " is not registered in " + $Map) -ForegroundColor Red
  Write-Host '       add an entry like:  "permissionKey": { "suite": "tests/<file>.html", "expect": <scenarios>, "label": "..." }'
  exit 1
}

$suiteText = [System.IO.File]::ReadAllText($suitePath)
foreach ($k in $keys) {
  if ($pseudoKeys.ContainsKey($k)) { continue }   # pseudo keys (roleDefaults) are not identifiers in the app
  if ($suiteText -notmatch ('\b' + [regex]::Escape($k) + '\b')) {
    Write-Host ("[FAIL] the suite never mentions '" + $k + "' - it does not test that permission") -ForegroundColor Red
    exit 1
  }
}

$bad = @($expects | Where-Object { $_ -ne $Total })
if ($bad.Count -and -not $AcceptCount) {
  Write-Host ("[FAIL] registry expects " + ($expects -join '/') + " scenario(s) for this suite but you are recording $Total") -ForegroundColor Red
  Write-Host "       if the suite really changed, re-run with -AcceptCount to update the registry"
  exit 1
}
if ($bad.Count -and $AcceptCount) {
  foreach ($p in $mapJson.permissions.PSObject.Properties) {
    if ((Norm-Suite ([string]$p.Value.suite)) -eq $want) { $p.Value.expect = $Total }
  }
  [System.IO.File]::WriteAllText($mapPath, ($mapJson | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
  Write-Host ("[INFO] registry updated: expect = $Total for " + $keys.Count + " permission(s)")
}

# ---- rebuild the record file (keep other entries) ---------------------------
$record = @{}
$lastPath = Resolve-FromRoot $LastRun
if (Test-Path $lastPath) {
  try {
    $old = Get-Content $lastPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($p in $old.PSObject.Properties) {
      $inner = @{}
      foreach ($q in $p.Value.PSObject.Properties) { $inner[$q.Name] = $q.Value }
      $record[$p.Name] = $inner
    }
  } catch { $record = @{} }
}

$indexName = Split-Path -Leaf $indexPath
# The web-version stamp line is masked before hashing (same rule as perm-test-check.ps1):
# re-stamping the build must NOT invalidate a permission suite that already passed.
$indexText = [System.IO.File]::ReadAllText($indexPath)
$maskedText = [regex]::Replace($indexText, "APP_WEB_VERSION\s*=\s*'[^']*'", "APP_WEB_VERSION = ''")
$md5Hash = [System.Security.Cryptography.MD5]::Create()
try {
  $md5 = ([System.BitConverter]::ToString($md5Hash.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($maskedText)))).Replace('-', '')
} finally { $md5Hash.Dispose() }
$suiteMd5 = (Get-FileHash $suitePath -Algorithm MD5).Hash
$entry = @{
  pass     = $Pass
  total    = $Total
  md5      = $md5
  suiteMd5 = $suiteMd5
  at       = (Get-Date).ToString('yyyy-MM-dd HH:mm')
  keys     = @($keys)
  note     = $Note
}
$buckets = @{}
if ($record.ContainsKey($indexName)) { $buckets = $record[$indexName] }
$buckets[$Suite] = $entry
$record[$indexName] = $buckets

Write-Host '--- permission suite record ---'
Write-Host ("suite     : " + $Suite)
Write-Host ("covers    : " + ($keys -join ', '))
Write-Host ("result    : $Pass/$Total (full run)")
Write-Host ("index     : $Index")
Write-Host ("md5       : $md5")
Write-Host ("suite md5 : $suiteMd5")
Write-Host ("saved to  : " + $LastRun)
Write-Host 'RESULT: recorded - tests/perm-test-check.ps1 will accept this build'
[System.IO.File]::WriteAllText($lastPath, ($record | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
exit 0
