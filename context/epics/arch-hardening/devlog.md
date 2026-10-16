---
dev-loop: devlog
format: v1
epic: arch-hardening
total-merged: 0
last-merge: none
---

（开发过程日志按行追加：[变更]/[验证]/[note]/[SSOT 修正]；≥5 条自动归并进 memory.md——dev-loop §2）
- [2026-10-16] [变更]: epic 立项：承接 window-kernel-split（已归档立法 epic）步 0→3 施工；施工稿 docs/design/arch-hardening.md；断点=步 0 立契约
- [2026-10-16] [验证]: 未执行: 立项轮无代码变更
- [2026-10-16] [变更]: 重勘认定：步 0-2（契约件/单入口/三调用点收敛）已由 window-kernel-split 施工完成；剩余范围为四条反向边斩断，影响清单已列待用户确认
- [2026-10-16] [验证]: 未执行: 重勘轮无代码变更
- [2026-10-16] [变更]: 反向边斩断四条闭环：①gateway→ui（弹层迁 ui/gateway_consent_dialog.dart + fail-closed headless_no_ui_prompt）②mcp→coordinator（ConnectionFace 注入 + ToolExecutionResult 下沉 core + AuditSink 端口）③mcp→llm（SamplingEngine 端口 + core ChatMessageData 消息货币 + 云适配 llm/cloud/sampling_engine.dart）④sandbox→llm（transcript codec 迁 llm/cloud/chat_message_codec.dart，存储层纯 JSON+core DTO）；红灯表与索引债表同步清零
- [2026-10-16] [验证]: flutter analyze → 0 issue；flutter test --timeout 120s → 706 例，704 过 2 败（memory_kernel_test×2，HEAD 存量非本轮引入，见下）
