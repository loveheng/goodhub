/// 网关配对 Token 的生成与起服决策（纯函数，零 IO，可独立单测）。
///
/// 背景（2026-10-23 用户拍板）：原实现「Token 留空 = 不鉴权」是**默认**行为，
/// 且网关默认监听 `0.0.0.0:8766` → 同局域网任意主机可无鉴权访问只读工具面
/// （L1 工具不弹确认卡）。本文件把「配对 Token」改回**默认必填**：
/// 起服时留空即自动生成；仅当用户显式关闭「自动生成」时才免鉴权。
library;

import 'dart:convert';
import 'dart:math';

/// 进程级安全随机源（A11：避免逐字节新建 Random.secure 的无谓开销）。
final Random _secureRandom = Random.secure();

/// 生成网关配对 Token。
///
/// 32 字节 `Random.secure` 熵 → base64url 无填充（约 43 字符）。强度只需覆盖
/// 「同局域网配对」场景（非长期凭据）；字符集为 URL-safe base64（无 `+/=`），
/// 便于用户手动抄进 PC 端而不易出错。
String generateGatewayToken() {
  final bytes = List<int>.generate(32, (_) => _secureRandom.nextInt(256));
  return base64Url.encode(bytes).replaceAll('=', '');
}

/// 起服 Token 决策（纯函数；UI 只负责 prefs 读写与回填）。
///
/// 口径：
/// - [input] 非空 → 用用户值（**用户显式指定优先**，不被自动生成覆盖）；
/// - [input] 为空 + [autoGenerate] 为真 → 生成新 Token（**默认安全路径**：
///   起服必带 `Authorization: Bearer`，不再存在「默认无鉴权」的暴露面）；
/// - [input] 为空 + [autoGenerate] 为假 → 返回空串 = **免鉴权**（用户显式
///   选择，逃生口保留给「仅 ADB 转发」场景）。
///
/// [generator] 为生成器注入位（单测可固定为常量，生产用 [generateGatewayToken]）。
String resolveGatewayToken({
  required String input,
  required bool autoGenerate,
  String Function()? generator,
}) {
  final trimmed = input.trim();
  if (trimmed.isNotEmpty) return trimmed;
  if (!autoGenerate) return '';
  return (generator ?? generateGatewayToken)();
}
