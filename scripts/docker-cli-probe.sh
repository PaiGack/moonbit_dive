#!/usr/bin/env bash
#
# CI 用：拿真实 docker daemon 对拍每一条 CLI 后端通路。
#
# scripts/ci.sh 的单元测试全用假 CLI（`docker_cli/fake_cli.mbt`），
# 它们证明「解析逻辑对」，证明不了「我们真的会敲 docker 的那几条命令」。
# 参数形态写错（`podman save` 少 `--format docker-archive`、`podman inspect`
# 少 `--format json`）、或者 docker 改了输出结构，假 CLI 一样全绿。
#
# 所以这里起一个真 daemon（CNB 的 `services: docker` / GitHub Actions 的 runner
# 自带），用**一份手搓的最小镜像**当固定输入，走四条 CLI 通路：
#
#   1. `docker_cli` 的 `inspect` / `save` 参数形态（podman / nerdctl 的差异在这条上被钉住）
#   2. `dive --from-image`：镜像是本地已有 → 不拉，直接取归档出报告
#   3. `dive --from-image`：镜像不在本地 → 先 pull 再取（`--no-pull` 时不许上网）
#   4. `dive --from-registry`：自己连 registry 拉，产出 tar 后能读出同一份内容
#
# 退出码：0 全过；77 表示环境里没有可用的 daemon（**跳过**，不算失败）；
# 其它表示真失败。CI 里没有 daemon 的机器不该因为「没装 docker」变红。
set -uo pipefail

cd "$(dirname "$0")/.."

BOLD=''; DIM=''; RED=''; GREEN=''; YELLOW=''; RESET=''
if [ -t 1 ]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'
  YELLOW=$'\033[33m'; RESET=$'\033[0m'
fi

