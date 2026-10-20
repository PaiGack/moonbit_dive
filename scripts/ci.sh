#!/usr/bin/env bash
#
# 本仓库唯一的 CI 步骤定义。
#
# GitHub Actions（.github/workflows/ci.yml）与 CNB（.cnb.yml）都只做两件事：
# 装 MoonBit 工具链，然后调这个脚本。两个平台的 job 名字一一对应，
# 步骤内容全部收在这里，避免两处流水线各改各的、慢慢漂移。
#
# 阶段：格式与接口 → 测试与覆盖率 → 构建 → CLI 冒烟 → 真实后端对拍
# （最后一步里含一份 zstd 层测试镜像，见 scripts/docker-cli-probe.sh 第 6 节）。
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
#
# 断言只看生成文件（`*.generated.mbti` / `*.mbti`）。工作区里还躺着
# .gitignore 之外的东西不归 CI 管——原先 `git diff --exit-code` 连未跟踪
# 文件之外的一切都算进来，跑一次 docker 对拍留下 tar 就会误判。
section "格式与接口"
run moon fmt --check
# 第一次 `moon info` 要下依赖 zip，是最容易撞网络超时的一步。
run retry 3 moon info
generated=$(git status --porcelain -- '*.mbti' '*.generated.mbti')
if [ -n "$generated" ]; then
  printf '%s\n' "$generated" >&2
  printf '%s.mbti 有未提交的改动——本地跑一遍 `moon info && moon fmt` 再提交%s\n' \
    "$RED" "$RESET" >&2
  exit 1
fi

# --------------------------------------------------------- 2. 测试与覆盖率 --
section "测试"
# 覆盖率产物落在 `<repo>/_build/moonbit_coverage_<ts>_<id>.txt`，每个测试可执行
# 文件一份，`moon test` 只清理它自己认得的那批。反复跑会越攒越多（实测一轮
# 5 次就攒到 49 份），`moon coverage report` 把新旧数据混在一起解析时，
# 有相当概率撞上 JSON 解析失败（本地复现 3/25）。每次跑之前先清干净，
# 保证「测试 + 报告」是自洽的一轮。
rm -f _build/moonbit_coverage_*.txt
# 不开 `--deny-warn`：工具链把 `result_error_return`（0078）默认提成了警告，
# 而本仓库 `Result[T, E]` 是有意为之的公开 API 形态。deny-warn 会让这份
# 与代码无关的策略变更直接红掉整条流水线，错误还得自己翻日志才看得出来。
run moon test --target native --enable-coverage
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

# ------------------------------------------------------- 5. 真实后端对拍 --
# 上面所有 docker_cli 用例都用假 CLI：它们证明解析逻辑对，证明不了
# 「`docker save` / `inspect` 的参数形态和真实输出对得上」。这一步拿真 daemon
# 和一份手搓的最小镜像跑一遍四条通路（见 scripts/docker-cli-probe.sh）。
# 环境里没有 daemon 时脚本退 77，这里跳过而不判红——「没装 docker」
# 不是代码问题，但「装了 docker 却取不到镜像」必须是。
#
# 第 6 节是 zstd 测试镜像：层用 docker 里的 `zstd -19` 压，
# 再让 dive 自己解压、建树、出报告。它需要能 `docker run`
# 一个装得上 zstd 的小镜像（默认 alpine）；拉不到时它自己跳过。
# 想换镜像源就设 DIVE_TEST_ZSTD_HELPER_IMAGE。
section "真实后端对拍（含 zstd 测试镜像）"
if [ "${CI_SKIP_DOCKER_PROBE:-0}" = "1" ]; then
  printf '%s跳过（CI_SKIP_DOCKER_PROBE=1）%s\n' "$DIM" "$RESET"
else
  probe_status=0
  bash scripts/docker-cli-probe.sh || probe_status=$?
  if [ "$probe_status" = "77" ]; then
    printf '%s跳过：没有可用的 docker daemon（CNB 需要 services: docker）%s\n' \
      "$DIM" "$RESET"
  elif [ "$probe_status" != "0" ]; then
    printf '%s真实后端对拍失败（exit %d）%s\n' "$RED" "$probe_status" "$RESET" >&2
    exit 1
  fi
fi

printf '\n%sCI 全绿%s\n' "$GREEN$BOLD" "$RESET"
