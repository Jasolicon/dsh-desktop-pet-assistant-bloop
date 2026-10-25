param([Parameter(Mandatory = $true)][string]$Lnk)

Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
public struct SHFILEINFO
{
    public IntPtr hIcon;
    public int iIcon;
    public uint dwAttributes;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
    public string szDisplayName;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 80)]
    public string szTypeName;
}

public static class ShellIcon
{
    [DllImport("shell32.dll", CharSet = CharSet.Auto)]
    public static extern IntPtr SHGetFileInfo(string path, uint attributes, ref SHFILEINFO info, uint infoSize, uint flags);

    [DllImport("user32.dll")]
    public static extern bool DestroyIcon(IntPtr icon);
}
"@

$info = New-Object SHFILEINFO
$size = [Runtime.InteropServices.Marshal]::SizeOf($info)
[void][ShellIcon]::SHGetFileInfo($Lnk, 0, [ref]$info, [uint32]$size, 0x100)
if ($info.hIcon -eq [IntPtr]::Zero) { throw "Shell returned no icon for $Lnk" }
try {
  $icon = [System.Drawing.Icon]::FromHandle($info.hIcon)
  $bitmap = $icon.ToBitmap()
  $out = Join-Path $PSScriptRoot '..\run\shortcut-icon-check.png'
  $bitmap.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
  Write-Output $out
  $bitmap.Dispose()
  $icon.Dispose()
} finally {
  [void][ShellIcon]::DestroyIcon($info.hIcon)
}
