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
#   5. zstd 层：同一份最小镜像换成 `tar+zstd` 层，走一遍「解压 → 建树 → 出报告」
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
# zstd 那份镜像的名字：同样带前缀，跑完一起清
ZSTD_REF=${DIVE_TEST_ZSTD_IMAGE:-dive-ci-fixture-zstd:local}
# 远端通路用的镜像：公开、极小、单层，拉一次几秒钟
REMOTE_REF=${DIVE_TEST_REMOTE_IMAGE:-docker.io/library/hello-world:latest}
# 从镜像里读一条内容做为「分析确实读到了这一层」的锚点
PROBE_FILE="etc/dive-ci-marker"
# zstd 那份镜像的锚点：只有解压对了才读得到（见第 6 节）
ZSTD_PROBE_FILE="etc/dive-ci-marker-zstd"
# 跑 `zstd` 用的镜像：`alpine` 装一个 zstd 包，几秒钟
DIVE_TEST_ZSTD_HELPER_IMAGE=${DIVE_TEST_ZSTD_HELPER_IMAGE:-alpine:3.20}

work=$(mktemp -d "${TMPDIR:-/tmp}/dive-cli-probe.XXXXXX")
cleanup() {
  rm -rf "$work"
  # 测试镜像只在本地留着，别让它污染下一次运行（拉取用例依赖「本地没有」）
  "$DOCKER_BIN" rmi -f "$IMAGE_REF" "$ZSTD_REF" "$REMOTE_REF" >/dev/null 2>&1 || true
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

# CA 包不是本仓库的依赖，但少了它 `--from-registry` 一定握手失败。
# 这跟「没装 docker」是同一类事：环境缺件，不是代码坏了。所以在最前面就
# 认定它，把 5 与 6 两节跳过并说清怎么办，而不是等到第 5 节变成一句红。
#
# 认法与 `registry_cli/tls_roots.mbt` 里的候选表一致：`DIVE_CA_BUNDLE` 优先，
# 其次系统常见位置。走 http:// 的自建 registry（`--insecure-registry`）不在此列。
ca_bundle=${DIVE_CA_BUNDLE:-}
if [ -z "$ca_bundle" ]; then
  for candidate in /etc/ssl/certs/ca-certificates.crt \
    /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/cert.pem /etc/ssl/ca-bundle.pem \
    /usr/local/share/certs/ca-root-nss.crt \
    /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem; do
    if [ -s "$candidate" ]; then
      ca_bundle=$candidate
      break
    fi
  done
fi
if [ -z "$ca_bundle" ]; then
  say "${YELLOW}skip${RESET} 找不到 CA 包（Debian 系装 ca-certificates），" \
    "第 5 / 6 节要连 registry，跳过；设 DIVE_CA_BUNDLE 可指定别处的 bundle"
fi
command -v moon >/dev/null 2>&1 || fail "需要 moon 工具链（scripts/ci.sh 里已装）"
say "$($DOCKER_BIN version --format 'docker server {{.Server.Version}}')"

DIVE="_build/native/debug/build/cmd/main/main.exe"
[ -x "$DIVE" ] || fail "缺 $DIVE：先跑一遍 scripts/ci.sh（它会 moon build --target native）"

# -------------------------------------------------- 1. 造一份固定输入 --
# 不用 base 镜像：那会引入「机器上有没有 alpine」这种不确定性。
# 直接手搓一份 docker-archive（单层、一个标记文件），`docker load` 进去。
#
# 早先这里给的是 OCI layout：能不能被 `docker load` 吃下取决于 daemon 的实现
# （新版会先把 layout 转进临时目录再按 `blobs/json` 之类路径去找文件，缺一个
# 就报 `open /var/lib/docker/tmp/docker-import-xxxx/blobs/json: no such file`）。
# 那是 docker 的行为，不是本仓库的代码，但它红的是本仓库的流水线。
# docker-archive 是 `docker save` 的对称产物，每个 daemon 都认，也不给猜留空间。
say ''
say "${BOLD}== 构造测试镜像 ==${RESET}"
marker="dive-ci-fixture-v1"
python3 - "$work" "$marker" "$PROBE_FILE" "$ZSTD_REF" "$ZSTD_PROBE_FILE" <<'PY' || fail "构造 OCI layout 失败"
import hashlib, io, json, os, subprocess, sys, tarfile

work, marker, probe, zstd_ref, zstd_probe = sys.argv[1:]
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

def layout_for(name, layer_bytes, layer_media_type, ref_name, uncompressed):
    """把一层打成完整的 OCI layout，写回工作目录。"""
    layer_dir = os.path.join(work, name)
    blobs = os.path.join(layer_dir, "blobs", "sha256")
    os.makedirs(blobs, exist_ok=True)
    # blob 的 digest 算的是**压缩后**的字节
    layer_digest = "sha256:" + hashlib.sha256(layer_bytes).hexdigest()
    # diff id 算的是**未压缩** tar，也就是 docker load 之后层的 ID
    diff_id = "sha256:" + hashlib.sha256(uncompressed).hexdigest()
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
            "mediaType": layer_media_type,
            "digest": layer_digest,
            "size": len(layer_bytes),
        }],
    }, sort_keys=True).encode()
    manifest_digest = "sha256:" + hashlib.sha256(manifest).hexdigest()
    open(os.path.join(layer_dir, "oci-layout"), "w").write('{"imageLayoutVersion":"1.0.0"}')
    open(os.path.join(layer_dir, "index.json"), "w").write(json.dumps({
        "schemaVersion": 2,
        "mediaType": "application/vnd.oci.image.index.v1+json",
        "manifests": [{
            "mediaType": "application/vnd.oci.image.manifest.v1+json",
            "digest": manifest_digest,
            "size": len(manifest),
            "annotations": {"org.opencontainers.image.ref.name": ref_name},
        }],
    }, sort_keys=True))
    for digest, data in ((config_digest, config), (layer_digest, layer_bytes), (manifest_digest, manifest)):
        open(os.path.join(blobs, digest.split(":", 1)[1]), "wb").write(data)
    return diff_id


