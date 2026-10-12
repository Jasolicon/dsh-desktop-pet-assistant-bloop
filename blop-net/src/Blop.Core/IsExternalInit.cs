#if NETFRAMEWORK
#nullable enable

namespace System.Runtime.CompilerServices;

/// <summary>
/// net48 上没有这个类型，而 <c>record</c> / <c>init</c> 需要它 —— C# 编译器会往
/// 生成的代码里引用 <see cref="IsExternalInit"/>，缺了它编 net48 就报
/// "IsExternalInit 未定义"。这是官方推荐的 polyfill，三行就够。
/// </summary>
internal static class IsExternalInit
{
}

#endif
