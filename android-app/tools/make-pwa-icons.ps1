# ============================================================
#  make-pwa-icons.ps1 - build the PWA icons (manifest.webmanifest)
# ============================================================
#  Why this exists: Chrome/Android only offers the "install" prompt when the
#  manifest is a REAL same-origin file with 192px + 512px PNG icons.
#  A `data:` manifest (what the app used to inject) is not installable.
#
#  Run:  powershell -NoProfile -ExecutionPolicy Bypass -File android-app/tools/make-pwa-icons.ps1
#  Optional: -Source <image>   -OutDir <folder>
#
#  Produces (default folder = the project root, next to index.html):
#    icon-192.png  icon-512.png                    full-bleed artwork  (purpose "any")
#    icon-maskable-192.png  icon-maskable-512.png  inset on brand green (purpose "maskable")
#
#  NOTE: keep this file ASCII-only (PowerShell 5.1 mis-reads Thai in no-BOM .ps1)
# ------------------------------------------------------------

param(
    [string]$Source = "C:\Users\RTX3060TI\Desktop\Gemini_Generated_Image_pvrinxpvrinxpvri.jpg",
    [string]$OutDir = ""
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

if (-not $OutDir) { $OutDir = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }  # tools -> android-app -> project root
if (-not (Test-Path $Source)) { throw "Source image not found: $Source" }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }

# brand green used by the Android adaptive icon background (res/values/ic_launcher_background.xml)
$brand = [System.Drawing.ColorTranslator]::FromHtml('#0E5C2F')

function Save-Icon {
    param([System.Drawing.Image]$Img, [int]$Size, [int]$InsetPercent, [string]$Path)
    $bmp = New-Object System.Drawing.Bitmap($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear($brand)

    $side = [Math]::Min($Img.Width, $Img.Height)
    $sx = [int](($Img.Width - $side) / 2)
    $sy = [int](($Img.Height - $side) / 2)
    $art = [int]($Size * $InsetPercent / 100)
    $off = [int](($Size - $art) / 2)
    $srcRect = New-Object System.Drawing.Rectangle($sx, $sy, $side, $side)
    $dstRect = New-Object System.Drawing.Rectangle($off, $off, $art, $art)
    $g.DrawImage($Img, $dstRect, $srcRect, [System.Drawing.GraphicsUnit]::Pixel)

    $g.Dispose()
    $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
}

$img = [System.Drawing.Image]::FromFile((Resolve-Path $Source).Path)
$made = @()
try {
    $jobs = @(
        @{ size = 192; inset = 100; name = 'icon-192.png' },           # any
        @{ size = 512; inset = 100; name = 'icon-512.png' },           # any
        # maskable: keep the car inside the safe zone so round/squircle masks never clip it
        @{ size = 192; inset = 80;  name = 'icon-maskable-192.png' },
        @{ size = 512; inset = 80;  name = 'icon-maskable-512.png' }
    )
    foreach ($j in $jobs) {
        $p = Join-Path $OutDir $j.name
        Save-Icon -Img $img -Size $j.size -InsetPercent $j.inset -Path $p
        $made += $p
    }
}
finally { $img.Dispose() }

Write-Host ("pwa icons written: " + $made.Count)
foreach ($m in $made) { Write-Host ("  " + $m + "  " + (Get-Item $m).Length + " bytes") }
