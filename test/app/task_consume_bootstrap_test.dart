/// 应用级装配单测（M4-2）：宿主上线接管的触发、跳过、幂等与解绑。
/// 不触真 Binder（假件注入 + 断言后立即 dispose 清定时器）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/app/task_consume_bootstrap.dart';
import 'package:goodhub/core/data_source.dart';
import 'package:goodhub/mcp/mcp_task_queue.dart';
import 'package:goodhub/task/task_source.dart';
import 'package:goodhub/task/task_source_registry.dart';
import 'package:goodhub/llm/cloud/cloud_llm.dart';
import 'package:goodhub/mcp/local_plugin_discovery.dart';
import 'package:goodhub/mcp/mcp_client.dart';
import 'package:goodhub/mcp/trusted_plugins.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeSource implements LocalPluginSource {
  _FakeSource(this.locals);

  final List<LocalPluginInfo> locals;
  int scanCount = 0;
  int createdCount = 0;

  @override
  Stream<void> get changes => const Stream<void>.empty();

  @override
  Future<List<LocalPluginInfo>> scan() async {
    scanCount++;
    return locals;
  }

  @override
  McpClient createClient(LocalPluginInfo info) {
    createdCount++;
    return McpClient.binder(
      transportId: info.transportId,
      packageName: info.packageName,
      serviceClassName: info.serviceClassName,
    );
  }
}

/// 假云端引擎（避免装配真实 BYOK/平台通道）。
class _FakeEngine implements CloudLlmEngine {
  @override
  String get name => 'fake';

  @override
  Stream<CloudStreamEvent> send(
    CloudChatRequest request, {
    void Function()? onActivity,
  }) async* {
    yield const CloudTextDelta('产出');
    yield const CloudDone(finishReason: CloudFinishReason.stop);
  }
}


/// 契约探测假件（通用化后 bootstrap 经 registry 注入探测——单测零 Binder）：
/// [kPrimaryDataSourcePackage] 命中 → 假 TaskSource（claim 恒 idle）；其余
/// 包名 = 普通插件（仅算力借用面）。
class _FakeRegistry implements TaskSourceRegistry {
  int probeCount = 0;

  @override
  Future<ResolvedTaskSource?> resolve(LocalPluginInfo info, McpClient client) async {
    probeCount++;
    if (info.packageName != kPrimaryDataSourcePackage) return null;
    return McpTaskQueueSource(_IdleFakeApi(), serverId: info.packageName);
  }
}

/// claim 恒 idle 的假 API（探测命中即建 loop 的最小形态）。
class _IdleFakeApi implements McpTaskQueueApi {
  @override
  void close() {}

  @override
  Future<ClaimedTask> claim() async => ClaimedTask.idle;

  @override
  Future<Object?> apply(ApplyPayload payload) async => <String, Object?>{};

  @override
  Future<bool> release(String taskId) async => true;

  @override
  Future<void> touch(String taskId) async {}
}

