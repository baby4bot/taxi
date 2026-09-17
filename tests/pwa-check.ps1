# ============================================================================
# PWA install gate - guards the path that lets Chrome/Samsung actually install
# the app (and create a home-screen icon).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests/pwa-check.ps1
#   ... -Index <file>   -Repo taxi-repo
#
# Why (owner report 2026-09-18): "กดติดตั้งแล้วไม่ติดตั้งจริง ไม่มีไอคอนขึ้นหน้าจอ"
#   Root cause: the page injected the manifest as a `data:` URL. Chrome only
#   accepts a manifest served from the same origin -> install prompt dies.
#   Second issue: the install banner kept appearing inside the Android APK,
#   where the user already has a home-screen icon.
#
# ASCII-only console output on purpose (PowerShell 5.1 mangles Thai literals in
# .ps1 files). Thai detail goes to tests/pwa-check-report.txt as UTF-8.
# ============================================================================
param(
  [string]$Index = 'index.html',
  [string]$Repo = 'taxi-repo'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $root) { $root = (Get-Location).Path }
function ResolveFromRoot([string]$p) { if ([System.IO.Path]::IsPathRooted($p)) { $p } else { Join-Path $root $p } }

$script:fail = 0
$script:lines = New-Object System.Collections.ArrayList
function Say([string]$s) { Write-Host $s; [void]$script:lines.Add($s) }
function Ok([string]$s) { Say ("[PASS] " + $s) }
function Bad([string]$s) { $script:fail++; Say ("[FAIL] " + $s) }

$indexPath = ResolveFromRoot $Index
if (-not (Test-Path $indexPath)) { Write-Host "index not found: $indexPath" -ForegroundColor Red; exit 1 }
$html = [System.IO.File]::ReadAllText($indexPath)

Write-Host '=== 1) manifest must be a real same-origin file ==='
$mf = ResolveFromRoot 'manifest.webmanifest'
$manifestLink = ([regex]::Match($html, '<link[^>]*id="dynamicManifest"[^>]*>')).Value
if ($manifestLink -match 'href\s*=\s*"([^"]+)"') {
    $href = $Matches[1]
    if ($href -match '^\./manifest\.webmanifest') { Ok "manifest link points at the file ($href)" }
    else { Bad "manifest link must be ./manifest.webmanifest (found: $href)" }
} else { Bad 'no <link id="dynamicManifest" href="..."> found in the index head' }

if ($html -match 'data:application/manifest\+json') { Bad 'index still builds a data: manifest (install prompt will not work)' }
else { Ok 'no data: manifest anywhere in the index' }

Write-Host ''
Write-Host '=== 2) manifest contents ==='
if (-not (Test-Path $mf)) { Bad "missing manifest.webmanifest" }
else {
    $m = $null
    try { $m = Get-Content $mf -Raw -Encoding UTF8 | ConvertFrom-Json; Ok 'manifest parses as JSON' }
    catch { Bad ("manifest is not valid JSON -> " + $_.Exception.Message) }
    if ($m) {
        if ($m.name) { Ok ("name = " + $m.name) } else { Bad 'manifest has no name' }
        if ($m.short_name) { Ok ("short_name = " + $m.short_name) } else { Bad 'manifest has no short_name' }
        if ($m.start_url) { Ok ("start_url = " + $m.start_url) } else { Bad 'manifest has no start_url' }
        if ($m.display -match '^(fullscreen|standalone|minimal-ui)$') { Ok ("display = " + $m.display) }
        else { Bad ("display must be fullscreen/standalone/minimal-ui (found: " + $m.display + ")") }
        $icons = @($m.icons)
        if ($icons.Count -ge 2) { Ok ("icons listed = " + $icons.Count) } else { Bad 'manifest needs at least 2 icons' }
        $sizes = @($icons | ForEach-Object { [string]$_.sizes })
        foreach ($need in @('192x192', '512x512')) {
            if ($sizes -contains $need) { Ok "icon size covered: $need" } else { Bad "manifest must list a $need icon" }
        }
        $png = @($icons | Where-Object { [string]$_.type -eq 'image/png' })
        if ($png.Count -eq $icons.Count) { Ok 'every icon is image/png' } else { Bad 'every icon must be image/png (browsers reject jpeg for install)' }
        if (@($icons | Where-Object { [string]$_.purpose -eq 'maskable' }).Count -ge 1) { Ok 'has a maskable icon (Android will not shrink it into a white circle)' }
        else { Bad 'add at least one icon with purpose "maskable"' }

        # every icon file must exist next to the manifest, as a real PNG
        $mfDir = Split-Path -Parent $mf
        foreach ($i in $icons) {
            $src = [string]$i.src
            if (-not $src -or $src -match '^https?:') { Bad "icon src must be a local file (found: $src)"; continue }
            $p = Join-Path $mfDir $src
            if (-not (Test-Path $p)) { Bad "icon file missing: $src"; continue }
            $len = (Get-Item $p).Length
            $fs = [IO.File]::OpenRead($p); $h = New-Object byte[] 8; $null = $fs.Read($h, 0, 8); $fs.Close()
            $sig = ($h | ForEach-Object { $_.ToString('x2') }) -join ''
            if ($len -gt 1000 -and $sig.StartsWith('89504e470d0a1a0a')) { Ok "icon ok: $src ($len bytes)" }
            else { Bad "icon looks broken: $src ($len bytes, sig=$sig)" }
        }
    }
}

