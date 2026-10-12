#nullable enable
using System;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Blop.Core;

/// <summary>桌宠自己的持久状态（<c>run\pet.json</c>）：位置、以及谁派活给它。</summary>
/// <remarks>
/// 写入时**保留别的键**：这个文件是两种形态共用的（PowerShell 版还会往里写 auto / muted /
/// paused / dispatchAgent），要是这边写一次就把不认识的字段清掉，会出现"我改了那边设置、
/// 跑一次这边就没了"这种查起来很烦的问题。
/// </remarks>
public sealed class PetState
{
    private readonly string _path;

    public PetState(string path) => _path = path ?? "";

    public int? X { get; private set; }
    public int? Y { get; private set; }

    /// <summary>读。文件不存在/坏了都当"没有记录"，用默认位置。</summary>
    public static PetState Load(string path)
    {
        var st = new PetState(path);
        if (string.IsNullOrEmpty(path) || !File.Exists(path)) return st;
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(path));
            if (doc.RootElement.ValueKind != JsonValueKind.Object) return st;
            if (doc.RootElement.TryGetProperty("x", out var x) && x.ValueKind == JsonValueKind.Number) st.X = x.GetInt32();
            if (doc.RootElement.TryGetProperty("y", out var y) && y.ValueKind == JsonValueKind.Number) st.Y = y.GetInt32();
        }
        catch
        {
            // 坏文件不该让桌宠起不来
        }

        return st;
    }

    /// <summary>写回位置，其它键原样保留。</summary>
    public void Save(int x, int y)
    {
        if (string.IsNullOrEmpty(_path)) return;
        X = x;
        Y = y;
        try
        {
            var dir = Path.GetDirectoryName(_path);
            if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);

            JsonObject obj;
            if (File.Exists(_path))
            {
                try
                {
                    obj = JsonNode.Parse(File.ReadAllText(_path)) as JsonObject ?? new JsonObject();
                }
                catch
                {
                    obj = new JsonObject();
                }
            }
            else
            {
                obj = new JsonObject();
            }

            obj["x"] = x;
            obj["y"] = y;
            File.WriteAllText(_path, obj.ToJsonString(new JsonSerializerOptions { WriteIndented = false }), new UTF8Encoding(false));
        }
        catch
        {
            // 存不下位置不是致命问题（下次起来用默认位置），但别把桌宠弄崩
        }
    }
}
