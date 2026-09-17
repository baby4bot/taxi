# ============================================================
#  fetch-apk.ps1 — ดึงไฟล์ APK ตัวล่าสุดจาก GitHub Release
#  มาวางไว้ในโฟลเดอร์โปรเจกต์ (โฟลเดอร์เดียวกับ index.html)
# ============================================================
#  ทำไมต้องมี: ผู้ใช้ส่งไฟล์ .apk จากคอมพิวเตอร์เข้าโทรศัพท์เอง
#  ⇒ ไฟล์ต้องอยู่ในโฟลเดอร์ที่หาเจอง่าย ไม่ใช่ซ่อนอยู่หลังลิงก์ GitHub
#
#  วิธีรัน (จากรากโปรเจกต์):
#    powershell -NoProfile -ExecutionPolicy Bypass -File android-app/tools/fetch-apk.ps1
#
#  ผลลัพธ์ในโฟลเดอร์โปรเจกต์:
#    ค่าแท็กซี่.apk        ← ไฟล์ติดตั้ง (ทับของเดิมทุกครั้ง = ตัวล่าสุดเสมอ)
#    ค่าแท็กซี่-info.txt   ← ชื่อแอป/ไอคอน/sha256/เวลาสร้าง (อ่านจากในไฟล์ APK เอง)
#
#  ⚠️ ถ้าไฟล์ไม่ถูกแทนที่ ให้ดูว่า Release ยัง build ไม่เสร็จ (สคริปต์จะปฏิเสธไฟล์ที่ดูไม่ใช่ APK)
# ------------------------------------------------------------

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# android-app/tools → android-app → รากโปรเจกต์
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$base = 'https://github.com/baby4bot/taxi/releases/download/apk-latest'

$apkPath = Join-Path $root 'ค่าแท็กซี่.apk'
$infoPath = Join-Path $root 'ค่าแท็กซี่-info.txt'
$tmp = Join-Path $env:TEMP ('taxi-apk-' + [guid]::NewGuid().ToString('N') + '.apk')

$apkUrl = "$base/app-release.apk"
Write-Host "download: $apkUrl"
Invoke-WebRequest -Uri $apkUrl -OutFile $tmp -UseBasicParsing

# 🧪 ด่านกันไฟล์ผิด: APK ต้องเป็นซิป (ขึ้นต้นด้วย PK) และต้องไม่เล็กจนผิดปกติ
$len = (Get-Item $tmp).Length
$fs = [IO.File]::OpenRead($tmp)
$head = New-Object byte[] 2
$null = $fs.Read($head, 0, 2)
$fs.Close()
$isZip = ([char]$head[0] -eq 'P' -and [char]$head[1] -eq 'K')
if ($len -lt 5000 -or -not $isZip) {
    Remove-Item $tmp -Force
    throw "ไฟล์ที่โหลดมาไม่เหมือน APK ($len ไบต์ · zip=$isZip) — Release อาจยัง build ไม่เสร็จ"
}

Move-Item -Force $tmp $apkPath

$info = $null
try {
    Invoke-WebRequest -Uri "$base/apk-info.txt" -OutFile $infoPath -UseBasicParsing
    $info = Get-Content -Raw -Encoding UTF8 $infoPath
} catch {
    Write-Host "(ยังไม่มี apk-info.txt ใน Release — ข้าม)"
}

$sha = (Get-FileHash -Algorithm SHA256 $apkPath).Hash.ToLower()
Write-Host ''
Write-Host "saved  : $apkPath"
Write-Host "size   : $len bytes"
Write-Host "sha256 : $sha"
if ($info) {
    Write-Host ''
    Write-Host '--- apk-info.txt (ข้อมูลจากในไฟล์ APK) ---'
    Write-Host $info.TrimEnd()
}
