/// L2 写操作确认卡（ui-design §3.2 操作卡片状态机：Amber 竖条 + 折叠参数区 +
/// 「本会话记住」豁免（拍板 C7）+ 终态锁定审计感）。
///
/// 弹出触觉 = 双击警示震动（§4.1）；确认/拒绝后锁定为灰阶弱化态、按钮消失。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:goodhub/coordinator/permission_gateway.dart';

import '../tokens/console_tokens.dart';

class ConfirmationCard extends StatefulWidget {
  const ConfirmationCard({
    required this.toolName,
    required this.argumentsJson,
    this.onDecision,
    this.lockedDecision,
    this.lockedAt,
    super.key,
  }) : assert(
          (onDecision == null) == (lockedDecision != null),
          '交互态给 onDecision，终态给 lockedDecision/lockedAt',
        );

  /// 交互态回调（终态时为 null）。
  final void Function(GateDecision decision)? onDecision;

  /// 终态锁定：已作出的裁决（灰阶展示，无按钮）。
  final GateDecision? lockedDecision;
  final DateTime? lockedAt;

  final String toolName;
  final String argumentsJson;

  @override
  State<ConfirmationCard> createState() => _ConfirmationCardState();
}

class _ConfirmationCardState extends State<ConfirmationCard> {
  final _reasonCtrl = TextEditingController();
  var _remember = false;

  static String _hhmm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  @override
  void initState() {
    super.initState();
    if (widget.onDecision != null) {
      // §4.1：L2 拦截卡弹出 → 双击警示震动（同步连发，不挂 Timer）
      HapticFeedback.heavyImpact();
      HapticFeedback.heavyImpact();
    }
  }

  @override
  void dispose() {
    _reasonCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = consoleTokens(context);
    final locked = widget.lockedDecision;
    if (locked != null) {
      final at = widget.lockedAt ?? DateTime.now();
      final text = locked.approved
          ? '✓ 已于 ${_hhmm(at)} 确认'
          : '✕ 已拒绝（原因：${locked.reason ?? '用户拒绝'}）';
      return _frame(
        context,
        barColor: t.terminalMuted,
        child: Text(
          text,
          style: TextStyle(
            color: t.terminalMuted,
            fontSize: 13,
            fontFamily: locked.approved ? null : t.monoFamily,
          ),
        ),
      );
    }
    return _frame(
      context,
      barColor: t.l2Warn,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('写操作确认', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.toolName,
                  style: TextStyle(
                    fontFamily: t.monoFamily,
                    fontSize: 12,
                    color: t.l2Warn,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          _argsBlock(context),
          const SizedBox(height: 6),
          TextField(
            controller: _reasonCtrl,
            enabled: widget.onDecision != null,
            decoration: const InputDecoration(
              labelText: '拒绝理由（可空，将回传模型原地修正）',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            style: const TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 4),
          // 拍板 C7：会话级豁免（内存态，会话结束/Abort 失效，不落盘）
          CheckboxListTile(
            value: _remember,
            onChanged: (v) => setState(() => _remember = v ?? false),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text(
              '本会话记住该工具（会话结束/中止即失效）',
              style: TextStyle(fontSize: 12.5),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => widget.onDecision?.call(GateDecision(
                  approved: false,
                  reason: _reasonCtrl.text.trim().isEmpty
                      ? null
                      : _reasonCtrl.text.trim(),
                )),
                child: Text('拒绝', style: TextStyle(color: t.danger)),
              ),
              const SizedBox(width: 8),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: t.l2Warn),
                onPressed: () => widget.onDecision?.call(GateDecision(
                  approved: true,
                  rememberSession: _remember,
                )),
                child: const Text('确认执行'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 参数区：折叠键值对（严禁大段无排版 JSON，§3.2）；解析失败退回原文等宽。
  Widget _argsBlock(BuildContext context) {
    final t = consoleTokens(context);
    final mono = TextStyle(fontFamily: t.monoFamily, fontSize: 11.5);
    final raw = widget.argumentsJson.trim().isEmpty ? '{}' : widget.argumentsJson;
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      decoded = null;
    }
    if (decoded is! Map) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: t.hairline,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(raw, style: mono),
      );
    }
    final entries = decoded.entries.toList();
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.zero,
        dense: true,
        title: Text('入参 (${entries.length})', style: mono),
        children: [
          for (final e in entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${e.key}: ', style: mono),
                  Expanded(
                    child: Text(
                      '${e.value}',
                      style: mono,
                      overflow: TextOverflow.ellipsis,
                      maxLines: 4,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _frame(BuildContext context,
      {required Color barColor, required Widget child}) {
    final t = consoleTokens(context);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(t.cardRadius),
        border: Border.all(color: t.hairline),
        color: Theme.of(context).cardColor,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(t.cardRadius),
        // IntrinsicHeight：ListView 无界高度下 stretch 竖条须按内容自量
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(width: 4, color: barColor),
              Expanded(
                child: Material(
                  type: MaterialType.transparency,
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: child,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
