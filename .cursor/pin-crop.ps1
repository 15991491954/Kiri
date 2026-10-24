Add-Type -AssemblyName System.Drawing
$src = [System.Drawing.Image]::FromFile((Join-Path (Get-Location) ".cursor\desktop-full.png"))
$rect = New-Object System.Drawing.Rectangle 1950, 520, 500, 360
$crop = New-Object System.Drawing.Bitmap 1000, 720
$g = [System.Drawing.Graphics]::FromImage($crop)
$g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
$g.DrawImage($src, (New-Object System.Drawing.Rectangle 0,0,1000,720), $rect, [System.Drawing.GraphicsUnit]::Pixel)
$g.Dispose()
$crop.Save((Join-Path (Get-Location) ".cursor\pin-crop.png"), [System.Drawing.Imaging.ImageFormat]::Png)
$crop.Dispose(); $src.Dispose()
"ok"
