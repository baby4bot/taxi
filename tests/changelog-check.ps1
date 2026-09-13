# ============================================================================
# Changelog pre-release check - run this BEFORE pushing index.html
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests/changelog-check.ps1
#   ... -Live                     also compare the live Firestore copy
#   ... -Index "index - 122 ....html"   check another build (e.g. a backup file)
#   ... -MaxLen 90                max characters allowed per bullet (default 90)
#   ... -UpdateBaseline           accept the current shape as the new baseline
#
# What it guards, from the failures that actually happened in this project:
#   1. a whole day card disappearing (its bullets merged into another day),
#   2. the number of bullets of a day changing silently while editing,
#   3. a bullet growing back into a long paragraph after it was shortened,
#   4. the same text appearing twice (the merge would silently drop one copy).
#
# Baseline file: tests/changelog-baseline.json (day -> bullet count). Make a new
# baseline ONLY when a day legitimately gains bullets, then say so in the commit.
#
# Exit code 0 = every check passed, 1 = at least one FAIL.
# ASCII-only output on purpose: PowerShell 5.1 mis-reads Thai literals in .ps1 files.
# ============================================================================
param(
  [string]$Index = 'index.html',
  [string]$Baseline = 'tests/changelog-baseline.json',
  [int]$MaxLen = 90,
  [switch]$Live,
  [switch]$UpdateBaseline,
  [string]$ProjectId = 'mytalkie-3955a',
  [string]$ApiKey = 'AIzaSyAhK_yT1kbFVl3A11n_QU4BgTvHrC7YkXI'
)

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$root = Split-Path -Parent $PSScriptRoot
if (-not $root) { $root = (Get-Location).Path }
function Resolve-FromRoot([string]$p) { if ([System.IO.Path]::IsPathRooted($p)) { $p } else { Join-Path $root $p } }

$script:rows = @()
$script:fail = 0
$script:details = New-Object System.Collections.ArrayList   # full (Thai) text of every problem - written to a UTF-8 report file
function Report {
  param([string]$Name, [string]$Verdict, [string]$Note)
  if ($Verdict -eq 'FAIL') { $script:fail++ }
  $script:rows += [pscustomobject]@{ Check = $Name; Verdict = $Verdict; Note = $Note }
}

function Unescape-Js([string]$s) { return ($s -replace '\\"', '"' -replace "\\'", "'") }
function VerNum([string]$v) {
  $m = [regex]::Match([string]$v, '^(\d+)\.(\d+)\.(\d+)$')
  if (-not $m.Success) { return 0 }
  return ([int]$m.Groups[1].Value * 10000) + ([int]$m.Groups[2].Value * 100) + [int]$m.Groups[3].Value
}

# --- parse index.html -------------------------------------------------------
$indexPath = Resolve-FromRoot $Index
if (-not (Test-Path $indexPath)) { Write-Host "index file not found: $indexPath" -ForegroundColor Red; exit 1 }
$raw = [System.IO.File]::ReadAllText($indexPath)

$start = $raw.IndexOf('const CHG_TABLE = [')
$end = $raw.IndexOf('const CHG_SEED_META')
if ($start -lt 0 -or $end -lt 0 -or $end -le $start) {
  Write-Host "CHG_TABLE / CHG_SEED_META not found in $Index - the changelog structure changed (see .freebuff/run.md)" -ForegroundColor Red
  exit 1
}
$seg = $raw.Substring($start, $end - $start)

$days = New-Object 'System.Collections.Specialized.OrderedDictionary'
foreach ($m in [regex]::Matches($seg, "\['(\d{4}-\d{2}-\d{2})',\s*'(.*?)'\],?")) {
  $d = $m.Groups[1].Value
  $t = Unescape-Js $m.Groups[2].Value
  if (-not $days.Contains($d)) { $days[$d] = New-Object System.Collections.ArrayList }
  [void]$days[$d].Add($t)
}

$dateM = [regex]::Match($raw, "APP_RELEASE_DATE = '(\d{4}-\d{2}-\d{2})'")
$releaseDate = if ($dateM.Success) { $dateM.Groups[1].Value } else { '' }

