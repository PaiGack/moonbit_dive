# P2 `layer_tree` — tar 层叠文件树 + whiteout diff

这是 dive 的心脏，也是本项目最有独立贡献的部分：MoonBit 生态目前没有人实现 `.wh.` whiteout 语义。

## 目标

把「逐层 tar 流」应用成一棵持久化文件树，并支持层间 diff。

## 范围

### 流式 tar 应用

- 复用生态已有的 tar 读取（`bobzhang/tar`）+ zstd/gzip 解压（`Milky2018/zstd`、`gmlewis/*`）
- 按顺序把每层 tar entry 应用到树上：新增、覆盖（后者胜）、删除
- 处理目录 entry 与隐式目录（tar 里没有显式目录 entry 的情况）
- 处理路径规范化：`./` 前缀、重复 `/`、`..` 逃逸检测（拒绝越界路径）

### whiteout 语义

- `.wh.<name>`：删除同层目录下的 `<name>`（文件或目录整棵子树）
- `.wh..wh..plnk`：硬链接占位（overlayfs 语义），记录为特殊节点
- `.wh..wh..opq`：不透明目录，标记该目录下层之前的内容全部被遮蔽
- 与上游 dive 语义逐条对齐，每条有测试

### 层间 diff

- 相邻层 diff：新增 / 修改 / 删除 / 白名单删除
- 任意两层 diff（dive 的 `renderStringTreeBetween`）
- 输出可读的树形文本，缩进 + 变更标记（dive 用 `A`/`M`/`D` 一类符号）

### 硬链接与元数据

- 记录 linkname、mode、uid/gid、mtime（体积分析用不到全部，但 diff 展示需要）
- 硬链接去重：同一 inode 的多个路径只算一份体积

## 非目标

- 不做真实文件系统落盘（内存树足够分析场景）
- 不做 tar 写出

## 验收

- [ ] 用真实镜像（如 `alpine`、`busybox` 的小 layer 集）构造 fixture，应用结果与 `docker save` + 手工比对一致
- [ ] whiteout 四种情况各至少一个测试，含「白名单删除整棵子树」
- [ ] 路径逃逸（`../../etc/passwd`）被拒绝并有错误信息
- [ ] 树渲染输出有快照测试
- [ ] `moon check` / `moon test` 全绿

## 参考

- dive `dive/filetree/`（约 1500 行 Go）与 overlayfs 文档
- OCI image-spec 的 layer 应用规则
