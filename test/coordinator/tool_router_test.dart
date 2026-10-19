/// coordinator/tool_router 单槽私有门控单测（MO：本地插件=私有 tier，须单槽隔离）。
///
/// 锁住的核心机制：privateServerIds 中的服务（含本地插件 id）在未激活时
/// 不进入 [ToolRouter.focusedSchemas]、[ToolRouter.execute] 被单槽门控拦截；
/// 仅激活的单一私有可见，其余私有被互斥隐藏。mcp_runtime 把本地插件 id 并入
/// privateServerIds 即依赖此机制——本测试钉住该机制不被回归破坏。
library;

import 'dart:convert' as json;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:goodhub/coordinator/agent_loop.dart';
import 'package:goodhub/coordinator/mcp_tool_face.dart';
import 'package:goodhub/coordinator/tool_router.dart';
import 'package:goodhub/llm/cloud/cloud_llm.dart';
import 'package:goodhub/mcp/mcp_client.dart';

McpClient _dummyClient() {
  final mock = MockClient((_) async => http.Response(
      json.jsonEncode({'jsonrpc': '2.0', 'id': 1, 'result': {}}),
      200,
      headers: {'content-type': 'application/json'}));
  return McpClient.http(baseUrl: 'http://fake', httpClient: mock);
}

/// 仅提供 canned schema / 结果，不触网（绕过 McpToolFace 真实传输）。
class _StubFace extends McpToolFace {
  _StubFace(this._schemas, this._result, {required super.serverId})
      : super(client: _dummyClient());

  final List<CloudToolSchema> _schemas;
  final ToolExecutionResult _result;

  @override
  List<CloudToolSchema> get cachedSchemas => List.unmodifiable(_schemas);

  @override
  Future<ToolExecutionResult> execute(AssembledToolCall call) async => _result;
}

CloudToolSchema _schema(String serverId, String tool) => CloudToolSchema(
      name: tool, // 裸名；schemasFor 会按 serverId 重新前缀化
      description: '',
      parametersSchema: const {},
    );

ToolRouter _router() => ToolRouter(
      faces: {
        'pub': _StubFace([_schema('pub', 'a')],
            const ToolExecutionResult(content: 'pub-ok'),
            serverId: 'pub'),
        'lp1': _StubFace([_schema('lp1', 'x')],
            const ToolExecutionResult(content: 'lp1-ok'),
            serverId: 'lp1'),
        'lp2': _StubFace([_schema('lp2', 'y')],
            const ToolExecutionResult(content: 'lp2-ok'),
            serverId: 'lp2'),
      },
      privateServerIds: {'lp1', 'lp2'}, // 本地插件同属私有 tier
    );

