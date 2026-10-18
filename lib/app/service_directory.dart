/// 应用装配容器（window-kernel-split 步 0-T7）：ServiceDirectory 单一入口。
///
/// [ServerEndpointStore] 的生产拼装收敛于此——此前 `chat_page` /
/// `settings_page` / `gateway_controller` 三处各自手拼 `mcp_servers.json`，
/// 其中 gateway 侧漏带旧 SharedPreferences 迁移（活 bug：旧单端点配置在
/// 网关侧读不到，三处读到不同内容）。
///
/// 新消费点一律经 [serverEndpointStore] 取 store，**禁止再手拼**
/// （coding-standards §1 拓扑自锁与 `dart:io` 豁免的解除单点）。
///
/// 资源中心内核 [ResourceStore] 同此（2026-10-19 收敛）：此前 picker sheet
/// 每次调用都 `underSupportDir` 新建实例并 `load()` 读盘一遍，多窗口各持一份有
/// 内存态与盘不一致风险；规格 §4 并发纪律 = **应用级单实例持有，不再新造**。
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../mcp/server_endpoints.dart';
import '../resources/resource_store.dart';

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

/// 资源中心内核（应用级单实例；跨会话持久，随进程存亡）。
ResourceStore? _resourceStore;

/// 测试注入位（非空时 [resourceStore] 恒返回之，免平台插件依赖）。
ResourceStore? resourceStoreOverride;

/// 资源中心内核装配：目录 = 应用支持目录/resource_center。
///
/// 首次取用时 `load()` 一次（清单入内存），其后复用同一实例——窗口层
/// （picker sheet / 管理页段）一律经此，禁各自 `underSupportDir` 新造
/// （规格 §4 并发纪律）。
Future<ResourceStore> resourceStore() async {
  final injected = resourceStoreOverride;
  if (injected != null) return injected;
  final cached = _resourceStore;
  if (cached != null) return cached;
  final support = await getApplicationSupportDirectory();
  final store = ResourceStore.underSupportDir(support.path);
  await store.load(); // 幂等；损坏 → 空库 + DEGRADE。
  _resourceStore = store;
  return store;
}
