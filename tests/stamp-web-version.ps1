# ============================================================================
# Stamp the web build version (owner request 18 Sep 2026):
#   "let the app notice a newer web build by itself and reload - without
#    reinstalling the APK"
#
# How the id is built
#   id = first 10 hex chars of md5(index.html with the stamp line normalised to
#   a placeholder). It changes whenever anything else in the file changes and
#   never depends on its own value (no chicken-and-egg).
#
# Files touched
#   index.html    -> const APP_WEB_VERSION = '<id>';   (never edit by hand)
#   version.json  -> { "v": "<id>", "at": "...", "md5": "<md5 of index.html>" }
#   <repo>/version.json (if the taxi-repo folder exists)
#
# Usage
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests/stamp-web-version.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests/stamp-web-version.ps1 -Check
#     -Check is the release gate: it fails when index.html changed but nobody
#     re-stamped it, i.e. when the app would NOT notice the new build.
#
# NOTE: console output is ASCII on purpose (PowerShell 5.1 mis-reads Thai
#       literals in BOM-less .ps1 files and the whole script dies).
# ============================================================================
param(
    [string]$Root = '',
    [switch]$Check
)

if (-not $Root) { $Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path }
$indexPath = Join-Path $Root 'index.html'
$verPath = Join-Path $Root 'version.json'
$repoVerPath = Join-Path $Root 'taxi-repo\version.json'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$stampPattern = "const APP_WEB_VERSION = '[^']*';"

function Get-Md5Hex([byte[]]$bytes) {
    $md5 = [System.Security.Cryptography.MD5]::Create()
    return ([BitConverter]::ToString($md5.ComputeHash($bytes))).Replace('-', '').ToLower()
}
function Get-Md5OfText([string]$text) {
    return Get-Md5Hex $utf8.GetBytes($text)
}
function Get-Md5OfFile([string]$path) {
    return Get-Md5Hex ([System.IO.File]::ReadAllBytes($path))
}

if (-not (Test-Path $indexPath)) { Write-Host "FAIL: index.html not found at $indexPath"; exit 1 }

$text = [System.IO.File]::ReadAllText($indexPath, $utf8)
if (-not [regex]::IsMatch($text, $stampPattern)) {
    Write-Host 'FAIL: index.html has no "const APP_WEB_VERSION = ...;" line to stamp'
    exit 1
}
$currentStamp = ([regex]::Match($text, $stampPattern)).Value -replace "^const APP_WEB_VERSION = '", '' -replace "';$", ''
$normalised = [regex]::Replace($text, $stampPattern, "const APP_WEB_VERSION = '__STAMP__';")
$id = (Get-Md5OfText $normalised).Substring(0, 10)

if ($Check) {
    $problems = @()
    if (-not (Test-Path $verPath)) { $problems += 'version.json is missing (run tests/stamp-web-version.ps1)' }
    else {
        $ver = $null
        try { $ver = Get-Content -Raw -Encoding UTF8 $verPath | ConvertFrom-Json } catch { $problems += 'version.json is not valid JSON' }
        if ($ver) {
            if ($ver.v -ne $currentStamp) { $problems += "index.html stamp '$currentStamp' != version.json v '$($ver.v)'" }
            $md5Now = Get-Md5OfFile $indexPath
            if ($ver.md5 -ne $md5Now) { $problems += "version.json md5 '$($ver.md5)' != index.html md5 '$md5Now' (index.html changed without re-stamping)" }
            if ($currentStamp -ne $id) { $problems += "stamp '$currentStamp' is stale (expected '$id')" }
        }
    }
    $repoIndex = Join-Path $Root 'taxi-repo\index.html'
    if (Test-Path $repoIndex) {
        if ((Get-Md5OfFile $repoIndex) -ne (Get-Md5OfFile $indexPath)) { $problems += 'taxi-repo/index.html differs from index.html (copy it before committing)' }
        if (Test-Path $verPath) {
            $repoVer = Join-Path $Root 'taxi-repo\version.json'
            if (-not (Test-Path $repoVer)) { $problems += 'taxi-repo/version.json is missing (copy it before committing)' }
            elseif ((Get-Md5OfFile $repoVer) -ne (Get-Md5OfFile $verPath)) { $problems += 'taxi-repo/version.json differs from version.json' }
        }
    }
    if ($problems.Count) {
        Write-Host 'FAIL: web version stamp is not release-ready'
        foreach ($p in $problems) { Write-Host "  - $p" }
        exit 1
    }
    Write-Host "PASS: web version stamp OK (v=$currentStamp, md5 $((Get-Md5OfFile $indexPath).Substring(0,8)))"
    exit 0
}

# ---- stamp mode -----------------------------------------------------------
if ($currentStamp -eq $id) {
    $same = $false
    if (Test-Path $verPath) {
        try { $ver = Get-Content -Raw -Encoding UTF8 $verPath | ConvertFrom-Json; $same = ($ver.v -eq $id -and $ver.md5 -eq (Get-Md5OfFile $indexPath)) } catch {}
    }
    if ($same) {
        if (Test-Path (Join-Path $Root 'taxi-repo')) { [System.IO.File]::WriteAllText($repoVerPath, [System.IO.File]::ReadAllText($verPath, $utf8), $utf8) }
        Write-Host "PASS: stamp already current (v=$id) - nothing to do"
        exit 0
    }
}

$stamped = [regex]::Replace($text, $stampPattern, "const APP_WEB_VERSION = '$id';")
[System.IO.File]::WriteAllText($indexPath, $stamped, $utf8)
$md5File = Get-Md5OfFile $indexPath
$json = [ordered]@{
    v = $id
    at = (Get-Date).ToString('yyyy-MM-dd HH:mm')
    md5 = $md5File
    files = @('index.html')
    note = 'web build id - the running app compares this with its own APP_WEB_VERSION'
} | ConvertTo-Json -Compress
[System.IO.File]::WriteAllText($verPath, $json, $utf8)
if (Test-Path (Join-Path $Root 'taxi-repo')) { [System.IO.File]::WriteAllText($repoVerPath, $json, $utf8) }
Write-Host "PASS: stamped v=$id (index.html md5 $($md5File.Substring(0,8))) + version.json written"
exit 0
