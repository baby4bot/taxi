# android.jar gate: every Android framework class/constant the APK code references
# must really exist in the local android.jar.
#
# Why (20 Sep 2026):
#   This machine has NO JDK, so the Android side cannot be compiled locally:
#   a broken reference only shows up when CI builds the APK, i.e. after the push.
#   The "fingerprint unlock" round hit two real compile errors that this gate catches:
#     1) BiometricManager.BIOMETRIC_WEAK               -> lives in BiometricManager.Authenticators
#     2) BiometricPrompt.BIOMETRIC_ERROR_NEGATIVE_BUTTON -> that class has no such constant
#        (it only exists in androidx), so the file must use its own local constant.
#
# What it checks:
#   1) every `import android....` has a matching class inside android.jar
#   2) every `ClassName.CONSTANT` reference exists inside that class
#      (nested-class references such as BiometricManager.Authenticators.DEVICE_CREDENTIAL work)
#   No android.jar on this machine -> SKIP (never blocks the push).
param(
    [string]$Root = (Split-Path -Parent $PSScriptRoot),
    [string]$Jar = '',
    [string]$Report = ''
)

$ErrorActionPreference = 'Stop'
if (-not $Report) { $Report = Join-Path $PSScriptRoot 'android-api-check-report.txt' }
$lines = New-Object System.Collections.Generic.List[string]
function Say([string]$s) { Write-Host $s; [void]$lines.Add($s) }
function Save-Report { try { [System.IO.File]::WriteAllLines($Report, $lines, (New-Object System.Text.UTF8Encoding($false))) } catch {} }

Say '=== android.jar gate (framework classes / constants) ==='

# ---------- 1) locate android.jar ----------
$jarPath = ''
if ($Jar -and (Test-Path $Jar)) { $jarPath = (Resolve-Path $Jar).Path }
if (-not $jarPath) {
    $roots = @()
    if ($env:LOCALAPPDATA) { $roots += (Join-Path $env:LOCALAPPDATA 'Android\Sdk\platforms') }
    if ($env:ANDROID_HOME) { $roots += (Join-Path $env:ANDROID_HOME 'platforms') }
    if ($env:ANDROID_SDK_ROOT) { $roots += (Join-Path $env:ANDROID_SDK_ROOT 'platforms') }
    $roots += 'C:\Android\Sdk\platforms'
    foreach ($r in $roots) {
        if (-not (Test-Path $r)) { continue }
        $found = @(Get-ChildItem -Path $r -Filter 'android.jar' -Recurse -ErrorAction SilentlyContinue |
            Sort-Object @{ Expression = { if ($_.Directory.Name -eq 'android-34') { 0 } else { 1 } } }, Name)
        if ($found.Count) { $jarPath = $found[0].FullName; break }
    }
}
if (-not $jarPath) {
    Say 'SKIP: no android.jar on this machine (CI does the real compile)'
    Save-Report
    exit 0
}
Say ('android.jar: ' + $jarPath)

# ---------- 2) open the jar and index class entries ----------
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($jarPath)
$textCache = @{}
function Class-Text([string]$entryName) {
    if ($textCache.ContainsKey($entryName)) { return $textCache[$entryName] }
    $t = $null
    $e = $script:zip.Entries | Where-Object { $_.FullName -eq $entryName }
    if ($e) {
        $sr = New-Object IO.StreamReader($e.Open())
        $t = $sr.ReadToEnd()
        $sr.Close()
    }
    $textCache[$entryName] = $t
    return $t
}
$simple = New-Object 'System.Collections.Generic.Dictionary[string,System.Collections.Generic.List[string]]'
foreach ($e in $zip.Entries) {
    $fn = $e.FullName
    if ($fn -notlike '*.class') { continue }
    $last = $fn.Substring($fn.LastIndexOf('/') + 1)
    $s = $last.Substring(0, $last.Length - 6)
    if ($s.Contains('$')) { $s = $s.Substring($s.LastIndexOf('$') + 1) }
    if (-not $simple.ContainsKey($s)) { $simple[$s] = New-Object 'System.Collections.Generic.List[string]' }
    [void]$simple[$s].Add($fn)
}

# ---------- 3) collect our own class names (never checked against the jar) ----------
$javaFiles = @(Get-ChildItem -Path (Join-Path $Root 'android-app') -Filter '*.java' -Recurse -ErrorAction SilentlyContinue)
if (-not $javaFiles.Count) {
    Say 'SKIP: no java sources found under android-app'
    $zip.Dispose()
    Save-Report
    exit 0
}
$own = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($f in $javaFiles) { [void]$own.Add($f.BaseName) }
foreach ($n in @('R', 'BuildConfig')) { [void]$own.Add($n) }

