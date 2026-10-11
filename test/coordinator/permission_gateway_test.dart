import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/agent_loop.dart';
import 'package:goodhub/coordinator/permission_gateway.dart';
import 'package:goodhub/llm/cloud/cloud_llm.dart';

class RecordingExecutor implements ToolExecutor {
  final executed = <AssembledToolCall>[];

  @override
  Future<ToolExecutionResult> execute(AssembledToolCall call) async {
    executed.add(call);
    return ToolExecutionResult(content: 'ok:${call.name}');
  }
}

class ScriptedDelegate implements GateDelegate {
  final decisions = <GateDecision>[];
  final confirmations = <ToolPendingConfirmation>[];
  Object? throwOnNext;

  @override
  Future<GateDecision> confirm(ToolPendingConfirmation pending) async {
    confirmations.add(pending);
    final t = throwOnNext;
    if (t != null) {
      throwOnNext = null;
      throw t;
    }
    return decisions.removeAt(0);
  }
}

AssembledToolCall call(String name, {String args = '{"id":"1"}'}) =>
    AssembledToolCall(id: 'c-${name.hashCode}', name: name, argumentsJson: args);

CloudToolSchema schema(String name, {Map<String, Object?>? annotations}) =>
    CloudToolSchema(
      name: name,
      description: '',
      parametersSchema: const {},
      annotations: annotations,
    );