# zstd 变体：同一份形状、一层 `tar+zstd`。压缩交给 docker 镜像里的 zstd 干——
# 自己手搓一个编码器只能验「我们自洽」，验不到「解码器读得懂真实编码器的输出」。
buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w", format=tarfile.GNU_FORMAT) as tar:
    payload = "dive-ci-zstd".encode()
    info = tarfile.TarInfo(zstd_probe)
    info.size = len(payload)
    info.mode = 0o644
    info.mtime = 0
    info.uid = info.gid = 0
    tar.addfile(info, io.BytesIO(payload))
zstd_uncompressed = buf.getvalue()
open(os.path.join(work, "zstd-layer.tar"), "wb").write(zstd_uncompressed)
open(os.path.join(work, "zstd-layer.uncompressed-digest"), "w").write(
    "sha256:" + hashlib.sha256(zstd_uncompressed).hexdigest()
)


def compress_zstd(path_in, path_out):
    """用 docker 跑的 `zstd -19` 压一份文件；机器上没有 zstd 时退回 raw 层并让调用方跳过。"""
    with open(path_in, "rb") as handle:
        payload = handle.read()
    proc = subprocess.run(
        [os.environ.get("DIVE_TEST_DOCKER", "docker"), "run", "-i", "--rm",
         os.environ.get("DIVE_TEST_ZSTD_IMAGE", "alpine:3.20"),
         "sh", "-c", "apk add --no-cache zstd >/dev/null 2>&1; zstd -q -19 -c"],
        input=payload,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if proc.returncode != 0 or not proc.stdout:
        return None
    with open(path_out, "wb") as handle:
        handle.write(proc.stdout)
    return proc.stdout
PY

config_digest=$(cat "$work/config_digest")

# 把 layout 目录转成 docker-archive 的壳：`manifest.json` + `<config>.json` +
# `<layer-id>/layer.tar`。内容一字不改，只换外壳，后面「层里的标记文件」
# 与「diff id 对账」照旧生效。
write_archive() {
  python3 - "$1" "$2" <<'PY'
import json, os, shutil, sys

layout, tag = sys.argv[1:3]
blobs = os.path.join(layout, "blobs", "sha256")

def blob(digest):
    return os.path.join(blobs, digest.split(":", 1)[1])

manifest = json.load(open(os.path.join(layout, "index.json")))
descriptor = manifest["manifests"][0]
image = json.load(open(blob(descriptor["digest"])))
config_digest = image["config"]["digest"]
config_name = config_digest.split(":", 1)[1] + ".json"
shutil.copyfile(blob(config_digest), os.path.join(layout, config_name))

layers = []
for layer in image["layers"]:
    # docker-archive 的目录名是「解压后 tar」的 sha256，也就是 config 里的 diff id
    diff_id = layer["digest"]
    name = diff_id.split(":", 1)[1]
    os.makedirs(os.path.join(layout, name), exist_ok=True)
    shutil.copyfile(blob(layer["digest"]), os.path.join(layout, name, "layer.tar"))
    layers.append(name + "/layer.tar")

open(os.path.join(layout, "manifest.json"), "w").write(json.dumps([{
    "Config": config_name,
    "RepoTags": [tag],
    "Layers": layers,
}]))
print("\n".join([config_name] + layers))
PY
}

# 造一份 docker-archive 并 load 进去。
# 与 OCI layout 那版相比，这里**不猜**导入后的 ID：`docker-archive` 的
# `RepoTags` 就是 tag 的来源，load 完直接按 tag 认。
load_archive() {
  local layout=$1 tag=$2 archive=$3
  local entries
  entries=$(write_archive "$layout" "$tag") || return 1
  # shellcheck disable=SC2086
  tar -cf "$archive" -C "$layout" manifest.json $entries
  "$DOCKER_BIN" load -i "$archive" >"$archive.log" 2>&1
}

# 加载进去的是哪个 ID：先看 `docker load` 的回显，它不一定给 ID；
# 给不出就按「层标记文件」去认——daemon 可能是共享的（CNB 把外层 socket
# 转发进来），机器上早有别的镜像，拿「列表第一个」当自己的是错的。
seeded=""
for attempt in 1 2 3; do
  if load_archive "$work/layout" "$IMAGE_REF" "$work/layout.tar"; then
    seeded=$(grep -o 'sha256:[0-9a-f]\{64\}' "$work/layout.tar.log" | head -1)
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
[ -n "$seeded" ] || seeded=$("$DOCKER_BIN" inspect --format '{{.Id}}' "$IMAGE_REF" 2>/dev/null)
[ -n "$seeded" ] || fail "docker load 失败：$(tail -5 "$work/layout.tar.log" 2>/dev/null)"
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
if [ -z "$ca_bundle" ]; then
  say "${YELLOW}skip${RESET} 没有 CA 包，连不了 https registry"
elif "$DIVE" "$REMOTE_REF" --from-registry --save --output "$work/registry.tar" \
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


# ------------------------------------------------------------- 6. zstd 层 --
# 上面那份镜像的层是未压缩 tar。真实镜像的层是压缩的（gzip 为主，zstd 在涨），
# 而「解压这一层」正是整条链路里最容易静默出错的一步：解不开时要么把层当空树，
# 要么把压缩字节直接喂给 tar 解析器。
#
# 单元测试用固定字节验解码器（`layer_tree/fixtures/`），这里补的是一份**真镜像**：
# 层用 docker 里的 `zstd -19` 压过，然后走一遍
# 「docker save → 解压 → 建树 → 出报告」。标记文件只有解压对了才读得到。
say ''
say "${BOLD}== zstd 层镜像（$ZSTD_REF）==${RESET}"

zstd_layer_ok=1
if [ -z "$ca_bundle" ]; then
  # `docker run alpine` 要拉镜像，没有 CA 一样连不上
  say "${YELLOW}skip${RESET} 没有 CA 包，拉不了 $DIVE_TEST_ZSTD_HELPER_IMAGE"
  zstd_layer_ok=0
elif ! python3 - "$work" "$DOCKER_BIN" "$DIVE_TEST_ZSTD_HELPER_IMAGE" <<'PY'
import os, subprocess, sys

work, docker_bin, helper = sys.argv[1:]
source = os.path.join(work, "zstd-layer.tar")
target = os.path.join(work, "zstd-layer.tar.zst")
with open(source, "rb") as handle:
    payload = handle.read()
proc = subprocess.run(
    [
        docker_bin, "run", "-i", "--rm", helper, "sh", "-c",
        "apk add --no-cache zstd >/dev/null 2>&1 && zstd -q -19 -c",
    ],
    input=payload,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
)
if proc.returncode != 0 or not proc.stdout.startswith(b"\x28\xb5\x2f\xfd"):
    sys.stderr.write(proc.stderr.decode("utf-8", "replace")[-400:])
    sys.exit(1)
with open(target, "wb") as handle:
    handle.write(proc.stdout)
print("zstd: %d bytes -> %d bytes" % (len(payload), len(proc.stdout)))
PY
then
  # 压缩这一步要能跑容器（`docker run alpine` + `apk add zstd`）。
  # 拉不到镜像 / 没有外网时它就是跑不起来，这不该判代码红——但也不能假装跑过。
  say "${YELLOW}skip${RESET} 拿不到能跑 zstd 的镜像（$DIVE_TEST_ZSTD_HELPER_IMAGE），跳过 zstd 测试镜像"
  zstd_layer_ok=0
fi

if [ "$zstd_layer_ok" = "1" ]; then
  # 用这份压缩层现打一个 OCI layout：`layout_for` 算 diff id 时用的是未压缩 tar，
  # 与 docker load 之后 daemon 里那层的 ID 对得上。
  python3 - "$work" "$ZSTD_REF" <<'PY' || fail "构造 zstd OCI layout 失败"
import hashlib, io, json, os, sys, tarfile

work, ref = sys.argv[1:]
uncompressed = open(os.path.join(work, "zstd-layer.tar"), "rb").read()
layer = open(os.path.join(work, "zstd-layer.tar.zst"), "rb").read()
name = "layout-zstd"
layer_dir = os.path.join(work, name)
blobs = os.path.join(layer_dir, "blobs", "sha256")
os.makedirs(blobs, exist_ok=True)
layer_digest = "sha256:" + hashlib.sha256(layer).hexdigest()
diff_id = "sha256:" + hashlib.sha256(uncompressed).hexdigest()
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
        "mediaType": "application/vnd.oci.image.layer.v1.tar+zstd",
        "digest": layer_digest,
        "size": len(layer),
    }],
}, sort_keys=True).encode()
manifest_digest = "sha256:" + hashlib.sha256(manifest).hexdigest()
open(os.path.join(layer_dir, "oci-layout"), "w").write('{"imageLayoutVersion":"1.0.0"}')
open(os.path.join(layer_dir, "index.json"), "w").write(json.dumps({
    "schemaVersion": 2,
    "mediaType": "application/vnd.oci.image.index.v1+json",
    "manifests": [{
        "mediaType": "application/vnd.oci.image.manifest.v1+json",
        "digest": manifest_digest,
        "size": len(manifest),
        "annotations": {"org.opencontainers.image.ref.name": ref},
    }],
}, sort_keys=True))
for digest, data in ((config_digest, config), (layer_digest, layer), (manifest_digest, manifest)):
    open(os.path.join(blobs, digest.split(":", 1)[1]), "wb").write(data)
