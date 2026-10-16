/// 网关 L2 确认卡的 Flutter 弹层实现（arch-hardening ①：从 gateway 域迁入
/// 窗口层——`appNavigatorKey` 与 material 属 UI，gateway 域只保留
/// [GateDelegate] 接口与 fail-closed 语义，不再反向 import ui/）。
///
/// 语义（TC12）：45s 超时自动拒绝（delegate 超时收 UI，guard 超时回包，
/// 双保险）；导航器未挂载（应用不在前台 / headless）= 无确认界面，
/// **fail-closed 恒拒绝**（reason = `headless_no_ui_prompt`），严禁悬挂等待。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../coordinator/permission_gateway.dart';
import '../gateway/gateway_security.dart' show kGatewayConsentTimeout;
import 'navigator_key.dart';

/// 手机屏 L2 确认卡（TC12：45s 超时自动弹回拒绝；安全层另有同限超时兜底，
/// 双保险——delegate 超时负责收 UI，guard 超时负责回包）。
class DialogGateDelegate implements GateDelegate {
  const DialogGateDelegate({this.timeout = kGatewayConsentTimeout});

  final Duration timeout;

  @override
  Future<GateDecision> confirm(ToolPendingConfirmation pending) async {
    final nav = appNavigatorKey.currentState;
    if (nav == null) {
      // Fail-closed：无可用弹窗桥（UI 未挂载/不在前台）绝不等待 Completer。
      return const GateDecision(
        approved: false,
        reason: 'headless_no_ui_prompt：应用不在前台，无确认界面',
      );
    }
    var settled = false;
    var remember = false;
    final dialog = showDialog<GateDecision>(
      context: nav.context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: const Text('PC 远程调用确认（L2 写操作）'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '工具：${pending.toolName}',
                  style: const TextStyle(
                      fontFamily: 'monospace', fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                const Text('参数：'),
                Text(
                  pending.argumentsJson,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('本网关会话记住该工具'),
                  value: remember,
                  onChanged: (v) => setDialog(() => remember = v ?? false),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () =>
                  nav.pop(const GateDecision(approved: false, reason: '用户拒绝')),
              child: const Text('拒绝'),
            ),
            FilledButton(
              onPressed: () => nav.pop(
                  GateDecision(approved: true, rememberSession: remember)),
              child: const Text('批准'),
            ),
          ],
        ),
      ),
    );
    unawaited(dialog.whenComplete(() => settled = true));
    final timer = Timer(timeout, () {
      if (!settled) {
        settled = true;
        nav.pop(const GateDecision(approved: false, reason: '确认超时（45s）'));
      }
    });
    try {
      final decision = await dialog;
      return decision ?? const GateDecision(approved: false, reason: '用户拒绝');
    } finally {
      settled = true;
      timer.cancel();
    }
  }
}
