# ============================================================================
# Pre-push gate - run this BEFORE every push (the owner asked for it 2026-09-15)
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests/pre-push.ps1
#   ... -AllowNoBullet   only for changes the driver cannot see (docs/tooling),
#                        i.e. this push legitimately adds no version-history line
#   ... -Live            also compare the live Firestore copy (needs internet)
#
# What it enforces, in this order:
#   1. the day card of APP_RELEASE_DATE gained at least one bullet since the
#      accepted baseline  -> "you edited code but never wrote what the driver got"
#   2. tests/changelog-check.ps1 still reports "8 of 8" (no lost day, no long
#      bullet, no duplicate, every past day untouched)
#   3. taxi-repo/index.html is identical to index.html (i.e. the file you are
#      about to push really is the file you tested)
#
# Exit code 0 = safe to push, 1 = do NOT push yet.
# ASCII-only console output on purpose: PowerShell 5.1 mis-reads Thai literals in
# .ps1 files. Thai bullet text goes to tests/pre-push-report.txt (UTF-8) instead.
# ============================================================================
param(
  [switch]$AllowNoBullet,
  [switch]$Live,
  [string]$Index = 'index.html',
  [string]$Baseline = 'tests/changelog-baseline.json',
  [string]$Repo = 'taxi-repo'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $root) { $root = (Get-Location).Path }
function Resolve-FromRoot([string]$p) { if ([System.IO.Path]::IsPathRooted($p)) { $p } else { Join-Path $root $p } }

$script:fail = 0
$script:lines = New-Object System.Collections.ArrayList
function Say([string]$s) { Write-Host $s; [void]$script:lines.Add($s) }
function Fail([string]$s) { $script:fail++; Say ("[FAIL] " + $s) }
function Pass([string]$s) { Say ("[PASS] " + $s) }
function Skip([string]$s) { Say ("[SKIP] " + $s) }

$indexPath = Resolve-FromRoot $Index
if (-not (Test-Path $indexPath)) { Write-Host "index file not found: $indexPath" -ForegroundColor Red; exit 1 }
$raw = [System.IO.File]::ReadAllText($indexPath)
function Unescape-Js([string]$s) { return ($s -replace '\\\\"', '"' -replace "\\\\'", "'") }

# --- which day is "today" according to the code -----------------------------
$dateM = [regex]::Match($raw, "APP_RELEASE_DATE = '(\d{4}-\d{2}-\d{2})'")
if (-not $dateM.Success) { Write-Host "APP_RELEASE_DATE not found in $Index" -ForegroundColor Red; exit 1 }
$today = $dateM.Groups[1].Value

# --- today's bullets in the code --------------------------------------------
$start = $raw.IndexOf('const CHG_TABLE = [')
$end = $raw.IndexOf('const CHG_SEED_META')
if ($start -lt 0 -or $end -le $start) { Write-Host "CHG_TABLE not found in $Index" -ForegroundColor Red; exit 1 }
$seg = $raw.Substring($start, $end - $start)
$todayNotes = New-Object System.Collections.ArrayList
foreach ($m in [regex]::Matches($seg, "\['(\d{4}-\d{2}-\d{2})',\s*'(.*?)'\],?")) {
  if ($m.Groups[1].Value -eq $today) { [void]$todayNotes.Add((Unescape-Js $m.Groups[2].Value)) }
}
$todayCount = $todayNotes.Count

# --- baseline count for today -----------------------------------------------
$baseCount = -1
$basePath = Resolve-FromRoot $Baseline
if (Test-Path $basePath) {
  try {
    $base = Get-Content $basePath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($d in $base.days) { if ($d.date -eq $today) { $baseCount = [int]$d.count } }
  } catch { }
}

Say "today (APP_RELEASE_DATE) = $today"
Say "today bullets in code    = $todayCount"
Say "today bullets baseline    = $(if ($baseCount -lt 0) { 'not in baseline' } else { $baseCount })"

# --- 1) did this round add a version-history line? --------------------------
$newCount = if ($baseCount -lt 0) { $todayCount } else { $todayCount - $baseCount }
if ($newCount -le 0) {
  if ($AllowNoBullet) {
    Skip "no new bullet this round (-AllowNoBullet given - docs/tooling only)"
  } else {
    Fail "today's card did not gain any bullet -> write what the driver got in CHG_TABLE, then run this again"
    Say  "       (add one line per change: ['$today', '...'] and keep it <= 90 chars)"
    Say  "       (only for changes the driver cannot see, re-run with -AllowNoBullet)"
  }
} else {
  Pass "version history updated this round (+$newCount bullet(s) today)"
}
Say "last bullets of today (full Thai text also saved to tests/pre-push-report.txt):"
$tail = @($todayNotes | Select-Object -Last 3)
for ($i = 0; $i -lt $tail.Count; $i++) { Say ("  - " + [string]$tail[$i]) }