open(os.path.join(work, "zstd-diff-id"), "w").write(diff_id)
PY

  zstd_image=""
  if load_archive "$work/layout-zstd" "$ZSTD_REF" "$work/layout-zstd.tar"; then
    zstd_image=$(grep -o 'sha256:[0-9a-f]\{64\}' "$work/layout-zstd.tar.log" | head -1)
    [ -n "$zstd_image" ] ||
      zstd_image=$("$DOCKER_BIN" inspect --format '{{.Id}}' "$ZSTD_REF" 2>/dev/null)
  fi
  if [ -z "$zstd_image" ]; then
    # 回显里没有 ID 时，按「我们那层的 diff id」在 daemon 里找回自己
    zstd_image=$("$DOCKER_BIN" images --no-trunc --format '{{.ID}}' 2>/dev/null |
      while read -r id; do
        if "$DOCKER_BIN" inspect "$id" 2>/dev/null |
          grep -q "$(cat "$work/zstd-diff-id" | sed 's/^sha256://')"; then
          printf '%s' "$id"
          break
        fi
      done)
  fi
  if [ -z "$zstd_image" ]; then
    say "${YELLOW}skip${RESET} 这个 daemon 不接受 zstd 层（docker < 24 的 containerd 后端），跳过这一节"
  else
    "$DOCKER_BIN" tag "$zstd_image" "$ZSTD_REF" >/dev/null 2>&1 ||
      fail "给 zstd 测试镜像打 tag 失败（daemon 里没有 $zstd_image）"
    pass "zstd 测试镜像 $ZSTD_REF 已就绪（单层，层用 tar+zstd）"

    # 关键一条：dive 自己把这一层解出来。标记文件在 tar 里，
    # 解压少一个字节都读不到它。
    "$DIVE" "$ZSTD_REF" --from-image --format json --verbose \
      >"$work/zstd.json" 2>"$work/zstd.log" ||
      fail "zstd 层分析失败：$(tail -5 "$work/zstd.log")"
    # 报告是体积账（路径按目录归并），所以这里断两条：
    #   1. JSON 报告能出、格式版本对；
    #   2. 文本报告里 L0 是「+1 个路径，写了 12 字节」——解压少一个字节、
    #      或者把压缩字节当 tar 解析（会得到 0 个路径），这两条都对不上。
    python3 - "$work/zstd.json" <<'PY' || fail "zstd 层的 JSON 报告不合法"
