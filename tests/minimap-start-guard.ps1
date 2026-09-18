# ============================================================================
# Mini-map start guard - run from tests/pre-push.ps1 (or by hand) before pushing
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests/minimap-start-guard.ps1
#   ... -Index index.html        another file to check
#   ... -SelfTest                also prove the guard really catches a planted leak
#                                (copies index.html, injects one violation, and
#                                 expects the guard to fail on that copy)
#
# Owner request 2026-09-18: the mini map must never start open by itself unless the
# admin ticked "open the mini map automatically at trip start" for that role
# (settings/roles -> <role>.miniMapAutoOpen, default OFF). Two regressions came
# back more than once in real use, so this gate blocks both:
#
#   A. pref.hidden = !permOk()   "has permission => show it right away"
#   B. show() (or pref.hidden = false) called directly from a start path
#      (startNavigationMap / navMiniResume) or from the late-permission path
#      (__navMiniApplyPerm) - that bypasses autoOpenAtStart(), which is the only
#      place that honours "the user pressed X, keep it closed"
#
# What it checks (all must pass):
#   1. no "pref.hidden = !..." anywhere in the file (regression A)
#   2. startNavigationMap: no direct show() / pref.hidden = false
#   3. navMiniResume: same
#   4. __navMiniApplyPerm: same (no popup mid-drive)
#   5. both start paths still default to collapsed (pref.hidden = true present)
#   6. autoOpenAtStart() still refuses to reopen after the user pressed X
#      (userClosedThisTrip guard present)
#   7. both start paths still go through canMiniMapAutoOpen()
#
# Console output is ASCII-only on purpose: PowerShell 5.1 mis-reads Thai literals
# in .ps1 files. The Thai detail (line numbers + the offending code) goes to
# tests/minimap-start-guard-report.txt (UTF-8, no BOM) instead.
#
# Exit code 0 = no leak, 1 = leak found (do NOT push).
# ============================================================================
param(
  [string]$Index = 'index.html',
  [string]$Report = 'tests/minimap-start-guard-report.txt',
  [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $root) { $root = (Get-Location).Path }
function Resolve-FromRoot([string]$p) { if ([System.IO.Path]::IsPathRooted($p)) { $p } else { Join-Path $root $p } }

$script:silent = $false
$script:lines = New-Object System.Collections.ArrayList
$script:detail = New-Object System.Collections.ArrayList
$script:fail = 0
$script:checks = 0
function Say([string]$s) { if (-not $script:silent) { Write-Host $s }; [void]$script:lines.Add($s) }
function Pass([string]$s) { $script:checks++; Say ("[PASS] " + $s) }
function Fail([string]$s) { $script:fail++; Say ("[FAIL] " + $s) }
function Detail([string]$s) { [void]$script:detail.Add($s) }

# Strip // comments before matching: the file documents the forbidden patterns in
# its own comments ("do not go back to pref.hidden = !permOk()"), which must not count.
function Code-Of([string]$line) { return [regex]::Replace($line, '(?<!:)//.*$', '') }

function Lines-With([string[]]$arr, [int]$from, [int]$to, [string]$pattern) {
  $hits = New-Object System.Collections.ArrayList
  for ($i = $from; $i -le $to -and $i -lt $arr.Count; $i++) {
    if ($i -lt 0) { continue }
    if ((Code-Of $arr[$i]) -match $pattern) { [void]$hits.Add([pscustomobject]@{ line = ($i + 1); text = $arr[$i].Trim() }) }
  }
  # ⚠️ ผู้เรียกต้องห่อด้วย @() เสมอ: ลิสต์ที่มีชิ้นเดียวจะถูก “กระจาย” ออกมาเป็นชิ้นเดียว
  #    แล้ว $x.Count ของ PSCustomObject ตัวเดียวจะคืน $null (เจอจริง: ด่านรายงานว่าไม่พบ pref.hidden = true ทั้งที่อยู่บรรทัดเดียวกัน)
  return $hits
}

# Locate "window.x = function (...) {" (or "function x() {") then walk to the matching
# closing line: "    };", "    }" - i.e. the end of that top-level block.
function Find-Block([string[]]$arr, [string]$marker) {
  $start = -1
  for ($i = 0; $i -lt $arr.Count; $i++) { if ($arr[$i].Contains($marker)) { $start = $i; break } }
  if ($start -lt 0) { return $null }
  for ($j = $start + 1; $j -lt $arr.Count; $j++) {
    if ($arr[$j] -match '^\s{4}\};?\s*$') { return @{ start = $start; end = $j } }
  }
  return @{ start = $start; end = $start }
}

function Invoke-Guard([string]$path, [switch]$Quiet) {
  $script:silent = [bool]$Quiet
  $script:lines = New-Object System.Collections.ArrayList
  $script:detail = New-Object System.Collections.ArrayList
  $script:fail = 0
  $script:checks = 0
  $raw = [System.IO.File]::ReadAllText($path)
  $arr = $raw -split "`r?`n"
  if (-not $Quiet) { Say ("minimap-start-guard - " + (Split-Path -Leaf $path)) }

  # --- 1) regression A: permission decides whether it opens -------------------
  $openByPerm = @(Lines-With $arr 0 ($arr.Count - 1) 'pref\.hidden\s*=\s*!')
  if ($openByPerm.Count) {
    Fail ("pref.hidden = !... is back (" + $openByPerm.Count + " hit(s)) - having permission must NOT mean open now")
    foreach ($h in $openByPerm) { Say ("        line " + $h.line); Detail ("  line " + $h.line + ": " + $h.text) }
    Detail '  แก้เป็น: pref.hidden = true (เริ่มจากยุบเสมอ) + canReopen = permOk() สำหรับปุ่มเปิด'
  } else {
    Pass 'no "pref.hidden = !..." regression (0 hit)'
  }

  # --- 2..4) start paths must only open through autoOpenAtStart() -------------
  # ⚠️ ต้องใช้ marker ที่ไม่ซ้ำ: ในไฟล์มี startNavigationMap 2 นิยาม (ตัวเก่าแบบ arrow
  #    `window.startNavigationMap = (startLat, ...) => {` ที่แผนที่ใหญ่ถูกปิดใช้งาน กับตัวจริง
  #    `window.startNavigationMap = function (sLat, ...) {` ในมอดูลมินิแมพ) ⇒ ต้องมีคำว่า `function (`
  #    ไม่งั้นด่านจะไปตรวจผิดตัว (เคสจริงที่เจอตอนเขียนด่านนี้)
  $paths = @(
    @{ marker = 'window.startNavigationMap = function ('; label = 'startNavigationMap'; mustCollapse = $true },
    @{ marker = 'window.navMiniResume = function';       label = 'navMiniResume';       mustCollapse = $true },
    @{ marker = 'window.__navMiniApplyPerm = function';  label = '__navMiniApplyPerm';  mustCollapse = $false }
  )
  foreach ($p in $paths) {
    $blk = Find-Block $arr $p.marker
    if (-not $blk) { Fail ($p.label + ': marker not found (' + $p.marker + ')'); continue }
    Detail ('  [' + $p.label + '] ตรวจบรรทัด ' + ($blk.start + 1) + '-' + ($blk.end + 1) + ' (จาก marker: ' + $p.marker + ')')
    $hits = New-Object System.Collections.ArrayList
    foreach ($h in @(Lines-With $arr $blk.start $blk.end '(?<![A-Za-z0-9_$.])show\s*\(')) { [void]$hits.Add($h) }
    foreach ($h in @(Lines-With $arr $blk.start $blk.end 'pref\.hidden\s*=\s*false')) { [void]$hits.Add($h) }
    if ($hits.Count) {
      Fail ($p.label + ': opens the map directly (' + $hits.Count + ' hit(s)) - must go through autoOpenAtStart()')
      foreach ($h in $hits) { Say ("        line " + $h.line); Detail ("  line " + $h.line + ": " + $h.text) }
      Detail '  แก้เป็น: if (window.canMiniMapAutoOpen && window.canMiniMapAutoOpen()) { autoOpenAtStart(); } else { hideNow(); }'
    } else {
      Pass ($p.label + ': no direct show()/pref.hidden=false')
    }
    if ($p.mustCollapse) {
      $col = @(Lines-With $arr $blk.start $blk.end 'pref\.hidden\s*=\s*true')
      if ($col.Count) { Pass ($p.label + ': still defaults to collapsed (pref.hidden = true)') }
      else {
        Fail ($p.label + ': pref.hidden = true is gone - the map would not start collapsed')
        Detail ('  ' + $p.label + ' (บรรทัด ' + ($blk.start + 1) + '-' + ($blk.end + 1) + '): ไม่พบ pref.hidden = true')
      }
    }
  }

  # --- 5) autoOpenAtStart() must keep the "user pressed X" guard --------------
  $auto = Find-Block $arr 'function autoOpenAtStart()'
  if (-not $auto) {
    Fail 'autoOpenAtStart() not found'
  } else {
    $hasGuard = $false
    for ($i = $auto.start; $i -le $auto.end; $i++) { if ((Code-Of $arr[$i]) -match 'userClosedThisTrip') { $hasGuard = $true; break } }
    if ($hasGuard) { Pass 'autoOpenAtStart(): still refuses to reopen after the user pressed X' }
    else {
      Fail 'autoOpenAtStart(): userClosedThisTrip guard is missing - it would reopen after the user closed it'
      Detail ('  autoOpenAtStart() (บรรทัด ' + ($auto.start + 1) + '-' + ($auto.end + 1) + '): ไม่พบ userClosedThisTrip')
    }
  }

  # --- 6) both start paths still ask the per-role setting ---------------------
  $gateHits = @(Lines-With $arr 0 ($arr.Count - 1) 'window\.canMiniMapAutoOpen\s*&&\s*window\.canMiniMapAutoOpen\(\)')
  if ($gateHits.Count -ge 2) {
    Pass ('both start paths still ask the per-role setting (' + $gateHits.Count + ' call site(s))')
  } else {
    Fail ('only ' + $gateHits.Count + ' call site(s) of canMiniMapAutoOpen() - expected 2 (trip start + resume)')
    foreach ($h in $gateHits) { Say ("        line " + $h.line) }
    Detail '  แก้เป็น: ทั้ง startNavigationMap และ navMiniResume ต้องเช็ค canMiniMapAutoOpen() เสมอ'
  }

  $res = @{ fail = $script:fail; checks = $script:checks; lines = $script:lines; detail = $script:detail }
  if (-not $Quiet) {
    Say ''
    if ($script:fail) { Say ("RESULT: " + $script:fail + " problem(s) - DO NOT PUSH until this is clean") }
    else { Say ("RESULT: " + $script:checks + " of " + $script:checks + " checks passed - safe to push.") }
  }
  $script:silent = $false
  return $res
}

# ============================ main ==========================================
$indexPath = Resolve-FromRoot $Index
if (-not (Test-Path $indexPath)) {
  Write-Host "[FAIL] index file not found: $indexPath"
  Write-Host 'RESULT: 1 problem(s) - DO NOT PUSH until this is clean'
  exit 1
}
$main = Invoke-Guard $indexPath

$reportPath = Resolve-FromRoot $Report
$body = New-Object System.Collections.ArrayList
[void]$body.Add("minimap-start-guard (ด่านกันมินิแมพเปิดเอง) - " + (Get-Date).ToString('yyyy-MM-dd HH:mm'))
[void]$body.Add("ไฟล์ที่ตรวจ: $Index")
[void]$body.Add('')
[void]$body.Add('=== ผลการตรวจ ===')
foreach ($l in $main.lines) { [void]$body.Add($l) }
[void]$body.Add('')
[void]$body.Add('=== จุดที่หลุด (บรรทัด + โค้ดจริง) ===')
if ($main.detail.Count) { foreach ($l in $main.detail) { [void]$body.Add($l) } }
else { [void]$body.Add('  ไม่มี — มินิแมพยัง "เริ่มจากยุบเสมอ" และเปิดเองได้เฉพาะยศที่แอดมินติ๊กไว้') }
[void]$body.Add('')
[void]$body.Add('=== กติกาที่ด่านนี้บังคับ (ห้ามผ่อน) ===')
[void]$body.Add('  1) ห้ามมี `pref.hidden = !permOk()` (มีสิทธิ์ = เปิดโชว์ทันที) — ต้องเป็น pref.hidden = true แล้วรอผู้ใช้กดปุ่ม')
[void]$body.Add('  2) เส้นทางเริ่มนำทาง (startNavigationMap / navMiniResume) ห้ามเรียก show() หรือตั้ง pref.hidden = false เอง')
[void]$body.Add('     ยกเว้นผ่าน autoOpenAtStart() เท่านั้น (ตัวนั้นกันกรณีผู้ใช้กด ✕ เองไว้ในตัว)')
[void]$body.Add('  3) __navMiniApplyPerm (สิทธิ์มาช้า) ห้ามเปิดแผนที่เอง — ให้ขึ้น "ปุ่มเปิด" เท่านั้น')
[void]$body.Add('  4) autoOpenAtStart() ต้องมีการกัน userClosedThisTrip เสมอ')
[void]$body.Add('  5) ทั้งสองเส้นทางเริ่มแผนที่ต้องเช็ค canMiniMapAutoOpen() (ค่าต่อยศ · ค่าเริ่มต้น = ปิด)')
[void]$body.Add('')
[void]$body.Add('รันเอง: powershell -NoProfile -ExecutionPolicy Bypass -File tests/minimap-start-guard.ps1 -SelfTest')
[System.IO.File]::WriteAllLines($reportPath, $body, (New-Object System.Text.UTF8Encoding($false)))

# ============================ self-test =====================================
# A gate nobody ever sees fail is a gate nobody can trust: plant one violation at a
# time into a copy of the file and require the guard to catch every one of them.
$selfFail = 0
if ($SelfTest) {
  $rawOrig = [System.IO.File]::ReadAllText($indexPath)
  $tmpDir = Join-Path $root '.freebuff/_guard-selftest'
  if (Test-Path $tmpDir) { Remove-Item $tmpDir -Recurse -Force }
  [void](New-Item -ItemType Directory -Path $tmpDir -Force)
  $cases = @(
    @{ name = 'A: pref.hidden = !permOk()';         old = 'pref.hidden = true;';   new = 'pref.hidden = !permOk();' },
    @{ name = 'B: direct show() at trip start';     old = 'window.__navArmed = true;'; new = "window.__navArmed = true;`r`n            show();" },
    @{ name = 'C: opener forced open at start';     old = 'pref.hidden = true;';   new = 'pref.hidden = false;' },
    @{ name = 'D: show() on late permission';       old = 'if (!pref.hidden) { pref.hidden = true; savePref(); }'; new = "if (!pref.hidden) { pref.hidden = true; savePref(); }`r`n                show();" }
  )
  Write-Host ''
  Write-Host 'self-test (plant one leak at a time, the guard must catch each):'
  foreach ($c in $cases) {
    $planted = $rawOrig.Replace($c.old, $c.new)
    if ($planted -eq $rawOrig) {
      $selfFail++
      Write-Host ("[FAIL] self-test could not plant case " + $c.name + " (anchor text changed)")
      continue
    }
    $copy = Join-Path $tmpDir 'index-broken.html'
    [System.IO.File]::WriteAllText($copy, $planted, (New-Object System.Text.UTF8Encoding($false)))
    $r = Invoke-Guard $copy -Quiet
    if ($r.fail -gt 0) { Write-Host ("[PASS] self-test caught " + $c.name + " (" + $r.fail + " check(s) failed)") }
    else { $selfFail++; Write-Host ("[FAIL] self-test MISSED " + $c.name + " - the guard would let it through") }
  }
  $rOk = Invoke-Guard $indexPath -Quiet
  if ($rOk.fail -eq 0) { Write-Host '[PASS] self-test: the real file passes (no false alarm)' }
  else { $selfFail++; Write-Host '[FAIL] self-test: the guard reports the real file as broken (false alarm)' }
  Remove-Item $tmpDir -Recurse -Force
  Write-Host ''
  if ($selfFail) { Write-Host ("RESULT: self-test failed (" + $selfFail + " case(s))") }
  else { Write-Host 'RESULT: self-test passed (guard catches every planted leak)' }
}

Write-Host ''
Write-Host ("report (Thai, with line numbers): " + (Split-Path -Leaf $reportPath))
if ($main.fail -or $selfFail) { exit 1 }
exit 0
