$log = Join-Path $PSScriptRoot "probe-steps.log"
function Step([string]$text) { $text | Out-File -FilePath $log -Append -Encoding utf8 }
Set-Content -Path $log -Value "start $(Get-Date -Format o)" -Encoding utf8
Add-Type -AssemblyName System.Windows.Forms
Step "forms ok"
Add-Type -AssemblyName System.Drawing
Step "drawing ok"
$b = New-Object System.Drawing.Bitmap(10, 10)
$g = [System.Drawing.Graphics]::FromImage($b)
$g.Clear([System.Drawing.Color]::Red)
$g.Dispose()
Step "bitmap ok"
[System.Windows.Forms.Clipboard]::SetImage($b)
Step "clipboard ok"
$b.Dispose()
Step "done"
