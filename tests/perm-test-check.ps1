# ============================================================================
# Per-role permission gate - run from tests/pre-push.ps1 (or by hand)
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests/perm-test-check.ps1
#   ... -Index index.html              the file about to be pushed
#   ... -BaselineFile <file>           compare against this file instead of
#                                      "git -C <Repo> show HEAD:index.html"
#   ... -Coverage                      also list permissions with no suite yet
#   ... -SelfTest                      plant changes and prove the gate catches them
#
# Owner request 2026-09-19:
#   "ถ้างานรอบนั้นแก้สิทธิ์รายยศ ต้องบังคับให้มีชุดทดสอบออฟไลน์ของสิทธินั้นผ่านก่อน
#    มิฉะนั้น push ไม่ผ่าน"
#
# What counts as "the round touched a per-role permission" (compared with the build
# that is already live, i.e. git HEAD of the repo copy):
#   A. a permission key added/removed            (defaultPermConfig rows, perm_xxx)
#   B. a per-role default value changed          (DEFAULT_ROLE_PERMS Manager/User
#                                                 literals + VIP/Admin overrides)
#   C. any source line that mentions the key changed
#      (the canX() gate, the settings row, the stored-role read, ...)
#   D. the DEFAULT_ROLE_PERMS plumbing changed   (which role copies which role)
#      -> reported as the pseudo key "roleDefaults"
#
# For every touched key the gate demands BOTH:
#   1. a registered offline suite  (tests/perm-test-map.json -> permissions.<key>)
#   2. a passing run recorded for that suite against the EXACT file being pushed
#      (tests/perm-test-last-run.json -> md5 of index.html must match byte for byte)
# No registration, no suite file, suite that never mentions the key, failed run or
# stale record ("index.html changed after the run") = DO NOT PUSH.
#
# Why a record file instead of running the suite here: a .ps1 gate cannot drive a
# browser. The record is the chain of custody - tests/perm-test-record.ps1 stamps
# "suite X passed N/N against md5 <index.html>" - and because the md5 is bound,
# editing index.html after the run invalidates it and the gate blocks again.
#
# Console output is ASCII-only on purpose: PowerShell 5.1 mis-reads Thai literals in
# .ps1 files. Thai detail goes to tests/perm-test-check-report.txt (UTF-8, no BOM).
#
# Exit code 0 = nothing to answer for, 1 = a permission changed without a passing suite.
# ============================================================================
param(
  [string]$Index = 'index.html',
  [string]$Map = 'tests/perm-test-map.json',
  [string]$LastRun = 'tests/perm-test-last-run.json',
  [string]$Repo = 'taxi-repo',
  [string]$BaselineFile = '',
  [string]$Report = 'tests/perm-test-check-report.txt',
  [switch]$Coverage,
  [switch]$SelfTest,
  [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $root) { $root = (Get-Location).Path }
function Resolve-FromRoot([string]$p) { if ([System.IO.Path]::IsPathRooted($p)) { $p } else { Join-Path $root $p } }
function Norm-Suite([string]$s) { return (($s -replace '\\', '/')).TrimStart('./').ToLowerInvariant() }

# ---------------------------------------------------------------- signature help
function Get-NormalizedLines([string]$text) {
  # trim + collapse runs of whitespace: the baseline comes from git (LF) while the
  # working file is CRLF, and only the code on the line matters - not the padding.
  $out = New-Object System.Collections.ArrayList
  foreach ($l in ($text -split "`r?`n")) {
    $t = ($l.Trim() -replace '\s+', ' ')
    if ($t.Length) { [void]$out.Add($t) }
  }
  return $out
}
function Get-SortedHash([string[]]$items) {
  $arr = @($items | Sort-Object)
  return (Get-StringHash (($arr -join "`n")))
}
function Get-StringHash([string]$s) {
  $md5 = [System.Security.Cryptography.MD5]::Create()
  try {
    $bytes = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($s))
    return ([System.BitConverter]::ToString($bytes)).Replace('-', '')
  } finally { $md5.Dispose() }
}

