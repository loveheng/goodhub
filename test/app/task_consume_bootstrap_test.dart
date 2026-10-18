/// 应用级装配单测（M4-2）：宿主上线接管的触发、跳过、幂等与解绑。
/// 不触真 Binder（假件注入 + 断言后立即 dispose 清定时器）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/app/task_consume_bootstrap.dart';
import 'package:goodhub/llm/cloud/cloud_llm.dart';
import 'package:goodhub/mcp/local_plugin_discovery.dart';
import 'package:goodhub/mcp/mcp_client.dart';

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

void main() {
  // McpClient.binder 构造会注册 MethodChannel handler —— 需先初始化 binding
  // （生产环境由 runApp 保证；纯 Dart 单测须显式初始化）。
  TestWidgetsFlutterBinding.ensureInitialized();

  const goodshare = LocalPluginInfo(
    serverId: 'goodshare',
    serverTitle: 'goodshare',
    packageName: kGoodsharePackage,
    serviceClassName: 'com.zzh.goodshare.McpBinderService',
  );
  const other = LocalPluginInfo(
    serverId: 'todo',
    serverTitle: 'todo',
    packageName: 'com.example.todo',
    serviceClassName: 'com.example.todo.Svc',
  );

  test('发现 goodshare 插件 → 装配并触发 catch-up，返回可用循环', () async {
    final source = _FakeSource([other, goodshare]);
    final bs = TaskConsumeBootstrap(discovery: source);
    final loop = await bs.start(engine: _FakeEngine());
    expect(loop, isNotNull);
    expect(source.createdCount, 1, reason: '只为目标插件建连接');
    bs.dispose(); // 立即清定时器，防异步触真 Binder
    expect(bs.loop, isNull);
  });

  test('未发现 goodshare → 跳过（null，不阻断启动）', () async {
    final source = _FakeSource([other]);
    final bs = TaskConsumeBootstrap(discovery: source);
    expect(await bs.start(engine: _FakeEngine()), isNull);
    expect(source.createdCount, 0);
    bs.dispose();
  });

  test('扫描失败 → DEGRADE 返回 null，不抛出', () async {
    final bs = TaskConsumeBootstrap(discovery: _ThrowingSource());
    expect(await bs.start(engine: _FakeEngine()), isNull);
    bs.dispose();
  });

  test('幂等：重复 start 复用同一循环，不重复建连接', () async {
    final source = _FakeSource([goodshare]);
    final bs = TaskConsumeBootstrap(discovery: source);
    final first = await bs.start(engine: _FakeEngine());
    final second = await bs.start(engine: _FakeEngine());
    expect(identical(first, second), isTrue);
    expect(source.createdCount, 1);
    bs.dispose();
    expect(bs.loop, isNull);
  });

  test('让路端口后置注入（窗口层运行态）对已建循环生效', () async {
    final source = _FakeSource([goodshare]);
    final bs = TaskConsumeBootstrap(discovery: source);
    await bs.start(engine: _FakeEngine());
    var busy = false;
    bs.isHostBusy = () => busy; // 模拟窗口层在运行态建立后注入
    expect(bs.isHostBusy?.call(), isFalse);
    busy = true;
    expect(bs.isHostBusy?.call(), isTrue, reason: '闭包读最新值');
    bs.dispose();
  });
}

class _ThrowingSource implements LocalPluginSource {
  @override
  Stream<void> get changes => const Stream<void>.empty();

  @override
  Future<List<LocalPluginInfo>> scan() async => throw StateError('通道不可用');

  @override
  McpClient createClient(LocalPluginInfo info) => throw StateError('unreachable');
}
