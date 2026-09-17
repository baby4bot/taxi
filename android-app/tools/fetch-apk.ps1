# ============================================================
#  fetch-apk.ps1 � ดึงไฟล์ APK ตัวล่าสุดจาก GitHub Release
#  มาวางไว้ในโฟล�ดอร์โปร�จกต์ (โฟล�ดอร์�ดียวกับ index.html)
# ============================================================
#  ทำไมต้องมี: �ู้ใช้ส่งไฟล์ .apk จากคอมพิว�ตอร์�ข้าโทรศัพท์�อง
#  �� ไฟล์ต้องอยู่ในโฟล�ดอร์ที่หา�จอง่าย ไม่ใช่ซ่อนอยู่หลังลิงก์ GitHub
#
#  วิธีรัน (จากรากโปร�จกต์):
#    powershell -NoProfile -ExecutionPolicy Bypass -File android-app/tools/fetch-apk.ps1
#    powershell ... -File android-app/tools/fetch-apk.ps1 -SelfTest     # ทดสอบตรรกะ (ไม่ต้องมี�น็ต)
#    powershell ... -File android-app/tools/fetch-apk.ps1 -Force        # ทับ�สมอ (ข้ามด่าน)
#
#  �ลลัพธ์ในโฟล�ดอร์โปร�จกต์:
#    ค่าแท็กซี่.apk        �� ไฟล์ติดตั้ง (ทับ�ฉพาะไฟล์ที่ "ติดตั้งทับได้จริง")
#    ค่าแท็กซี่-info.txt   �� ชื่อแอป/ไอคอน/sha256/กุญแจ (อ่านจากในไฟล์ APK �อง)
#
#  🛡️ ด่านกันไฟล์แย่ทับไฟล์ดี (�ู้ใช้ขอ 18 ก.ย. 69)
#    ถ้า APK ที่โหลดมา�ซ็นด้วย "กุญแจชั่วคราว" (ยังไม่ได้ตั้ง Secrets) มันจะติดตั้งทับ
#    แอปใน�ครื่อง�ู้ใช้ไม่ได้ �� สคริปต์จะ **ไม่ทับ** ไฟล์�ดิมที่ติดตั้งได้อยู่ และอธิบายวิธีแก้
#    �หตุการณ์จริง: lิงก์ Release �ป็นงาน #9 (กุญแจชั่วคราว) แต่ไฟล์ในโฟล�ดอร์�ป็นงาน #8
#    (กุญแจตรงกับแอปใน�ครื่อง) � ถ้าทับทันทีจะได้ไฟล์ที่ติดตั้งไม่ได้โดยไม่มีใครรู้
#
#  ��️ ถ้าไฟล์ไม่ถูกแทนที่ ให้ดูว่า Release ยัง build ไม่�สร็จ (สคริปต์จะปฏิ�สธไฟล์ที่ดูไม่ใช่ APK)
#     หรือยังไม่ได้ตั้ง Secrets (สคริปต์จะบอกตรง ๆ)
# ------------------------------------------------------------

