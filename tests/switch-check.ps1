# ============================================================================
# Switch check - run this BEFORE pushing index.html (also called by pre-push.ps1)
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests/switch-check.ps1
#   ... -Index "index - 200 ....html"    check another build (e.g. a backup file)
#
# The owner asked (16 Sep 2026) for every on/off control in the app to be a
# sliding pill (.app-switch), not a bare checkbox - "it reads the state better".
# This gate stops a raw checkbox from creeping back in, and reports exactly
# where the leftovers are so the next round can fix them.
#
# What counts as OK:
#   1. the checkbox is the hidden input of a pill:
#         <input type="checkbox" ...><span class="app-slider"></span>
#      (the slider has to be the very next thing after the input tag)
#   2. it is explicitly allow-listed below, with a written reason
#   3. its wrapping <label>/<span> carries an allow-listed class (selection list)
#
# Exit code 0 = clean, 1 = at least one raw checkbox (or a pill with no slider).
# ASCII-only console output on purpose: PowerShell 5.1 mis-reads Thai literals in
# .ps1 files. The Thai details go to tests/switch-check-report.txt (UTF-8).
# ============================================================================
param(
  [string]$Index = 'index.html'
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
if (-not $root) { $root = (Get-Location).Path }
function Resolve-FromRoot([string]$p) { if ([System.IO.Path]::IsPathRooted($p)) { $p } else { Join-Path $root $p } }

# --- allow-list (edit ONLY on purpose, each entry needs a reason) -----------
# Hidden helpers: the state holder of a custom 3-way control, never shown as a box.
$allowedIds = @{
  'editOledToggle' = 'ตัวช่วยเก็บสถานะที่ซ่อนอยู่ (display:none) - ผู้ใช้เห็นเป็นตัวเลือกธีม 3 ปุ่มแทน'
}
# Multi-select lists (a tick that means "include this row", not "switch on/off").
$allowedWrapClasses = @{
  'txt-bulk-item' = 'ช่องติ๊ก "เลือกรายการ" ในลิสต์แก้ข้อความทั้งชุด (ติ๊กได้หลายอัน ไม่ใช่เปิด/ปิด)'
}

# --- read the file ----------------------------------------------------------
$path = Resolve-FromRoot $Index
if (-not (Test-Path $path)) { Write-Host "index file not found: $path" -ForegroundColor Red; exit 1 }
$raw = [System.IO.File]::ReadAllText($path)

function LineOf([int]$pos) { return ([regex]::Matches($raw.Substring(0, $pos), "`n").Count + 1) }
function Preview([string]$s, [int]$n) {
  $flat = ($s -replace "\r", ' ' -replace "\n", ' ')
  if ($flat.Length -gt $n) { return $flat.Substring(0, $n) + '...' }
  return $flat
}

$rxInput = [regex]'<input[^>]*type="checkbox"[^>]*>'
$rxSlider = [regex]'^<span class="app-slider">'

$switches = 0
$showcased = @()    # allow-listed findings (allowed, but written down)
$offenders = @()    # FAIL
$noId = @()

foreach ($m in $rxInput.Matches($raw)) {
  $tag = $m.Value
  $line = LineOf $m.Index
  $tail = $raw.Substring($m.Index + $m.Length, [Math]::Min(60, $raw.Length - ($m.Index + $m.Length)))
  $idM = [regex]::Match($tag, 'id="([^"]+)"')
  $id = if ($idM.Success) { $idM.Groups[1].Value } else { '' }

  # 1) the pill pattern: the slider must come straight after the input tag
  if ($rxSlider.IsMatch($tail)) { $switches++; continue }

  # 2) allow-listed hidden helper (by id)
  if ($id -and $allowedIds.ContainsKey($id)) {
    $showcased += "ALLOWED  line $line  id=$id  $($allowedIds[$id])`r`n         $(Preview $tag 120)"
    continue
  }

  # 3) allow-listed wrapping container (selection lists)
  $beforeStart = [Math]::Max(0, $m.Index - 500)
  $before = $raw.Substring($beforeStart, $m.Index - $beforeStart)
  $wraps = [regex]::Matches($before, '<(?:label|span)[^>]*class="([^"]*)"')
  $wrapClass = ''
  if ($wraps.Count) { $wrapClass = $wraps[$wraps.Count - 1].Groups[1].Value }
  $hitClass = ''
  foreach ($k in $allowedWrapClasses.Keys) { if ($wrapClass -split '\s+' -contains $k) { $hitClass = $k; break } }
  if ($hitClass) {
    $showcased += "ALLOWED  line $line  wrapper=$wrapClass  $($allowedWrapClasses[$hitClass])`r`n         $(Preview $tag 120)"
    continue
  }

  # 4) anything left is a raw checkbox the driver sees
  $label = if ($id) { "id=$id" } else { 'id=(none)' }
  $offenders += "RAW CHECKBOX  line $line  $label  wrapper='$wrapClass'`r`n         $(Preview $tag 160)"
  if (-not $id) { $noId += $line }
}

# --- structure: every pill needs its slider --------------------------------
$swCount = ([regex]::Matches($raw, 'class="app-switch')).Count
$slCount = ([regex]::Matches($raw, 'class="app-slider"')).Count

# --- console (ASCII only) ---------------------------------------------------
Write-Host ''
Write-Host "Switch check - $Index" -ForegroundColor Cyan
Write-Host "checkbox inputs : $($rxInput.Matches($raw).Count)"
Write-Host "app-switch pills: $switches"
Write-Host "allowed special : $($showcased.Count)  (detail in tests/switch-check-report.txt)"
Write-Host ''

$fail = 0
if ($offenders.Count) {
  $fail++
  Write-Host ("[FAIL] raw checkbox(es): $($offenders.Count) -> run with the report for lines") -ForegroundColor Red
  foreach ($o in $offenders) {
    $firstLine = ($o -split "`r`n")[0]
    Write-Host ("        " + ($firstLine -replace '[^\x20-\x7E]', '?')) -ForegroundColor DarkRed
  }
} else {
  Write-Host "[PASS] every on/off control is an .app-switch pill" -ForegroundColor Green
}

if ($swCount -ne $slCount) {
  $fail++
  Write-Host "[FAIL] app-switch without app-slider: $swCount switch(es) vs $slCount slider(s)" -ForegroundColor Red
  Write-Host "        a pill without its slider renders as a bare grey box" -ForegroundColor DarkRed
} else {
  Write-Host "[PASS] every .app-switch has exactly one .app-slider ($swCount)" -ForegroundColor Green
}

if ($switches -eq 0) {
  $fail++
  Write-Host "[FAIL] no pill found at all - the switch markup changed shape" -ForegroundColor Red
} else {
  Write-Host "[PASS] pills found: $switches" -ForegroundColor Green
}

# --- report (UTF-8 so Thai survives PowerShell 5.1) -------------------------
$report = Resolve-FromRoot 'tests/switch-check-report.txt'
$stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm')
$body = @(
  "switch check - $Index - $stamp",
  "checkbox inputs: $($rxInput.Matches($raw).Count)   pills: $switches   allowed: $($showcased.Count)   raw: $($offenders.Count)",
  "",
  "--- raw checkboxes (must be fixed) ---"
) + @(if ($offenders.Count) { $offenders } else { 'none' }) + @(
  "",
  "--- allowed exceptions (why each one stays a checkbox) ---"
) + @(if ($showcased.Count) { $showcased } else { 'none' })
[System.IO.File]::WriteAllLines($report, $body, (New-Object System.Text.UTF8Encoding($false)))
Write-Host ''
Write-Host "detail (UTF-8): $report" -ForegroundColor DarkGray

Write-Host ''
if ($fail) {
  Write-Host "RESULT: $fail problem(s) - turn them into .app-switch before pushing." -ForegroundColor Red
  exit 1
}
Write-Host "RESULT: clean - every on/off control is a pill." -ForegroundColor Green
exit 0
