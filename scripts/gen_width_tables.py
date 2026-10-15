#!/usr/bin/env python3
"""生成 tui/width_tables.mbt 的零宽码点区间表。

数据源：`moonbit-community/unicodewidth` 的打包表（UAX #11 派生，Unicode 16.0）。
口径是「该码点自身占 0 列」——组合记号、格式控制、变体选择符、tag 字符、
Hangul Jamo 中声与终声。逐码点过筛，不整段照抄：unicodewidth 的零宽区间里
混着 Mc / Lo（那边另有 cluster 级规则兜着），整段抄进来会把「字与字之间
本来会显示的记号」也判成零宽。

用法（仓库根目录）：
  moon add moonbit-community/unicodewidth@0.2.1
  python3 scripts/gen_width_tables.py > tui/width_tables.mbt
生成后可以 `moon remove moonbit-community/unicodewidth` —— 表落地后不再需要它。
"""
import re
import sys
import unicodedata
from pathlib import Path

TABLES = Path('.mooncakes/moonbit-community/unicodewidth/tables.mbt')
if not TABLES.exists():
    sys.exit('找不到 %s，先 `moon add moonbit-community/unicodewidth`' % TABLES)

text = TABLES.read_text()


def block(name):
    i = text.index('let %s : ' % name)
    j = text.index('[', text.index('=', i))
    depth = 0
    for k in range(j, len(text)):
        if text[k] == '[':
            depth += 1
        elif text[k] == ']':
            depth -= 1
            if depth == 0:
                return text[j:k + 1]
    raise ValueError('unbalanced: ' + name)


def unpack(arr):
    return eval(re.sub(r'//.*', '', arr).replace('ReadOnlyArray', '').replace('UInt', ''))


root, middle, leaves = (unpack(block(n)) for n in ('width_root', 'width_middle', 'width_leaves'))


def uw_width(cp):
    """unicodewidth 的查表宽度（0 窄 1 宽 2 ... 3 表示"查表未定义"）。"""
    t1 = root[cp >> 13]
    t2 = middle[t1][(cp >> 7) & 0x3F]
    packed = leaves[t2][(cp >> 2) & 0x1F]
    return (packed >> (2 * (cp & 0b11))) & 0b11


# unicodewidth 把 U+FE00..U+FE0F 记成 3（Mn，查表未定义），但终端里变体选择符
# 一律不占列；Rust unicode-width 也是在 cluster 层把它们扣掉的。这里显式补上。
ZERO_WIDTH_CATEGORIES = {'Mn', 'Me', 'Cf'}
kept = [cp for cp in range(0xA0, 0x110000)
        if (uw_width(cp) == 0 or 0xFE00 <= cp <= 0xFE0F)
        and unicodedata.category(chr(cp)) in ZERO_WIDTH_CATEGORIES]

ranges = []
start = prev = kept[0]
for cp in kept[1:]:
    if cp == prev + 1:
        prev = cp
    else:
        ranges.append((start, prev))
        start = prev = cp
ranges.append((start, prev))

print('''///|
/// 零宽码点区间表（含端点），由 `scripts/gen_width_tables.py` 生成，勿手改。
///
/// 口径是「单个码点占 0 列」：组合记号（Mn/Me）、格式控制（Cf）、
/// 变体选择符、Hangul Jamo 中声与终声、tag 字符。
/// 数据源是 `moonbit-community/unicodewidth` 的打包表（Unicode 16.0）。
///
/// 表落地后本仓**不依赖** unicodewidth：cluster 合并是自研的（见 `width.mbt`），
/// 引库会把「文本测量」这个本可独立验收的点绑死在别人的版本上。
/// 按区间存，几百行换 log 级查找。
pub let zero_width_ranges : ReadOnlyArray[(Int32, Int32)] = [''')
for a, b in ranges:
    print('  (0x%X, 0x%X),' % (a, b))
print(']')
print('// %d ranges, %d codepoints (Unicode 16.0)' % (len(ranges), len(kept)), file=sys.stderr)
