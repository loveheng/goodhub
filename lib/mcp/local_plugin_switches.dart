/// 本地插件 per-plugin 挂载开关（m4 [P3]，对齐远端节点 M4-T5 `enabled` 口径；
/// 规范预留条款 = local-plugin-access-trust.md §1.7）。
///
/// 语义：开关与信任正交（同签名私有生态也可摘除）——关 = 装配/网关两处闸门
/// 跳过该插件 + 向 PC 下行 `tools/list_changed`（摘除后经 `GatewayController
/// .rescan()` → `facesChanged` 既有机制，勿另立通知通道）。持久化于
/// SharedPreferences（`Map<String, bool>`，**缺省 true** = 零配置自动挂载
/// 语义不变，未登记的插件恒为开）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'local_plugin_discovery.dart' show LocalPluginInfo;
import 'trusted_plugins.dart';

/// 开关变更广播（摘除/恢复后触发）：网关侧订阅 → `rescan()` → 装配过滤生效
/// + `facesChanged` → 对 PC 下行 `tools/list_changed`（§6 机制复用，与包变更
/// 同构；UI 严禁直调网关——R4 ui↛gateway_controller 断点保持）。
final StreamController<void> _switchChanges =
    StreamController<void>.broadcast();

/// 开关变更流（网关装配侧订阅；面板写入后广播）。
Stream<void> get localPluginSwitchChanges => _switchChanges.stream;

/// 持久键（独立于信任白名单 `_key`——开关对同签名插件也生效，同签名不在
/// 白名单 map 里）。
const String kLocalPluginEnabledKey = 'goodhub.local_plugin_enabled';

Map<String, Object?> _map(SharedPreferences prefs) {
  final raw = prefs.getString(kLocalPluginEnabledKey);
  if (raw == null || raw.isEmpty) return <String, Object?>{};
  try {
    final decoded = jsonDecode(raw);
    return decoded is Map<String, Object?>
        ? Map<String, Object?>.of(decoded)
        : <String, Object?>{};
  } on Object {
    return <String, Object?>{};
  }
}

/// 该插件当前是否启用挂载（未登记 = 缺省开，零配置语义不变）。
Future<bool> isLocalPluginEnabled(String packageName) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final v = _map(prefs)[packageName];
    return v is bool ? v : true;
  } on Object {
    // 测试环境 SharedPreferences 不可用等：按开处理（DEGRADE 语义，禁挡装配）。
    return true;
  }
}

/// 写开关（摘除/恢复）。写后广播变更（网关订阅重扫 → tools/list_changed
/// 下行）；聊天页装配在下次发送时生效。
Future<void> setLocalPluginEnabled(String packageName, bool enabled) async {
  final prefs = await SharedPreferences.getInstance();
  final m = _map(prefs);
  m[packageName] = enabled;
  await prefs.setString(kLocalPluginEnabledKey, jsonEncode(m));
  _switchChanges.add(null);
}

/// 本地插件挂载判定的**单一入口**（对齐 task-capability W1-S03 红线风格：
/// 信任判定经 [localPluginTrustSatisfied]，开关面在此合取——消费方禁再内联
/// 信任 + enabled 组合）。开关关闭 = 装配跳过（无提示卡，属用户主动摘除）。
Future<bool> localPluginMountAllowed(
  LocalPluginInfo info,
  PluginTrustGate gate,
) async {
  if (!localPluginTrustSatisfied(info, gate)) return false;
  return isLocalPluginEnabled(info.packageName);
}
