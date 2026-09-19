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

# --- 3b) the PWA install path must stay usable ------------------------------
#   (owner report 18 Sep 2026: "กดติดตั้งแล้วไม่ติดตั้งจริง ไม่มีไอคอนขึ้นหน้าจอ"
#    - the page used to inject the manifest as a data: URL, and Chrome refuses to
#      install from anything that is not a real same-origin file.)
#   It also guards the other half of the report: the install banner must stay
#   hidden inside the Android APK, where the user already has an app icon.
$pwaChecker = Resolve-FromRoot 'tests/pwa-check.ps1'
if (Test-Path $pwaChecker) {
  $pOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $pwaChecker -Index $Index -Repo $Repo 2>&1 | Out-String
  $pBad = @($pOut -split "`r?`n" | Where-Object { $_ -match '^\[FAIL\]' })
  if ($pBad.Count) {
    Fail 'pwa-check not clean -> the home-screen install path is broken'
    foreach ($l in $pBad) { Say ('        ' + $l.Trim()) }
    Say  '       (full Thai detail: tests/pwa-check-report.txt)'
  } else {
    Pass 'pwa-check: real manifest + local icons + no banner inside the app'
  }
} else {
  Fail 'tests/pwa-check.ps1 missing'
}

# --- 3c) the web build must carry a fresh version stamp ----------------------
#   (owner request 18 Sep 2026: "let the app notice a newer web build by itself
#    and reload, without reinstalling the APK". version.json is what the RUNNING
#    app compares against, so it must describe the exact index.html being
#    pushed - otherwise the app either never notices an update or reloads
#    forever. -Check also compares taxi-repo copies.)
$stamper = Resolve-FromRoot 'tests/stamp-web-version.ps1'
if (Test-Path $stamper) {
  $sOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $stamper -Check -Root $root 2>&1 | Out-String
  $sLines = @($sOut -split "`r?`n" | Where-Object { $_ -match '\S' })
  if ($LASTEXITCODE -eq 0 -and -not @($sLines | Where-Object { $_ -match '^FAIL' }).Count) {
    Pass ('web version stamp: ' + (@($sLines | Where-Object { $_ -match '^PASS' }) -join ' '))
  } else {
    Fail 'web version stamp is stale -> run: powershell -File tests/stamp-web-version.ps1'
    foreach ($l in $sLines) { Say ('        ' + $l.Trim()) }
  }
} else {
  Fail 'tests/stamp-web-version.ps1 missing'
}

# --- 3c-bis) the mini map must never open by itself again ---------------------
#   (owner request 18 Sep 2026: "add a pre-push gate that stops any code from going
#    back to pref.hidden = !permOk() or calling show() at navigation start, and
#    report the leaking spots" - Thai detail goes to the guard's own report file)
#   Regression A: pref.hidden = !permOk()  = "has permission => open it right away"
#   Regression B: show() / pref.hidden = false inside a start path (startNavigationMap,
#   navMiniResume, __navMiniApplyPerm) bypasses autoOpenAtStart(), which is the only
#   place that honours "the user pressed X, keep it closed" and the per-role setting.
$mmChecker = Resolve-FromRoot 'tests/minimap-start-guard.ps1'
if (Test-Path $mmChecker) {
  $mOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $mmChecker -Index $Index 2>&1 | Out-String
  $mBad = @($mOut -split "`r?`n" | Where-Object { $_ -match '^\[FAIL\]' })
  if ($mBad.Count) {
    Fail 'minimap-start-guard not clean -> the mini map can open by itself again'
    foreach ($l in $mBad) { Say ('        ' + $l.Trim()) }
    foreach ($l in @($mOut -split "`r?`n" | Where-Object { $_ -match 'line \d+' })) { Say ('        ' + $l.Trim()) }
    Say  '       (fix: those start paths may only open through autoOpenAtStart(); otherwise stay collapsed)'
    Say  '       (full Thai detail with line numbers: tests/minimap-start-guard-report.txt)'
  } else {
    $mRes = ([regex]::Match($mOut, 'RESULT:[^\r\n]*')).Value
    Pass ('minimap-start-guard: mini map cannot self-open -> ' + $mRes.Trim())
  }
} else {
  Fail 'tests/minimap-start-guard.ps1 missing'
}

# --- 3c-bis-2) Android framework classes/constants must exist in android.jar --------
#   (owner report 20 Sep 2026: "ปุ่มลงทะเบียนปลดล็อกด้วยลายนิ้วมือ ถ้าใช้ผ่านโทรศัพท์มันใช้ไม่ได้"
#    While fixing it we found two references that would NOT compile at CI:
#      BiometricManager.BIOMETRIC_WEAK (lives in BiometricManager.Authenticators)
#      BiometricPrompt.BIOMETRIC_ERROR_NEGATIVE_BUTTON (that class has no such constant)
#    This machine has NO JDK, so a broken reference only surfaces in the CI build - i.e.
#    after the push. The gate reads the real android.jar and verifies every
#    `import android....` and every `ClassName.CONSTANT` the APK uses. No jar -> SKIP.)
$apiChecker = Resolve-FromRoot 'tests/android-api-check.ps1'
if (Test-Path $apiChecker) {
  $aOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $apiChecker -Root $root 2>&1 | Out-String
  $aBad = @($aOut -split "`r?`n" | Where-Object { $_ -match '^\[FAIL\]' })
  $aSkip = @($aOut -split "`r?`n" | Where-Object { $_ -match '^SKIP' })
  if ($aSkip.Count) {
    Skip 'android-api-check: no android.jar on this machine (CI does the real compile)'
  } elseif ($aBad.Count) {
    Fail 'android-api-check not clean -> the APK code would not compile at CI'
    foreach ($l in $aBad) { Say ('        ' + $l.Trim()) }
    Say  '       (fix the reference, then re-run: powershell -File tests/android-api-check.ps1)'
    Say  '       (full detail: tests/android-api-check-report.txt)'
  } else {
    $aRes = ([regex]::Match($aOut, 'checked:[^\r\n]*')).Value
    Pass ('android-api-check: framework classes/constants all exist -> ' + $aRes.Trim())
  }
} else {
  Fail 'tests/android-api-check.ps1 missing'
}

