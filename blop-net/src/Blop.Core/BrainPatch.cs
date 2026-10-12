#nullable enable
using System;
using System.IO;
using System.Text;

namespace Blop.Core;

/// <summary>
/// 生成"让 DSH 用你已登录账号"的最小 patch。
/// </summary>
/// <remarks>
/// 为什么要它：DSH 各个 profile 默认走的是 `deepseek-official`（要 <c>DEEPSEEK_API_KEY</c> 环境变量），
/// 而桌宠用的是**你在 DSH 里已登录的账号**（<c>deepseek-account</c>）。把 provider 通过
/// <c>--patch</c> 注进去，就不用让用户再配一把 key —— 这正是 PowerShell 版
/// <c>dsh-agents.ps1</c> 里 <c>Write-AgentPatch</c> 干的事，这里只保留"模型"那一层。
///
/// ⚠️ 字段名是踩出来的：这条的 id 必须叫 <c>agent-default-model</c>；写错不会报错，
/// 只会静默不生效（然后你会看到 MISSING_CREDENTIAL，一脸问号）。
/// </remarks>
public static class BrainPatch
{
    /// <summary>把 patch 写到 <paramref name="path"/>，返回该路径。</summary>
    public static string Write(string path, string provider = "deepseek-account", string model = "deepseek-flash", string effort = "low")
    {
        var sb = new StringBuilder();
        sb.AppendLine("- id: agent-default-model");
        sb.AppendLine("  name: \"@deepseek-ai/dsh-agent-default-model\"");
        sb.AppendLine("  config:");
        sb.AppendLine("    provider: " + provider);
        sb.AppendLine("    model: " + model);
        if (!string.IsNullOrEmpty(effort)) sb.AppendLine("    reasoningEffort: " + effort);
        var dir = Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
        File.WriteAllText(path, sb.ToString(), new UTF8Encoding(false));
        return path;
    }
}
