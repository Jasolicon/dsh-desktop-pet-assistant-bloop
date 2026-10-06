# 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
# Copyright (c) 2026 Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

# -*- coding: utf-8 -*-
"""
构建「主动式长时指导/监工型 AI 产品」跨行业方向评分矩阵。

用法：
    & "<bundled python>" ".\build_matrix.py"
产出：
    .\方向评分矩阵.xlsx
"""

import json
import os
import sys

import xlsxwriter

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "matrix_data.json")
OUT = os.path.join(HERE, "方向评分矩阵.xlsx")

HEADERS = [
    "序号", "行业", "岗位", "任务类",
    "不可替代性", "反馈延迟", "状态可读性", "规则可写性", "错误代价", "竞争空隙",
    "总分", "一句话结论", "致命风险",
]
WIDTHS = [6, 12, 12, 16, 11, 10, 12, 12, 10, 10, 9, 40, 42]


def load_rows():
    with open(DATA, encoding="utf-8") as fh:
        raw = json.load(fh)
    rows = []
    for item in raw["directions"]:
        rows.append([
            item["industry"],
            item["role"],
            item["task_class"],
            int(item["score_irreplaceability"]),
            int(item["score_feedback_gap"]),
            int(item["score_state_legibility"]),
            int(item["score_rule_codifiability"]),
            int(item["score_error_cost"]),
            int(item["score_competitive_openness"]),
            item["verdict"],
            item["fatal_risk"],
        ])
    # 按 6 个维度总分降序；同分时按状态可读性 → 规则可写性 → 错误代价 依次决胜，
    # 因为状态可读性是最硬的工程约束。
    rows.sort(key=lambda r: (sum(r[3:9]), r[5], r[7], r[8]), reverse=True)
    return rows


def main():
    rows = load_rows()
    n = len(rows)
    last = n  # 数据行 1..n，末行索引 = n（0 基），Excel 行号 = n+1

    wb = xlsxwriter.Workbook(OUT)
    ws = wb.add_worksheet("方向评分矩阵")

    fmt_title = wb.add_format({
        "bold": True, "font_size": 13, "font_color": "#1F4E79", "align": "left",
    })
    fmt_note = wb.add_format({
        "font_size": 9, "font_color": "#595959", "italic": True, "text_wrap": True,
        "valign": "top",
    })
    fmt_hdr = wb.add_format({
        "bold": True, "bg_color": "#1F4E79", "font_color": "#FFFFFF",
        "align": "center", "valign": "vcenter", "text_wrap": True, "border": 1,
    })
    fmt_center = wb.add_format({"align": "center", "valign": "vcenter", "border": 1})
    fmt_text = wb.add_format({"valign": "vcenter", "text_wrap": True, "border": 1})
    fmt_text_top = wb.add_format({"valign": "top", "text_wrap": True, "border": 1})
    fmt_score = wb.add_format({
        "align": "center", "valign": "vcenter", "border": 1, "bg_color": "#FFFFFF",
    })
    fmt_total = wb.add_format({
        "align": "center", "valign": "vcenter", "border": 1, "bold": True,
    })

    ws.write(0, 0, "主动式长时指导 / 监工型 AI 产品 —— 跨行业方向评分矩阵", fmt_title)
    ws.write(1, 0,
             "评分口径统一为 1-5 分，5 分最好。总分 = 六项之和（满分 30）。"
             "反馈延迟一列 5 分表示「做错了很久以后才发现」，它对需求成立是加分，"
             "但对产品拿到即时反馈是减分，解读时须注意。"
             "排序规则：总分降序，同分按 状态可读性 → 规则可写性 → 错误代价 决胜，"
             "因为状态可读性是最硬的工程约束。", fmt_note)
    ws.merge_range(1, 0, 2, len(HEADERS) - 1, None, fmt_note)

    hdr_row = 3
    ws.write_row(hdr_row, 0, HEADERS, fmt_hdr)

    for i, r in enumerate(rows):
        excel_row = hdr_row + 1 + i
        ws.write_number(excel_row, 0, i + 1, fmt_center)
        ws.write_string(excel_row, 1, r[0], fmt_text)
        ws.write_string(excel_row, 2, r[1], fmt_text)
        ws.write_string(excel_row, 3, r[2], fmt_text)
        for c in range(6):
            ws.write_number(excel_row, 4 + c, r[3 + c], fmt_score)
        ws.write_formula(excel_row, 10,
                         "=SUM(E{r}:J{r})".format(r=excel_row + 1), fmt_total)
        ws.write_string(excel_row, 11, r[9], fmt_text_top)
        ws.write_string(excel_row, 12, r[10], fmt_text_top)

    first_data = hdr_row + 1
    last_data = hdr_row + n

    ws.add_table(hdr_row, 0, last_data, len(HEADERS) - 1, {
        "name": "DirectionScoreMatrix",
        "style": "Table Style Medium 2",
        "columns": [{"header": h} for h in HEADERS],
    })

    # 评分列条件格式：低分偏红、高分偏绿，叠加三色阶
    ws.conditional_format(first_data, 4, last_data, 9, {
        "type": "cell", "criteria": "<=", "value": 2,
        "format": wb.add_format({"bg_color": "#F8696B", "font_color": "#9C0006",
                                 "align": "center", "border": 1}),
    })
    ws.conditional_format(first_data, 4, last_data, 9, {
        "type": "cell", "criteria": ">=", "value": 4,
        "format": wb.add_format({"bg_color": "#C6EFCE", "font_color": "#006100",
                                 "align": "center", "border": 1}),
    })
    ws.conditional_format(first_data, 4, last_data, 9, {
        "type": "3_color_scale",
        "min_color": "#F8696B", "mid_color": "#FFEB84", "max_color": "#63BE7B",
    })
    ws.conditional_format(first_data, 10, last_data, 10, {
        "type": "data_bar", "bar_color": "#638EC6",
    })

    ws.freeze_panes(hdr_row + 1, 0)
    for c, w in enumerate(WIDTHS):
        ws.set_column(c, c, w)

    wb.close()
    print("written: {0}  rows={1}".format(OUT, n))
    print("score range: {0} .. {1}".format(
        sum(rows[-1][3:9]), sum(rows[0][3:9])))


if __name__ == "__main__":
    sys.exit(main())
