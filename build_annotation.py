# 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
# Copyright (c) 2026 Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

# -*- coding: utf-8 -*-
"""
构建「实时通话指导副驾」v0.3 验证用的标注与统计工作簿。

v0.3 结构（按用户要求：不考虑是否执行选项，只考虑用户行动后软件干什么）：
  - 表1 动作事件：A1-A6
  - 表2 状态快照：每个动作后的状态
  - 表3 响应事件：R0-R5（含 R0 沉默）
  - 表4 人工核对：状态准确率（仅 20 通）
  - 统计：沉默比 / 触发覆盖率 / 状态准确率 / 响应延迟 / R2假阳性
  - 阈值：参数与判死标准

用法：
    & "<bundled python>" ".\build_annotation.py"
产出：
    .\通话指导标注表_v0.3.xlsx
"""

import os
import sys

import xlsxwriter

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "通话指导标注表_v0.3.xlsx")

N = 300  # 每表预留行数

ACTIONS = ["A1 用户说了一段", "A2 用户提了问题", "A3 用户切换话题",
           "A4 沉默变长", "A5 议程走完一项", "A6 收口动作"]
ACTION_CODES = ["A1", "A2", "A3", "A4", "A5", "A6"]

RESPONSES = ["R0 沉默", "R1 确认", "R2 阻断纠错", "R3 决策点选项",
             "R4 前瞻提示", "R5 议程结转"]
RESPONSE_CODES = ["R0", "R1", "R2", "R3", "R4", "R5"]

STAGES = ["开场", "探需", "方案", "异议", "收口", "结束"]

# ---------------- 表1 动作事件 ----------------
A_HEADERS = ["通话ID", "动作时间戳(秒)", "动作类型", "原文片段",
             "触发来源", "是否关键动作(人工金标准)", "备注"]

# ---------------- 表2 状态快照 ----------------
S_HEADERS = ["通话ID", "动作时间戳(秒)", "阶段", "议题列表", "客户立场",
             "未决事项", "已说承诺", "检测到的矛盾", "上一个动作", "备注"]

# ---------------- 表3 响应事件 ----------------
R_HEADERS = ["通话ID", "响应时间戳(秒)", "响应类型", "输出内容",
             "依据", "置信度(1-5)", "是否假阳性(R2专用)", "是否被抑制", "备注"]

# ---------------- 表4 人工核对 ----------------
C_HEADERS = ["通话ID", "动作时间戳(秒)", "人工判定状态", "系统状态",
             "是否一致", "差异类型", "差异说明"]

PARAMS = [
    ("沉默比下限", 0.70, "pct", "低于此值说明触发太宽，产品是噪音源"),
    ("状态准确率下限", 0.80, "pct", "最致命的一条：状态不准，后面全建立在错误前提上"),
    ("触发覆盖率下限", 0.50, "pct", "低于此值说明系统没在听"),
    ("判死用覆盖率", 0.30, "pct", "低于此值直接判死"),
    ("响应延迟P95上限(秒)", 1.5, "num", "过期响应比没有响应更糟"),
    ("判死用延迟(秒)", 3.0, "num", "超过此值直接判死"),
    ("R2假阳性上限", 0.20, "pct", "阻断纠错错了最伤信任，它拿着最高优先级"),
    ("R1占比上限", 0.20, "pct", "超过说明系统在空转，状态没有实质推进"),
    ("单通话响应上限(不含R0)", 12, "int", "超过说明触发太宽"),
    ("R2每通上限", 3, "int", "超过说明判据太松"),
    ("单组选项数上限", 4, "int", "超过出现选择瘫痪"),
    ("常驻显示响应数", 1, "int", "视野边缘的注意力预算"),
    ("刷新频率上限(次/30秒)", 1, "int", "画面抖动比误报更烦人"),
]