$meta = @{}
$metaStart = $raw.IndexOf('const CHG_SEED_META')
$metaEnd = $raw.IndexOf('};', $metaStart)
if ($metaStart -ge 0 -and $metaEnd -gt $metaStart) {
  $metaSeg = $raw.Substring($metaStart, $metaEnd - $metaStart)
  foreach ($m in [regex]::Matches($metaSeg, "'(\d{4}-\d{2}-\d{2})':\s*\{\s*v:\s*'([^']+)',\s*color:\s*(\d+)")) {
    $meta[$m.Groups[1].Value] = @{ v = $m.Groups[2].Value; color = [int]$m.Groups[3].Value }
  }
}

$dates = @($days.Keys | Sort-Object)
$totalBullets = 0
foreach ($d in $dates) { $totalBullets += $days[$d].Count }

Write-Host ""
Write-Host "Changelog pre-release check - $Index" -ForegroundColor Cyan
Write-Host "days: $($dates.Count)   bullets: $totalBullets   today: $releaseDate   max bullet: $MaxLen chars" -ForegroundColor DarkGray
foreach ($d in $dates) {
  $v = 'today'
  if ($meta.ContainsKey($d)) { $v = $meta[$d].v }
  Write-Host ("  {0}  v{1,-7} {2,3} bullets" -f $d, $v, $days[$d].Count)
}
Write-Host ""

# --- 1) table present -------------------------------------------------------
if ($dates.Count -eq 0) {
  Report 'table parses' 'FAIL' 'CHG_TABLE produced no rows'
} else {
  Report 'table parses' 'PASS' "$($dates.Count) days / $totalBullets bullets"
}

# --- 2) today card ----------------------------------------------------------
if (-not $releaseDate) {
  Report 'today card' 'FAIL' 'APP_RELEASE_DATE not found'
} elseif (-not $days.Contains($releaseDate)) {
  Report 'today card' 'FAIL' "APP_RELEASE_DATE ($releaseDate) has no bullets in CHG_TABLE"
} elseif ($dates[-1] -ne $releaseDate) {
  Report 'today card' 'FAIL' "newest day in the table is $($dates[-1]) but APP_RELEASE_DATE is $releaseDate"
} elseif ($meta.ContainsKey($releaseDate)) {
  Report 'today card' 'FAIL' "$releaseDate is also listed in CHG_SEED_META - the card would be built twice"
} else {
  Report 'today card' 'PASS' "$releaseDate = $($days[$releaseDate].Count) bullets, not duplicated in CHG_SEED_META"
}

# --- 3) no day missing inside the range -------------------------------------
$cursor = [datetime]::ParseExact($dates[0], 'yyyy-MM-dd', $null)
$lastDate = [datetime]::ParseExact($dates[-1], 'yyyy-MM-dd', $null)
$missing = @()
while ($cursor -le $lastDate) {
  $k = $cursor.ToString('yyyy-MM-dd')
  if (-not $days.Contains($k)) { $missing += $k }
  $cursor = $cursor.AddDays(1)
}
if ($missing.Count) {
  Report 'no day missing' 'FAIL' ("day(s) with no bullets: " + ($missing -join ', '))
} else {
  Report 'no day missing' 'PASS' "every day from $($dates[0]) to $($dates[-1]) exists"
}

# --- 4) seed meta covers exactly the past days ------------------------------
$pastDays = @($dates | Where-Object { $_ -ne $releaseDate })
$metaMissing = @($pastDays | Where-Object { -not $meta.ContainsKey($_) })
$metaExtra = @($meta.Keys | Where-Object { $dates -notcontains $_ })
if ($metaMissing.Count -or $metaExtra.Count) {
  $bits = @()
  if ($metaMissing.Count) { $bits += 'missing from CHG_SEED_META: ' + ($metaMissing -join ', ') }
  if ($metaExtra.Count) { $bits += 'in CHG_SEED_META but not in CHG_TABLE: ' + ($metaExtra -join ', ') }
  Report 'seed meta covers days' 'FAIL' ($bits -join ' | ')
} else {
  Report 'seed meta covers days' 'PASS' "$($meta.Count) past days carry their version number"
}

