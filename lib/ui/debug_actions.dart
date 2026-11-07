/// 动作执行面适配（实现已迁至公共包 `app_debug_bridge`）。
///
/// 宿主保留两处**测试注入位**并映射进公共包入口，因此既有 import 路径与测试
/// 断言零改动；公共包侧的遍历起点 / 导航句柄 / 路由白名单由装配期设置
/// （见 `lib/ui/debug_wiring.dart`）。
library;

import 'package:app_debug_bridge/app_debug_bridge.dart' as kit;
import 'package:flutter/widgets.dart';


import '../coordinator/on_device_admin.dart';
import 'navigator_key.dart';

export 'package:app_debug_bridge/app_debug_bridge.dart' show kDebugActions;

/// 宿主专属动作名（先于公共包动作面拦截；与 [kit.kDebugActions] 互补，不重名）。
const List<String> kHostDebugActions = <String>[
  'list_models',
  'set_history_policy',
  'get_history_policy',
  'query_on_device',
];

/// 测试注入位：非空时替代宿主 navigator 的遍历起点。
BuildContext? debugActionContextOverride;

/// 测试注入位：非空时替代宿主 navigator。
NavigatorState? debugActionNavigatorOverride;

/// 宿主动作面入口（供 `DebugBridge.actionHandler` 装配）。
///
/// 宿主专属测试注入动作（策略/模型查询等，依赖宿主业务域）在此**先于**公共包
/// 动作面拦截处理；其余交给公共包通用动作面（tap_node/set_text/navigate…）。
///
/// 这些宿主动作直接读写 `SharedPreferences`（经 app 自身上下文），绕开
/// `run-as` 被 SELinux 禁的硬约束，使历史策略切换 / 模型选择可纯真机自动化，
/// 不再依赖手动点 UI 或资源中心 debug 路由（资源中心不在路由白名单内）。
Future<Object?> executeDebugAction(String action, Map<String, Object?> args) async {
  switch (action) {
    case 'list_models':
      return await _listModels();
    case 'set_history_policy':
      return await _setHistoryPolicy(args);
    case 'get_history_policy':
      return await _getHistoryPolicy(args);
    case 'query_on_device':
      return await _queryOnDevice(args);
    case 'simulate_deferred':
      return await OnDeviceAdmin.simulateDeferredCall(
        instruction: (args['instruction'] as String?) ?? '提取关键词',
        input: (args['input'] as String?) ?? '端侧联调测试文本',
      );
    default:
      return kit.executeDebugAction(
        action,
        args,
        contextOverride: debugActionContextOverride,
        navigatorOverride: debugActionNavigatorOverride,
      );
  }
}

/// 解析目标模型 dirName：显式 `modelDir` > 当前选中模型；均缺省抛 [StateError]。
Future<String> _resolveTargetDir(Map<String, Object?> args) async {
  final explicit = args['modelDir']?.toString();
  if (explicit != null && explicit.isNotEmpty) return explicit;
  final selected = await OnDeviceModelSelection.read();
  if (selected == null) {
    throw StateError('未选中任何端侧模型（也未指定 modelDir）');
  }
  return selected.dirName;
}

/// [_resolveTargetDir] 的容错版：无法解析（无选中/无显式）时返 null 而非抛。
Future<String?> _resolveTargetDirOrNull(Map<String, Object?> args) async {
  try {
    return await _resolveTargetDir(args);
  } on Object {
    return null;
  }
}

Map<String, Object?> _policyError(String code, Object e) =>
    <String, Object?>{'ok': false, 'error': code, 'detail': e.toString()};

/// 列已装端侧模型 + 各自当前历史策略 + 选中态（自动化取 dirName 用）。
Future<Map<String, Object?>> _listModels() async {
  try {
    final selected = await OnDeviceModelSelection.read();
    final installed = await ModelRegistry.scan();
    final models = <Map<String, Object?>>[];
    for (final m in installed) {
      final pid = await HistoryPolicySelection.readForModel(m.dirName, device: true);
      models.add(<String, Object?>{
        'dirName': m.dirName,
        'displayName': m.displayName,
        'runtime': m.runtime,
        'contextTokens': m.modelProfile?.contextTokens,
        'policyId': pid,
        'policyLabel': HistoryPolicySelection.label(pid),
        'selected': selected != null && selected.dirName == m.dirName,
      });
    }
    return <String, Object?>{
      'ok': true,
      'action': 'list_models',
      'selectedDir': selected?.dirName,
      'models': models,
    };
  } on Object catch (e) {
    return _policyError('list_models_failed', e);
  }
}

/// 回读某模型当前历史策略（默认 = 当前选中模型）。
Future<Map<String, Object?>> _getHistoryPolicy(Map<String, Object?> args) async {
  final dirName = await _resolveTargetDirOrNull(args);
  if (dirName == null) {
    return <String, Object?>{
      'ok': false,
      'error': 'no_target_model',
      'hint': '指定 args.modelDir 或先在 App 选一个端侧模型',
    };
  }
  final pid = await HistoryPolicySelection.readForModel(dirName, device: true);
  return <String, Object?>{
    'ok': true,
    'action': 'get_history_policy',
    'modelDir': dirName,
    'policyId': pid,
    'policyLabel': HistoryPolicySelection.label(pid),
  };
}

