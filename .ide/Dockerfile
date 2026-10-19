# .ide/Dockerfile
#
# CNB 的 web-ide / 流水线共用这个镜像：装好 MoonBit 工具链、
# native 后端需要的 C 工具链，以及一堆 VS Code 扩展。
# cnb 用 versionBy: .ide/Dockerfile 做缓存键——这个文件变了才会重新 build。
FROM cnbcool/default-dev-env:latest

# moonbit native 后端要 gcc/glibc；其余是裸环境里调试常用的小工具。
# docker-cli + curl 给「真实后端对拍」用（scripts/docker-cli-probe.sh）：
# 它在流水线里会 `docker inspect` / `save` / `pull`，镜像里没客户端就只能跳过。
RUN apt-get update && apt-get install -y --no-install-recommends \
      gcc libc6-dev libssl-dev strace python3 openssl ca-certificates \
      curl docker.io \
    && rm -rf /var/lib/apt/lists/*

# MoonBit 工具链（国内镜像），顺手验一次版本，装失败就直接让 build 挂掉。
RUN curl -fsSL https://cli.moonbitlang.cn/install/unix.sh | bash \
     && "$HOME/.moon/bin/moon" version \
     && code-server --install-extension moonbit.moonbit-lang

RUN curl -fsSL https://downloads.claude.ai/claude-code-releases/bootstrap.sh | bash

RUN curl -fsSL https://github.com/SaladDay/cc-switch-cli/releases/latest/download/install.sh | bash

ENV PATH="$PATH:/root/.local/bin:/root/.moon/bin"

ENV workspace="/workspace"

RUN code-server --install-extension tamasfe.even-better-toml \
     && code-server --install-extension usernamehw.errorlens \
     && code-server --install-extension chanhx.crabviz \
     && code-server --install-extension Anthropic.claude-code
