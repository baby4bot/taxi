# Launcher for the local test server — handles the Thai project path robustly.
# Usage:  powershell -NoProfile -ExecutionPolicy Bypass -File tests/serve-tests.ps1
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$log  = Join-Path $root '.freebuff\testserver.log'
$err  = Join-Path $root '.freebuff\testserver.log.err'
$ps   = Join-Path $root 'tests\static-server.ps1'
$p = Start-Process -FilePath 'powershell.exe' `
    -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$ps`"",'-Root',"`"$root`"",'-Port','58911') `
    -RedirectStandardOutput $log -RedirectStandardError $err `
    -WindowStyle Hidden -PassThru
Write-Output "PID=$($p.Id)"
