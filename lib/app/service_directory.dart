/// 应用装配容器（window-kernel-split 步 0-T7）：ServiceDirectory 单一入口。
///
/// [ServerEndpointStore] 的生产拼装收敛于此——此前 `chat_page` /
/// `settings_page` / `gateway_controller` 三处各自手拼 `mcp_servers.json`，
/// 其中 gateway 侧漏带旧 SharedPreferences 迁移（活 bug：旧单端点配置在
/// 网关侧读不到，三处读到不同内容）。
///
/// 新消费点一律经 [serverEndpointStore] 取 store，**禁止再手拼**
/// （coding-standards §1 拓扑自锁与 `dart:io` 豁免的解除单点）。
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../mcp/server_endpoints.dart';

/// 服务目录 store 生产装配：文件 = 应用支持目录/mcp_servers.json，
/// 旧单端点 SharedPreferences 经 [flutterPrefsLike] 注入迁移。
///
/// [supportPath] 供已持有支持目录路径的调用方复用（如 gateway_controller
/// 装配段），缺省走 path_provider 现取。
Future<ServerEndpointStore> serverEndpointStore({String? supportPath}) async {
  final support = supportPath ?? (await getApplicationSupportDirectory()).path;
  return ServerEndpointStore(
    file: File('$support/mcp_servers.json'),
    prefs: flutterPrefsLike(
      (key) => SharedPreferences.getInstance().then((sp) => sp.getString(key)),
    ),
  );
}