[CmdletBinding()]
param(
    # ข้ามด่านความปลอดภัย: ทับไฟล์�ดิมทุกกรณี (ใช้�ฉพาะ�มื่อรู้แน่ว่าต้องการของจาก Release)
    [switch]$Force,
    # ทดสอบตรรกะตัดสินใจด้วย�คสจำลอง (ไม่ต้องมี�น็ต/ไม่แตะไฟล์)
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# android-app/tools �� android-app �� รากโปร�จกต์
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$base = 'https://github.com/baby4bot/taxi/releases/download/apk-latest'

$apkPath = Join-Path $root 'ค่าแท็กซี่.apk'
$infoPath = Join-Path $root 'ค่าแท็กซี่-info.txt'
$fpPath = Join-Path $root 'android-app/signing-key-fingerprint.txt'

# ============================================================
#  🧠 ตรรกะตัดสินใจ (ฟังก์ชันล้วน � ไม่แตะ�น็ต/ไฟล์ �� ทดสอบได้)
# ============================================================
function Get-ApkKeyVerdict {
    param(
        [string]$InfoText,
        [string]$ExpectedFingerprint
    )
    $expected = ($ExpectedFingerprint -replace '[^0-9a-fA-F]', '').ToLower()
    $out = @{ Kind = 'unknown'; Fingerprint = ''; Expected = $expected }
    if ([string]::IsNullOrWhiteSpace($InfoText)) { return $out }

    $m = [regex]::Match($InfoText, 'Signer #1 certificate SHA-256 digest:\s*([0-9a-fA-F:]+)')
    if ($m.Success) { $out.Fingerprint = ($m.Groups[1].Value -replace '[^0-9a-fA-F]', '').ToLower() }

    # 1) ประกาศโหมดมา�อง = �ชื่อได้ที่สุด
    if ($InfoText -match 'โหมดกุญแจ:\s*ถาวร') { $out.Kind = 'permanent'; return $out }
    if ($InfoText -match 'โหมดกุญแจ:\s*ชั่วคราว') { $out.Kind = 'temporary'; return $out }

    # 2) ไม่มีบรรทัดโหมด (ไฟล์�ก่ากว่ารุ่นที่�พิ่มฟี�จอร์นี้) �� �ทียบลายนิ้วมือที่ประกาศไว้
    if ($out.Fingerprint -and $expected) {
        if ($out.Fingerprint -eq $expected) { $out.Kind = 'permanent' }
        else { $out.Kind = 'mismatch' }
    }
    return $out
}

# ไฟล์�ดิม "น่าจะติดตั้งได้" ไหม � ถ้าไม่มี/ไฟล์พัง ก็ไม่มีอะไร�สียหายให้ปกป้อง
function Test-LooksLikeApk {
    param([string]$Path)
    try {
        $fi = Get-Item $Path
        if ($fi.Length -lt 5000) { return $false }
        $fs = [IO.File]::OpenRead($Path)
        try {
            $head = New-Object byte[] 2
            $null = $fs.Read($head, 0, 2)
        } finally { $fs.Close() }
        return ([char]$head[0] -eq 'P' -and [char]$head[1] -eq 'K')
    } catch { return $false }
}

function Get-FileSha256 {
    param([string]$Path)
    try { return (Get-FileHash -Algorithm SHA256 $Path).Hash.ToLower() } catch { return '' }
}

function Write-SecretsHelp {
    Write-Host ''
    Write-Host '👉 วิธีแก้ (ทำครั้ง�ดียว ใช้ได้ตลอด):' -ForegroundColor Cyan
    Write-Host '   1) https://github.com/baby4bot/taxi/settings/secrets/actions �� New repository secret'
    Write-Host '      � ชื่อ KEYSTORE_BASE64   = คัดลอกทั้งไฟล์ .freebuff/signing-key/secret-KEYSTORE_BASE64.txt'
    Write-Host '      � ชื่อ KEYSTORE_PASSWORD = คัดลอกทั้งไฟล์ .freebuff/signing-key/secret-KEYSTORE_PASSWORD.txt'
    Write-Host '   2) ไปที่ Actions �� งาน "Build Android APK" �� Run workflow (หรือ Re-run งาน�ดิม)'
    Write-Host '   3) กลับมารันสคริปต์นี้อีกครั้ง �� APK ใหม่จะ "ติดตั้งทับของ�ดิมได้" และถูกวางในโฟล�ดอร์ให้'
}

# ============================================================
#  🧪 โหมดทดสอบตัว�อง (ไม่ต้องมี�น็ต · ไม่แตะไฟล์จริง)
# ============================================================
if ($SelfTest) {
    $exp = '74449ae235baf1ef2e668dae363230366f7d07dfe7f100962068f5cc934aefbe'
    $cases = @(
        @{ name = 'บรรทัด "ถาวร" �� อนุญาต';            info = "โหมดกุญแจ: ถาวร (มาจาก Secrets) � ติดตั้งทับของ�ดิมได้ �"; want = 'permanent' },
        @{ name = 'บรรทัด "ชั่วคราว" �� ปฏิ�สธ';        info = "โหมดกุญแจ: ชั่วคราว (สร้างใหม่ทุกบิลด์) �� ติดตั้งทับของ�ดิม ไม่ได้ � ตั้ง Secrets ก่อน"; want = 'temporary' },
        @{ name = 'ไม่มีบรรทัดโหมด + ลายนิ้วมือตรง';   info = "Signer #1 certificate SHA-256 digest: 74449ae235baf1ef2e668dae363230366f7d07dfe7f100962068f5cc934aefbe"; want = 'permanent' },
        @{ name = 'ไม่มีบรรทัดโหมด + ลายนิ้วมือ�ิด';   info = "Signer #1 certificate SHA-256 digest: c6a873cf808cca132ccf3a978c78cc053bfea6c8188c5747dda5e0e69f17e778"; want = 'mismatch' },
        @{ name = 'ลายนิ้วมือคั่นด้วย ":" ยังอ่านได้';  info = "Signer #1 certificate SHA-256 digest: 74:44:9A:E2:35:BA:F1:EF:2E:66:8D:AE:36:32:30:36:6F:7D:07:DF:E7:F1:00:96:20:68:F5:CC:93:4A:EF:BE"; want = 'permanent' },
        @{ name = 'ไฟล์ข้อมูลว่าง �� ไม่รู้';            info = ''; want = 'unknown' },
        @{ name = 'ไฟล์มีแต่ชื่อแอป �� ไม่รู้';          info = "application-label:'ค่าแท็กซี่'"; want = 'unknown' }
    )
    $bad = 0
    Write-Host '=== ทดสอบตรรกะตัดสินใจ (ไม่ต้องมี�น็ต) ==='
    foreach ($c in $cases) {
        $got = (Get-ApkKeyVerdict -InfoText $c.info -ExpectedFingerprint $exp).Kind
        if ($got -eq $c.want) { Write-Host ("[PASS] {0} �� {1}" -f $c.name, $got) }
        else { $bad++; Write-Host ("[FAIL] {0} �� ได้ {1} คาด {2}" -f $c.name, $got, $c.want) -ForegroundColor Red }
    }
    Write-Host ''
    if ($bad) { Write-Host ("RESULT: ล้ม�หลว {0} �คส" -f $bad) -ForegroundColor Red; exit 1 }
    Write-Host ("RESULT: �่านครบ {0} �คส � ตรรกะกันกุญแจชั่วคราวทำงานถูกต้อง" -f $cases.Count)
    exit 0
}

# ============================================================
#  ทำงานจริง
# ============================================================
$expectedFp = ''
if (Test-Path $fpPath) { $expectedFp = (Get-Content -Raw $fpPath).Trim() }

$tmp = Join-Path $env:TEMP ('taxi-apk-' + [guid]::NewGuid().ToString('N') + '.apk')
$tmpInfo = Join-Path $env:TEMP ('taxi-apk-info-' + [guid]::NewGuid().ToString('N') + '.txt')

$apkUrl = "$base/app-release.apk"
Write-Host "download: $apkUrl"
Invoke-WebRequest -Uri $apkUrl -OutFile $tmp -UseBasicParsing

# 🧪 ด่านกันไฟล์�ิด: APK ต้อง�ป็นซิป (ขึ้นต้นด้วย PK) และต้องไม่�ล็กจน�ิดปกติ
$len = (Get-Item $tmp).Length
if ($len -lt 5000 -or -not (Test-LooksLikeApk $tmp)) {
    Remove-Item $tmp -Force
    throw "ไฟล์ที่โหลดมาไม่�หมือน APK ($len ไบต์) � Release อาจยัง build ไม่�สร็จ"
}

# ข้อมูลกำกับ (มีลายนิ้วมือกุญแจ/โหมด) � ไฟล์�ก่าอาจไม่มี
$infoText = ''
try {
    Invoke-WebRequest -Uri "$base/apk-info.txt" -OutFile $tmpInfo -UseBasicParsing
    $infoText = Get-Content -Raw -Encoding UTF8 $tmpInfo
} catch {
    Write-Host '(ยังไม่มี apk-info.txt ใน Release � จะตัดสินจากไฟล์�ดิมอย่างระวัง)'
}

$verdict = Get-ApkKeyVerdict -InfoText $infoText -ExpectedFingerprint $expectedFp
$newSha = Get-FileSha256 $tmp
$haveOld = Test-Path $apkPath
$oldOk = $haveOld -and (Test-LooksLikeApk $apkPath)
$oldSha = if ($haveOld) { Get-FileSha256 $apkPath } else { '' }

Write-Host ("โหมดกุญแจของไฟล์ที่โหลดมา : {0}{1}" -f $verdict.Kind, $(if ($verdict.Fingerprint) { ' (' + $verdict.Fingerprint.Substring(0, 16) + '�)' } else { '' }))

# ไฟล์�ดิม�ป็นตัว�ดียวกันอยู่แล้ว �� ไม่ต้องทำอะไร (แต่ยังอัป�ดต info ให้ตรง)
if ($oldOk -and $newSha -and $newSha -eq $oldSha) {
    Write-Host 'ไฟล์ในโฟล�ดอร์�ป็นตัว�ดียวกันกับ Release อยู่แล้ว � ไม่ต้องแทนที่'
    Move-Item -Force $tmp $apkPath
    if ($infoText) { Move-Item -Force $tmpInfo $infoPath } else { Remove-Item $tmpInfo -Force -ErrorAction SilentlyContinue }
    exit 0
}

# 🛡️ ด่านสำคัญ: อย่า�อาตัวที่ติดตั้งทับไม่ได้มาทับตัวที่ติดตั้งได้
$refuse = ''
if ($oldOk -and -not $Force) {
    switch ($verdict.Kind) {
        'permanent' { }
        'temporary' { $refuse = 'APK ที่โหลดมา�ซ็นด้วย กุญแจชั่วคราว (ยังไม่ได้ตั้ง Secrets) �� �ครื่องที่ติดตั้งแอปอยู่จะอัป�ดตทับไม่ได้' }
        'mismatch'  { $refuse = 'APK ที่โหลดมา�ซ็นด้วยกุญแจ คนละดอก กับที่แอป�ู้ใช้ใช้อยู่ �� ติดตั้งทับได้แต่จะขึ้นว่า ติดตั้งไม่ได้' }
        default     { $refuse = 'อ่านข้อมูลกุญแจของ APK ที่โหลดมาไม่ได้ (Release ยังไม่มี apk-info.txt รุ่นใหม่) �� ตัดสินไม่ได้ว่าติดตั้งทับได้ไหม' }
    }
}

if ($refuse) {
    Remove-Item $tmp -Force
    Remove-Item $tmpInfo -Force -ErrorAction SilentlyContinue
    Write-Host ''
    Write-Host '�� ไม่ทับไฟล์�ดิม � �พราะ:' -ForegroundColor Yellow
    Write-Host "   $refuse"
    Write-Host ''
    Write-Host "   ไฟล์ที่�ก็บไว้ (ยังใช้ติดตั้งทับได้): $apkPath"
    Write-Host ("   sha256 �ดิม : {0}" -f $oldSha)
    Write-Host ("   ไฟล์ที่ปฏิ�สธ (release) : sha256 {0} · โหมด {1}" -f $newSha, $verdict.Kind)
    Write-SecretsHelp
    Write-Host ''
    Write-Host '   (ถ้าแน่ใจว่าต้องการไฟล์จาก Release จริง ๆ �� รันซ้ำด้วย -Force)' -ForegroundColor DarkGray
    exit 3
}

if ($Force -and $oldOk) {
    Write-Host '��️ -Force: ทับไฟล์�ดิมตามคำสั่ง (ข้ามด่านความปลอดภัย)' -ForegroundColor Yellow
}

Write-Host ("ไม่มีไฟล์�ดิมที่ติดตั้งได้ หรือไฟล์ใหม่�่านด่าน (โหมด {0}) �� แทนที่" -f $verdict.Kind)
Move-Item -Force $tmp $apkPath

$info = $infoText
if ($infoText) {
    Move-Item -Force $tmpInfo $infoPath
} else {
    $info = $null
}

$sha = Get-FileSha256 $apkPath
Write-Host ''
Write-Host "saved  : $apkPath"
Write-Host "size   : $len bytes"
Write-Host "sha256 : $sha"
if ($verdict.Kind -eq 'permanent') {
    Write-Host 'กุญแจ : ถาวร �� ส่ง�ข้า�ครื่องแล้วติดตั้งทับของ�ดิมได้�ลย ไม่ต้องถอน' -ForegroundColor Green
} else {
    Write-Host 'กุญแจ : อาจติดตั้งทับของ�ดิมไม่ได้ � ตรวจบรรทัด โหมดกุญแจ ข้างล่าง' -ForegroundColor Yellow
}
if ($info) {
    Write-Host ''
    Write-Host '--- apk-info.txt (ข้อมูลจากในไฟล์ APK) ---'
    Write-Host $info.TrimEnd()
}
exit 0
