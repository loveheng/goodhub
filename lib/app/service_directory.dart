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

import 'package:flutter/foundation.dart' show debugPrint;

import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../coordinator/cow_sync.dart';
import '../coordinator/user_prompt_store.dart';
import '../llm/cloud/byok_store.dart';
import '../mcp/server_endpoints.dart';
import '../resources/resource_store.dart';
import '../sandbox/workspace_state_store.dart';

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
      (key) => SharedPreferences.getInstance().then((sp) => sp.remove(key)),
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

/// CoW 覆写库（应用级单实例；跨会话持久，随进程存亡）。
///
/// 2026-10-28 S1 第一批：此前消费点各自 `CowOverridesStore(dir: ...)` 就地构造
/// （`cow_section` / `prompts_overview_section` / `cow_skill_sync`），多实例各自
/// 持 `_cache` 且写回为**全量覆盖** → 跨实例静默丢失更新（实证见
/// `test/coordinator/multi_instance_lost_update_test.dart`）。
CowOverridesStore? _cowStore;

/// 测试注入位（非空时 [cowOverridesStore] 恒返回之）。
CowOverridesStore? cowOverridesStoreOverride;

Future<CowOverridesStore> cowOverridesStore() async {
  final injected = cowOverridesStoreOverride;
  if (injected != null) return injected;
  final cached = _cowStore;
  if (cached != null) return cached;
  final docs = await getApplicationDocumentsDirectory();
  return _cowStore = CowOverridesStore(dir: docs);
}

/// user 全局 prompt 库（应用级单实例；同上丢失更新实证）。
UserGlobalPromptsStore? _userPromptStore;

/// 测试注入位（非空时 [userGlobalPromptsStore] 恒返回之）。
UserGlobalPromptsStore? userGlobalPromptsStoreOverride;

Future<UserGlobalPromptsStore> userGlobalPromptsStore() async {
  final injected = userGlobalPromptsStoreOverride;
  if (injected != null) return injected;
  final cached = _userPromptStore;
  if (cached != null) return cached;
  final docs = await getApplicationDocumentsDirectory();
  return _userPromptStore = UserGlobalPromptsStore(dir: docs);
}

/// 测试隔离复位（S1 契约）：清掉全部进程内缓存与注入位，单测在 `setUp` /
/// `tearDown` 成对调用——否则静态缓存跨用例串扰。
void resetAllForTest() {
  _resourceStore = null;
  _cowStore = null;
  _userPromptStore = null;
  _byokStore = null;
  _wsStates = null;
  _appVersion = null;
  resourceStoreOverride = null;
  cowOverridesStoreOverride = null;
  userGlobalPromptsStoreOverride = null;
  byokStoreOverride = null;
  workspaceStateStoreOverride = null;
  appVersionOverride = null;
}

/// BYOK 配置库（应用级单实例）：`hybrid_assembly` 与设置页此前各自 `ByokStore()`，
/// 每轮装配重读安全存储；收此复用同一实例。
///
/// **同步访问器**：`ByokStore` 构造自身无 IO（密钥读取才走平台通道），故不必
/// 让窗口层在 `build` 里 await——同步即可满足「UI 只注入同步件」（§S1）。
ByokStore? _byokStore;

/// 测试注入位（非空时 [byokStore] 恒返回之）。
ByokStore? byokStoreOverride;

ByokStore byokStore() => byokStoreOverride ?? (_byokStore ??= ByokStore());

/// 工作区状态库（应用级单实例）：此前 `chat_page` 每轮发送都
/// `WorkspaceStateStore.underSupportDir(...)` 新造一份。
WorkspaceStateStore? _wsStates;

/// 测试注入位（非空时 [workspaceStateStore] 恒返回之）。
WorkspaceStateStore? workspaceStateStoreOverride;

Future<WorkspaceStateStore> workspaceStateStore() async {
  final injected = workspaceStateStoreOverride;
  if (injected != null) return injected;
  final cached = _wsStates;
  if (cached != null) return cached;
  final support = await getApplicationSupportDirectory();
  return _wsStates = WorkspaceStateStore.underSupportDir(support.path);
}

/// 应用版本字符串（`version+buildNumber`）——进程内缓存，读取失败按 `unknown`
/// 兜底（**非数据面降级**：环境事实拿不到不该让调用链炸）。
///
/// 2026-10-23 新增：`get_host_status` 需要真实版本（PC 据此做协议兼容判断，
/// 占位版本会让工具产生误导）。此前版本读取散在 `ui/sections/about_section`
/// 与 `ui/update_page` 两处自调 `PackageInfo.fromPlatform()`——后续可一并收敛
/// 到本访问器（本次不改 UI，避免扩大改动面）。
String? _appVersion;

/// 测试注入位（非空时 [appVersion] 恒返回之，免平台插件依赖）。
String? appVersionOverride;

/// 应用版本（应用级单入口，缓存一次）。
Future<String> appVersion() async {
  final injected = appVersionOverride;
  if (injected != null) return injected;
  final cached = _appVersion;
  if (cached != null) return cached;
  try {
    final info = await PackageInfo.fromPlatform();
    return _appVersion = '${info.version}+${info.buildNumber}';
  } on Object catch (e) {
    debugPrint('[DEGRADE] service-directory: 版本读取失败按 unknown: $e');
    return _appVersion = 'unknown';
  }
}
