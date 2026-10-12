#nullable enable
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Text.RegularExpressions;
using Blop.Core;

namespace Blop.Cases;

/// <summary>
/// 用例表里的"假世界"：这一条用例假定环境变量是什么、哪些路径存在、PATH 上有什么命令。
/// </summary>
/// <remarks>
/// 路径解析的规则之所以能测，全靠这一层把"外部世界"变成纯输入 ——
/// 否则只能测"在这台机器上解不解得出来"，而真正会出事的恰恰是**别的**机器
///（装在别处、只有 DSH 没有 node、PATH 上没有 dsh…）。
/// </remarks>
internal sealed class FakePathWorld : IPathWorld
{
    private readonly Dictionary<string, string> _env;
    private readonly HashSet<string> _exists;
    private readonly Dictionary<string, string> _commands;
    private readonly Dictionary<string, List<string>> _files;
    private readonly string _running;

    public FakePathWorld(JsonElement world, JsonElement defaults)
    {
        _env = Map(Pick(world, defaults, "env"));
        _exists = new HashSet<string>(StringArray(Pick(world, defaults, "exists")), StringComparer.OrdinalIgnoreCase);
        _commands = Map(Pick(world, defaults, "commands"));
        _running = Pick(world, defaults, "runningHarnessRoot") is { ValueKind: JsonValueKind.String } r
            ? r.GetString()!
            : "";
        _files = new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);
        var filesElement = Pick(world, defaults, "files");
        if (filesElement is { ValueKind: JsonValueKind.Object })
        {
            foreach (var p in filesElement.Value.EnumerateObject())
            {
                _files[p.Name] = p.Value.EnumerateArray().Select(v => v.GetString() ?? "").ToList();
            }
        }
    }

    public string Env(string name)
    {
        if (string.IsNullOrEmpty(name)) return "";
        return _env.TryGetValue(name, out var v) ? v.Trim() : "";
    }

    public bool Exists(string path) => !string.IsNullOrEmpty(path) && _exists.Contains(path);

    public string PathOf(string command)
        => !string.IsNullOrEmpty(command) && _commands.TryGetValue(command, out var v) ? v : "";

    public string RunningHarnessRoot() => _running;

    public IEnumerable<string> ListFiles(string dir, string pattern)
    {
        if (string.IsNullOrEmpty(dir) || !_files.TryGetValue(dir, out var names)) return Array.Empty<string>();
        var re = new Regex("^" + Regex.Escape(pattern).Replace(@"\*", ".*").Replace(@"\?", ".") + "$",
            RegexOptions.IgnoreCase);
        return names.Where(n => re.IsMatch(n)).Select(n => System.IO.Path.Combine(dir, n)).ToList();
    }

    /// <summary>用例写了就用用例的，没写就用 defaults 的。</summary>
    private static JsonElement? Pick(JsonElement world, JsonElement defaults, string key)
    {
        if (world.ValueKind == JsonValueKind.Object && world.TryGetProperty(key, out var v) && v.ValueKind != JsonValueKind.Null)
            return v;
        return defaults.TryGetProperty(key, out var d) ? d : null;
    }

    private static Dictionary<string, string> Map(JsonElement? e)
    {
        var map = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        if (e is not { ValueKind: JsonValueKind.Object }) return map;
        foreach (var p in e.Value.EnumerateObject()) map[p.Name] = p.Value.GetString() ?? "";
        return map;
    }

    private static List<string> StringArray(JsonElement? e)
        => e is { ValueKind: JsonValueKind.Array }
            ? e.Value.EnumerateArray().Select(v => v.GetString() ?? "").ToList()
            : new List<string>();
}