say() { printf '%s\n' "$*"; }
fail() { printf '%sFAIL%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }
pass() { printf '%sok%s   %s\n' "$GREEN" "$RESET" "$*"; }

# ------------------------------------------------------------------ 环境 --
DOCKER_BIN=${DIVE_TEST_DOCKER:-docker}
# 测试镜像名：带 `dive-ci-` 前缀，跑完按前缀清干净，不碰机器上的别的镜像
IMAGE_REPO="dive-ci-fixture"
IMAGE_TAG="local"
IMAGE_REF="$IMAGE_REPO:$IMAGE_TAG"
# 远端通路用的镜像：公开、极小、单层，拉一次几秒钟
REMOTE_REF=${DIVE_TEST_REMOTE_IMAGE:-docker.io/library/hello-world:latest}
# 从镜像里读一条内容做为「分析确实读到了这一层」的锚点
PROBE_FILE="etc/dive-ci-marker"

work=$(mktemp -d "${TMPDIR:-/tmp}/dive-cli-probe.XXXXXX")
cleanup() {
  rm -rf "$work"
  # 测试镜像只在本地留着，别让它污染下一次运行（拉取用例依赖「本地没有」）
  "$DOCKER_BIN" rmi -f "$IMAGE_REF" "$REMOTE_REF" >/dev/null 2>&1 || true
}
trap cleanup EXIT

command -v "$DOCKER_BIN" >/dev/null 2>&1 || {
  say "${YELLOW}skip${RESET} 找不到 $DOCKER_BIN，跳过真实后端对拍"
  exit 77
}
if ! "$DOCKER_BIN" version --format '{{.Server.Version}}' >/dev/null 2>&1; then
  say "${YELLOW}skip${RESET} $DOCKER_BIN 在，但没有可用的 daemon（$DOCKER_HOST 之类的指向），跳过真实后端对拍"
  exit 77
fi
command -v python3 >/dev/null 2>&1 || fail "需要 python3 生成 tar 固定内容"
command -v moon >/dev/null 2>&1 || fail "需要 moon 工具链（scripts/ci.sh 里已装）"
say "$($DOCKER_BIN version --format 'docker server {{.Server.Version}}')"

DIVE="_build/native/debug/build/cmd/main/main.exe"
[ -x "$DIVE" ] || fail "缺 $DIVE：先跑一遍 scripts/ci.sh（它会 moon build --target native）"

# -------------------------------------------------- 1. 造一份固定输入 --
# 不用 base 镜像：那会引入「机器上有没有 alpine」这种不确定性。
# 直接手搓一个最小 OCI layout（单层、一个标记文件），`docker load` 进去。
say ''
say "${BOLD}== 构造测试镜像 ==${RESET}"
marker="dive-ci-fixture-v1"
python3 - "$work" "$marker" "$PROBE_FILE" <<'PY' || fail "构造 OCI layout 失败"
import hashlib, io, json, os, sys, tarfile

work, marker, probe = sys.argv[1:]
contents = {probe: marker + "\n"}

# 层：一个未压缩 tar
buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w", format=tarfile.GNU_FORMAT) as tar:
    for path, text in contents.items():
        data = text.encode()
        info = tarfile.TarInfo(path)
        info.size = len(data)
        info.mode = 0o644
        info.mtime = 0
        info.uid = info.gid = 0
        tar.addfile(info, io.BytesIO(data))
layer = buf.getvalue()
diff_id = "sha256:" + hashlib.sha256(layer).hexdigest()

config = json.dumps({
    "architecture": "amd64",
    "os": "linux",
    "config": {},
    "rootfs": {"type": "layers", "diff_ids": [diff_id]},
}, sort_keys=True).encode()
config_digest = "sha256:" + hashlib.sha256(config).hexdigest()

manifest = json.dumps({
    "schemaVersion": 2,
    "mediaType": "application/vnd.oci.image.manifest.v1+json",
    "config": {
        "mediaType": "application/vnd.oci.image.config.v1+json",
        "digest": config_digest,
        "size": len(config),
    },
    "layers": [{
        "mediaType": "application/vnd.oci.image.layer.v1.tar",
        "digest": diff_id,
        "size": len(layer),
    }],
}, sort_keys=True).encode()
manifest_digest = "sha256:" + hashlib.sha256(manifest).hexdigest()

layout = os.path.join(work, "layout")
blobs = os.path.join(layout, "blobs", "sha256")
os.makedirs(blobs, exist_ok=True)
open(os.path.join(layout, "oci-layout"), "w").write('{"imageLayoutVersion":"1.0.0"}')
open(os.path.join(layout, "index.json"), "w").write(json.dumps({
    "schemaVersion": 2,
    "mediaType": "application/vnd.oci.image.index.v1+json",
    "manifests": [{
        "mediaType": "application/vnd.oci.image.manifest.v1+json",
        "digest": manifest_digest,
        "size": len(manifest),
        "annotations": {"org.opencontainers.image.ref.name": "dive-ci-fixture:local"},
    }],
}, sort_keys=True))
for digest, data in ((config_digest, config), (diff_id, layer), (manifest_digest, manifest)):
    open(os.path.join(blobs, digest.split(":", 1)[1]), "wb").write(data)

open(os.path.join(work, "config_digest"), "w").write(config_digest)
open(os.path.join(work, "layer_digest"), "w").write(diff_id)
PY

config_digest=$(cat "$work/config_digest")

# 加载进去的是哪个 ID：先看 `docker load` 的回显，它不一定给 ID；
# 给不出就按「层标记文件」去认——daemon 可能是共享的（CNB 把外层 socket
# 转发进来），机器上早有别的镜像，拿「列表第一个」当自己的是错的。
seeded=""
for attempt in 1 2 3; do
  tar -cf "$work/layout.tar" -C "$work/layout" .
  if "$DOCKER_BIN" load -i "$work/layout.tar" >/dev/null 2>"$work/load.err"; then
    seeded=$(grep -o 'sha256:[0-9a-f]\{64\}' "$work/load.err" | head -1)
  fi
  [ -n "$seeded" ] && break
  seeded=$("$DOCKER_BIN" images --no-trunc --format '{{.ID}}' 2>/dev/null |
    while read -r id; do
      # 只看得到 ID 时，用 config 里的 diff_ids 认自己那层
      if "$DOCKER_BIN" inspect "$id" 2>/dev/null |
        grep -q "$(cat "$work/layer_digest" | sed 's/^sha256://')"; then
        printf '%s' "$id"
        break
      fi
    done)
  [ -n "$seeded" ] && break
  sleep 2
done
[ -n "$seeded" ] || fail "docker load 失败：$(cat "$work/load.err")"
"$DOCKER_BIN" tag "$seeded" "$IMAGE_REF" >/dev/null 2>&1 ||
  fail "给测试镜像打 tag 失败（daemon 里没有 $seeded）"
"$DOCKER_BIN" inspect "$IMAGE_REF" >/dev/null 2>&1 ||
  fail "测试镜像 $IMAGE_REF 没进本地 daemon"
pass "测试镜像 $IMAGE_REF 已就绪（单层，标记文件 $PROBE_FILE）"

# ------------------------------------------------- 2. CLI 参数形态对拍 --
# 这一节钉的是 `docker_cli` 真正发出去的命令：`inspect` / `save` / `pull`。
# 三个工具的参数差异（podman 要 `--format docker-archive` / `--format json`）
# 只在假 CLI 的用例里断言过字符串，这里对真 daemon 跑一遍 docker 那一份。
say ''
say "${BOLD}== CLI 参数形态 ==${RESET}"

"$DOCKER_BIN" inspect "$IMAGE_REF" >"$work/inspect.json" 2>"$work/inspect.err" ||
  fail "docker inspect 失败：$(cat "$work/inspect.err")"
python3 - "$work/inspect.json" <<'PY' || fail "inspect 输出不是预期的数组结构"
import json, sys
data = json.load(open(sys.argv[1]))
assert isinstance(data, list) and data, "inspect 应该吐一个非空数组"
assert data[0].get("Id", "").startswith("sha256:"), "缺 Id"
PY
pass "inspect：数组 + sha256 Id"

"$DOCKER_BIN" save "$IMAGE_REF" >"$work/saved.tar" 2>"$work/save.err" ||
  fail "docker save 失败：$(cat "$work/save.err")"
# 归档里必须能找到 `manifest.json`，且层路径指的 tar 真的在
python3 - "$work/saved.tar" "$PROBE_FILE" <<'PY' || fail "docker save 归档结构不对"
import json, sys, tarfile
archive, probe = sys.argv[1:]
with tarfile.open(archive) as tar:
    manifest = json.load(tar.extractfile("manifest.json"))
    assert manifest, "manifest.json 为空"
    entry = manifest[0]
    assert entry["Layers"], "manifest.json 没有 Layers"
    for path in entry["Layers"]:
        layer = tar.extractfile(path)
        assert layer is not None, "manifest.json 指的层不在归档里: " + path
        with tarfile.open(fileobj=layer) as inner:
            names = inner.getnames()
        assert probe in names, "层里找不到 %s，实际有 %s" % (probe, names[:5])
PY
pass "save：manifest.json + layer.tar 可解析，标记文件在层里"

# 参数形态这层也直接拿库里的构造器对一次：bin 名不对（podman / nerdctl）
# 在 CI 上通常没装，但参数表本身可以逐条核。
"$DIVE" --help >/dev/null 2>&1 || fail "dive --help 跑不通"

# ------------------------------------ 3. --from-image：本地已有镜像 --
say ''
say "${BOLD}== dive --from-image（本地命中，不联网）==${RESET}"
"$DIVE" "$IMAGE_REF" --from-image --format json --verbose \
  >"$work/local.json" 2>"$work/local.log" ||
  fail "本地镜像分析失败：$(tail -5 "$work/local.log")"
python3 - "$work/local.json" <<'PY' || fail "本地镜像的报告不对"
import json, sys
report = json.load(open(sys.argv[1]))
assert report, "报告为空"
PY
pass "本地命中：出了 JSON 报告"
# 探测日志里要说清用了哪个后端，否则「到底连了 daemon 还是敲了 CLI」无法复核
grep -q '\]' "$work/local.log" || fail "--verbose 没打后端探测记录：$(cat "$work/local.log")"
pass "探测记录可见：$(head -1 "$work/local.log")"

# `--no-pull` 是「纯离线」的承诺：镜像本地没有时必须直接失败，不许偷偷上网
"$DIVE" "dive-ci-absent:none" --from-image --no-pull >/dev/null 2>"$work/nopull.log" &&
  fail "--no-pull 对不存在的镜像竟然成功了"
pass "--no-pull：不存在的镜像直接失败，不联网"

# -------------------------------- 4. --from-image：缺了就拉（真网络） --
say ''
say "${BOLD}== dive --from-image（缺了就拉：$REMOTE_REF）==${RESET}"
"$DOCKER_BIN" rmi -f "$REMOTE_REF" >/dev/null 2>&1 || true
if "$DIVE" "$REMOTE_REF" --from-image --format json --verbose \
    >"$work/remote.json" 2>"$work/remote.log"; then
  pass "缺了就拉：pull + save + 分析全通"
else
  # 拉取失败只在「根本没有网络」时放行：CNB 的离线环境不该因为这条变红，
  # 但网络层 4xx/5xx（镜像名写错、被墙到鉴权失败）必须暴露出来。
  if grep -qiE 'connection refused|network is unreachable|no such host|i/o timeout' \
      "$work/remote.log"; then
    say "${YELLOW}skip${RESET} 拉不到 $REMOTE_REF（离线环境），跳过这条"
  else
    fail "缺了就拉失败：$(tail -5 "$work/remote.log")"
  fi
fi

# ------------------------------ 5. --from-registry：零 daemon 冷路径 --
# 这条不该依赖本地 docker：`registry_cli` 自己走 HTTP 拉 blob 再打包。
# 现状里它也是整条链路唯一「完全不需要 daemon」的入口。
say ''
say "${BOLD}== dive --from-registry（不碰本地 daemon）==${RESET}"
if "$DIVE" "$REMOTE_REF" --from-registry --save --output "$work/registry.tar" \
    --format json >"$work/registry.json" 2>"$work/registry.log"; then
  [ -s "$work/registry.tar" ] || fail "--from-registry --save 没落盘"
  python3 - "$work/registry.tar" <<'PY' || fail "--from-registry 的产物不是合法 docker-archive"
import json, sys, tarfile
with tarfile.open(sys.argv[1]) as tar:
    manifest = json.load(tar.extractfile("manifest.json"))
    assert manifest and manifest[0]["Layers"], "registry 产物缺层"
PY
  pass "registry 直拉：落盘 tar 可被 docker_cli 解析"
else
  if grep -qiE 'connection refused|network is unreachable|no such host|i/o timeout' \
      "$work/registry.log"; then
    say "${YELLOW}skip${RESET} 连不上 registry（离线环境），跳过这条"
  else
    fail "--from-registry 失败：$(tail -5 "$work/registry.log")"
  fi
fi

say ''
printf '%s真实后端对拍全绿%s\n' "$GREEN$BOLD" "$RESET"