def base_formats(wb):
    return {
        "title": wb.add_format({"bold": True, "font_size": 13, "font_color": "#1F4E79"}),
        "note": wb.add_format({"font_size": 9, "font_color": "#595959",
                               "italic": True, "text_wrap": True, "valign": "top"}),
        "hdr": wb.add_format({"bold": True, "bg_color": "#1F4E79", "font_color": "#FFFFFF",
                              "align": "center", "valign": "vcenter",
                              "text_wrap": True, "border": 1}),
        "text": wb.add_format({"valign": "vcenter", "text_wrap": True, "border": 1}),
        "ctr": wb.add_format({"align": "center", "valign": "vcenter", "border": 1}),
        "int": wb.add_format({"align": "center", "valign": "vcenter",
                              "border": 1, "num_format": "0"}),
        "num": wb.add_format({"align": "center", "valign": "vcenter",
                              "border": 1, "num_format": "0.0"}),
        "pct": wb.add_format({"align": "center", "valign": "vcenter",
                              "border": 1, "num_format": "0.0%"}),
        "bold": wb.add_format({"bold": True, "align": "center",
                               "valign": "vcenter", "border": 1}),
        "boldtext": wb.add_format({"bold": True, "valign": "vcenter"}),
        "ok": wb.add_format({"bg_color": "#C6EFCE", "font_color": "#006100",
                             "bold": True, "align": "center", "border": 1}),
        "warn": wb.add_format({"bg_color": "#F8696B", "font_color": "#9C0006",
                               "bold": True, "align": "center", "border": 1}),
        "hit": wb.add_format({"bg_color": "#C6EFCE", "font_color": "#006100",
                              "align": "center", "border": 1}),
        "miss": wb.add_format({"bg_color": "#FFC7CE", "font_color": "#9C0006",
                               "align": "center", "border": 1}),
        "mid": wb.add_format({"bg_color": "#FFEB9C", "font_color": "#9C6500",
                              "align": "center", "border": 1}),
        "dim": wb.add_format({"align": "center", "valign": "vcenter",
                              "border": 1, "font_color": "#808080"}),
    }


def make_sheet(wb, F, name, title, note, headers, widths, validations=None):
    ws = wb.add_worksheet(name)
    ws.write(0, 0, title, F["title"])
    ws.merge_range(1, 0, 2, len(headers) - 1, note, F["note"])
    hdr_row = 3
    ws.write_row(hdr_row, 0, headers, F["hdr"])
    first = hdr_row + 1
    last = hdr_row + N
    for i in range(N):
        for c in range(len(headers)):
            ws.write_blank(first + i, c, None, F["text"])
    ws.add_table(hdr_row, 0, last, len(headers) - 1, {
        "name": name + "Table",
        "style": "Table Style Medium 2",
        "columns": [{"header": h} for h in headers],
    })
    for col, spec in (validations or {}).items():
        ws.data_validation(first, col, last, col, spec)
    for c, w in enumerate(widths):
        ws.set_column(c, c, w)
    ws.freeze_panes(hdr_row + 1, 0)
    return ws, first + 1, last + 1