# ------------------------------------------------------------------ perm model
function New-PermModel([string]$text) {
  $model = @{
    keys   = @{}          # key -> $true  (permission keys seen anywhere in the model)
    lists  = @{}          # key -> $true  (declared in defaultPermConfig, i.e. has a row in the settings screen)
    defs   = @{}          # role -> @{ key -> bool }
    sig    = @{}          # key -> md5 of every normalized line mentioning it
    struct = ''           # md5 of the DEFAULT_ROLE_PERMS plumbing lines
    raw    = $text
  }

  # 1) the permission list: { id: 'perm_canX', label: '...' }
  foreach ($x in [regex]::Matches($text, "id:\s*'(perm_[A-Za-z0-9_]+)'")) {
    $k = $x.Groups[1].Value.Substring(5)
    $model.keys[$k] = $true
    $model.lists[$k] = $true
  }
  # 2) keys used inside the DEFAULT_ROLE_PERMS object literals / overrides
  foreach ($x in [regex]::Matches($text, "DEFAULT_ROLE_PERMS[^\n]*?(\w+)\s*:\s*(?:true|false)")) {
    $model.keys[$x.Groups[1].Value] = $true
  }
  foreach ($x in [regex]::Matches($text, "DEFAULT_ROLE_PERMS\.\w+\.(\w+)\s*=\s*(?:true|false)")) {
    $model.keys[$x.Groups[1].Value] = $true
  }

  # 3) per-role defaults: Manager / User literals, then VIP / Admin = copy of a role + overrides
  $blockM = [regex]::Match($text, "DEFAULT_ROLE_PERMS\s*=\s*\{(?<b>.*?)\n\s*\};", 'Singleline')
  $block = $(if ($blockM.Success) { $blockM.Groups['b'].Value } else { '' })
  foreach ($role in @('Manager', 'User')) {
    $rm = [regex]::Match($block, $role + ':\s*\{(?<r>.*?)\}', 'Singleline')
    if (-not $rm.Success) { continue }
    $d = @{}
    foreach ($p in [regex]::Matches($rm.Groups['r'].Value, '(\w+)\s*:\s*(true|false)')) {
      $d[$p.Groups[1].Value] = ($p.Groups[2].Value -eq 'true')
    }
    $model.defs[$role] = $d
  }
  foreach ($role in @('VIP', 'Admin')) {
    $sp = [regex]::Match($text, 'DEFAULT_ROLE_PERMS\.' + $role + '\s*=\s*\{\s*\.\.\.DEFAULT_ROLE_PERMS\.(\w+)')
    if (-not $sp.Success) { continue }
    $src = $sp.Groups[1].Value
    if (-not $model.defs.ContainsKey($src)) { continue }
    $d = @{}
    foreach ($k in @($model.defs[$src].Keys)) { $d[$k] = $model.defs[$src][$k] }
    foreach ($o in [regex]::Matches($text, 'DEFAULT_ROLE_PERMS\.' + $role + '\.(\w+)\s*=\s*(true|false)')) {
      $d[$o.Groups[1].Value] = ($o.Groups[2].Value -eq 'true')
    }
    $model.defs[$role] = $d
  }

  # 3b) every key that has a per-role default is a permission key too
  foreach ($role in @($model.defs.Keys)) {
    foreach ($k in @($model.defs[$role].Keys)) { $model.keys[$k] = $true }
  }

  # 4) line signature per known key + plumbing signature
  $bucket = @{}
  $structLines = New-Object System.Collections.ArrayList
  foreach ($k in @($model.keys.Keys)) { $bucket[$k] = New-Object System.Collections.ArrayList }
  foreach ($line in (Get-NormalizedLines $text)) {
    # The Manager/User literals put EVERY key on one very long line, so hashing that
    # line would flag all ~37 permissions on a single default flip (measured: one
    # planted flip reported 36 touched permissions). Those lines are covered by the
    # per-role default table above instead - skip them here for per-key granularity.
    if ($line -match '^(Manager|User)\s*:\s*\{.*\},?$') { continue }
    $keysHere = @{}
    foreach ($t in [regex]::Matches($line, '\b[A-Za-z_][A-Za-z0-9_]*\b')) {
      $tok = $t.Value
      if ($model.keys.ContainsKey($tok)) { $keysHere[$tok] = $true }
    }
    foreach ($k in @($keysHere.Keys)) { [void]$bucket[$k].Add($line) }
    if ($line -match 'DEFAULT_ROLE_PERMS' -and $keysHere.Count -eq 0) { [void]$structLines.Add($line) }
  }
  foreach ($k in @($bucket.Keys)) { $model.sig[$k] = (Get-SortedHash @($bucket[$k])) }
  $model.struct = (Get-SortedHash @($structLines))

  return $model
}

