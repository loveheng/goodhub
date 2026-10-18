/// 面板级错误行（ux-hardening P0-3 口径的**唯一实现**）：Rose 文案 + 重试入口。
///
/// 背景：面板初始化失败曾有两种历史病——① 一处失败打死整页（其余可用面板被
/// 替换）；② store 读取失败后 `store == null` 永显「读取中…」（错误不可见、
/// 无恢复入口）。统一口径 = 面板自持错误态，不打死宿主列表。
///
/// 抽出动机（resource-center 拆页）：资源中心段从设置页迁出为独立页后，两处
/// 宿主都需要同一份 errorRowBuilder——与其各抄一份，不如收敛为公共件，宿主
/// 只负责传自己的 onRetry（= 各自的 bootstrap）。
library;

import 'package:flutter/material.dart';

import '../tokens/console_tokens.dart';

/// 面板错误行构造器签名（各段只依赖此 typedef，不反向依赖页面）。
typedef PanelErrorRowBuilder = Widget Function(
  ConsoleTokens t,
  String message,
  VoidCallback onRetry, {
  ValueKey<String>? key,
});

/// 面板级错误态：⚠ + 结构化文案（Rose）+ 右侧重试入口。
///
/// [key] 非空时重试钮派生 `<key>-retry` 键，供测试定位。
Widget panelErrorRow(
  ConsoleTokens t,
  String message,
  VoidCallback onRetry, {
  ValueKey<String>? key,
}) {
  return Padding(
    key: key,
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '⚠ $message',
          style: TextStyle(fontSize: Fsz.telemetry, color: t.danger),
        ),
        const SizedBox(height: 2),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            key: key == null ? null : ValueKey('${key.value}-retry'),
            onPressed: onRetry,
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('重试'),
          ),
        ),
      ],
    ),
  );
}