/// 写某模型历史策略（默认 = 当前选中模型），回读校验落盘。
///
/// 生成时 `hybrid_cloud_engine` 实时 `readForModel` 取策略，故写入**即时生效**，
/// 无需重建/重启——下一轮请求即按新策略拼装。
Future<Map<String, Object?>> _setHistoryPolicy(Map<String, Object?> args) async {
  final pid = args['policyId']?.toString();
  if (pid == null || !HistoryPolicyIds.all.contains(pid)) {
    return <String, Object?>{
      'ok': false,
      'error': 'bad_policy_id',
      'hint': 'policyId 须为 ${HistoryPolicyIds.all.join(' / ')}',
    };
  }
  final dirName = await _resolveTargetDirOrNull(args);
  if (dirName == null) {
    return <String, Object?>{
      'ok': false,
      'error': 'no_target_model',
      'hint': '指定 args.modelDir 或先在 App 选一个端侧模型',
    };
  }
  try {
    await HistoryPolicySelection.writeForModel(dirName, pid);
  } on Object catch (e) {
    return _policyError('write_failed', e);
  }
  final verified = await HistoryPolicySelection.readForModel(dirName, device: true);
  return <String, Object?>{
    'ok': true,
    'action': 'set_history_policy',
    'modelDir': dirName,
    'policyId': pid,
    'policyLabel': HistoryPolicySelection.label(pid),
    'verifiedId': verified,
  };
}

/// 解析目标模型完整选项（[OnDeviceModelOption]）：显式 `modelDir` > 当前选中；
/// 均缺省返 null。供直接驱动引擎用（需 contextTokens / enable）。
Future<OnDeviceModelOption?> _resolveTargetModel(
    Map<String, Object?> args) async {
  final dir = await _resolveTargetDirOrNull(args);
  if (dir == null) return null;
  final selected = await OnDeviceModelSelection.read();
  if (selected != null && selected.dirName == dir) return selected;
  for (final m in await ModelRegistry.scan()) {
    if (m.dirName == dir) return m.toOption();
  }
  return null;
}

/// policyId → 策略实例（③ rolling_summary 需摘要器注入，P3 暂不直驱）。
OnDeviceHistoryPolicy _policyInstance(String id) {
  if (id == HistoryPolicyIds.anchorRecent) {
    return const AnchorAndRecentHistoryPolicy();
  }
  if (id == HistoryPolicyIds.dropOldest) return const DropOldestHistoryPolicy();
  if (id == HistoryPolicyIds.bare) return const BarePromptHistoryPolicy();
  throw StateError('policyId=$id 需摘要器注入，暂经 chat UI 验证（P3 不涉及）');
}

/// 确保引擎对 [model] 就绪：`enable` 在 `_loadState==ready` 时**不区分模型**
/// 直接 return（曾导致切换 Qwen↔Gemma 时跑在错误引擎上返回空），故必须显式
/// `disable()` 并**等其真正生效**（离开 ready）后再 `enable(model)`，杜绝竞态。
/// 全程对 `authoritativeStatus()` 的瞬时 `not_bound` 等异常容错，沿用 bench
/// 口径 150s 覆盖冷启动重载。
Future<EngineStatus?> _safeStatus() async {
  try {
    return await sharedOnDeviceEngine.authoritativeStatus();
  } on Object {
    return null;
  }
}

Future<bool> _ensureReady(OnDeviceModelOption model) async {
  try {
    await sharedOnDeviceEngine.disable();
  } on Object {
    // 未装载时 disable 可能抛；忽略，交给 enable 兜底。
  }
  // 等 disable 生效：loadState 离开 ready（disable 为异步，避免 enable 抢跑）。
  for (var i = 0; i < 30; i++) {
    if (await _safeStatus() != EngineStatus.ready) break;
    await Future.delayed(const Duration(milliseconds: 200));
  }
  try {
    final st = await sharedOnDeviceEngine.enable(model: model);
    if (st == EngineStatus.unsupportedDevice) return false;
  } on Object {
    // enable 抛错（如票据面瞬时不可用 / not_bound）→ 落到下方轮询面继续探。
  }
  for (var i = 0; i < 150; i++) {
    final s = await _safeStatus();
    if (s == EngineStatus.ready) return true;
    if (s == EngineStatus.unsupportedDevice ||
        s == EngineStatus.assetMissing) {
      return false;
    }
    await Future.delayed(const Duration(seconds: 1));
  }
  return false;
}

