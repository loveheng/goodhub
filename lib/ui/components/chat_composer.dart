import 'package:flutter/material.dart';

import '../tokens/console_tokens.dart';
import 'status_capsule.dart';
import 'status_strip.dart';

/// 底部输入集群（断点③ step2：从 `chat_page.build` 抽出，传数据与回调，
/// 不依赖 `_ChatPageState` 私有态）。含状态带 + 输入条 + 发送/中止单槽复用钮。
class ChatComposer extends StatelessWidget {
  const ChatComposer({
    super.key,
    required this.inputCtrl,
    required this.running,
    required this.hasContext,
    required this.contextId,
    required this.endpointName,
    required this.hasEndpoints,
    required this.localPluginCount,
    required this.pillTone,
    required this.pillLabel,
    required this.runStartedAt,
    required this.onOpenMenu,
    required this.onSend,
    required this.onAbort,
  });

  final TextEditingController inputCtrl;
  final bool running;
  final bool hasContext;
  final String? contextId;
  final String Function(String id) endpointName;
  final bool hasEndpoints;
  final int localPluginCount;
  final CapsuleTone pillTone;
  final String pillLabel;
  final DateTime? runStartedAt;
  final VoidCallback onOpenMenu;
  final VoidCallback onSend;
  final VoidCallback onAbort;

  @override
  Widget build(BuildContext context) {
    final t = consoleTokens(context);
    return SafeArea(
      top: false,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
            // 底部控制集群：药丸输入条（状态带 + 相位 + 输入 + 主操作钮）；
            // 运行态发送钮形变复用为「中止」键（§3.1：单一主操作槽切换
            // 发送↔中止，避免右侧另起红键挤占输入区，省一条常驻空行）。
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: t.hairline),
                      color: Theme.of(context).cardColor,
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // §3.1 状态做在输入框本身上沿（框内顶部状态带），idle
                        // 高度收 0，运行态平滑展开；文本输入区始终全宽（D+B 改造）。
                        AnimatedContainer(
                          duration: t.fastDuration,
                          curve: Curves.easeOut,
                          height: (running || hasContext || hasEndpoints) ? 30 : 0,
                          clipBehavior: Clip.antiAlias,
                          decoration: const BoxDecoration(
                            borderRadius: BorderRadius.vertical(
                              top: Radius.circular(24),
                            ),
                          ),
                          child: StatusStrip(
                            t: t,
                            pillTone: pillTone,
                            pillLabel: pillLabel,
                            running: running,
                            runStartedAt: runStartedAt,
                            contextId: contextId,
                            localPluginCount: localPluginCount,
                            hasEndpoints: hasEndpoints,
                            endpointName: endpointName,
                            onOpenMenu: onOpenMenu,
                          ),
                        ),
                        Row(
                          children: [
                            IconButton(
                              icon: const Icon(Icons.add),
                              tooltip: '会话上下文（绑定 MCP 服务）',
                              onPressed: onOpenMenu,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                  minWidth: 36, minHeight: 36),
                            ),
                            Expanded(
                              child: TextField(
                                controller: inputCtrl,
                                // 运行中保持可预输入（发送由按钮/_guard 挡 running）。
                                minLines: 1,
                                maxLines: 4,
                                textInputAction: TextInputAction.send,
                                decoration: InputDecoration(
                                  hintText: running
                                      ? '生成中…可先预输入下一轮'
                                      : '描述任务…（Enter 发送；如：列出今天的待办）',
                                  border: InputBorder.none,
                                  contentPadding:
                                      const EdgeInsets.fromLTRB(14, 12, 6, 12),
                                ),
                                onSubmitted: (_) => onSend(),
                              ),
                            ),
                            const SizedBox(width: 4),
                            // §3.1 复用发送钮：运行态形变为主操作「中止」键，
                            // 单一槽位内切换 发送↔中止，避免右侧另起红键挤占输入区。
                            // P1-4（§1 高反差拍板）：Crimson 实底 + 白图标 +
                            // 40×40——filledTonal 的 tonal 底在运行态不足以让
                            // 普通用户一眼找到「停止」。
                            IconButton.filledTonal(
                              style: IconButton.styleFrom(
                                minimumSize: const Size(40, 40),
                                padding: EdgeInsets.zero,
                                foregroundColor: running ? Colors.white : null,
                                backgroundColor: running ? t.dangerDeep : null,
                              ),
                              onPressed: running ? onAbort : onSend,
                              tooltip: running ? '中止' : '发送',
                              icon: Icon(
                                running ? Icons.stop : Icons.arrow_upward,
                                size: 20,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