# --- 5) versions strictly increasing ----------------------------------------
$badVer = @()
$prev = ''
$prevNum = -1
foreach ($d in ($pastDays | Sort-Object)) {
  $v = $meta[$d].v
  $n = VerNum $v
  if ($prevNum -ge 0 -and $n -le $prevNum) {
    $badVer += "$d (v$v) is not newer than v$prev"
  }
  $prev = $v; $prevNum = $n
}
if ($badVer.Count) {
  Report 'versions increase' 'FAIL' ($badVer -join ' | ')
} elseif ($pastDays.Count) {
  Report 'versions increase' 'PASS' "v$($meta[$pastDays[0]].v) up to v$prev, then the current day is a new patch version"
} else {
  Report 'versions increase' 'PASS' 'only the current day exists so far'
}

# --- 6) bullet length -------------------------------------------------------
$tooLong = @()
foreach ($d in $dates) {
  $idx = 0
  foreach ($n in $days[$d]) {
    $idx++
    if ($n.Length -gt $MaxLen) {
      $tooLong += "$d #$idx ($($n.Length) chars)"
      [void]$script:details.Add("TOO LONG  $d #$idx  $($n.Length) chars  [$n]")
    }
  }
}
if ($tooLong.Count) {
  Report 'bullets stay short' 'FAIL' ("$($tooLong.Count) bullet(s) over $MaxLen chars -> " + (($tooLong | Select-Object -First 5) -join ' | '))
} else {
  $longest = 0
  foreach ($d in $dates) { foreach ($n in $days[$d]) { if ($n.Length -gt $longest) { $longest = $n.Length } } }
  Report 'bullets stay short' 'PASS' "longest bullet = $longest chars (limit $MaxLen)"
}

# --- 7) duplicate text ------------------------------------------------------
$seen = @{}
$dups = @()
foreach ($d in $dates) {
  foreach ($n in $days[$d]) {
    if ($seen.ContainsKey($n)) {
      $dups += "$($seen[$n]) + $d"
      [void]$script:details.Add("DUPLICATE  $($seen[$n]) and $d  [$n]")
    } else { $seen[$n] = $d }
  }
}
if ($dups.Count) {
  Report 'no duplicate text' 'FAIL' (($dups | Select-Object -First 5) -join ' | ')
} else {
  Report 'no duplicate text' 'PASS' "$($seen.Count) distinct bullets (nothing gets merged away on sync)"
}

# --- 8) baseline: no day lost, no count changed -----------------------------
$baselinePath = Resolve-FromRoot $Baseline
if ($UpdateBaseline) {
  $obj = [ordered]@{
    note = 'Expected shape of the in-app version history. Regenerate with -UpdateBaseline only when a day legitimately gains bullets.'
    maxLenLimit = $MaxLen
    totalBullets = $totalBullets
    days = @()
  }
  foreach ($d in $dates) {
    $v = 'today'
    if ($meta.ContainsKey($d)) { $v = $meta[$d].v }
    $obj.days += [ordered]@{ date = $d; v = $v; count = $days[$d].Count }
  }
  $json = $obj | ConvertTo-Json -Depth 6
  [System.IO.File]::WriteAllText($baselinePath, $json, (New-Object System.Text.UTF8Encoding($false)))
  Write-Host "baseline written: $baselinePath" -ForegroundColor Yellow
  exit 0
}