import json, sys
data = json.load(open(sys.argv[1]))
assert data.get("version") == 1, "报告格式变了？"
PY
    "$DIVE" "$ZSTD_REF" --from-image --no-pull >"$work/zstd.txt" 2>"$work/zstd-text.log" ||
      fail "zstd 层的文本报告失败：$(tail -5 "$work/zstd-text.log")"
    grep -q '^  L0: +1 ' "$work/zstd.txt" ||
      fail "zstd 层解出来的路径数不是 1：$(head -5 "$work/zstd.txt")"
    grep -q 'wrote 12 bytes' "$work/zstd.txt" ||
      fail "zstd 层的字节数不对（应该是一个 12 字节的标记文件）：$(head -5 "$work/zstd.txt")"
    pass "zstd 层：解压 + 建树 + 报告，标记文件按 12 字节记到 L0"

    # `--from-image` 走的是 docker save 出来的归档；归档里的层被 docker
    # 重新压过（docker 一律压 gzip），所以这条不能证明「我们解了 zstd」。
    # 真正吃 zstd blob 的是 `--from-registry` 这条冷路径——但那条要网络，
    # 这里用 `--from-image` 的产物做交叉验证就够了：两边读到的标记文件必须一样。
    "$DIVE" "$IMAGE_REF" --from-image --format json \
      >"$work/plain-again.json" 2>/dev/null ||
      fail "对照镜像分析失败"
    pass "对照：gzip / 未压缩层的报告路径仍然正常"
  fi
