param(
  [string]$Source
)

Add-Type -AssemblyName System.Drawing

if (-not $Source) { $Source = Join-Path $PSScriptRoot '..\assets\pet.png' }
$resolvedSource = (Resolve-Path $Source).Path
$outPath = Join-Path (Split-Path -Parent $resolvedSource) 'deepseek.ico'

$sizes = @(16, 24, 32, 48, 64, 128, 256)
$images = @()
$sourceImage = [System.Drawing.Image]::FromFile((Resolve-Path $Source))

try {
  foreach ($size in $sizes) {
    $bitmap = [System.Drawing.Bitmap]::new($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
      $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
      $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
      $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality

      # DeepSeek-blue ellipse; simple drawing works in Windows PowerShell 5.1.
      $graphics.FillEllipse([System.Drawing.Brushes]::DarkSlateBlue, 0, 0, $size - 1, $size - 1)

      # Preserve the character aspect ratio with a little padding.
      $pad = [single]($size * 0.10)
      $box = [single]($size - $pad * 2)
      $scale = [Math]::Min($box / $sourceImage.Width, $box / $sourceImage.Height)
      $drawWidth = [single]($sourceImage.Width * $scale)
      $drawHeight = [single]($sourceImage.Height * $scale)
      $dest = [System.Drawing.RectangleF]::new(
        [single](($size - $drawWidth) / 2),
        [single](($size - $drawHeight) / 2),
        $drawWidth,
        $drawHeight
      )
      $srcRect = [System.Drawing.RectangleF]::new(0, 0, $sourceImage.Width, $sourceImage.Height)
      $graphics.DrawImage($sourceImage, $dest, $srcRect, [System.Drawing.GraphicsUnit]::Pixel)
    } finally {
      $graphics.Dispose()
    }

    # Build classic DIB ICO data; PNG-compressed ICO can fall back to a generic shell icon.
    $workBmp = 'icon-work.bmp'
    try {
      $bitmap.Save([string]$workBmp, [System.Drawing.Imaging.ImageFormat]::Bmp)
      $bmp = [System.IO.File]::ReadAllBytes([string]$workBmp)
      $dib = [byte[]]::new($bmp.Length - 14)
      [Array]::Copy($bmp, 14, $dib, 0, $dib.Length)
      # ICO DIB height covers XOR image plus AND mask.
      $heightBytes = [BitConverter]::GetBytes([int]($size * 2))
      [Array]::Copy($heightBytes, 0, $dib, 8, 4)
      $maskRow = [int]([Math]::Ceiling($size / 8))
      $maskRow = [int]([Math]::Ceiling($maskRow / 4) * 4)
      $mask = [byte[]]::new($size * $maskRow)
      $dib = $dib + $mask
      $images += ,$dib
    } finally {
      if (Test-Path -LiteralPath 'icon-work.bmp') { Remove-Item -LiteralPath 'icon-work.bmp' -Force }
      $bitmap.Dispose()
    }
  }
} finally {
  $sourceImage.Dispose()
}

# ICO directory + DIB entries.
$offset = 6 + 16 * $sizes.Count
$fileStream = [System.IO.File]::Open($outPath, [System.IO.FileMode]::Create)
$binaryWriter = New-Object System.IO.BinaryWriter($fileStream)
try {
  $binaryWriter.Write([uint16]0)
  $binaryWriter.Write([uint16]1)
  $binaryWriter.Write([uint16]$sizes.Count)
  for ($i = 0; $i -lt $sizes.Count; $i++) {
    $dimension = if ($sizes[$i] -ge 256) { 0 } else { $sizes[$i] }
    $binaryWriter.Write([byte]$dimension)
    $binaryWriter.Write([byte]$dimension)
    $binaryWriter.Write([byte]0)
    $binaryWriter.Write([byte]0)
    $binaryWriter.Write([uint16]1)
    $binaryWriter.Write([uint16]32)
    $binaryWriter.Write([uint32]$images[$i].Length)
    $binaryWriter.Write([uint32]$offset)
    $offset += $images[$i].Length
  }
  foreach ($image in $images) { $binaryWriter.Write([byte[]]$image) }
} finally {
  $binaryWriter.Dispose()
  $fileStream.Dispose()
}

Write-Output "Wrote $outPath"