void main() {
  group('ToolRouter 切域事务与 Run 快照（prompt-mgmt Phase 2）', () {
    test('requestSlot 只写 pending：活跃槽位在 commitPendingSlot 前不变', () {
      final router = _router();
      router.requestSlot('lp1');
      expect(router.activePrivateServerId, isNull, reason: '提交点前活跃槽位不变');
      router.commitPendingSlot();
      expect(router.activePrivateServerId, 'lp1');
    });

    test('提交点前 endRun 丢弃 pending（Abort 前槽位保持原状）', () {
      final router = _router();
      router.beginRun();
      router.requestSlot('lp1');
      router.endRun(); // Run 收尾：未提交 pending 丢弃
      expect(router.activePrivateServerId, isNull, reason: '提交前 Abort 不切换');
      router.commitPendingSlot(); // endRun 后无 pending，幂等 no-op
      expect(router.activePrivateServerId, isNull);
    });

    test('提交点后不回滚：commitPendingSlot 单向，endRun 不撤', () {
      final router = _router();
      router.beginRun();
      router.requestSlot('lp1');
      router.commitPendingSlot(); // ToolResultMessage 落历史后提交
      expect(router.activePrivateServerId, 'lp1');
      router.endRun(); // 提交后 Abort/收尾
      expect(router.activePrivateServerId, 'lp1', reason: '切换是显式意图，不回滚');
    });

    test('Run 快照隔离：Run 内 focusedSchemas/execute 消费启动快照', () async {
      final router = _router();
      router.activePrivateServerId = 'lp1';
      router.beginRun(); // 快照 = lp1
      router.requestSlot('lp2');
      router.commitPendingSlot(); // Run 中途提交
      expect(router.activePrivateServerId, 'lp2');
      expect(router.focusedSchemas().map((s) => s.name).toList(),
          ['pub__a', 'lp1__x'],
          reason: 'Run 内工具面仍按启动快照 lp1（同拍同源，防撕裂）');
      // Run 内幻觉调用新槽位 lp2：按快照被拦（新工具面下一 Run 生效）。
      final blocked = await router.execute(
          AssembledToolCall(id: '1', name: 'lp2__y', argumentsJson: '{}'));
      expect(blocked.isError, isTrue);
      router.endRun();
      expect(router.focusedSchemas().map((s) => s.name).toList(),
          ['pub__a', 'lp2__y'], reason: '下一 Run 消费新槽位');
    });

    test('无快照时 effectiveSlot 回落活跃槽位（未 beginRun 的直用路径）', () {
      final router = _router();
      router.activePrivateServerId = 'lp1';
      expect(router.effectiveSlot, 'lp1');
    });

    test('断连降级：激活私有掉线 → pending 标记 → beginRun 置空 + 通告', () {
      final router = _router();
      router.activePrivateServerId = 'lp1';
      router.markPrivateServerOffline('lp1');
      // Run 中途标记不影响本 Run：beginRun 前槽位不变。
      expect(router.activePrivateServerId, 'lp1');
      final notice = router.beginRun();
      expect(router.activePrivateServerId, isNull, reason: '僵尸槽位自愈置空');
      expect(notice, contains('lp1'), reason: '降级可见通告');
      expect(notice, contains('纯公共'));
      router.endRun();
    });

    test('断连降级不影响未激活的私有服务与公共面', () {
      final router = _router();
      router.activePrivateServerId = 'lp1';
      router.markPrivateServerOffline('lp2'); // 掉线的是未激活私有
      expect(router.beginRun(), isNull);
      expect(router.activePrivateServerId, 'lp1', reason: '非激活私有掉线不动槽位');
      router.endRun();
    });

    test('掉线 + 显式切域并存：显式切域请求优先于降级', () {
      final router = _router();
      router.activePrivateServerId = 'lp1';
      router.markPrivateServerOffline('lp1');
      router.requestSlot('lp2'); // 用户显式意图
      final notice = router.beginRun();
      expect(router.activePrivateServerId, 'lp2', reason: '显式切域优先');
      expect(notice, isNull);
      router.endRun();
    });

    test('无激活槽位时掉线标记不产生降级通告', () {
      final router = _router();
      router.markPrivateServerOffline('lp1'); // 当前无槽位
      expect(router.beginRun(), isNull);
      router.endRun();
    });
  });

  group('ToolRouter 单槽私有门控（本地插件=私有 tier）', () {
    test('私有（含本地插件 id）未激活：不在工具面，execute 拦截', () async {
      final router = _router();

      expect(router.focusedSchemas().map((s) => s.name).toList(), ['pub__a'],
          reason: '未激活私有（含本地插件）不得进入工具面');

      final blocked = await router.execute(
          AssembledToolCall(id: '1', name: 'lp1__x', argumentsJson: '{}'));
      expect(blocked.isError, isTrue);
      expect(blocked.content, contains('未激活'),
          reason: '非激活私有调用须被单槽门控拦截');
    });

    test('仅激活的单一私有可见（单槽互斥），其余私有隐藏', () async {
      final router = _router();
      router.activePrivateServerId = 'lp1';

      expect(router.focusedSchemas().map((s) => s.name).toList(),
          ['pub__a', 'lp1__x'],
          reason: '仅激活私有 lp1 可见，lp2 被互斥隐藏');

      final ok = await router.execute(
          AssembledToolCall(id: '1', name: 'lp1__x', argumentsJson: '{}'));
      expect(ok.isError, isFalse, reason: '激活私有可调用');

      final blocked = await router.execute(
          AssembledToolCall(id: '2', name: 'lp2__y', argumentsJson: '{}'));
      expect(blocked.isError, isTrue);
      expect(blocked.content, contains('单一私有域独占'),
          reason: '被互斥的私有 lp2 调用须拦截');
    });
  });
}