def main():
    wb = xlsxwriter.Workbook(OUT)
    F = base_formats(wb)

    # ============ 表1 动作事件 ============
    a, a_f, a_l = make_sheet(
        wb, F, "动作事件",
        "表1 动作事件（A1-A6）",
        "逐通听录音，把每个可观测动作标出来。A4(沉默变长)只用于更新状态，"
        "不单独触发响应。「是否关键动作」填人工金标准，用来算触发覆盖率。",
        A_HEADERS,
        [16, 15, 14, 34, 14, 20, 22],
        validations={
            2: {"validate": "list", "source": ACTION_CODES},
            5: {"validate": "list", "source": ["是", "否"]},
        })

    # ============ 表2 状态快照 ============
    s, s_f, s_l = make_sheet(
        wb, F, "状态快照",
        "表2 状态快照（每个动作后的状态）",
        "建议只对 20 通通话完整落库，其余只落增量——这张表会很大。"
        "承诺与矛盾只增不减（单调性），旧信息不覆盖只记冲突。",
        S_HEADERS,
        [16, 15, 10, 24, 24, 22, 26, 26, 12, 20],
        validations={2: {"validate": "list", "source": STAGES}})

    # ============ 表3 响应事件 ============
    r, r_f, r_l = make_sheet(
        wb, F, "响应事件",
        "表3 响应事件（R0-R5，含沉默）",
        "R0 沉默是默认响应，也必须落库——否则算不出沉默比。"
        "「是否假阳性」只对 R2 填。",
        R_HEADERS,
        [16, 15, 14, 30, 26, 12, 16, 12, 20],
        validations={
            2: {"validate": "list", "source": RESPONSE_CODES},
            5: {"validate": "integer", "criteria": "between", "minimum": 1, "maximum": 5},
            6: {"validate": "list", "source": ["是", "否", "不适用"]},
            7: {"validate": "list", "source": ["是", "否"]},
        })
    r.conditional_format(r_f - 1, 6, r_l - 1, 6, {
        "type": "text", "criteria": "containing", "value": "是", "format": F["miss"]})
    r.conditional_format(r_f - 1, 6, r_l - 1, 6, {
        "type": "text", "criteria": "containing", "value": "否", "format": F["hit"]})

    # ============ 表4 人工核对 ============
    c, c_f, c_l = make_sheet(
        wb, F, "人工核对",
        "表4 人工核对（状态准确率，仅 20 通）",
        "让另一个人独立建同一份状态表再对照。两人的一致率就是状态准确率的上限——"
        "如果两个人自己都对不上 80%，先改字段定义，不要写代码。",
        C_HEADERS,
        [16, 15, 30, 30, 12, 18, 30],
        validations={
            4: {"validate": "list", "source": ["一致", "不一致"]},
            5: {"validate": "list",
                "source": ["动作漏识别", "字段定义不清", "判据不同", "系统错误", "其他"]},
        })
    c.conditional_format(c_f - 1, 4, c_l - 1, 4, {
        "type": "text", "criteria": "containing", "value": "一致", "format": F["hit"]})
    c.conditional_format(c_f - 1, 4, c_l - 1, 4, {
        "type": "text", "criteria": "containing", "value": "不一致", "format": F["miss"]})

    # ============ 阈值 ============
    pa = wb.add_worksheet("阈值")
    pa.write(0, 0, "阈值与容量参数", F["title"])
    pa.merge_range(1, 0, 2, 2,
                   "全部是待校准的初始值。改这里，「统计」表的判定会跟着变。"
                   "上线前必须替换成真实通话数据算出的数字。", F["note"])
    pa.write_row(3, 0, ["参数", "值", "说明"], F["hdr"])
    for i, (nm, val, kind, note) in enumerate(PARAMS):
        row = 4 + i
        pa.write_string(row, 0, nm, F["text"])
        fmt = {"pct": F["pct"], "num": F["num"], "int": F["int"]}[kind]
        pa.write_number(row, 1, val, fmt)
        pa.write_string(row, 2, note, F["text"])
    pa.set_column(0, 0, 26)
    pa.set_column(1, 1, 12)
    pa.set_column(2, 2, 50)
    # 阈值具名引用
    B = {"silence": "$B$5", "state": "$B$6", "cover": "$B$7", "cover_kill": "$B$8",
         "lat": "$B$9", "lat_kill": "$B$10", "r2fp": "$B$11", "r1": "$B$12"}

    # ============ 统计 ============
    st = wb.add_worksheet("统计")
    st.write(0, 0, "v0.3 指标汇总（不依赖是否执行选项）", F["title"])
    st.merge_range(1, 0, 2, 8,
                   "全部自动计算，数据来自「动作事件」「响应事件」「人工核对」。"
                   "按 v0.3 要求，不统计「用户是否执行选项」——那部分遥测已从设计里移除。",
                   F["note"])

    A = "'动作事件'"
    R = "'响应事件'"
    C = "'人工核对'"
    a_rng = "{s}!$C${f}:$C${l}".format(s=A, f=a_f, l=a_l)
    a_key = "{s}!$F${f}:$F${l}".format(s=A, f=a_f, l=a_l)
    r_rng = "{s}!$C${f}:$C${l}".format(s=R, f=r_f, l=r_l)
    r_fp = "{s}!$G${f}:$G${l}".format(s=R, f=r_f, l=r_l)
    c_rng = "{s}!$E${f}:$E${l}".format(s=C, f=c_f, l=c_l)

    # ---- 主指标（表头在第 4 行，数据从第 5 行开始；行号与公式一一对应） ----
    st.write_row(3, 0, ["指标", "计算", "值", "门槛", "判定"], F["hdr"])

    # 关键字面量：与「响应事件」表 C 列的下拉值一致
    K_R0 = '"R0"'
    K_R2 = '"R2"'
    K_YES = '"是"'
    K_OK = '"一致"'
    K_BAD = '"不一致"'

    st.write_string(4, 0, "动作总数", F["text"])
    st.write_formula(4, 2, '=COUNTIF({r},"<>")-COUNTBLANK({r})'.format(r=a_rng), F["int"])
    for col in (1, 3, 4):
        st.write_blank(4, col, None, F["ctr"])

    st.write_string(5, 0, "响应总数", F["text"])
    st.write_formula(5, 2, '=COUNTIF({r},"<>")-COUNTBLANK({r})'.format(r=r_rng), F["int"])
    for col in (1, 3, 4):
        st.write_blank(5, col, None, F["ctr"])

    st.write_string(6, 0, "R0 沉默数", F["text"])
    st.write_formula(6, 2, '=COUNTIF({r},{k})'.format(r=r_rng, k=K_R0), F["int"])
    for col in (1, 3, 4):
        st.write_blank(6, col, None, F["ctr"])

    st.write_string(7, 0, "沉默比", F["text"])
    st.write_string(7, 1, "R0/响应总数，应≥70%", F["note"])
    st.write_formula(7, 2, '=IF($C$6=0,"",$C$7/$C$6)', F["pct"])
    st.write_formula(7, 3, "=阈值!$B$5", F["pct"])
    st.write_formula(7, 4, '=IF($C$8="","未标注",IF($C$8<阈值!$B$5,"判死：太吵","通过"))',
                     F["bold"])

    st.write_string(8, 0, "关键动作数", F["text"])
    st.write_formula(8, 2, '=COUNTIF({k},{y})'.format(k=a_key, y=K_YES), F["int"])
    for col in (1, 3, 4):
        st.write_blank(8, col, None, F["ctr"])

    st.write_string(9, 0, "被识别的关键动作", F["text"])
    st.write_formula(9, 2, '=COUNTIFS({k},{y},{r},"<>")'.format(k=a_key, r=a_rng, y=K_YES),
                     F["int"])
    for col in (1, 3, 4):
        st.write_blank(9, col, None, F["ctr"])

    st.write_string(10, 0, "触发覆盖率", F["text"])
    st.write_string(10, 1, "被识别的关键动作/关键动作数", F["note"])
    st.write_formula(10, 2, '=IF($C$9=0,"",$C$10/$C$9)', F["pct"])
    st.write_formula(10, 3, "=阈值!$B$7", F["pct"])
    st.write_formula(10, 4, '=IF($C$11="","未标注",IF($C$11<阈值!$B$8,"判死：没在听",'
                            'IF($C$11<阈值!$B$7,"警告：漏得多","通过")))', F["bold"])

    st.write_string(11, 0, "一致数", F["text"])
    st.write_formula(11, 2, '=COUNTIF({r},{k})'.format(r=c_rng, k=K_OK), F["int"])
    for col in (1, 3, 4):
        st.write_blank(11, col, None, F["ctr"])

    st.write_string(12, 0, "不一致数", F["text"])
    st.write_formula(12, 2, '=COUNTIF({r},{k})'.format(r=c_rng, k=K_BAD), F["int"])
    for col in (1, 3, 4):
        st.write_blank(12, col, None, F["ctr"])

    st.write_string(13, 0, "状态准确率", F["text"])
    st.write_string(13, 1, "一致/(一致+不一致)，最致命指标", F["note"])
    st.write_formula(13, 2, '=IF(($C$12+$C$13)=0,"",$C$12/($C$12+$C$13))', F["pct"])
    st.write_formula(13, 3, "=阈值!$B$6", F["pct"])
    st.write_formula(13, 4, '=IF($C$14="","未标注",IF($C$14<阈值!$B$6,"判死：状态不准","通过"))',
                     F["bold"])
    st.conditional_format(4, 4, 13, 4, {
        "type": "text", "criteria": "containing", "value": "通过", "format": F["ok"]})
    st.conditional_format(4, 4, 13, 4, {
        "type": "text", "criteria": "containing", "value": "判死", "format": F["warn"]})
    st.conditional_format(4, 4, 13, 4, {
        "type": "text", "criteria": "containing", "value": "警告", "format": F["mid"]})

    # ---- 响应类型分布 ----
    rr0 = 16
    st.write_string(rr0, 0, "响应类型分布（R0 应占七成以上）", F["boldtext"])
    st.write_row(rr0 + 1, 0, ["响应", "次数", "占比", "说明"], F["hdr"])
    # 分母必须是「响应总数」= C6，不是动作总数 C5
    resp_total = "$C$6"
    r_notes = {
        "R0": "默认状态。占比低说明触发太宽",
        "R1": "纯记账，占比应低",
        "R2": "最高优先级，错了最伤信任",
        "R3": "决策点选项",
        "R4": "前瞻提示",
        "R5": "静默结转，不显示",
    }
    for i, code in enumerate(RESPONSE_CODES):
        rr = rr0 + 2 + i
        st.write_string(rr, 0, code, F["ctr"])
        st.write_formula(rr, 1, '=COUNTIF({r},$A{r2})'.format(r=r_rng, r2=rr + 1), F["int"])
        st.write_formula(rr, 2, '=IF({t}=0,"",$B{r2}/{t})'.format(t=resp_total, r2=rr + 1),
                         F["pct"])
        st.write_string(rr, 3, r_notes[code], F["text"])
    # R1 占比判定（直接引用 R1 那一行，不用位置偏移）
    r1_row = rr0 + 3          # R0 在第 19 行，R1 在其下一行
    r1_judge = rr0 + 8
    st.write_string(r1_judge, 0, "R1 占比判定", F["boldtext"])
    st.write_formula(r1_judge, 1,
                     '=IF($B{r}=0,"",IF($C{r}>阈值!{k},"判死：系统在空转","通过"))'.format(
                         r=r1_row, k=B["r1"]), F["bold"])
    st.conditional_format(r1_judge, 1, r1_judge, 1, {
        "type": "text", "criteria": "containing", "value": "通过", "format": F["ok"]})
    st.conditional_format(r1_judge, 1, r1_judge, 1, {
        "type": "text", "criteria": "containing", "value": "判死", "format": F["warn"]})

    # ---- R2 假阳性 ----
    rr2 = rr0 + 10
    st.write_string(rr2, 0, "R2 阻断性纠错的假阳性", F["boldtext"])
    st.write_row(rr2 + 1, 0, ["项目", "数值"], F["hdr"])
    st.write_string(rr2 + 2, 0, "R2 总次数", F["text"])
    st.write_formula(rr2 + 2, 1, '=COUNTIF({r},"R2")'.format(r=r_rng), F["int"])
    st.write_string(rr2 + 3, 0, "判定为假阳性", F["text"])
    st.write_formula(rr2 + 3, 1, '=COUNTIF({r},"是")'.format(r=r_fp), F["int"])
    st.write_string(rr2 + 4, 0, "R2 假阳性率", F["text"])
    st.write_formula(rr2 + 4, 1, '=IF($B{r}=0,"",$B{r2}/$B{r})'.format(
        r=rr2 + 3, r2=rr2 + 4), F["pct"])
    st.write_string(rr2 + 5, 0, "判定", F["boldtext"])
    st.write_formula(rr2 + 5, 1, '=IF($B{r}=0,"未标注",IF($B{rate}>阈值!{k},"判死：纠错不可信","通过"))'.format(
        r=rr2 + 6, rate=rr2 + 5, k=B["r2fp"]), F["bold"])
    st.conditional_format(rr2 + 5, 1, rr2 + 5, 1, {
        "type": "text", "criteria": "containing", "value": "通过", "format": F["ok"]})
    st.conditional_format(rr2 + 5, 1, rr2 + 5, 1, {
        "type": "text", "criteria": "containing", "value": "判死", "format": F["warn"]})

    # ---- 动作类型分布 ----
    rr3 = rr2 + 8
    st.write_string(rr3, 0, "动作类型分布（用来砍掉识别不准的动作类型）", F["boldtext"])
    st.write_row(rr3 + 1, 0, ["动作", "次数", "占比"], F["hdr"])
    a_total = "$C$4"
    for i, code in enumerate(ACTION_CODES):
        rr = rr3 + 2 + i
        st.write_string(rr, 0, code, F["ctr"])
        st.write_formula(rr, 1, '=COUNTIFS({r},$A{r2}&"*")'.format(r=a_rng, r2=rr + 1), F["int"])
        st.write_formula(rr, 2, '=IF({t}=0,"",$B{r2}/{t})'.format(t=a_total, r2=rr + 1),
                         F["pct"])

    # ---- 差异类型分布 ----
    rr4 = rr3 + 10
    st.write_string(rr4, 0, "状态差异类型（指导你改字段定义还是改代码）", F["boldtext"])
    st.write_row(rr4 + 1, 0, ["差异类型", "次数"], F["hdr"])
    diff_types = ["动作漏识别", "字段定义不清", "判据不同", "系统错误", "其他"]
    diff_rng = "{s}!$F${f}:$F${l}".format(s=C, f=c_f, l=c_l)
    for i, dt in enumerate(diff_types):
        rr = rr4 + 2 + i
        st.write_string(rr, 0, dt, F["text"])
        st.write_formula(rr, 1, '=COUNTIF({r},$A{r2})'.format(r=diff_rng, r2=rr + 1), F["int"])

    # ---- 判死标准 ----
    rr5 = rr4 + 9
    st.write_string(rr5, 0, "判死标准（六条，任一不过即停或改规则）", F["boldtext"])
    kills = [
        "状态准确率 < 80% → 最致命：状态不准，后面所有响应都建立在错误前提上",
        "沉默比 < 70% → 触发太宽，必然被无视",
        "响应延迟 P95 > 3 秒 → 过期响应比没有响应更糟",
        "R2 假阳性 > 20% → 阻断纠错错了最伤信任，它拿着最高优先级",
        "触发覆盖率 < 30% → 系统没在听，状态一定也错了",
        "R1（确认）占比 > 20% → 说明系统在空转，状态没有实质推进",
    ]
    for i, t in enumerate(kills):
        st.write(rr5 + 1 + i, 0, "· " + t, F["note"])

    st.write(rr5 + 8, 0,
             "注意：本版不统计「用户是否执行选项」。v0.2 的 L2/L3 指标已按 v0.3 要求移除。",
             F["note"])

    for col, w in enumerate([22, 26, 12, 12, 16]):
        st.set_column(col, col, w)
    st.freeze_panes(4, 0)

    wb.close()
    print("written: {0}".format(OUT))
    print("sheets: 动作事件 / 状态快照 / 响应事件 / 人工核对 / 阈值 / 统计")


if __name__ == "__main__":
    sys.exit(main())
