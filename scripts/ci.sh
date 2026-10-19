#!/usr/bin/env bash
#
# 本仓库唯一的 CI 步骤定义。
#
# GitHub Actions（.github/workflows/ci.yml）与 CNB（.cnb.yml）都只做两件事：
# 装 MoonBit 工具链，然后调这个脚本。两个平台的 job 名字一一对应，
# 步骤内容全部收在这里，避免两处流水线各改各的、慢慢漂移。
#
# 阶段：格式与接口 → 测试与覆盖率 → 构建 → CLI 冒烟。
set -euo pipefail

cd "$(dirname "$0")/.."

# ---------------------------------------------------------------- 输出样式 --
if [ -t 1 ]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'; RESET=$'\033[0m'
else
  BOLD=''; DIM=''; RED=''; GREEN=''; RESET=''
fi

step=0
run() {
  step=$((step + 1))
  printf '\n%s[%02d] %s%s\n' "$BOLD" "$step" "$*" "$RESET"
  printf '%s$ %s%s\n' "$DIM" "$*" "$RESET"
  "$@"
}

section() {
  printf '\n%s== %s ==%s\n' "$BOLD" "$1" "$RESET"
}

# ---------------------------------------------------------------- 网络重试 --
# `moon update` 拉 registry 索引，`moon info` / `moon test` 首次会现下依赖
# zip（download.mooncakes.io）。这两步都是纯网络操作，偶发 `operation timed
# out` 会直接红掉一整轮（实测白跑 3 分钟）。网络抖动不是代码问题，所以按次
# 重试，重试完还失败才算真失败。用法：`retry <次数> <命令...>`。
retry() {
  local attempts=$1 i
  shift
  local delay=15
  for ((i = 1; i <= attempts; i++)); do
    if "$@"; then
      return 0
    fi
    if ((i == attempts)); then
      printf '%s连试 %d 次仍失败：%s%s\n' "$RED" "$attempts" "$*" "$RESET" >&2
      return 1
    fi
    printf '%s第 %d/%d 次失败，%ds 后重试：%s%s\n' \
      "$DIM" "$i" "$attempts" "$delay" "$*" "$RESET" >&2
    sleep "$delay"
  done
}

# ------------------------------------------------------------------ 依赖 --
# 新 checkout 里没有 registry 索引，直接 `moon check` 会解析依赖失败。
section "环境"
if command -v moon >/dev/null 2>&1; then
  moon version
else
  printf '%smoon 不在 PATH 里，先装工具链或把它加进 PATH%s\n' "$RED" "$RESET" >&2
  exit 1
fi
# CI 里想跳过网络更新时设 CI_SKIP_MOON_UPDATE=1；本地跑默认也更新，
# 这样依赖漂移能在本地先暴露出来。
if [ "${CI_SKIP_MOON_UPDATE:-0}" != "1" ]; then
  run retry 3 moon update
fi

# -------------------------------------------------- 1. 格式与接口一致性 --
# `moon fmt --check` 只看格式，`moon info` 后用 git 断言才能发现
# 忘了提交的 .mbti 变更。两者都靠「本地必须干净」这条规则。
section "格式与接口"
run moon fmt --check
# 第一次 `moon info` 要下依赖 zip，是最容易撞网络超时的一步。
run retry 3 moon info
if ! git diff --exit-code; then
  printf '%s.mbti 或源码有未提交的改动——本地跑一遍 `moon info && moon fmt` 再提交%s\n' \
    "$RED" "$RESET" >&2
  exit 1
fi
run git status

# --------------------------------------------------------- 2. 测试与覆盖率 --
section "测试"
# 覆盖率产物落在 `<repo>/_build/moonbit_coverage_<ts>_<id>.txt`，每个测试可执行
# 文件一份，`moon test` 只清理它自己认得的那批。反复跑会越攒越多（实测一轮
# 5 次就攒到 49 份），`moon coverage report` 把新旧数据混在一起解析时，
# 有相当概率撞上 JSON 解析失败（本地复现 3/25）。每次跑之前先清干净，
# 保证「测试 + 报告」是自洽的一轮。
rm -f _build/moonbit_coverage_*.txt
run moon test --target native --deny-warn --enable-coverage
run moon coverage report -f summary

# ------------------------------------------------------------------ 3. 构建 --
section "构建"
run moon build --target native
run moon build --target native --release

# -------------------------------------------------------------- 4. CLI 冒烟 --
# 退出码只有 native 后端能传给 shell，所以冒烟也走 native。
# 这里只验 --help 能跑通：真正的镜像分析由测试夹具覆盖。
section "CLI 冒烟"
run moon run --target native cmd/main -- --help

printf '\n%sCI 全绿%s\n' "$GREEN$BOLD" "$RESET"