# --- 3c-ter) a per-role permission change must ship a passing offline suite ----
#   (owner request 19 Sep 2026: "ถ้างานรอบนั้นแก้สิทธิ์รายยศ ต้องบังคับให้มีชุด
#    ทดสอบออฟไลน์ของสิทธินั้นผ่านก่อน มิฉะนั้น push ไม่ผ่าน")
#   The gate compares the file being pushed with the build that is already live
#   (git HEAD of the repo copy) and, for every per-role permission it finds
#   touched (key added/removed, per-role default flipped, any source line that
#   mentions the key changed, DEFAULT_ROLE_PERMS plumbing changed), demands:
#     * a registered offline suite (tests/perm-test-map.json)
#     * a passing run of that suite recorded against this exact md5
#       (tests/perm-test-last-run.json, written by tests/perm-test-record.ps1)
$permChecker = Resolve-FromRoot 'tests/perm-test-check.ps1'
if (Test-Path $permChecker) {
  $pOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $permChecker -Index $Index -Repo $Repo 2>&1 | Out-String
  $pBad = @($pOut -split "`r?`n" | Where-Object { $_ -match '^\[FAIL\]' })
  if ($pBad.Count) {
    Fail 'permission gate not clean -> a per-role permission changed without a passing offline suite'
    foreach ($l in $pBad) { Say ('        ' + $l.Trim()) }
    Say  '       (fix: register the suite in tests/perm-test-map.json, run it, then tests/perm-test-record.ps1 -Suite <file> -Pass <n> -Total <n>)'
    Say  '       (full Thai detail: tests/perm-test-check-report.txt)'
  } else {
    $pTouched = ([regex]::Match($pOut, 'touched\s*:\s*([^\r\n]*)')).Groups[1].Value
    if ($pTouched -and $pTouched.Trim() -ne '(none)') {
      Pass ('permission gate: touched ' + $pTouched.Trim() + ' -> registered suite(s) passed on this build')
      foreach ($l in @($pOut -split "`r?`n" | Where-Object { $_ -match '^\[PASS\] .*->.*md5 ok' })) { Say ('        ' + $l.Trim()) }
    } else {
      Pass 'permission gate: no per-role permission changed this round'
    }
  }
} else {
  Fail 'tests/perm-test-check.ps1 missing'
}

# --- 3d) never ship the APK signing key -------------------------------------
#   (owner request 18 Sep 2026: "ติดตั้งทับได้เลย ไม่ต้องถอนของเก่า" -> the key at
#    .freebuff/signing-key/ + GitHub Actions secrets keeps one identity forever.
#    If that private key ever lands in the repo, anyone can publish an APK that
#    updates the drivers' installed app. Only the public fingerprint may ship.)
$keyDir = Resolve-FromRoot '.freebuff/signing-key'
if (Test-Path $keyDir) { Pass 'signing key kept outside the repo (.freebuff/signing-key)' }
else { Skip 'no local signing-key folder (fine on a fresh clone)' }
$keyLeak = @()
try {
  Push-Location (Join-Path $root $Repo)
  foreach ($f in @(git ls-files)) {
    $isAllowed = $f -match 'signing-key-fingerprint\.txt$'
    if (-not $isAllowed -and $f -match '(?i)(keystore|\.jks$|\.keystore$|\.p12$|signing-key)') { $keyLeak += $f }
  }
  $keyB64 = Join-Path $keyDir 'secret-KEYSTORE_BASE64.txt'
  if ((Test-Path $keyB64) -and @(git ls-files).Count) {
    $prefix = ([System.IO.File]::ReadAllText($keyB64)).Trim()
    if ($prefix.Length -gt 24) { $prefix = $prefix.Substring(0, 24) }
    foreach ($f in @(git ls-files)) {
      $p = Join-Path $root (Join-Path $Repo $f)
      if (-not (Test-Path $p)) { continue }
      try {
        if ([System.IO.File]::ReadAllText($p).Contains($prefix)) { $keyLeak += "$f (contains the key!) " }
      } catch { }
    }
  }
} catch { } finally { Pop-Location }
if ($keyLeak.Count) {
  Fail 'key material is inside the repo -> remove it before pushing'
  foreach ($l in @($keyLeak | Select-Object -Unique)) { Say ('        ' + $l) }
} else {
  Pass 'no key material tracked (only the public fingerprint file is allowed)'
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

# --- desktop notification (owner asked 2026-09-20: "notify me when the work is done") ---
# This gate takes minutes to run, so the owner should not have to watch it.
# notify-done.ps1 is ASCII-only and reads all Thai text from UTF-8 files.
try {
  $notifier = Join-Path $PSScriptRoot 'notify-done.ps1'
  if (Test-Path $notifier) {
    if ($script:fail) {
      & $notifier -Kind fail -Message "pre-push gate: $($script:fail) problem(s) - see tests/pre-push-report.txt" | Out-Null
    } else {
      & $notifier -Kind done -Message 'pre-push gate: safe to push' | Out-Null
    }
  }
} catch {}

Say ''
if ($script:fail) {
  Say "RESULT: $($script:fail) problem(s) - DO NOT PUSH until this is clean"
  exit 1
}
Say 'RESULT: safe to push'
exit 0
