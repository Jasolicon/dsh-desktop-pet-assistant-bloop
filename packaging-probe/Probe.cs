// 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
// Copyright (c) 2026 Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

// packaging-probe/Probe.cs —— 打包路线可行性探针（诊断用）
//
// 要回答的问题：这台机器上 Smart App Control 强制开启时，
//   **本地编译出来的、未签名的 WinForms exe 到底能不能跑？**
// 能 → WinForms / .NET 打包路线可用；不能 → 任何未签名 exe 路线都不可用，只能签名。
//
// 编译（不需要 .NET SDK，用 Windows 自带的 Framework 编译器）：
//   C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /nologo /target:exe ^
//     /out:probe.exe /r:System.Windows.Forms.dll /r:System.Drawing.dll Probe.cs
//
// 注意：这台机器的 csc 是 Framework 4.0 那版，只认 C# 5 —— 别用插值字符串等新语法。

using System;
using System.Drawing;
using System.Windows.Forms;

internal static class Probe
{
    [STAThread]
    private static void Main(string[] args)
    {
        Console.WriteLine("[probe] main entered, runtime = " + Environment.Version);
        Console.Out.Flush();

        bool gui = Array.IndexOf(args, "--no-ui") < 0;
        if (!gui)
        {
            Console.WriteLine("[probe] --no-ui, exiting");
            return;
        }

        Console.WriteLine("[probe] creating a WinForms window...");
        Console.Out.Flush();

        Form form = new Form();
        form.Text = "packaging probe";
        form.Size = new Size(420, 200);
        form.StartPosition = FormStartPosition.CenterScreen;
        form.TopMost = true;
        form.Paint += delegate(object s, PaintEventArgs e)
        {
            e.Graphics.DrawString("WinForms OK", new Font("Segoe UI", 22), Brushes.Black, 24, 60);
        };

        Timer timer = new Timer();
        timer.Interval = 3500;
        timer.Tick += delegate(object s, EventArgs e) { form.Close(); };
        timer.Start();

        Application.Run(form);
        Console.WriteLine("[probe] window closed normally -> WinForms 路线在这台机器上可用");
    }
}