# --- 2) the changelog checker must stay clean -------------------------------
$checker = Resolve-FromRoot 'tests/changelog-check.ps1'
if (Test-Path $checker) {
  $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $checker, '-Index', $Index, '-Baseline', $Baseline)
  if ($Live) { $args += '-Live' }
  $out = & powershell @args 2>&1 | Out-String
  $resultLine = ([regex]::Matches($out, 'RESULT:.*') | ForEach-Object { $_.Value } | Select-Object -Last 1)
  if ($out -match 'RESULT: 8 of 8') { Pass ('changelog-check: ' + $resultLine.Trim()) }
  else { Fail ('changelog-check not clean -> ' + ([string]$resultLine).Trim()) }
} else {
  Fail "tests/changelog-check.ps1 missing"
}

# --- 3) every on/off control must be a sliding pill -------------------------
#   (the owner asked 16 Sep 2026: bare checkboxes read badly on a phone in the
#    car, so every switch in the app is .app-switch; this step stops one from
#    creeping back in. Leftovers are reported line by line.)
$switchChecker = Resolve-FromRoot 'tests/switch-check.ps1'
if (Test-Path $switchChecker) {
  $sOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $switchChecker -Index $Index 2>&1 | Out-String
  $sBad = @($sOut -split "`r?`n" | Where-Object { $_ -match '^\[FAIL\]' })
  if ($sBad.Count) {
    Fail 'switch-check not clean -> every on/off control must be an .app-switch pill'
    foreach ($l in $sBad) { Say ('        ' + $l.Trim()) }
    Say  '       (a raw <input type="checkbox"> the driver sees: turn it into a pill, or allow-list it in tests/switch-check.ps1 with a reason)'
    Say  '       (full Thai detail: tests/switch-check-report.txt)'
  } else {
    $sCount = ([regex]::Match($sOut, 'checkbox inputs\s*:\s*(\d+)')).Groups[1].Value
    $sPills = ([regex]::Match($sOut, 'app-switch pills\s*:\s*(\d+)')).Groups[1].Value
    $sAllow = ([regex]::Match($sOut, 'allowed special\s*:\s*(\d+)')).Groups[1].Value
    Pass ("switch-check: $sPills sliding pill(s), $sCount checkbox input(s) total, 0 raw ($sAllow allow-listed)")
  }
} else {
  Fail 'tests/switch-check.ps1 missing'
}

# --- 4) the repo copy must match the file you tested ------------------------
$repoCopy = Join-Path $root (Join-Path $Repo 'index.html')
if (Test-Path $repoCopy) {
  $a = (Get-FileHash $indexPath -Algorithm MD5).Hash
  $b = (Get-FileHash $repoCopy -Algorithm MD5).Hash
  if ($a -eq $b) { Pass "$Repo/index.html matches $Index (md5 $($a.Substring(0,8)))" }
  else { Fail "$Repo/index.html differs from $Index -> copy it before committing" }
  $repoReadme = Join-Path $root (Join-Path $Repo 'README.md')
  $readme = Resolve-FromRoot 'README.md'
  if ((Test-Path $repoReadme) -and (Test-Path $readme)) {
    $ra = (Get-FileHash $readme -Algorithm MD5).Hash
    $rb = (Get-FileHash $repoReadme -Algorithm MD5).Hash
    if ($ra -eq $rb) { Pass "$Repo/README.md matches README.md" } else { Skip "$Repo/README.md differs (fine if the push does not change the README)" }
  }
  try {
    Push-Location (Join-Path $root $Repo)
    $dirty = @(git status --short)
    if ($dirty.Count) { Skip ("repo has uncommitted change(s): " + (($dirty | Select-Object -First 6) -join ' | ')) }
    else { Pass "repo working tree clean (nothing staged yet)" }
  } catch { Skip "could not read git status" } finally { Pop-Location }
} else {
  Skip "no $Repo/index.html to compare"
}

# --- report (UTF-8 so Thai survives PowerShell 5.1) -------------------------
$report = Resolve-FromRoot 'tests/pre-push-report.txt'
$stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm')
$body = @("pre-push gate - $stamp", "today: $today  bullets: $todayCount  baseline: $baseCount  new: $newCount", "") + $script:lines + @("", "--- today's bullets ---") + @($todayNotes)
[System.IO.File]::WriteAllLines($report, $body, (New-Object System.Text.UTF8Encoding($false)))

Say ''
if ($script:fail) {
  Say "RESULT: $($script:fail) problem(s) - DO NOT PUSH until this is clean"
  exit 1
}
Say 'RESULT: safe to push'
exit 0
