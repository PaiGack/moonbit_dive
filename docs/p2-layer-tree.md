# P2 `layer_tree` — tar 层叠文件树 + whiteout diff

## 目标

把镜像的每一层 tar 依次应用到一个文件树上，正确处理 OCI/AUFS 的 whiteout 语义，
并给出相邻层之间的 diff。这是 dive 的技术心脏，也是 MoonBit 生态目前完全空白的一段。

## 范围

### 文件树模型

- 节点：路径、类型（file / dir / symlink / hardlink）、大小、权限、所属 layer 索引
- 根节点固定 `/`，路径规范化（去掉 `./`、折叠重复 `/`、拒绝 `..` 逃逸）
- 同一路径被后层覆盖时记录覆盖历史

### tar 应用

- 流式读 tar entry（复用 `bobzhang/tar`），按 entry type 建/改/删节点
- 处理 layer 压缩：gzip / zstd 先解压再喂给 tar 解析
- 硬链接：指向目标节点而不是复制内容
- 符号链接：记录链接目标，不跟随

### whiteout 语义（独立贡献点）

- `.wh.<name>`：删除同目录下名为 `<name>` 的条目
- `.wh..wh..plnk` / 目录级 whiteout：删除整个子树
- overlayfs 的 opaque dir 语义
- whiteout 条目本身不出现在最终文件树里

### 层间 diff

- 给定层 `n-1` 与 `n`，输出 added / modified / removed 三组路径
- removed 集合由 whiteout 推导，不是简单做集合差
- 支持全量层叠：`apply(layers) -> Tree` 与 `diff(layer_n) -> Diff`

### 树渲染

- 参考 dive 的 `renderStringTreeBetween`：以缩进文本树输出，供 CLI 与测试快照使用
- 渲染结果要稳定可快照（`moon test --update`）

## 非目标

- 不做体积统计与评分（P3 的职责）
- 不做交互式 TUI

## 验收

- [ ] 手工构造的多层 tar fixture：普通文件、覆盖、删除、硬链接、符号链接、压缩层各一组
- [ ] whiteout 三种语义各有专门测试，含「删除后再新增同名文件」的边界
- [ ] diff 结果对「删除后新增」「目录整棵被 wh 掉」用例正确
- [ ] 渲染快照测试稳定
- [ ] 大镜像（如 20+ 层）不爆内存，采用流式处理
- [ ] `moon check` / `moon test` 全绿

## 参考

- <https://github.com/opencontainers/image-spec/blob/main/layer.md#whiteouts>（Apache-2.0）
- dive 的 `dive/filetree/`（MIT）：whiteout 与 diff 的原始思路
