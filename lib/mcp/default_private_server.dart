/// 默认私有服务（跨手动端点 + 本地插件的统一钉选，持久于 SharedPreferences）。
///
/// 单槽私有绑定的「持久默认」：聊天页开新会话时若未显式绑定，按此默认回退；
/// 设置页可改。覆盖两种私有来源——手动端点与本地自动挂载插件（挂载方式不同，
/// 权限隔离一视同仁，见 mcp-orchestration epic）。
///
/// 与 [ServerEndpoint.isDefault] 的关系：isDefault 是旧的「手动端点内单选」遗留位，
/// 无法表达本地插件默认；本键是统一权威默认，聊天页回退链以本键为准。
library;

import 'package:shared_preferences/shared_preferences.dart';

/// 持久键（SharedPreferences）。
const String kDefaultPrivateServerKey = 'default.private.server';

/// 读默认私有服务 id（null = 无默认，新会话走纯公共/首私有回退）。
Future<String?> readDefaultPrivateServerId() async {
  final sp = await SharedPreferences.getInstance();
  return sp.getString(kDefaultPrivateServerKey);
}

/// 写默认私有服务 id（null/空 = 清除默认）。
Future<void> writeDefaultPrivateServerId(String? id) async {
  final sp = await SharedPreferences.getInstance();
  if (id == null || id.isEmpty) {
    await sp.remove(kDefaultPrivateServerKey);
  } else {
    await sp.setString(kDefaultPrivateServerKey, id);
  }
}
