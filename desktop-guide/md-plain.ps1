# 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
# Copyright (c) 2026 Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

# md-plain.ps1 —— 把 Markdown 压成纯文本（气泡 / 对话栏用）
#
# 为什么需要它：
#   气泡（DesktopGuide.ps1 的 DrawBubble）和对话栏（chat-panel.ps1 的 ChatBubbleView）
#   都是 GDI+ 自绘的纯文本控件（TextRenderer.DrawText），不会编译 Markdown。
#   模型只要输出 `**首选：…**`、`# 标题`、反引号，屏幕上就会原样出现这些符号。
#
# 取舍：要么真渲染，要么不渲染。
#   真渲染 = 在自绘控件里实现一套 Markdown 排版引擎（多字体混排、列表缩进、表格…），
#   而气泡只有一行两行的位置、字号 6pt，收益极低、出错面很大。
#   所以这里选「不渲染」：进控件之前把标记去掉，输出是干净的纯文本。
#
# 用法：. md-plain.ps1 ；然后 ConvertTo-PlainText $modelText

function ConvertTo-PlainText {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }

    $t = $Text -replace "`r`n", "`n" -replace "`r", "`n"

    # --- 块级 ---
    # 代码围栏：只删掉 ``` 那一行，代码本体保留
    $t = [regex]::Replace($t, '(?m)^[ \t]*```[^\n]*$', '')
    # 标题：去掉开头的 #
    $t = [regex]::Replace($t, '(?m)^[ \t]{0,3}#{1,6}[ \t]*', '')
    # 引用：去掉 >
    $t = [regex]::Replace($t, '(?m)^[ \t]{0,3}>[ \t]?', '')
    # 分割线 --- / *** / ___
    $t = [regex]::Replace($t, '(?m)^[ \t]*([-*_])[ \t]*(\1[ \t]*){2,}$', '')
    # 表格分隔行 |---|---|
    $t = [regex]::Replace($t, '(?m)^[ \t]*\|?[ \t]*:?-{2,}:?[ \t]*(\|[ \t]*:?-{2,}:?[ \t]*)*\|?[ \t]*$', '')
    # 无序列表 -> ·（有序列表 1. 原样保留，编号是有信息量的）
    $t = [regex]::Replace($t, '(?m)^([ \t]*)[-*+][ \t]+', '$1· ')
    # 表格：去掉首尾竖线，中间的 | 换成 ·
    $t = [regex]::Replace($t, '(?m)^[ \t]*\|(.+)\|[ \t]*$', '$1')
    $t = [regex]::Replace($t, '[ \t]*\|[ \t]*', ' · ')

    # --- 行内 ---
    # 图片 / 链接：只留可见文字
    $t = [regex]::Replace($t, '!\[([^\]]*)\]\([^)]*\)', '$1')
    $t = [regex]::Replace($t, '\[([^\]]*)\]\([^)]*\)', '$1')
    $t = [regex]::Replace($t, '<((?:https?|mailto):[^>\s]+)>', '$1')
    # 行内代码
    $t = [regex]::Replace($t, '`{1,3}([^`]*)`{1,3}', '$1')
    # 粗体 / 斜体 / 删除线。
    # 这里的负向断言不是洁癖：`**/*.js`（glob）和 `2 * 3`、`a_b_c`（代码）在纯文本里必须原样保留，
    # 所以要求强调标记「贴字」——两侧都紧挨着非空白、非 / 、非 * 的字符，才认为它是 Markdown 强调。
    $t = [regex]::Replace($t, '(?<![0-9A-Za-z*])\*\*\*(?=[^ \t\n/*])([^\n]*?)(?<=\S)\*\*\*(?![0-9A-Za-z*])', '$1')
    $t = [regex]::Replace($t, '(?<![0-9A-Za-z*])\*\*(?=[^ \t\n/*])([^\n]*?)(?<=\S)\*\*(?![0-9A-Za-z*])', '$1')
    $t = [regex]::Replace($t, '(?<![0-9A-Za-z*])\*(?=[^ \t\n/*])([^*\n]*?)(?<=\S)\*(?![0-9A-Za-z*])', '$1')
    # 下划线强调要格外小心：`__init__`、`_private` 这类标识符不能被当成 Markdown 吃掉，
    # 所以内容要是"一个裸标识符"就原样放过。
    $underscore = {
        param($m)
        $inner = $m.Groups[1].Value
        if ($inner -match '^[A-Za-z_][A-Za-z0-9_]*$') { return $m.Value }
        return $inner
    }
    $t = [regex]::Replace($t, '(?<![0-9A-Za-z_])__(?=[^ \t\n_/])([^\n]*?)(?<=\S)__(?![0-9A-Za-z_])', $underscore)
    $t = [regex]::Replace($t, '(?<![0-9A-Za-z_])_(?=[^ \t\n_/])([^_\n]*?)(?<=\S)_(?![0-9A-Za-z_])', $underscore)
    $t = [regex]::Replace($t, '~~(?=\S)([^\n]*?)(?<=\S)~~', '$1')
    # 反斜杠转义
    $t = [regex]::Replace($t, '\\([\\`*_{}\[\]()#+.!>~-])', '$1')
    # HTML 标签
    $t = [regex]::Replace($t, '</?[A-Za-z][^>\n]{0,80}>', '')

    # --- 收尾 ---
    $t = [regex]::Replace($t, '(?m)[ \t]+$', '')
    $t = [regex]::Replace($t, '\n{3,}', "`n`n")
    return $t.Trim()
}
