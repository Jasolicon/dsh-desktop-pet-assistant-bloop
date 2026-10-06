# 生成一张**纯代码绘制**的主页插图（不依赖任何第三方素材，所以能跟着本项目一起分发）
#
# 用法：pwsh -NoProfile -ExecutionPolicy Bypass -File .\docs\images\make-hero.ps1
#
# ⚠️ 它**不是** README 现在那张主图。README 第一张图 `docs/images/pet.png` 是**实拍截图**
#    （见提交 50e98c8「README 主图换成实拍截图（金额打码）」），尺寸和这张完全不同。
#    所以输出名刻意叫 hero-code.png —— 别写成 pet.png，那会把 README 的真图覆盖掉（实测过：
#    两者一个 45KB 一个 141.5KB，不是同一张）。
#
# 留着的用处：需要一张"不依赖任何外部素材、可随仓库分发"的插图时，用它现画一张。
# 原先它躺在仓库根的 run\（临时目录）里，头部写的用法却一直是 docs\images\，现在归位。

Add-Type -AssemblyName System.Drawing

$out = Join-Path $PSScriptRoot 'hero-code.png'
$out = [System.IO.Path]::GetFullPath($out)
$W = 1200; $H = 420

$bmp = New-Object System.Drawing.Bitmap $W, $H
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit

$bgRect = New-Object System.Drawing.Rectangle 0, 0, $W, $H
$bg = New-Object System.Drawing.Drawing2D.LinearGradientBrush $bgRect, ([System.Drawing.Color]::FromArgb(232, 242, 255)), ([System.Drawing.Color]::White), 35.0
$g.FillRectangle($bg, $bgRect)
$bg.Dispose()

function New-RoundRect($x, $y, $w, $h, $r) {
  $p = New-Object System.Drawing.Drawing2D.GraphicsPath
  $d = $r * 2
  $p.AddArc($x, $y, $d, $d, 180, 90)
  $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
  $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
  $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
  $p.CloseFigure()
  return $p
}

# 影子
$sh = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(120, 201, 218, 240))
$g.FillEllipse($sh, 90, 396, 480, 26)
$sh.Dispose()

$bodyBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 110, 166, 238))

# 尾鳍
$tail = New-Object System.Drawing.Drawing2D.GraphicsPath
$tail.AddBezier(200, 300, 150, 268, 118, 236, 96, 226)
$tail.AddBezier(96, 226, 112, 272, 130, 292, 152, 302)
$tail.AddBezier(152, 302, 118, 318, 100, 352, 96, 372)
$tail.AddBezier(96, 372, 132, 360, 176, 332, 200, 310)
$tail.CloseFigure()
$g.FillPath($bodyBrush, $tail)
$tail.Dispose()

# 身体
$g.FillEllipse($bodyBrush, 150, 195, 360, 210)
$bodyBrush.Dispose()

# 肚子
$belly = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 236, 245, 255))
$g.FillEllipse($belly, 235, 250, 275, 145)
$belly.Dispose()

# 胸鳍
$fin = New-Object System.Drawing.Drawing2D.GraphicsPath
$fin.AddBezier(330, 352, 300, 382, 272, 400, 252, 406)
$fin.AddBezier(252, 406, 288, 410, 330, 396, 352, 378)
$fin.CloseFigure()
$finBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 92, 146, 222))
$g.FillPath($finBrush, $fin)
$finBrush.Dispose(); $fin.Dispose()

# 眼睛 + 高光
$eye = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 22, 50, 79))
$g.FillEllipse($eye, 428, 252, 34, 34)
$eye.Dispose()
$white = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
$g.FillEllipse($white, 436, 258, 12, 12)
$white.Dispose()

# 腮红
$blush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(150, 246, 160, 176))
$g.FillEllipse($blush, 462, 300, 44, 22)
$blush.Dispose()

# 微笑
$pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 22, 50, 79)), 5
$pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
$pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
$g.DrawArc($pen, 400, 288, 66, 46, 15, 150)
$pen.Dispose()

# 喷出的泡泡
$bubblePen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(200, 255, 255, 255)), 4
$b1 = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(150, 255, 255, 255))
$b2 = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(110, 255, 255, 255))
$g.FillEllipse($b1, 424, 116, 52, 52)
$g.DrawEllipse($bubblePen, 424, 116, 52, 52)
$g.FillEllipse($b2, 486, 78, 30, 30)
$g.DrawEllipse($bubblePen, 486, 78, 30, 30)
$g.FillEllipse($b2, 520, 126, 17, 17)
$pl = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(235, 255, 255, 255))
$g.FillEllipse($pl, 436, 128, 14, 14)
$g.FillEllipse($pl, 492, 84, 8, 8)
$pl.Dispose()
$b1.Dispose(); $b2.Dispose(); $bubblePen.Dispose()

# 气泡（带一点投影）
$bubbleShadow = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(70, 180, 200, 225))
$sp = New-RoundRect 616 96 540 212 30
$g.FillPath($bubbleShadow, $sp)
$sp.Dispose(); $bubbleShadow.Dispose()

$bp = New-RoundRect 610 90 540 212 30
$bubbleFill = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
$g.FillPath($bubbleFill, $bp)
$bsPen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 214, 226, 243)), 2
$g.DrawPath($bsPen, $bp)

# 气泡的小尾巴，指向鲸鱼
$bt = New-Object System.Drawing.Drawing2D.GraphicsPath
$tailPoints = New-Object 'System.Drawing.Point[]' 3
$tailPoints[0] = New-Object System.Drawing.Point 612, 168
$tailPoints[1] = New-Object System.Drawing.Point 556, 148
$tailPoints[2] = New-Object System.Drawing.Point 612, 206
$bt.AddPolygon($tailPoints)
$g.FillPath($bubbleFill, $bt)
$g.DrawLine($bsPen, 612, 168, 556, 148)
$g.DrawLine($bsPen, 556, 148, 612, 206)
$bt.Dispose(); $bubbleFill.Dispose(); $bp.Dispose(); $bsPen.Dispose()

# 文案
$f1 = New-Object System.Drawing.Font 'Microsoft YaHei', 32, ([System.Drawing.FontStyle]::Regular), ([System.Drawing.GraphicsUnit]::Pixel)
$f2 = New-Object System.Drawing.Font 'Microsoft YaHei', 21, ([System.Drawing.FontStyle]::Regular), ([System.Drawing.GraphicsUnit]::Pixel)
$t1 = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 23, 50, 79))
$t2 = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 132, 150, 172))
$g.DrawString('真该开口的那一次，', $f1, $t1, 656, 128)
$g.DrawString('它才吐个泡泡说一句。', $f1, $t1, 656, 178)
$g.DrawString('大多数时候，它什么都不说。', $f2, $t2, 660, 248)
$f1.Dispose(); $f2.Dispose(); $t1.Dispose(); $t2.Dispose()

$g.Dispose()
$bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Write-Output ("hero.png -> {0}  {1} KB" -f $out, [int]((Get-Item -LiteralPath $out).Length / 1024))