Write-Host ''
Write-Host '=== 3) home-screen icons must be ours, not a third-party host ==='
# ⚠️ ลำดับ attribute ในแท็ก <link> ไม่แน่นอน (href ก่อนหรือ rel ก่อนก็ได้) → ต้องดูทีละแท็ก ไม่ใช่ regex ต่อเนื่อง
$linkTags = @([regex]::Matches($html, '<link[^>]*>') | ForEach-Object { $_.Value })
$appleTag = @($linkTags | Where-Object { $_ -match 'rel="apple-touch-icon"' })[0]
if ($appleTag -and $appleTag -match 'href="\./icon') { Ok 'apple-touch-icon is a local file' }
else { Bad 'apple-touch-icon must point at a local ./icon-*.png (a remote host breaks offline)' }
$favTag = @($linkTags | Where-Object { $_ -match 'rel="shortcut icon"' -or $_ -match 'rel="icon"' })[0]
if ($favTag -and $favTag -match 'href="\./') { Ok 'favicon is a local file' }
else { Bad 'favicon must point at a local file' }

Write-Host ''
Write-Host '=== 4) install banner must stay hidden inside the Android app ==='
if ($html -match 'isNativeAppShell') { Ok 'index defines isNativeAppShell()' } else { Bad 'index must detect the Android app shell (isNativeAppShell)' }
if ($html -match 'if \(isNativeAppShell\(\)\)\s*\{\s*hideInstallBanner\(\)') { Ok 'tryShowInstallBanner bails out inside the app' }
else { Bad 'tryShowInstallBanner must hide the banner inside the Android app' }
if ($html -match 'taxiNativeAvailable') { Ok 'uses the TaxiNative bridge as the first signal' } else { Bad 'should check window.taxiNativeAvailable()' }
if ($html -match 'TaxiMeterApp') { Ok 'user-agent fallback present (works before modules load)' } else { Bad 'add a user-agent fallback for the Android shell' }

Write-Host ''
Write-Host '=== 5) the repo copy must carry the same files ==='
$repoDir = ResolveFromRoot $Repo
if (Test-Path $repoDir) {
    foreach ($f in @('manifest.webmanifest', 'icon-192.png', 'icon-512.png', 'icon-maskable-192.png', 'icon-maskable-512.png')) {
        $a = ResolveFromRoot $f; $b = Join-Path $repoDir $f
        if (-not (Test-Path $b)) { Bad "$Repo/$f is missing -> copy it before committing" }
        elseif (Test-Path $a) {
            $ha = (Get-FileHash $a -Algorithm MD5).Hash; $hb = (Get-FileHash $b -Algorithm MD5).Hash
            if ($ha -eq $hb) { Ok "$Repo/$f matches" } else { Bad "$Repo/$f differs from the project file" }
        }
    }
} else { Say ("[SKIP] no " + $Repo + " folder to compare") }

$report = ResolveFromRoot 'tests/pwa-check-report.txt'
$body = @("pwa install gate - " + (Get-Date).ToString('yyyy-MM-dd HH:mm'), "") + $script:lines
[System.IO.File]::WriteAllLines($report, $body, (New-Object System.Text.UTF8Encoding($false)))

Say ''
if ($script:fail) { Say "RESULT: $($script:fail) problem(s) - install path is broken"; exit 1 }
Say 'RESULT: pwa install path ok'
exit 0