if (-not (Test-Path $baselinePath)) {
  Report 'baseline intact' 'FAIL' "no baseline at $Baseline - create it once with -UpdateBaseline"
} else {
  $base = Get-Content $baselinePath -Raw | ConvertFrom-Json
  $lost = @(); $changed = @(); $added = @(); $grew = @()
  foreach ($b in $base.days) {
    if (-not $days.Contains($b.date)) { $lost += $b.date }
    elseif ($days[$b.date].Count -ne $b.count) {
      # The CURRENT day (APP_RELEASE_DATE) is allowed to GAIN bullets while work
      # continues on it; losing bullets is still a failure. Past days never change.
      if ($b.date -eq $releaseDate -and $days[$b.date].Count -gt $b.count) {
        $grew += "$($b.date): $($b.count) -> $($days[$b.date].Count)"
      } else {
        $changed += "$($b.date): $($b.count) -> $($days[$b.date].Count)"
      }
    }
  }
  foreach ($d in $dates) {
    if (-not ($base.days | Where-Object { $_.date -eq $d })) { $added += "$d ($($days[$d].Count) bullets)" }
  }
  if ($lost.Count -or $changed.Count) {
    $bits = @()
    if ($lost.Count) { $bits += 'day card GONE: ' + ($lost -join ', ') }
    if ($changed.Count) { $bits += 'bullet count changed: ' + ($changed -join ', ') }
    foreach ($l in $lost) { [void]$script:details.Add("DAY GONE  $l - it existed in the baseline but has no bullets now") }
    foreach ($c in $changed) { [void]$script:details.Add("COUNT CHANGED  $c") }
    Report 'baseline intact' 'FAIL' ($bits -join ' | ')
  } else {
    $note = "$($base.days.Count) baseline days unchanged"
    if ($grew.Count) { $note += ' | today gained bullets: ' + ($grew -join ', ') + ' (refresh baseline with -UpdateBaseline when the day is done)' }
    if ($added.Count) { $note += ' | new day(s), remember to refresh the baseline: ' + ($added -join ', ') }
    Report 'baseline intact' 'PASS' $note
  }
}

# --- 9) live Firestore copy (optional) --------------------------------------
if ($Live) {
  $url = "https://firestore.googleapis.com/v1/projects/$ProjectId/databases/(default)/documents/settings/changelog?key=$ApiKey"
  # NOTE: do not name this $live - PowerShell is case-insensitive and would clash with the -Live switch.
  $liveDoc = $null
  $liveErr = ''
  $prevPref = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { $liveDoc = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 25 } catch { $liveDoc = $null; $liveErr = $_.Exception.Message }
  $ErrorActionPreference = $prevPref
  if (-not $liveDoc) {
    Report 'live copy in sync' 'SKIP' "could not read Firestore (offline / rules) - not counted as a failure | $liveErr"
  } else {
    $mismatch = @()
    $seenLive = @{}
    foreach ($en in $liveDoc.fields.entries.arrayValue.values) {
      $f = $en.mapValue.fields
      $d = $f.date.stringValue
      $seenLive[$d] = $true
      $old = @(); foreach ($x in $f.notes.arrayValue.values) { $old += $x.stringValue }
      if (-not $days.Contains($d)) { $mismatch += "$d exists in Firestore but not in CHG_TABLE"; continue }
      $new = @($days[$d])
      if ($old.Count -ne $new.Count) { $mismatch += "$d count $($old.Count) live vs $($new.Count) code"; continue }
      for ($i = 0; $i -lt $new.Count; $i++) {
        if ($old[$i] -ne $new[$i]) { $mismatch += "$d bullet $($i + 1) text differs" }
      }
    }
    foreach ($d in $dates) { if (-not $seenLive.ContainsKey($d)) { $mismatch += "$d missing from Firestore" } }
    if ($mismatch.Count) {
      Report 'live copy in sync' 'FAIL' (($mismatch | Select-Object -First 5) -join ' | ')
    } else {
      Report 'live copy in sync' 'PASS' "Firestore matches all $($dates.Count) days bullet for bullet"
    }
  }
}

# --- summary ----------------------------------------------------------------
Write-Host ""
foreach ($r in $script:rows) {
  $color = switch ($r.Verdict) { 'PASS' { 'Green' } 'FAIL' { 'Red' } default { 'DarkGray' } }
  Write-Host ("  [{0,-4}] {1,-22} {2}" -f $r.Verdict, $r.Check, $r.Note) -ForegroundColor $color
}
$passed = @($script:rows | Where-Object { $_.Verdict -eq 'PASS' }).Count
Write-Host ""
if ($script:details.Count) {
  $reportPath = Join-Path $root 'tests/changelog-check-report.txt'
  [System.IO.File]::WriteAllText($reportPath, ($script:details -join "`r`n") + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
  Write-Host "Details (full text, UTF-8): $reportPath" -ForegroundColor Yellow
}
if ($script:fail -gt 0) {
  Write-Host "RESULT: $passed of $($script:rows.Count) checks passed - $($script:fail) FAILED. Do not push until this is clean." -ForegroundColor Red
  exit 1
}
Write-Host "RESULT: $passed of $($script:rows.Count) checks passed - safe to push." -ForegroundColor Green
exit 0
