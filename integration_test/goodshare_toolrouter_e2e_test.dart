// goodshare 单服务经 ToolRouter 全链（M4-T6-4 回归坐证）：
// 复刻 ChatPage._send 的本地插件装配路径——discovery(sameSignature) → createClient
// → negotiate → McpToolFace → listTools → ToolRouter(faces) → 默认全激活 →
// activatedSchemas() 前缀化 + DiscoveryExecutor JIT 元工具可见 + 经 router 路由一次
// 真实 tools/call + 未激活幻觉调用防线。
//
// 与 goodshare_binder_e2e_test.dart 的分层：那个验传输层（McpClient bind+tools）；
// 本测试验 T6 装配层（ToolRouter 前缀隔离 / JIT 两级发现 / 激活集门控）。
//
// 前置：goodhub + goodshare 同机同一 debug keystore 同批安装（§5 门禁已过：
// D.1 指纹 SAME / D.2 bind 通）。运行：
//   flutter test integration_test/goodshare_toolrouter_e2e_test.dart -d <device>

library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:goodhub/coordinator/agent_loop.dart'
    show ToolExecutionResult, ToolExecutor;
import 'package:goodhub/coordinator/discovery_executor.dart';
import 'package:goodhub/coordinator/mcp_tool_face.dart';
import 'package:goodhub/coordinator/tool_router.dart';
import 'package:goodhub/llm/cloud/cloud_llm.dart' show AssembledToolCall;
import 'package:goodhub/mcp/local_plugin_discovery.dart';

Future<T> _withTimeout<T>(Future<T> f, String label) => f.timeout(
      const Duration(seconds: 30),
      onTimeout: () =>
          throw TimeoutException('超时: $label', const Duration(seconds: 30)),
    );

/// 最小 inner：JIT 元工具被 DiscoveryExecutor 最外层拦截，非元工具不应到达此处。
class _ThrowInner implements ToolExecutor {
  @override
  Future<ToolExecutionResult> execute(AssembledToolCall call) async =>
      throw StateError('inner 不应被调用: ${call.name}');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('T6-4: goodshare 单服务经 ToolRouter 前缀路由 + JIT 元工具全链',
      (tester) async {
    // ---- 发现 goodshare（同签名私有生态，§1.2.6 零弹窗自动信任）----
    final plugins = await _withTimeout(localPluginDiscovery.scan(), 'scan');
    final found =
        plugins.where((p) => p.serverId == 'goodshare').toList();
    expect(found, isNotEmpty, reason: '应扫描到 goodshare 本地插件');
    final gs = found.first;
    expect(gs.sameSignature, isTrue, reason: '两包须同签名（§5 D.1/D.2 已过）');

    // ---- 复刻 ChatPage 本地插件装配：negotiate → face → listTools ----
    final client = localPluginDiscovery.createClient(gs);
    await _withTimeout(client.negotiate(), 'negotiate');
    final face = McpToolFace(client: client, serverId: gs.serverId);
    await _withTimeout(face.listTools(), 'listTools');

    // T6：路由注册表 + 默认激活全部已挂载（保单服务回归）。
    final router = ToolRouter(faces: {gs.serverId: face});
    router.activatedServers.addAll(router.serverIds);

    try {
      // 断言1：serverIds 含 goodshare。
      expect(router.serverIds, contains('goodshare'));

      // 断言2：activatedSchemas 前缀化 + 含已知工具（F1.2 命名空间隔离）。
      final schemas = router.activatedSchemas();
      expect(schemas, isNotEmpty, reason: '激活 schema 不应为空');
      final names = schemas.map((s) => s.name).toList();
      expect(names, contains('goodshare__list_items'),
          reason: '工具名须带 goodshare__ 前缀');
      expect(names.every((n) => n.startsWith('goodshare__')), isTrue,
          reason: '全部工具名均带服务前缀');

      // 断言3：serverFor 前缀解析（本地工具名无前缀 → null）。
      expect(router.serverFor('goodshare__list_items'), 'goodshare');
      expect(router.serverFor('get_connected_apps'), isNull,
          reason: '宿主本地工具名无前缀 → null');

      // 断言4：JIT 元工具随 tools 下发 + get_connected_apps 列出 goodshare。
      final discovery = DiscoveryExecutor(
        router: router,
        inner: _ThrowInner(),
        serverSummaries: {gs.serverId: 'goodshare (本地)'},
      );
      final staticNames =
          DiscoveryExecutor.staticSchemas().map((s) => s.name).toList();
      expect(
          staticNames,
          containsAll(['get_connected_apps', 'activate_server_tools']),
          reason: 'JIT 两级发现元工具应随 tools 下发');
      final listed = await discovery.execute(
        const AssembledToolCall(
            id: 't6-4-list', name: 'get_connected_apps', argumentsJson: '{}'),
      );
      expect(listed.isError, isFalse);
      expect(listed.content, contains('goodshare'),
          reason: 'get_connected_apps 应列出已挂载 goodshare');

      // 断言5：经 router 前缀路由一次真实 tools/call。
      final routed = await _withTimeout(
        router.execute(
          AssembledToolCall(
              id: 't6-4-call',
              name: 'goodshare__list_items',
              argumentsJson: '{"limit":5}'),
        ),
        'routed list_items',
      );
      expect(routed.isError, isFalse,
          reason: '经 ToolRouter 路由的 tools/call 不应 isError: ${routed.content}');
      expect(routed.content, isNotEmpty);

      // 断言6：未激活服务的幻觉调用防线（引导 activate_server_tools）。
      router.activatedServers.remove(gs.serverId);
      final blocked = await router.execute(
        AssembledToolCall(
            id: 't6-4-blocked',
            name: 'goodshare__list_items',
            argumentsJson: '{}'),
      );
      expect(blocked.isError, isTrue,
          reason: '未激活服务的调用应被拦并引导 activate_server_tools');
      expect(blocked.content, contains('activate_server_tools'));
    } finally {
      client.close();
    }
  });
}