# ------------------------------------------------------------------- baseline
function Has-Prop($obj, [string]$name) {
  if ($null -eq $obj) { return $false }
  return (@($obj.PSObject.Properties.Name) -contains $name)
}
function Get-GitHeadIndex([string]$repoPath) {
  if (-not (Test-Path (Join-Path $repoPath '.git'))) { return $null }
  # git emits UTF-8 bytes: decode native output as UTF-8 or the Thai lines would be
  # garbled and every permission would look "changed". Never pipe through Out-String
  # either - it wraps long lines at the console width and breaks the comparison.
  $prevEnc = [Console]::OutputEncoding
  $prev = (Get-Location).Path
  try {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $lines = (& git -C $repoPath show 'HEAD:index.html' 2>$null)
    if ($LASTEXITCODE -ne 0 -or $null -eq $lines) { return $null }
    $txt = (@($lines) -join "`n")
    if (-not $txt.Trim().Length) { return $null }
    return $txt
  } catch { return $null } finally { [Console]::OutputEncoding = $prevEnc; Set-Location $prev }
}

# ----------------------------------------------------------------------- gate
function Get-MapPerms($mapJson) { if (Has-Prop $mapJson 'permissions') { return $mapJson.permissions } return $null }

function Invoke-Gate([string]$indexPath, [string]$baselineText, [string]$baselineName, [switch]$QuietRun) {
  $res = @{ fail = 0; touched = @(); info = @(); lines = @(); report = @() }
  $failMsgs = New-Object System.Collections.ArrayList
  $infoMsgs = New-Object System.Collections.ArrayList

  $nowText = [System.IO.File]::ReadAllText($indexPath)
  $now = New-PermModel $nowText
  $old = New-PermModel $baselineText
  # ⚠️ ตัดบรรทัด "ประทับเวอร์ชันเว็บ" (APP_WEB_VERSION) ออกก่อนคิด md5
  #    ⇒ การประทับเวอร์ชันใหม่ (ขั้นตอนตอน push) ไม่ทำให้ผลรันชุดทดสอบเดิมกลายเป็น “เก่า”
  #      ซึ่งจะทำให้ push ไม่ผ่านทั้ง ๆ ที่สิทธิ์ไม่ได้เปลี่ยนเลย
  $indexMd5 = Get-StringHash ([regex]::Replace($nowText, "APP_WEB_VERSION\s*=\s*'[^']*'", "APP_WEB_VERSION = ''"))

  # which keys changed?
  $allKeys = @{}
  foreach ($k in @($now.keys.Keys)) { $allKeys[$k] = $true }
  foreach ($k in @($old.keys.Keys)) { $allKeys[$k] = $true }

  $reasons = @{}
  foreach ($k in @($allKeys.Keys | Sort-Object)) {
    $nowHas = $now.keys.ContainsKey($k)
    $oldHas = $old.keys.ContainsKey($k)
    if ($nowHas -ne $oldHas) {
      $reasons[$k] = $(if ($nowHas) { 'permission added this round' } else { 'permission removed this round' })
      continue
    }
    if ($now.sig[$k] -ne $old.sig[$k]) { $reasons[$k] = 'source lines of this permission changed'; continue }
    # per-role default value changed (any of the four roles)
    foreach ($role in @('Manager', 'User', 'VIP', 'Admin')) {
      $dn = $(if ($now.defs.ContainsKey($role)) { $now.defs[$role] } else { @{} })
      $do = $(if ($old.defs.ContainsKey($role)) { $old.defs[$role] } else { @{} })
      $vn = $(if ($dn.ContainsKey($k)) { [string]$dn[$k] } else { 'n/a' })
      $vo = $(if ($do.ContainsKey($k)) { [string]$do[$k] } else { 'n/a' })
      if ($vn -ne $vo) {
        $reasons[$k] = "default for role $role changed ($vo -> $vn)"
        break
      }
    }
  }
  if ($now.struct -ne $old.struct) { $reasons['roleDefaults'] = 'DEFAULT_ROLE_PERMS plumbing changed (which role copies which role)' }

  $touched = @($reasons.Keys | Sort-Object)
  $res.touched = $touched

  # registry + run records
  $mapPath = Resolve-FromRoot $Map
  $mapOk = Test-Path $mapPath
  $mapJson = $null
  if ($mapOk) { try { $mapJson = Get-Content $mapPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $mapOk = $false } }
  if (-not $mapOk) {
    $res.fail++
    [void]$failMsgs.Add("permission test registry unreadable: $Map")
  }
  $lastPath = Resolve-FromRoot $LastRun
  $lastJson = $null
  if (Test-Path $lastPath) { try { $lastJson = Get-Content $lastPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $lastJson = $null } }
  $indexName = (Split-Path -Leaf $indexPath)

  # NB: local name must not collide with the script-scope parameters ($Report is a
  # string there and PowerShell variables are case-insensitive).
  $report = New-Object System.Collections.ArrayList
  [void]$report.Add("per-role permission gate")
  [void]$report.Add("index      : $indexPath")
  [void]$report.Add("md5        : $indexMd5")
  [void]$report.Add("baseline   : $baselineName")
  [void]$report.Add("touched    : $(if ($touched.Count) { $touched -join ', ' } else { '(none)' })")
  [void]$report.Add('')

  if (-not $touched.Count) {
    [void]$report.Add('ไม่มีสิทธิ์รายยศถูกแก้ในรอบนี้ — ไม่ต้องมีชุดทดสอบเพิ่ม')
  } else {
    [void]$report.Add('สิทธิ์ที่ถูกแก้ในรอบนี้ (เทียบกับบิลด์ที่เว็บใช้อยู่):')
    foreach ($k in $touched) {
      $label = ''
      if ($mapOk -and (Has-Prop (Get-MapPerms $mapJson) $k)) { $label = [string](Get-MapPerms $mapJson).$k.label }
      [void]$report.Add(("  - " + $k + $(if ($label) { " ($label)" } else { '' }) + " : " + $reasons[$k]))
    }
    [void]$report.Add('')
  }

  $recorded = @{}
  if (Has-Prop $lastJson $indexName) {
    foreach ($p in $lastJson.$indexName.PSObject.Properties) { $recorded[(Norm-Suite $p.Name)] = $p.Value }
  }

  $checkedSuites = @{}
  foreach ($k in $touched) {
    $entry = $null
    if ($mapOk -and (Has-Prop (Get-MapPerms $mapJson) $k)) { $entry = (Get-MapPerms $mapJson).$k }
    if (-not $entry) {
      $res.fail++
      [void]$failMsgs.Add("permission '$k' changed but no offline suite is registered for it -> add it to $Map")
      [void]$report.Add("❌ สิทธิ์ $k ถูกแก้ แต่ยังไม่มีชุดทดสอบในทะเบียน ($Map)")
      [void]$report.Add("   วิธี: เขียนชุดทดสอบออฟไลน์ที่กดปุ่มจริงของสิทธินี้ แล้วใส่ `"$k`": { `"suite`": `"tests/<ไฟล์>.html`", `"expect`": <จำนวนสถานการณ์>, `"label`": `"...`" }")
      continue
    }
    $suiteRel = [string]$entry.suite
    $expect = 0
    if ($entry.PSObject.Properties.Name -contains 'expect') { $expect = [int]$entry.expect }
    $suitePath = Resolve-FromRoot $suiteRel
    $n = Norm-Suite $suiteRel

    if (-not (Test-Path $suitePath)) {
      $res.fail++
      [void]$failMsgs.Add("suite file missing for '$k': $suiteRel")
      [void]$report.Add("❌ สิทธิ์ $k ระบุชุดทดสอบ $suiteRel แต่ไม่พบไฟล์")
      continue
    }
    $isPseudo = (Has-Prop $entry 'pseudo') -and ([bool]$entry.pseudo)
    $suiteText = [System.IO.File]::ReadAllText($suitePath)
    if ((-not $isPseudo) -and ($suiteText -notmatch ('\b' + [regex]::Escape($k) + '\b'))) {
      $res.fail++
      [void]$failMsgs.Add("suite $suiteRel never mentions '$k' -> it does not test this permission")
      [void]$report.Add("❌ ชุดทดสอบ $suiteRel ไม่ได้อ้างถึงสิทธิ์ $k เลย (ไม่ได้ทดสอบสิทธินี้จริง)")
      continue
    }
    if (-not $recorded.ContainsKey($n)) {
      $res.fail++
      [void]$failMsgs.Add("no pass record for '$k' ($suiteRel) -> run the suite, then: tests/perm-test-record.ps1 -Suite $suiteRel -Pass $expect -Total $expect")
      [void]$report.Add("❌ สิทธิ์ $k ยังไม่มีผลรันที่บันทึกไว้ของ $suiteRel")
      [void]$report.Add("   วิธี: เปิดชุดทดสอบให้ผ่านครบ $expect/$expect แล้วรัน `"powershell -NoProfile -ExecutionPolicy Bypass -File tests/perm-test-record.ps1 -Suite $suiteRel -Pass $expect -Total $expect`"")
      continue
    }
    $rec = $recorded[$n]
    $rPass = [int]$rec.pass; $rTotal = [int]$rec.total; $rMd5 = [string]$rec.md5
    $rSuiteMd5 = $(if (Has-Prop $rec 'suiteMd5') { [string]$rec.suiteMd5 } else { '' })
    $nowSuiteMd5 = (Get-FileHash $suitePath -Algorithm MD5).Hash
    if ($rPass -ne $rTotal) {
      $res.fail++
      [void]$failMsgs.Add("recorded run of $suiteRel did NOT pass ($rPass/$rTotal)")
      [void]$report.Add("❌ ผลรันที่บันทึกของ $suiteRel ไม่ผ่านครบ ($rPass/$rTotal) — ต้องแก้ให้ผ่านก่อน")
      continue
    }
    if ($expect -gt 0 -and $rTotal -ne $expect) {
      $res.fail++
      [void]$failMsgs.Add("recorded run of $suiteRel is $rTotal scenario(s) but the registry expects $expect")
      [void]$report.Add("❌ ทะเบียนบอกว่าชุดนี้มี $expect สถานการณ์ แต่ผลรันที่บันทึกมี $rTotal — แก้ทะเบียนหรือแก้ชุดทดสอบให้ตรงกัน")
      continue
    }
    if ($rMd5 -ne $indexMd5) {
      $res.fail++
      [void]$failMsgs.Add("pass record for $suiteRel was taken on md5 $($rMd5.Substring(0,[Math]::Min(8,$rMd5.Length))) but this file is $($indexMd5.Substring(0,8)) -> re-run the suite")
      [void]$report.Add("❌ ผลรันของ $suiteRel เก่ากว่าไฟล์ที่กำลัง push (ผลรัน md5 " + $rMd5 + " ≠ " + $indexMd5 + ")")
      [void]$report.Add('   ไฟล์ถูกแก้หลังรัน → ต้องรันชุดทดสอบใหม่อีกครั้งแล้วบันทึกผล')
      continue
    }
    if ($rSuiteMd5 -ne $nowSuiteMd5) {
      $res.fail++
      [void]$failMsgs.Add("the suite file $suiteRel changed after the recorded run -> re-run it and record again")
      [void]$report.Add("❌ ชุดทดสอบ $suiteRel ถูกแก้หลังรัน (หรือผลรันเก่ากว่ารุ่นที่บันทึก) — ต้องรันใหม่แล้วบันทึกผลอีกครั้ง")
      continue
    }
    $checkedSuites[$n] = $true
    [void]$infoMsgs.Add("$k -> $suiteRel ($rPass/$rTotal, md5 ok)")
    [void]$report.Add("✅ สิทธิ์ $k : $suiteRel ผ่าน $rPass/$rTotal และผูกกับ md5 ของไฟล์นี้แล้ว")
  }

  if ($Coverage) {
    $unmapped = New-Object System.Collections.ArrayList
    foreach ($k in @($now.lists.Keys | Sort-Object)) {
      if (-not ($mapOk -and (Has-Prop (Get-MapPerms $mapJson) $k))) { [void]$unmapped.Add($k) }
    }
    [void]$report.Add('')
    [void]$report.Add("สิทธิ์ทั้งหมดในแอป: $($now.lists.Count) · มีชุดทดสอบแล้ว: $($now.lists.Count - $unmapped.Count) · ยังไม่มี: $($unmapped.Count)")
    if ($unmapped.Count) { [void]$report.Add('ยังไม่มีชุดทดสอบ: ' + (($unmapped | Sort-Object) -join ', ')) }
    $res.info += "coverage: $($now.lists.Count - $unmapped.Count)/$($now.lists.Count) permission(s) registered"
  }
  [void]$report.Add('')
  [void]$report.Add($(if ($res.fail) { "สรุป: ไม่ผ่าน ($($res.fail) ข้อ) — ห้าม push" } else { 'สรุป: ผ่าน — สิทธิ์ที่แก้ในรอบนี้มีชุดทดสอบออฟไลน์ผ่านครบ' }))

  $res.failMsgs = @($failMsgs)
  $res.infoMsgs = @($infoMsgs)
  $res.report = @($report)
  return $res
}

# ------------------------------------------------------------------- baseline pick
$indexPath = Resolve-FromRoot $Index
if (-not (Test-Path $indexPath)) { Write-Host "index file not found: $indexPath" -ForegroundColor Red; exit 1 }

$baselineText = ''
$baselineName = ''
if ($BaselineFile) {
  $bp = Resolve-FromRoot $BaselineFile
  if (-not (Test-Path $bp)) { Write-Host "baseline file not found: $bp" -ForegroundColor Red; exit 1 }
  $baselineText = [System.IO.File]::ReadAllText($bp)
  $baselineName = $BaselineFile
} else {
  $repoPath = Resolve-FromRoot $Repo
  $baselineText = Get-GitHeadIndex $repoPath
  if ($baselineText) { $baselineName = "git HEAD:index.html ($Repo)" }
  else {
    $repoCopy = Join-Path $repoPath 'index.html'
    if (Test-Path $repoCopy) {
      $same = ((Get-FileHash $indexPath -Algorithm MD5).Hash -eq (Get-FileHash $repoCopy -Algorithm MD5).Hash)
      $baselineText = [System.IO.File]::ReadAllText($repoCopy)
      $baselineName = "$Repo/index.html (git unavailable)"
      if ($same) { $baselineName += ' [identical to index.html - pass -BaselineFile to compare against an older build]' }
    }
  }
}
if (-not $baselineText) {
  Write-Host "cannot determine the live baseline (no $Repo git repo and no $Repo/index.html) - pass -BaselineFile" -ForegroundColor Red
  exit 1
}

# ------------------------------------------------------------------- self test
$selfFail = 0
if ($SelfTest) {
  Write-Host '--- self-test (the gate must catch a planted permission change) ---'
  $realText = [System.IO.File]::ReadAllText($indexPath)
  $tmpDir = Join-Path $env:TEMP ("perm-gate-selftest-" + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
  $utf8 = New-Object System.Text.UTF8Encoding($false)
  $cases = @(
    @{ name = 'per-role default flipped (User gets meter-from-route)'; old = 'canStartMeterRoute: false }'; new = 'canStartMeterRoute: true }'; mustName = 'canStartMeterRoute' },
    @{ name = 'brand new permission row added'; old = "{ id: 'perm_canExportTrips'"; new = "{ id: 'perm_canFakeThing' },`r`n        { id: 'perm_canExportTrips'"; mustName = 'canFakeThing' },
    @{ name = 'gate line of a permission edited'; old = 'canUseSpeedAlert()'; new = 'canUseSpeedAlertAlways()'; mustName = 'canUseSpeedAlert' }
  )
  foreach ($c in $cases) {
    $planted = $realText.Replace($c.old, $c.new)
    if ($planted -eq $realText) {
      $selfFail++
      Write-Host ("[FAIL] self-test could not plant case: " + $c.name + " (anchor text changed)")
      continue
    }
    $copy = Join-Path $tmpDir 'index-planted.html'
    [System.IO.File]::WriteAllText($copy, $planted, $utf8)
    $r = Invoke-Gate $copy $realText 'self-test baseline' -QuietRun
    $named = @($r.touched) -contains $c.mustName
    if ($r.fail -gt 0 -and $named) {
      Write-Host ("[PASS] self-test caught: " + $c.name + " (blocked on '$($c.mustName)')")
    } else {
      $selfFail++
      Write-Host ("[FAIL] self-test MISSED: " + $c.name + " (fail=$($r.fail), touched='$($r.touched -join ',')')")
    }
  }
  $rReal = Invoke-Gate $indexPath $baselineText $baselineName -QuietRun
  if ($rReal.fail -eq 0) { Write-Host '[PASS] self-test: the real file pair reports no problem (no false alarm)' }
  else { Write-Host ("[INFO] self-test: the real pair reports $($rReal.fail) problem(s) - see the run below") }
  Remove-Item $tmpDir -Recurse -Force
  Write-Host ''
}

# --------------------------------------------------------------------- run gate
$res = Invoke-Gate $indexPath $baselineText $baselineName

if (-not $Quiet) {
  Write-Host '--- per-role permission gate ---'
  Write-Host ("index      : " + $Index)
  Write-Host ("baseline   : " + $baselineName)
  Write-Host ("touched    : " + $(if ($res.touched.Count) { ($res.touched -join ', ') } else { '(none)' }))
  foreach ($l in $res.infoMsgs) { Write-Host ("[PASS] " + $l) }
  foreach ($l in $res.failMsgs) { Write-Host ("[FAIL] " + $l) }
  foreach ($l in $res.info) { Write-Host ("[PASS] " + $l) }
}

$reportPath = Resolve-FromRoot $Report
[System.IO.File]::WriteAllLines($reportPath, @($res.report), (New-Object System.Text.UTF8Encoding($false)))

if ($SelfTest) {
  Write-Host ''
  Write-Host ("report (Thai): " + (Split-Path -Leaf $reportPath))
  if ($selfFail) { Write-Host ("RESULT: self-test failed (" + $selfFail + " case(s))"); exit 1 }
  if ($res.fail) { Write-Host ("RESULT: blocked (" + $res.fail + " problem(s)) - DO NOT PUSH"); exit 1 }
  Write-Host 'RESULT: self-test passed + safe to push'
  exit 0
}

Write-Host ''
Write-Host ("report (Thai): " + (Split-Path -Leaf $reportPath))
if ($res.fail) {
  Write-Host ("RESULT: " + $res.fail + " permission problem(s) - DO NOT PUSH until the offline suite passes and is recorded")
  exit 1
}
Write-Host 'RESULT: permission gate clean'
exit 0
