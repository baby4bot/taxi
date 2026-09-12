# ไฟล์ static file server ขนาดเล็ก (PowerShell, ไม่มี dependency) — ใช้รันการทดสอบอัตโนมัติแบบ local
# วิธีใช้:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests/static-server.ps1 -Root "G:\My Drive\HTML\freebuff\แท็กซี" -Port 58911
# แล้วเปิด http://127.0.0.1:58911/tests/catchup-regression.html
param(
    [string]$Root = (Get-Location).Path,
    [int]$Port = 58911
)
$Root = [System.IO.Path]::GetFullPath($Root)
$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
$listener.Start()
Write-Output "LISTENING $Port $Root"
$mimes = @{ '.html' = 'text/html; charset=utf-8'; '.js' = 'text/javascript; charset=utf-8'; '.css' = 'text/css; charset=utf-8'; '.json' = 'application/json'; '.png' = 'image/png'; '.svg' = 'image/svg+xml'; '.woff2' = 'font/woff2'; '.jpg' = 'image/jpeg'; '.ico' = 'image/x-icon'; '.txt' = 'text/plain; charset=utf-8'; '.md' = 'text/plain; charset=utf-8' }
while ($true) {
    $client = $listener.AcceptTcpClient()
    try {
        $stream = $client.GetStream()
        # ⏱️ กันเบราว์เซอร์เปิด connection ทิ้งไว้ (preconnect) แล้วไม่มี request ส่งมา — ถ้าไม่ตั้ง timeout เซิร์ฟเวอร์จะค้างรออ่านไม่สิ้นสุด
        #    ทำให้คำขอถัดไปต่อคิวรอนานจนเบราว์เซอร์ขึ้น error (chrome-error) ทั้งที่ไฟล์มีอยู่
        try { $client.ReceiveTimeout = 5000; $stream.ReadTimeout = 5000 } catch { }
        $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::ASCII)
        $line = $reader.ReadLine()
        $path = ''
        if ($line) { $parts = $line.Split(' '); if ($parts.Count -ge 2) { $path = [Uri]::UnescapeDataString($parts[1]) } }
        if ($path -eq '' -or $path -eq '/') { $path = '/index.html' }
        # ✂️ ตัด query string ออก (?a=1) — ถ้าไม่ตัด Join-Path/GetFullPath จะ throw (ตัวอักษร '?' ห้าม),
        #    แล้วเซิร์ฟเวอร์จะตอบเปล่า (curl ได้ 000 / เบราว์เซอร์เห็น chrome-error) แทนที่จะเสิร์ฟไฟล์
        $qi = $path.IndexOf('?')
        if ($qi -ge 0) { $path = $path.Substring(0, $qi) }
        $full = ''
        if ($path.Contains('..')) {
            $full = $null # ป้องกัน path traversal
        } else {
            $full = [System.IO.Path]::GetFullPath((Join-Path $Root $path.TrimStart('/')))
        }
        $ok = $false
        if ($full -and $full.StartsWith($Root)) {
            if (Test-Path -LiteralPath $full -PathType Container) { $full = Join-Path $full 'index.html' }
            if (Test-Path -LiteralPath $full) {
                $bytes = [System.IO.File]::ReadAllBytes($full)
                $ext = [System.IO.Path]::GetExtension($full).ToLower()
                $mime = if ($mimes.ContainsKey($ext)) { $mimes[$ext] } else { 'application/octet-stream' }
                $head = "HTTP/1.1 200 OK`r`nContent-Type: $mime`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`nCache-Control: no-store`r`n`r`n"
                $hb = [System.Text.Encoding]::ASCII.GetBytes($head)
                $stream.Write($hb, 0, $hb.Length); $stream.Write($bytes, 0, $bytes.Length)
                $ok = $true
            }
        }
        if (-not $ok) {
            $body = 'Not found'
            $bb = [System.Text.Encoding]::UTF8.GetBytes($body)
            $resp = "HTTP/1.1 404 Not Found`r`nContent-Type: text/plain`r`nContent-Length: $($bb.Length)`r`nConnection: close`r`n`r`n"
            $respB = [System.Text.Encoding]::ASCII.GetBytes($resp)
            $stream.Write($respB, 0, $respB.Length); $stream.Write($bb, 0, $bb.Length)
        }
    } catch { }
    finally { try { $client.Close() } catch { } }
}