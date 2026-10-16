/// 输入条内嵌状态带（§3.1，步 4 对账 Epic C 外提，纯视图件）：状态做在输入框
/// 本身上沿，不挤占文本区。idle 由调用处将高度收 0（AnimatedContainer 平滑），
/// 运行态展开为极简状态带：1px hairline 分隔 + 呼吸点 + 等宽相位；文本输入区
/// 始终全宽（D+B 改造）。已绑定私有服务时，状态带常驻显示上下文胶囊（药丸内
/// 弱感知）；公共态（有可绑定端点）显示「公共」胶囊。**胶囊可点 → 打开会话
/// 上下文菜单**，因此即便输入中「+」隐藏，也能随时切换绑定（解决输入一半想切
/// 服务的痛点）。
library;

import 'package:flutter/material.dart';

import '../tokens/console_tokens.dart';
import 'status_capsule.dart';

class StatusStrip extends StatelessWidget {
  const StatusStrip({
    super.key,
    required this.t,
    required this.pillTone,
    required this.pillLabel,
    required this.running,
    required this.runStartedAt,
    required this.contextId,
    required this.localPluginCount,
    required this.hasEndpoints,
    required this.endpointName,
    required this.onOpenMenu,
  });

  final ConsoleTokens t;
  final CapsuleTone pillTone;
  final String pillLabel;
  final bool running;
  final DateTime? runStartedAt;

  /// 本会话三态绑定：null=未绑定 / ''=显式公共 / id=锁定。
  final String? contextId;
  final int localPluginCount;
  final bool hasEndpoints;
  final String Function(String id) endpointName;
  final VoidCallback onOpenMenu;

  /// 胶囊标签人话化：内部英文相位 → 用户可读中文；工具名等宽原名保持透传。
  /// P1-6：breaker/fence 去黑话（「熔断排查/围栏拦截」→ 报的是什么、等什么）。
  static String pillText(String label) => switch (label) {
    'idle' => '空闲',
    'connecting' => '连接中',
    'thinking' => '思考中',
    'done' => '已完成',
    'failed' => '失败',
    'rejected' => '已拒绝',
    'breaker' => '工具报错，待处理',
    'fence' => '敏感信息，待确认',
    _ => label,
  };

  /// 已耗时格式化（mm:ss），自 [runStartedAt] 起算，供运行态计时显示。
  static String fmtElapsed(DateTime start) {
    final s = DateTime.now().difference(start).inSeconds;
    final m = s ~/ 60;
    final sec = s % 60;
    return '${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final color = switch (pillTone) {
      CapsuleTone.idle => t.terminalMuted,
      CapsuleTone.l1 => t.l1Info,
      CapsuleTone.l2 => t.l2Warn,
      CapsuleTone.danger => t.danger,
    };
    final hasCtx = contextId != null && contextId!.isNotEmpty;
    final hasLocal = localPluginCount > 0;
    // 绑定私有端点 / 本地插件 均按「私有」呈现（锁形 + l1 色），不视作公有；
    // 三者任一即显示上下文胶囊（均可点开菜单）。
    final isPrivate = hasCtx || hasLocal;
    final showChip = isPrivate || hasEndpoints;
    Widget? chip;
    if (showChip) {
      final chipColor = isPrivate ? t.l1Info : t.terminalMuted;
      final chipIcon = isPrivate ? Icons.lock_outline : Icons.public;
      final chipText = hasCtx
          ? endpointName(contextId!)
          : (hasLocal ? '本地×$localPluginCount' : '公共');
      chip = GestureDetector(
        onTap: onOpenMenu,
        child: Container(
          margin: const EdgeInsets.only(right: 8),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: chipColor.withValues(alpha: 0.16),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                chipIcon,
                size: 11,
                color: chipColor,
              ),
              const SizedBox(width: 4),
              Text(
                chipText,
                style: TextStyle(
                  fontFamily: t.monoFamily,
                  fontSize: Fsz.micro,
                  color: chipColor,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: t.hairline, width: 1)),
      ),
      child: Row(
        children: [
          ? chip,
          // §4.2 紧凑动效：状态点颜色随相位过渡（150~200ms，禁 Spring）。
          AnimatedContainer(
            width: 7,
            height: 7,
            duration: t.fastDuration,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              pillText(pillLabel),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: t.monoFamily,
                fontSize: Fsz.micro,
                color: color,
              ),
            ),
          ),
          if (running && runStartedAt != null)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text(
                fmtElapsed(runStartedAt!),
                style: TextStyle(
                  fontFamily: t.monoFamily,
                  fontSize: Fsz.micro,
                  color: color,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
