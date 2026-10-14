---
dev-loop: devlog
format: v1
epic: stream-perf
total-merged: 1
last-merge: 2026-10-14
---

（开发过程日志按行追加：[变更]/[验证]/[note]/[SSOT 修正]；≥5 条自动归并进 memory.md——dev-loop §2）
- [2026-10-14] [变更]: 测试阶段:补 P1 优化效果机械证明测试(计量 parser 包裹真实 parser,流式喂入 1.4K 字符多块文本,增量解析总量 2999 vs 全量重解析口径 13366 字符=4.5x 降幅,且未计入 P0 节流对 ingest 频次的削减);清 2 处本轮 analyze 新增(dual_track unused_import/测试 brace interp)
- [2026-10-14] [验证]: flutter analyze 1 issue=存量基线 0 新增;flutter test --timeout 120s 全量 443 绿(442+1 新增);flutter build apk --debug 成功;adb install -r 真机 CPH2767 成功;am start MainActivity 进程存活无崩溃日志
- [2026-10-14] [变更]: 流式滚动跟随纠偏(详见 page-revamp devlog 同日 B 项):_pinToBottom 由「每 40ms flush 强制 jumpTo 底部」改为用户上翻暂停自动跟随 + 回底 FAB,流式输出期不再劫持用户滚动;P0 节流缓冲机制不变
