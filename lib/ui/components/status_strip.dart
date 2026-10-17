/// 输入条内嵌状态带（§3.1，步 4 对账 Epic C 外提，纯视图件）：状态做在输入框
/// 本身上沿，不挤占文本区。idle 由调用处将高度收 0（AnimatedContainer 平滑），
/// 运行态展开为极简状态带：1px hairline 分隔 + 呼吸点 + 等宽相位；文本输入区
/// 始终全宽（D+B 改造）。已绑定私有服务时，状态带常驻显示上下文胶囊（药丸内
/// 弱感知）；公共态（有可绑定端点）显示「公共」胶囊。**胶囊可点 → 打开会话
/// 上下文菜单**，因此即便输入中「+」隐藏，也能随时切换绑定（解决输入一半想切
/// 服务的痛点）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../tokens/console_tokens.dart';
import 'status_capsule.dart';

/// 上下文胶囊——本会话绑定的私有服务 / 本地插件 / 公共态的弱感知，点击
/// 打开会话上下文菜单。[SSOT 修正] B6 已回退（2026-10-17 用户拍板）：
/// 胶囊只挂输入框上方状态带（B6 曾把 idle 期胶囊融输入行，已撤销），
/// 显隐由状态带展开条件决定（running || hasContext || hasEndpoints）。
class ContextChip extends StatelessWidget {
  const ContextChip({
    super.key,
    required this.t,
    required this.contextId,
    required this.localPluginCount,
    required this.hasEndpoints,
    required this.endpointName,
    required this.onTap,
  });

  final ConsoleTokens t;

  /// 本会话三态绑定：null=未绑定 / ''=显式公共 / id=锁定。
  final String? contextId;
  final int localPluginCount;
  final bool hasEndpoints;
  final String Function(String id) endpointName;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hasCtx = contextId != null && contextId!.isNotEmpty;
    final hasLocal = localPluginCount > 0;
    // 绑定私有端点 / 本地插件 均按「私有」呈现（锁形 + l1 色），不视作公有。
    final isPrivate = hasCtx || hasLocal;
    final chipColor = isPrivate ? t.l1Info : t.terminalMuted;
    final chipIcon = isPrivate ? Icons.lock_outline : Icons.public;
    final chipText = hasCtx
        ? endpointName(contextId!)
        : (hasLocal ? '本地×$localPluginCount' : '公共');
    return GestureDetector(
      // B3：轻触觉确认（点击已被接收的确定感）。
      onTap: () {
        unawaited(HapticFeedback.selectionClick());
        onTap();
      },
      child: Container(
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: chipColor.withValues(alpha: 0.16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(chipIcon, size: 11, color: chipColor),
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
}

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

  /// A2（page-beautify）：工具名 → 人话动作标签。优先取服务端下发的
  /// description 首子句（goodshare 侧实证为中文人话长句，首子句即动作）；
  /// 无描述回退裸工具名（剥 `<serverId>__` 服务前缀）；无分隔符（宿主
  /// 本地工具）原样透传。原始前缀名仍由 CallCard 头部等宽遥测轨展示。
  static String toolAction(
    String prefixedName,
    Map<String, String> descriptions,
  ) {
    final desc = descriptions[prefixedName]?.trim();
    if (desc != null && desc.isNotEmpty) return shortClause(desc);
    final i = prefixedName.indexOf('__');
    return i > 0 ? prefixedName.substring(i + 2) : prefixedName;
  }

  /// 长描述 → 短标签：至首个分隔标点（中英文句读 / 左括号，描述常见
  /// 「……（原文 + 机器态）；……」结构）——自然截断不加省略号（短语已完整）；
  /// 无标点且超 16 字才硬截并加省略号。
  static String shortClause(String text) {
    final t = text.trim();
    if (t.isEmpty) return t;
    const seps = '。；;！!？?（(';
    for (var i = 0; i < t.length; i++) {
      if (seps.contains(t[i])) return t.substring(0, i);
    }
    if (t.length <= 16) return t;
    return '${t.substring(0, 16)}…';
  }

  /// 已耗时格式化（mm:ss），自 [start] 起算，供运行态计时显示。
  /// [now] 为可注入时间源（默认 `DateTime.now`，测试可控）。
  static String fmtElapsed(DateTime start, [DateTime Function() now = DateTime.now]) {
    final s = now().difference(start).inSeconds;
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
    // running 态三者任一即显示上下文胶囊（可点开菜单；idle 期胶囊在输入条）。
    final isPrivate = hasCtx || hasLocal;
    final showChip = isPrivate || hasEndpoints;
    Widget? chip;
    if (showChip) {
      chip = ContextChip(
        t: t,
        contextId: contextId,
        localPluginCount: localPluginCount,
        hasEndpoints: hasEndpoints,
        endpointName: endpointName,
        onTap: onOpenMenu,
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
              child: ElapsedText(start: runStartedAt!, t: t, color: color),
            ),
        ],
      ),
    );
  }
}

/// 已耗时自管件（window-slim P1-B 续 · chat_page 二轮下沉切片 A）：原先由
/// ChatPage 每秒 `setState` 重建整页（含输入框 TextField）只为刷新本 `mm:ss`
/// 文本——典型反模式，且运行态逐秒重建 TextField 有丢光标/焦点风险。改由本件
/// 自持 1s 定时器，仅自身重建，杜绝整页级重绘级联（状态流转与 UI 分离的第一步）。
class ElapsedText extends StatefulWidget {
  const ElapsedText({
    super.key,
    required this.start,
    required this.t,
    required this.color,
    this.now = DateTime.now,
  });
  final DateTime start;
  final ConsoleTokens t;
  final Color color;
  /// 时间源（副作用收敛端口：默认真实时钟，测试可注入可控时钟，避免 fake-timer
  /// 与真实时钟错位导致数值不可测）。
  final DateTime Function() now;

  @override
  State<ElapsedText> createState() => _ElapsedTextState();
}

class _ElapsedTextState extends State<ElapsedText> {
  late String _text = StatusStrip.fmtElapsed(widget.start, widget.now);
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() => _text = StatusStrip.fmtElapsed(widget.start, widget.now));
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text(
        _text,
        style: TextStyle(
          fontFamily: widget.t.monoFamily,
          fontSize: Fsz.micro,
          color: widget.color,
        ),
      );
}