/// 直接驱动端侧引擎跑一轮（绕开混合路由，强制 on-device），用模型当前/指定
/// 历史策略拼装多轮 prompt，返回全文 + 时延——供 P3 历史策略 A/B 真机验证。
///
/// 入参：`prompt`（末轮 user，必填）、`history`（可选 prior 轮 [{role,content}]）、
/// `policyId`（可选，缺省读模型存储策略）、`modelDir`（可选）、`maxTokens`（可选）。
/// 真实聊天经 `hybrid_cloud_engine` 运行时 `readForModel` 取策略拼装——本动作
/// 复用同一 `buildOnDeviceChatPromptJsonAsync` 入口，策略层面与真机聊天同构；
/// 区别仅在强制 on-device（不触发云端回退），正是 P3 要测的端侧路径。
Future<Map<String, Object?>> _queryOnDevice(Map<String, Object?> args) async {
  final prompt = args['prompt']?.toString();
  if (prompt == null || prompt.isEmpty) {
    return <String, Object?>{
      'ok': false,
      'error': 'missing_prompt',
      'hint': 'args.prompt 必填（末轮 user 消息）',
    };
  }
  final model = await _resolveTargetModel(args);
  if (model == null) {
    return <String, Object?>{
      'ok': false,
      'error': 'no_target_model',
      'hint': '指定 args.modelDir 或先在 App 选一个端侧模型',
    };
  }
  final overridePid = args['policyId']?.toString();
  final pid = overridePid != null && overridePid.isNotEmpty
      ? overridePid
      : await HistoryPolicySelection.readForModel(model.dirName, device: true);
  if (!HistoryPolicyIds.all.contains(pid)) {
    return <String, Object?>{
      'ok': false,
      'error': 'bad_policy_id',
      'hint': 'policyId 须为 ${HistoryPolicyIds.all.join(' / ')}',
    };
  }
  OnDeviceHistoryPolicy policy;
  try {
    policy = _policyInstance(pid);
  } on Object catch (e) {
    return <String, Object?>{
      'ok': false,
      'error': 'policy_unsupported',
      'detail': e.toString(),
    };
  }

  // 构造多轮消息：history（user/assistant/system）→ 末轮 user(prompt)。
  final messages = <CloudChatMessage>[];
  final hist = args['history'];
  if (hist is List) {
    for (final h in hist) {
      if (h is! Map) continue;
      final role = (h as Map<Object?, Object?>?)?['role']?.toString() ?? 'user';
      final content =
          (h as Map<Object?, Object?>?)?['content']?.toString() ?? '';
      if (content.isEmpty) continue;
      if (role == 'assistant') {
        messages.add(AssistantMessage(content: content));
      } else if (role == 'system') {
        messages.add(SystemMessage(content));
      } else {
        messages.add(UserMessage(content));
      }
    }
  }
  messages.add(UserMessage(prompt));

  if (!await _ensureReady(model)) {
    return <String, Object?>{
      'ok': false,
      'error': 'engine_not_ready',
      'hint': '端侧引擎未能就绪（装载失败/不支持设备）',
    };
  }

  final promptJson = await buildOnDeviceChatPromptJsonAsync(
    messages,
    contextTokens: model.contextTokens,
    historyPolicy: policy,
  );

  final rec = model.recommendedSampling;
  final maxTokens = args['maxTokens'] is int ? args['maxTokens'] as int : 256;
  final config = GenerationConfig(
    maxTokens: maxTokens,
    temperature: rec?.temperature ?? 1.0,
    topP: rec?.topP ?? 0.95,
  );

  final sw = Stopwatch()..start();
  Duration? ttft;
  var chunks = 0;
  final buf = StringBuffer();
  try {
    await for (final c in sharedOnDeviceEngine.generate(
      requestId: 'dbg-${DateTime.now().microsecondsSinceEpoch}',
      prompt: promptJson,
      config: config,
    )) {
      ttft ??= sw.elapsed;
      buf.write(c.deltaText);
      chunks++;
    }
  } catch (e) {
    return <String, Object?>{
      'ok': false,
      'error': 'generate_failed',
      'detail': e.toString(),
      'policyId': pid,
      'promptChars': promptJson.length,
    };
  }

  return <String, Object?>{
    'ok': true,
    'action': 'query_on_device',
    'modelDir': model.dirName,
    'policyId': pid,
    'policyLabel': HistoryPolicySelection.label(pid),
    'promptChars': promptJson.length,
    'ttftMs': ttft?.inMilliseconds,
    'totalMs': sw.elapsed.inMilliseconds,
    'chunks': chunks,
    'chars': buf.length,
    'text': buf.toString(),
  };
}

/// 装配期把宿主 navigator 接到公共包的遍历起点 / 导航句柄。
void bindDebugNavigator() {
  kit.debugContextProvider = () => appNavigatorKey.currentContext;
  kit.debugNavigatorProvider = () => appNavigatorKey.currentState;
}

/// 装配期（或测试）设置公共包的路由白名单（宿主页面清单）。
void bindDebugRoutes(kit.DebugRouteRegistry registry) {
  kit.debugRouteRegistry = registry;
}
