---
memo: todos
format: v3
epic: resource-center
---

# resource-center · 域内待办
- [ ] [2026-10-19] (风险) (层:L1) (重:中) 直选路径严禁旁路 ResourceStore.import 校验闸门（存在性/10MB/utf8 严格解码/NUL 探测/tmp+rename 复制入库）：禁直接持原路径 attach——否则原文件改删致会话引用漂移，且击穿一期文本类与体积边界 (src: ai, 挂载点复盘)