void main() {
  late RecordingExecutor inner;
  late PermissionGateway gateway;

  setUp(() {
    inner = RecordingExecutor();
    gateway = PermissionGateway(inner: inner);
  });

  group('classify 裁决矩阵（拍板 C2）', () {
    test('无 hint：表命中→L1，未命中→L2（未知从严）', () {
      expect(gateway.classify('list_items', null), GatewayLevel.l1ReadOnly);
      expect(gateway.classify('delete_item', null), GatewayLevel.l2Write);
      expect(gateway.classify('brand_new_tool', null), GatewayLevel.l2Write);
    });

    test('仅 hint：hint 裁决（表外新工具可凭 hint 走 L1）', () {
      expect(gateway.classify('new_read_tool', const {'readOnlyHint': true}),
          GatewayLevel.l1ReadOnly);
      expect(gateway.classify('new_write_tool', const {'readOnlyHint': false}),
          GatewayLevel.l2Write);
    });

    test('双源冲突按更严格者：表说只读但 hint=false → L2', () {
      expect(gateway.classify('list_items', const {'readOnlyHint': false}),
          GatewayLevel.l2Write);
      expect(gateway.classify('list_items', const {'readOnlyHint': true}),
          GatewayLevel.l1ReadOnly);
    });

    test('hint 非布尔（形状异常）视为缺席', () {
      expect(gateway.classify('list_items', const {'readOnlyHint': 'yes'}),
          GatewayLevel.l1ReadOnly);
      expect(gateway.classify('delete_item', const {'readOnlyHint': 1}),
          GatewayLevel.l2Write);
    });
  });

  group('L1 只读静默', () {
    test('直通内层执行 + 药丸通告 + 不弹卡', () async {
      final notices = <ToolNotice>[];
      final g = PermissionGateway(
        inner: inner,
        onNotice: notices.add,
        delegate: ScriptedDelegate(),
      );
      g.loadCatalog([schema('list_items')]);
      final r = await g.execute(call('list_items'));
      expect(r.content, 'ok:list_items');
      expect(r.isError, isFalse);
      expect(notices.single.toolName, 'list_items');
      expect(notices.single.viaSessionGrant, isFalse);
    });
  });

  group('L2 确认卡', () {
    late ScriptedDelegate delegate;
    late PermissionGateway gated;

    setUp(() {
      delegate = ScriptedDelegate();
      gateway = PermissionGateway(inner: inner, delegate: delegate);
      gateway.loadCatalog([schema('update_item')]);
    });

    PermissionGateway buildGated({void Function(ToolNotice)? onNotice}) {
      final g = PermissionGateway(inner: inner, delegate: delegate, onNotice: onNotice);
      g.loadCatalog([schema('update_item')]);
      return g;
    }

    test('批准 → 执行内层并回传结果', () async {
      final gated = buildGated();
      delegate.decisions.add(const GateDecision(approved: true));
      final r = await gated.execute(call('update_item'));
      expect(inner.executed.single.name, 'update_item');
      expect(r.content, 'ok:update_item');
      expect(delegate.confirmations.single.argumentsJson, '{"id":"1"}');
    });

    test('批准且记住 → 后续同工具静默放行（viaSessionGrant 通告）', () async {
      final notices = <ToolNotice>[];
      final gated = buildGated(onNotice: notices.add);
      delegate.decisions.add(const GateDecision(approved: true, rememberSession: true));
      await gated.execute(call('update_item'));
      final r = await gated.execute(call('update_item', args: '{"id":"2"}'));
      expect(delegate.confirmations, hasLength(1));
      expect(inner.executed, hasLength(2));
      expect(r.content, 'ok:update_item');
      expect(notices, hasLength(1));
      expect(notices.single.viaSessionGrant, isTrue);
    });

    test('拒绝 → user_rejected 结果 isError=false，内层不执行', () async {
      delegate.decisions
          .add(const GateDecision(approved: false, reason: '先别改这条'));
      final r = await buildGated().execute(call('update_item'));
      expect(inner.executed, isEmpty);
      expect(r.isError, isFalse);
      final decoded = jsonDecode(r.content) as Map<String, Object?>;
      expect(decoded['status'], 'user_rejected');
      expect(decoded['reason'], '先别改这条');
    });

    test('拒绝无理由 → 默认 reason', () async {
      delegate.decisions.add(const GateDecision(approved: false));
      final r = await buildGated().execute(call('update_item'));
      expect((jsonDecode(r.content) as Map)['reason'], '用户拒绝');
    });

    test('拒绝时携带 rememberSession 不生效（仅批准可豁免）', () async {
      final gated = buildGated();
      delegate.decisions.add(const GateDecision(approved: false, rememberSession: true));
      await gated.execute(call('update_item'));
      delegate.decisions.add(const GateDecision(approved: true));
      await gated.execute(call('update_item'));
      expect(delegate.confirmations, hasLength(2));
    });

    test('delegate 抛异常 → 按拒绝处理（保守缺省）', () async {
      delegate.throwOnNext = Exception('UI 崩了');
      final r = await buildGated().execute(call('update_item'));
      expect(inner.executed, isEmpty);
      expect(r.isError, isFalse);
      final decoded = jsonDecode(r.content) as Map<String, Object?>;
      expect(decoded['status'], 'user_rejected');
      expect((decoded['reason'] as String).contains('UI 崩了'), isTrue);
    });
  });

  test('无 delegate（无人值守）→ L2 一律拒绝', () async {
    final r = await gateway.execute(call('delete_item'));
    expect(inner.executed, isEmpty);
    expect(r.isError, isFalse);
    expect((jsonDecode(r.content) as Map)['status'], 'user_rejected');
  });

  test('resetSessionGrants 清空豁免（会话结束/Abort 语义）', () async {
    final delegate = ScriptedDelegate();
    gateway = PermissionGateway(inner: inner, delegate: delegate);
    gateway.loadCatalog([schema('update_item')]);
    delegate.decisions.add(const GateDecision(approved: true, rememberSession: true));
    await gateway.execute(call('update_item'));
    gateway.resetSessionGrants();
    delegate.decisions.add(const GateDecision(approved: true));
    await gateway.execute(call('update_item'));
    expect(delegate.confirmations, hasLength(2));
  });

  test('loadCatalog 全量刷新（旧目录不留存，§8 缓存失效）', () async {
    gateway.loadCatalog([schema('list_items'), schema('add_item')]);
    gateway.loadCatalog([schema('get_item')]);
    // 旧目录工具按未知处理（无 hint → 表裁决），刷新不残留
    expect(gateway.classify('add_item', null), GatewayLevel.l2Write);
    final delegate = ScriptedDelegate();
    gateway = PermissionGateway(inner: inner, delegate: delegate);
    gateway.loadCatalog([schema('add_item', annotations: const {'readOnlyHint': true})]);
    expect(gateway.classify('add_item', const {'readOnlyHint': true}),
        GatewayLevel.l1ReadOnly);
  });
}