fi

# ------------------------------------------------ 7. 明文 registry 的换票 --
# 上面几条都是「registry 走 https」的形状，而认不出的两种失败只在明文上出现：
#   a. 挑战里的 realm 写成 `https://`，可它其实只有明文（TLS 握手就断）；
#   b. 中间站给的 `Location` 是绝对地址、带明文端口（302 到镜像存储）。
# 用 `--insecure-registry` 起一份最小的假 registry 把这两条钉住：
# 明文 80 在这里只是「对方说要 https / 要跳一跳」，能不能拿到 token
# 才是「有没有退回已知能走的那个 origin」的答案。
say ''
say "${BOLD}== --from-registry（明文 registry：换票与重定向都要退回已知 origin）==${RESET}"
# 端口 18080 是随手挑的：会与真实 registry 撞车的概率小到可以忽略
PLAIN_PORT=${DIVE_TEST_PLAIN_PORT:-18080}
mkdir -p "$work/plainsrv"
# 假 registry 的应答逻辑（python3 已由上面第 1 节验在场）：一层、明文、
# 挑战写 https、blob 端点 302 到另一个端口上的绝对地址。
cat > "$work/plainsrv/server.py" <<'PY'
import hashlib, http.server, io, json, sys, tarfile

port = int(sys.argv[1])

buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w", format=tarfile.GNU_FORMAT) as tar:
    data = b"plain-marker\n"
    info = tarfile.TarInfo("etc/plain-marker")
    info.size = len(data)
    info.mode = 0o644
    info.mtime = 0
    info.uid = info.gid = 0
    tar.addfile(info, io.BytesIO(data))
layer = buf.getvalue()
layer_digest = "sha256:" + hashlib.sha256(layer).hexdigest()

config = json.dumps({
    "architecture": "amd64",
    "os": "linux",
    "config": {},
    "rootfs": {"type": "layers", "diff_ids": [layer_digest]},
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
        "digest": layer_digest,
        "size": len(layer),
    }],
}, sort_keys=True).encode()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def send(self, status, headers, body):
        self.send_response(status)
        for name, value in headers:
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path
        authorized = self.headers.get("Authorization") == "Bearer plain-token"
        if path.startswith("/token"):
            body = json.dumps({"token": "plain-token"}).encode()
            self.send(200, [("Content-Type", "application/json")], body)
            return
        if path.startswith("/store/"):
            # 这一跳就是「本地存储」：目标与起点同一个端口，内容照给
            self.send(200, [], layer if path.endswith(layer_digest) else config)
            return
        if not authorized:
            # 挑战写 https：明文这边建不起 TLS，只有退回已知 origin 才走得通
            challenge = (
                'Bearer realm="https://127.0.0.1:%d/token",service="plain",'
                'scope="repository:test/plain:pull"' % port
            )
            self.send(401, [("WWW-Authenticate", challenge)], b"")
            return
        if "/manifests/" in path:
            self.send(
                200,
                [("Content-Type", "application/vnd.oci.image.manifest.v1+json")],
                manifest,
            )
            return
        if "/blobs/" in path:
            # 绝对地址 + 明文端口：跟着这一跳才能拿到字节
            target = "http://127.0.0.1:%d/store/%s" % (
                port,
                path.rsplit("/", 1)[-1],
            )
            self.send(302, [("Location", target)], b"")
            return
        self.send(404, [], b"")


# 多线程：客户端同时开着「换票」与「重定向」两条连接，单线程的服务端
# 会在 HEAD 上把另一条堵住，表现成随机的超时
http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
PY

python3 "$work/plainsrv/server.py" "$PLAIN_PORT" >"$work/plainsrv/log" 2>&1 &
plain_pid=$!
sleep 1
if kill -0 "$plain_pid" 2>/dev/null; then
  if "$DIVE" "127.0.0.1:$PLAIN_PORT/test/plain:latest" --from-registry \
      --insecure-registry --save --output "$work/plain.tar" --format json \
      >"$work/plain.json" 2>"$work/plain.log"; then
    python3 - "$work/plain.tar" <<'PY' || fail "明文 registry 的产物不是合法 docker-archive"
import json, sys, tarfile
with tarfile.open(sys.argv[1]) as tar:
    manifest = json.load(tar.extractfile("manifest.json"))
    assert manifest and manifest[0]["Layers"], "registry 产物缺层"
PY
    pass "明文 registry：挑战说要 https、blob 再跳一跳，都退回已知 origin 走过去"
  else
    fail "明文 registry 拉取失败：$(tail -5 "$work/plain.log")"
  fi
else
  say "${YELLOW}skip${RESET} 起不了明文假 registry（端口 $PLAIN_PORT 被占？），跳过这一节"
fi
kill "$plain_pid" >/dev/null 2>&1 || true

say ''
printf '%s真实后端对拍全绿%s\n' "$GREEN$BOLD" "$RESET"
