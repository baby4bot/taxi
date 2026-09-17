# ============================================================
#  make-icons.ps1 - build the Android launcher icons from a photo
# ============================================================
#  Run:  powershell -NoProfile -ExecutionPolicy Bypass -File tools/make-icons.ps1
#  Optional: pass a different source image path as the first argument.
#
#  Produces (all inside app/src/main/res):
#    mipmap-{mdpi,hdpi,xhdpi,xxhdpi,xxxhdpi}/ic_launcher.png           (square, 48/72/96/144/192)
#    mipmap-{...}/ic_launcher_round.png                                (circle masked, same sizes)
#    mipmap-{...}/ic_launcher_foreground.png                           (108dp canvas, 108/162/216/324/432)
#    mipmap-anydpi-v26/ic_launcher.xml + ic_launcher_round.xml         (adaptive icon)
#    values/ic_launcher_background.xml                                 (solid colour behind the photo)
#
#  NOTE: keep this file ASCII-only. Windows PowerShell 5.1 mis-reads Thai text
#        in a .ps1 that is saved as UTF-8 without BOM.
# ------------------------------------------------------------

param(
    [string]$Source = "C:\Users\RTX3060TI\Desktop\Gemini_Generated_Image_pvrinxpvrinxpvri.jpg"
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$res = Join-Path $PSScriptRoot '..\app\src\main\res'
$res = (Resolve-Path $res).Path

if (-not (Test-Path $Source)) { throw "Source image not found: $Source" }

# density folder -> (legacy size, adaptive canvas size)
$tiers = @(
    @{ dir = 'mipmap-mdpi';    legacy = 48;  canvas = 108 },
    @{ dir = 'mipmap-hdpi';    legacy = 72;  canvas = 162 },
    @{ dir = 'mipmap-xhdpi';   legacy = 96;  canvas = 216 },
    @{ dir = 'mipmap-xxhdpi';  legacy = 144; canvas = 324 },
    @{ dir = 'mipmap-xxxhdpi'; legacy = 192; canvas = 432 }
)

function New-SquareImage {
    param([System.Drawing.Image]$Img, [int]$Size, [bool]$Round, [string]$Path)
    $bmp = New-Object System.Drawing.Bitmap($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)

    if ($Round) {
        $clip = New-Object System.Drawing.Drawing2D.GraphicsPath
        $clip.AddEllipse(0, 0, $Size, $Size)
        $g.SetClip($clip)
    }

    # centre-crop the source to a square, then fill the whole target
    $side = [Math]::Min($Img.Width, $Img.Height)
    $sx = [int](($Img.Width - $side) / 2)
    $sy = [int](($Img.Height - $side) / 2)
    $srcRect = New-Object System.Drawing.Rectangle($sx, $sy, $side, $side)
    $dstRect = New-Object System.Drawing.Rectangle(0, 0, $Size, $Size)
    $g.DrawImage($Img, $dstRect, $srcRect, [System.Drawing.GraphicsUnit]::Pixel)

    $g.Dispose()
    $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
}

$img = [System.Drawing.Image]::FromFile((Resolve-Path $Source).Path)
$made = @()

try {
    foreach ($t in $tiers) {
        $dir = Join-Path $res $t.dir
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }

        $p1 = Join-Path $dir 'ic_launcher.png'
        New-SquareImage -Img $img -Size $t.legacy -Round $false -Path $p1
        $made += $p1

        $p2 = Join-Path $dir 'ic_launcher_round.png'
        New-SquareImage -Img $img -Size $t.legacy -Round $true -Path $p2
        $made += $p2

        # adaptive foreground: full-bleed photo on a 108dp canvas (launcher mask trims it)
        $p3 = Join-Path $dir 'ic_launcher_foreground.png'
        New-SquareImage -Img $img -Size $t.canvas -Round $false -Path $p3
        $made += $p3
    }
}
finally {
    $img.Dispose()
}

# adaptive icon descriptors
$anydpi = Join-Path $res 'mipmap-anydpi-v26'
if (-not (Test-Path $anydpi)) { New-Item -ItemType Directory -Path $anydpi | Out-Null }

$adaptive = @"
<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
</adaptive-icon>
"@
$adaptive = $adaptive -replace "`n", "`r`n" -replace "`r`r`n", "`r`n"

foreach ($name in @('ic_launcher.xml', 'ic_launcher_round.xml')) {
    $p = Join-Path $anydpi $name
    [System.IO.File]::WriteAllText($p, $adaptive, (New-Object System.Text.UTF8Encoding($false)))
    $made += $p
}

$bgXml = @"
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="ic_launcher_background">#0E5C2F</color>
</resources>
"@
$bgXml = $bgXml -replace "`n", "`r`n" -replace "`r`r`n", "`r`n"
$bgPath = Join-Path $res 'values\ic_launcher_background.xml'
[System.IO.File]::WriteAllText($bgPath, $bgXml, (New-Object System.Text.UTF8Encoding($false)))
$made += $bgPath

Write-Host ("icons written: " + $made.Count)
foreach ($m in $made) { Write-Host ("  " + $m.Substring($res.Length + 1)) }