void main() {
  // McpClient.binder 构造会注册 MethodChannel handler —— 需先初始化 binding
  // （生产环境由 runApp 保证；纯 Dart 单测须显式初始化）。
  TestWidgetsFlutterBinding.ensureInitialized();

  // S04：未注入 trustGate 的用例会走生产默认 TrustedPlugins 单例（读
  // SharedPreferences）——mock 空白名单 + 每用例重置进程级单例缓存防串数据。
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TrustedPlugins.resetForTest();
  });

  const goodshare = LocalPluginInfo(
    serverId: 'goodshare',
    serverTitle: 'goodshare',
    packageName: kPrimaryDataSourcePackage,
    serviceClassName: 'com.zzh.goodshare.McpBinderService',
    sameSignature: true, // 同签名私有生态：零弹窗自动信任（生产实况）
  );
  const untrustedThirdParty = LocalPluginInfo(
    serverId: 'goodshare',
    serverTitle: 'goodshare',
    packageName: kPrimaryDataSourcePackage,
    serviceClassName: 'com.zzh.goodshare.McpBinderService',
    sameSignature: false, // 第三方异签名：须白名单命中（S04 验收钉夹具）
  );
  const other = LocalPluginInfo(
    serverId: 'todo',
    serverTitle: 'todo',
    packageName: 'com.example.todo',
    serviceClassName: 'com.example.todo.Svc',
  );

  test('发现 goodshare 插件 → 装配并触发 catch-up，返回可用循环', () async {
    final source = _FakeSource([other, goodshare]);
    final bs = TaskConsumeBootstrap(
        discovery: source, sourceRegistry: _FakeRegistry());
    final loop = await bs.start(engine: _FakeEngine());
    expect(loop, isNotNull);
    expect(source.createdCount, 1, reason: '只为目标插件建连接');
    bs.dispose(); // 立即清定时器，防异步触真 Binder
    expect(bs.loop, isNull);
  });

  test('未发现 goodshare → 跳过（null，不阻断启动）', () async {
    final source = _FakeSource([other]);
    final bs = TaskConsumeBootstrap(
        discovery: source, sourceRegistry: _FakeRegistry());
    expect(await bs.start(engine: _FakeEngine()), isNull);
    expect(source.createdCount, 0);
    bs.dispose();
  });

  test('S04 验收钉：未信任第三方插件经任务路径不挂载（拒建连接）', () async {
    final source = _FakeSource([untrustedThirdParty]);
    final bs = TaskConsumeBootstrap(
      discovery: source,
      sourceRegistry: _FakeRegistry(),
      trustGate: _DenyAllGate(), // 白名单未命中（第三方异签名未确认）
    );
    expect(await bs.start(engine: _FakeEngine()), isNull,
        reason: '未信任插件不得经任务路径挂载');
    expect(source.createdCount, 0, reason: '信任校验须先于 createClient');
    bs.dispose();
  });

  test('扫描失败 → DEGRADE 返回 null，不抛出', () async {
    final bs = TaskConsumeBootstrap(
        discovery: _ThrowingSource(),
        sourceRegistry: _FakeRegistry());
    expect(await bs.start(engine: _FakeEngine()), isNull);
    bs.dispose();
  });

  test('幂等：重复 start 复用同一循环，不重复建连接', () async {
    final source = _FakeSource([goodshare]);
    final bs = TaskConsumeBootstrap(
        discovery: source, sourceRegistry: _FakeRegistry());
    final first = await bs.start(engine: _FakeEngine());
    final second = await bs.start(engine: _FakeEngine());
    expect(identical(first, second), isTrue);
    expect(source.createdCount, 1);
    bs.dispose();
    expect(bs.loop, isNull);
  });

  test('让路端口后置注入（窗口层运行态）对已建循环生效', () async {
    final source = _FakeSource([goodshare]);
    final bs = TaskConsumeBootstrap(
        discovery: source, sourceRegistry: _FakeRegistry());
    await bs.start(engine: _FakeEngine());
    var busy = false;
    bs.isHostBusy = () => busy; // 模拟窗口层在运行态建立后注入
    expect(bs.isHostBusy?.call(), isFalse);
    busy = true;
    expect(bs.isHostBusy?.call(), isTrue, reason: '闭包读最新值');
    bs.dispose();
  });
}

/// 全拒信任闸（S04 验收钉夹具）：模拟白名单未命中的第三方异签名插件。
class _DenyAllGate implements PluginTrustGate {
  @override
  bool isTrusted(String packageName, {String signatureSha256 = ''}) => false;
}

class _ThrowingSource implements LocalPluginSource {
  @override
  Stream<void> get changes => const Stream<void>.empty();

  @override
  Future<List<LocalPluginInfo>> scan() async => throw StateError('通道不可用');

  @override
  McpClient createClient(LocalPluginInfo info) => throw StateError('unreachable');
}