$fails = New-Object System.Collections.Generic.List[string]
$skips = New-Object System.Collections.Generic.List[string]
$checkedImports = 0
$checkedConsts = 0

foreach ($f in $javaFiles) {
    $rel = $f.FullName.Substring($Root.Length + 1)
    $src = [System.IO.File]::ReadAllLines($f.FullName)

    # simple class name -> fully qualified name of this file's imports.
    # Only classes imported from `android.*` can be verified against android.jar;
    # androidx / third-party classes (e.g. androidx.car.app.model.Action) are skipped,
    # which also kills false positives from same-named helper classes.
    $imp = @{}
    foreach ($l in $src) {
        $mi = [regex]::Match($l, '^\s*import\s+(static\s+)?([A-Za-z0-9_.]+)\s*;')
        if ($mi.Success) {
            $fq = $mi.Groups[2].Value
            $leaf = $fq.Substring($fq.LastIndexOf('.') + 1)
            $imp[$leaf] = $fq
        }
    }

    for ($i = 0; $i -lt $src.Count; $i++) {
        $line = $src[$i]
        $n = $i + 1

        # 1) import android.x.y.Z must exist as android/x/y/Z.class
        foreach ($m in [regex]::Matches($line, '^\s*import\s+(android\.[A-Za-z0-9_.]+)\s*;')) {
            $fq = $m.Groups[1].Value
            $checkedImports++
            $entry = ($fq -replace '\.', '/') + '.class'
            if (-not ($zip.Entries | Where-Object { $_.FullName -eq $entry })) {
                $fails.Add('import not found in android.jar: ' + $fq + '  (' + $rel + ':' + $n + ')')
            }
        }

        # 2) X.CONSTANT (or X.Y.CONSTANT) must exist in the imported android.* class
        #    (nested classes count: Build.VERSION.SDK_INT is inside Build$VERSION)
        foreach ($m in [regex]::Matches($line, '(?<chain>[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*)\.(?<const>[A-Z][A-Z0-9_]{2,})\b')) {
            $chain = $m.Groups['chain'].Value -split '\.'
            $const = $m.Groups['const'].Value
            $cls = $chain[0]
            if ($own.Contains($cls)) { continue }
            if (-not $imp.ContainsKey($cls)) { $skips.Add(($chain -join '.') + '.' + $const + ' @ ' + $rel + ':' + $n); continue }
            $fq = $imp[$cls]
            if (-not $fq.StartsWith('android.')) { $skips.Add($fq + ' (not a framework class) @ ' + $rel + ':' + $n); continue }
            $checkedConsts++
            $path = ($fq -replace '\.', '/')
            if ($chain.Count -gt 1) {
                # explicit nested access: Outer.Nested.CONSTANT -> Outer$Nested.class
                $path += '$' + ($chain[1..($chain.Count - 1)] -join '$')
            }
            $entry = $path + '.class'
            $txt = Class-Text $entry
            $hitOk = ($null -ne $txt -and $txt.Contains($const))
            if (-not $hitOk -and $chain.Count -eq 1) {
                # not in the class itself, but maybe inside a nested class? then the member is
                # NOT reachable as Outer.CONSTANT (this is the BiometricManager.BIOMETRIC_WEAK trap)
                $nestedHit = ''
                foreach ($e2 in $zip.Entries) {
                    $p2 = $e2.FullName
                    if (-not $p2.StartsWith($path + '$')) { continue }
                    if (-not $p2.EndsWith('.class')) { continue }
                    $t2 = Class-Text $p2
                    if ($t2 -and $t2.Contains($const)) {
                        $nestedHit = $p2.Substring($p2.LastIndexOf('/') + 1)
                        break
                    }
                }
                if ($nestedHit) {
                    $fails.Add(('constant needs its nested class: ' + $fq + '.' + $const + '  (' + $rel + ':' + $n + ')') +
                               '  -> declared inside ' + $nestedHit.Replace('$', '.').Replace('.class', '') + ' -- write the full nested name')
                }
            }
            if (-not $hitOk -and -not $nestedHit) {
                $fails.Add('constant not found: ' + ($chain -join '.') + '.' + $const + '  (' + $rel + ':' + $n + ')' +
                           '  -> ' + $fq + ' has no such member')
            }
        }
    }
}

$zip.Dispose()

Say ('checked: ' + $checkedImports + ' import(s), ' + $checkedConsts + ' constant reference(s), skipped (not a jar class) ' + $skips.Count)
if ($fails.Count) {
    foreach ($x in $fails) { Say ('[FAIL] ' + $x) }
    Say ('RESULT: ' + $fails.Count + ' problem(s) - the Android code would not compile at CI')
    Save-Report
    exit 1
}
Say 'RESULT: ok - every framework class/constant exists'
Save-Report
exit 0
