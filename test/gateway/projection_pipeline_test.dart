/// 策略投影管道单测（host-tools-gateway-export PR2）。
///
/// 覆盖设计稿四节契约：§投影策略规范（三策略目录形态）·§过滤顺序铁律（四级
/// 顺序与元组级结构化过滤）·§single 入站前缀补齐（幂等/他服务拒绝/畸形名）
/// ·§会话绑定契约（策略解析的 Fail-Fast）。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/mcp_tool_face.dart';
import 'package:goodhub/gateway/mcp_gateway_handler.dart';
import 'package:goodhub/gateway/projection_pipeline.dart';
import 'package:goodhub/mcp/mcp_client.dart';
import 'package:goodhub/mcp/transport/mcp_transport.dart';

/// 假传输：`tools/list` 回给定条目，`tools/call` 回 echo 文本。
class _FakeTransport implements McpTransport {
  _FakeTransport(this.tools);

  final List<Map<String, Object?>> tools;

  @override
  Future<TransportResponse> send(String requestBody) async {
    final req = jsonDecode(requestBody) as Map<String, Object?>;
    final method = req['method'];
    final result = method == 'tools/list'
        ? {
            'tools': tools
          }
        : {
            'content': [
              {'type': 'text', 'text': 'echo:${req['params'] != null ? ((req['params'] as Map)['name']) : ''}'}
            ]
          };
    return TransportResponse(
      statusCode: 200,
      contentType: 'application/json',
      body: jsonEncode({'jsonrpc': '2.0', 'id': req['id'], 'result': result}),
    );
  }

  @override
  Future<StreamedTransportResponse> sendStream(String requestBody) async {
    final req = jsonDecode(requestBody) as Map<String, Object?>;
    return StreamedTransportResponse(
      statusCode: 200,
      contentType: 'application/json',
      lines: Stream<String>.fromIterable([jsonEncode({
        'jsonrpc': '2.0',
        'id': req['id'],
        'result': {
          'content': [
            {
              'type': 'text',
              'text': 'echo:${req['params'] != null ? ((req['params'] as Map)['name']) : ''}'
            }
          ]
        }
      })]),
    );
  }

  @override
  Future<StreamedTransportResponse> getStream() =>
      throw UnsupportedError('假传输无 GET SSE');

  @override
  void close() {}
}

Map<String, Object?> _tool(
  String name, {
  bool shared = true,
  List<String> tags = const [],
}) =>
    {
      'name': name,
      'description': 'd-$name',
      'inputSchema': const {'type': 'object'},
      '_meta': {
        'goodhub': {
          'visibility': shared ? 'shared' : 'private',
          if (tags.isNotEmpty) 'tags': tags,
        }
      },
    };

Future<McpToolFace> _face(String serverId, List<Map<String, Object?>> tools) async {
  final f = McpToolFace(client: McpClient(_FakeTransport(tools)), serverId: serverId);
  await f.listTools();
  return f;
}

/// 变更某 face 的目录（模拟重扫后 `tools/list` 重拉——`cachedSchemas` 是
/// 不可变视图，唯一变更路径就是重拉）。
Future<void> _reload(McpToolFace face, List<Map<String, Object?>> tools) async {
  final t = face.client.transport as _FakeTransport;
  t.tools
    ..clear()
    ..addAll(tools);
  await face.listTools();
}

void main() {
  group('§会话绑定契约 · 策略解析（Fail-Fast）', () {
    // 「可访问」判定桩：host / goodshare 恒可访问（public 语义）
    bool accessible(String id) => id == 'host' || id == 'goodshare';

    test('无 strategy / 空串 → full（默认暴露面语义不变）', () {
      expect(ProjectionPolicy.parse({}, isAccessible: accessible).strategy,
          ProjectionStrategy.full);
      expect(
          ProjectionPolicy.parse({'strategy': ' '}, isAccessible: accessible).strategy,
          ProjectionStrategy.full);
    });

    test('strategy=full 忽略其余参数', () {
      final p =
          ProjectionPolicy.parse({'strategy': 'full', 'server': 'x'}, isAccessible: accessible);
      expect(p.strategy, ProjectionStrategy.full);
    });

    test('strategy=pruned&tag=core → tags 集（支持逗号多值）', () {
      final p = ProjectionPolicy.parse(
          {'strategy': 'pruned', 'tag': 'core, io'}, isAccessible: accessible);
      expect(p.tags, {'core', 'io'});
      expect(p.isPruned, isTrue);
    });

    test('pruned 缺 tag → 抛（不静默退化为全量）', () {
      expect(() => ProjectionPolicy.parse({'strategy': 'pruned'}, isAccessible: accessible),
          throwsA(isA<ProjectionPolicyException>()));
    });

    test('single 目标已挂载 → 绑定；未挂载 → 抛 target server not found', () {
      final ok =
          ProjectionPolicy.parse({'strategy': 'single', 'server': 'host'}, isAccessible: accessible);
      expect(ok.isSingle, isTrue);
      expect(ok.targetServerId, 'host');
      expect(
          () => ProjectionPolicy.parse(
              {'strategy': 'single', 'server': 'ghost'}, isAccessible: accessible),
          throwsA(isA<ProjectionPolicyException>()));
    });

    test('single 缺 server / 未知字面量 → 抛（不猜不降级）', () {
      expect(() => ProjectionPolicy.parse({'strategy': 'single'}, isAccessible: accessible),
          throwsA(isA<ProjectionPolicyException>()));
      expect(
          () => ProjectionPolicy.parse({'strategy': 'narrow'}, isAccessible: accessible),
          throwsA(isA<ProjectionPolicyException>()));
    });
  });

  group('§过滤顺序铁律 · 四级管道', () {
    late McpToolFace pub;
    late McpToolFace priv;
    late McpToolFace host;

    setUp(() async {
      pub = await _face('pub', [_tool('a'), _tool('hidden', shared: false)]);
      priv = await _face('priv', [_tool('p'), _tool('hidden', shared: false)]);
      host = await _face('host', [_tool('echo_host', tags: ['core'])]);
    });

    /// 默认**不带**系统工具（聚焦四级过滤本身）；系统工具的策略相关性由
    /// 「④ full/pruned 保留前缀 + 系统工具只在非 single 列出」单独断言。
    List<String> names(ProjectionPolicy policy, {String? activePrivate}) {
      final r = ProjectionFilter.project(
        faces: {'pub': pub, 'priv': priv, 'host': host},
        privateServerIds: {'priv'},
        activePrivateServerId: activePrivate,
        policy: policy,
        systemTools: const [],
      );
      return [for (final t in r.tools) t.name];
    }

    test('① visibility 海关：private 工具任何策略都不进面', () {
      for (final p in [
        const ProjectionPolicy.full(),
        ProjectionPolicy.pruned({'core'}),
        ProjectionPolicy.single('pub'),
      ]) {
        expect(names(p), isNot(contains('pub__hidden')), reason: '$p');
        expect(names(p), isNot(contains('hidden')), reason: '$p');
      }
    });

    test('② 私有投影防火墙：非激活私有不进面（策略不得先于防火墙）', () {
      final n = names(const ProjectionPolicy.full());
      expect(n, contains('pub__a'));
      expect(n, contains('host__echo_host'));
      expect(n, isNot(contains('priv__p')),
          reason: '未激活私有域不进面');
      expect(names(const ProjectionPolicy.full(), activePrivate: 'priv'),
          contains('priv__p'),
          reason: '本连接激活私有后其 shared 工具进面');
    });

    test('② 防火墙先于策略：single 指定未激活私有服务也不放行', () {
      final n = names(ProjectionPolicy.single('priv'));
      expect(n, isEmpty,
          reason: '策略过滤不得成为绕开私有防火墙的后门');
    });

    test('② 海关豁免：激活私有域的非 shared 工具进面（2026-10-23 裁决，修「能调不能看」）', () {
      final n = names(const ProjectionPolicy.full(), activePrivate: 'priv');
      expect(n, contains('priv__hidden'),
          reason: '绑定即信任边界：激活私有域全量工具进目录，与调用侧「声明非 ACL」对齐');
      expect(n, contains('priv__p'), reason: 'shared 工具照常进面');
      // full 档：豁免域工具保留 <serverId>__<tool> 前缀
      expect(n, isNot(contains('hidden')), reason: 'full 不剥前缀');
    });

    test('② 海关豁免不外溢：非激活域/公共面的 private 工具仍剔除', () {
      final n = names(const ProjectionPolicy.full(), activePrivate: 'priv');
      expect(n, isNot(contains('pub__hidden')),
          reason: '豁免仅限激活私有域本身，公共面照旧 default-deny');
      final inactive = names(ProjectionPolicy.single('priv'));
      expect(inactive, isEmpty, reason: '未激活（防火墙拦截）时无任何豁免');
    });

    test('② 海关豁免：single 指向激活私有域 → 非 shared 工具剥前缀进面', () {
      final n = names(ProjectionPolicy.single('priv'), activePrivate: 'priv');
      expect(n, ['hidden', 'p'],
          reason: 'single 剥前缀；私有域内 shared 与 private 工具全量（输出按名排序）');
    });

    test('single 切入公共档服务 → 绑定激活域，私有声明工具剥前缀进面（2026-10-24 裁决）', () {
      // 修「single 切入公共档服务后私有声明工具不可见」：切入即信任边界，
      // 与目标 tier 无关（v1.1.1 的可见性来自宿主默认绑定偶然生效，非设计）。
      final n = names(ProjectionPolicy.single('pub'), activePrivate: 'pub');
      expect(n, ['a', 'hidden'],
          reason: 'single 剥前缀；目标服务全量工具（shared + private 声明）都进面');
    });

    test('③ single 收敛到单一目标 + ④ 剥前缀直出裸名', () {
      final n = names(ProjectionPolicy.single('host'));
      expect(n, ['echo_host']);
    });

    test('owner 档（宿主内部）：海关全豁免——公共面的 private 工具也进面', () {
      final n = names(ProjectionPolicy.owner(), activePrivate: 'priv');
      expect(n, containsAll(['pub__a', 'pub__hidden', 'priv__p', 'priv__hidden']),
          reason: '机主全权视图：visibility 声明不收窄目录（对齐 focusedSchemas「声明非访问控制」）');
      expect(n, contains('host__echo_host'));
      // 前缀化命名（full 风格），防火墙仍由 activePrivateServerId 门控
    });

    test('owner 档：私有防火墙照常——未激活私有域不进面', () {
      final n = names(ProjectionPolicy.owner());
      expect(n, containsAll(['pub__a', 'pub__hidden', 'host__echo_host']),
          reason: '海关豁免 ≠ 防火墙豁免：公共面 private 工具进面，私有域仍需激活');
      expect(n, isNot(contains('priv__p')), reason: '未激活私有域不进面');
      expect(n, isNot(contains('priv__hidden')));
    });

    test('owner 档目录集 == focusedSchemas 语义（公共全量 + 激活私有槽，前缀化）', () {
      // focusedSchemas 语义（tool_router.dart §7.4）：全部公共 face（排序）+
      // 激活私有槽（尾部）。管道 owner 档的**集合**应与之一致（排序约定各自
      // 保留——router 三段式序保 prompt 缓存，管道按名排序，集合等价即归一）。
      final owner = names(ProjectionPolicy.owner(), activePrivate: 'priv');
      final focused = <String>[
        'pub__a', 'pub__hidden', // 公共 face 全量（含 private 工具，无海关）
        'host__echo_host', // 公共 face（host 虚拟服务）
        'priv__p', 'priv__hidden', // 激活私有槽
      ];
      expect(owner.toSet(), focused.toSet(),
          reason: '机制归一断言：App 视图 = policy=owner 的管道求值（2026-10-23 方向裁决）');
    });

    test('③ pruned 保守白名单：未打标一律剔除（含外部服务）', () {
      final core = names(ProjectionPolicy.pruned({'core'}));
      expect(core, ['host__echo_host'],
          reason: '仅打标 core 的宿主工具进面（系统工具已在本组 names 中剔除）');
      expect(core, isNot(contains('pub__a')), reason: '未打标 → 剔除');
      expect(names(ProjectionPolicy.pruned({'io'})), isEmpty);
    });

    test('④ full/pruned 保留前缀 + 系统工具只在非 single 列出', () {
      expect(names(const ProjectionPolicy.full()), contains('pub__a'));
      Set<String> withSystem(ProjectionPolicy policy) {
        final r = ProjectionFilter.project(
          faces: {'pub': pub, 'priv': priv, 'host': host},
          privateServerIds: {'priv'},
          activePrivateServerId: null,
          policy: policy,
          systemTools: GatewayHandler.systemToolJson,
        );
        return {for (final t in r.tools) t.name};
      }

      expect(withSystem(const ProjectionPolicy.full()),
          contains(GatewayHandler.kGatewaySelectPrivate));
      expect(withSystem(ProjectionPolicy.pruned({'core'})),
          contains(GatewayHandler.kGatewaySelectPrivate));
      // 系统工具裁剪**不在本函数**（由 `GatewayHandler.project` 按策略给清单）——
      // pipeline 拿到什么就纳入什么，故此处 single 仍会纳入调用方给出的清单。
      expect(withSystem(ProjectionPolicy.single('host')),
          contains(GatewayHandler.kGatewaySelectPrivate),
          reason: '纳入与否由调用方裁剪，pipeline 不二次裁决');
    });

    test('投影集签名按 serverId/bareName 结构化（与对外前缀解耦）', () {
      final single = ProjectionFilter.project(
        faces: {'host': host},
        privateServerIds: const {},
        activePrivateServerId: null,
        policy: ProjectionPolicy.single('host'),
        systemTools: const [],
      );
      final full = ProjectionFilter.project(
        faces: {'host': host},
        privateServerIds: const {},
        activePrivateServerId: null,
        policy: const ProjectionPolicy.full(),
        systemTools: const [],
      );
      expect(single.signature, {'host/echo_host'});
      expect(full.signature, single.signature,
          reason: '同一批工具在不同策略下签名相同——差异在策略不在集合');
      expect(single.tools.single.name, 'echo_host');
      expect(full.tools.single.name, 'host__echo_host');
    });
  });

  group('§single 入站前缀补齐（结构化 · 幂等）', () {
    final single = ProjectionPolicy.single('host');
    bool projected(String serverId, String bare) =>
        serverId == 'host' && bare == 'echo_host';

    test('无前缀 → 补 target 前缀后放行（prefixNormalized=true）', () {
      final r = resolveInboundToolName(
          name: 'echo_host', policy: single, isProjected: projected);
      expect(r, isA<InboundAllowed>());
      final a = r as InboundAllowed;
      expect(a.resolvedName, 'host__echo_host');
      expect(a.prefixNormalized, isTrue);
    });

    test('已带正确前缀 → 原样放行且不二次拼接（幂等）', () {
      final r = resolveInboundToolName(
          name: 'host__echo_host', policy: single, isProjected: projected);
      final a = r as InboundAllowed;
      expect(a.resolvedName, 'host__echo_host', reason: '不得变成 host__host__…');
      expect(a.prefixNormalized, isFalse);
    });

    test('他服务前缀 → 显式拒绝（越出本连接投影面）', () {
      final r = resolveInboundToolName(
          name: 'goodshare__task', policy: single, isProjected: projected);
      expect(r, isA<InboundRejected>());
      expect((r as InboundRejected).reason, contains('越出本连接投影面'));
    });

    test('工具名自身含 __（畸形）→ -32602 协议级拒绝', () {
      final r = resolveInboundToolName(
          name: 'host__other__tool', policy: single, isProjected: projected);
      expect(r, isA<InboundProtocolError>());
      expect((r as InboundProtocolError).code, -32602);
    });

    test('投影集外调用（含未投影的 private 工具）→ 拒绝', () {
      final r = resolveInboundToolName(
          name: 'host__secret', policy: single, isProjected: projected);
      expect(r, isA<InboundRejected>());
      expect((r as InboundRejected).reason, contains('不在当前投影集内'));
    });

    test('single 下 gateway__* 系统工具 → 显式拒绝（零泄漏）', () {
      final r = resolveInboundToolName(
          name: GatewayHandler.kGatewaySelectPrivate,
          policy: single,
          isProjected: projected);
      expect(r, isA<InboundRejected>());
    });

    test('full 下缺前缀维持既有口径：isError 回填（非协议 error）', () {
      final r = resolveInboundToolName(
          name: 'no_prefix',
          policy: const ProjectionPolicy.full(),
          isProjected: projected);
      expect(r, isA<InboundRejected>(), reason: '既有语义：业务级 isError');
      expect((r as InboundRejected).reason, contains('缺少服务前缀'));
    });
  });

  group('handler 接线：目录 / 调用 / 差分抑制', () {
    late McpToolFace host;
    late McpToolFace other;

    setUp(() async {
      host = await _face('host', [_tool('echo_host'), _tool('secret', shared: false)]);
      other = await _face('goodshare', [_tool('task')]);
    });

    GatewayHandler handler(ProjectionPolicy policy) => GatewayHandler(
          faces: {'host': host, 'goodshare': other},
          policy: policy,
        );

    test('single 会话：目录只含裸名 host 工具 + 唯一出口工具', () {
      final names = handler(ProjectionPolicy.single('host'))
          .toolsList()
          .map((e) => e['name'])
          .toList();
      expect(names, ['echo_host', GatewayHandler.kGatewaySelectPrivate],
          reason: 'private 工具与列举工具零泄漏；出口工具必须保留（否则死锁）');
    });

    test('single 会话：无前缀调用经补齐直达 host face', () async {
      final r = await handler(ProjectionPolicy.single('host')).toolsCall(
        name: 'echo_host',
        arguments: const {},
        onProgress: (_) {},
      );
      expect(r.isError, isFalse);
      expect(r.content, contains('echo_host'));
    });

    test('single 会话：他服务工具与 private 工具均被拒', () async {
      final h = handler(ProjectionPolicy.single('host'));
      final cross = await h.toolsCall(
          name: 'goodshare__task',
          arguments: const {},
          onProgress: (_) {});
      expect(cross.isError, isTrue);
      final secret = await h.toolsCall(
          name: 'secret', arguments: const {}, onProgress: (_) {});
      expect(secret.isError, isTrue,
          reason: '投影集外的 private 工具按 single 调用边界拒绝');
    });

    test('full 会话：行为与既有口径逐条等价（带前缀 + 私有防火墙）', () async {
      final h = handler(const ProjectionPolicy.full());
      final names = h.toolsList().map((e) => e['name']).toList();
      expect(names, contains('host__echo_host'));
      expect(names, contains('goodshare__task'));
      expect(names, contains(GatewayHandler.kGatewaySelectPrivate));
      final ok = await h.toolsCall(
          name: 'host__echo_host',
          arguments: const {},
          onProgress: (_) {});
      expect(ok.isError, isFalse);
    });

    test('广播差分：无变化抑制，投影集变化才广播', () async {
      final h = handler(ProjectionPolicy.single('host'));
      h.markProjectionBaseline();
      expect(h.projectionChangedSinceBaseline(), isFalse,
          reason: '基线后无变化 → 抑制（single 对无关服务变更无感）');
      // 无关服务（goodshare）新增工具 → single 投影不变 → 继续抑制
      await _reload(other, [_tool('task'), _tool('task2')]);
      expect(h.projectionChangedSinceBaseline(), isFalse,
          reason: 'single 策略只看目标服务，其他服务变更与本连接无关');
      // 目标服务新增 shared 工具 → 投影变化 → 应广播
      await _reload(host,
          [_tool('echo_host'), _tool('secret', shared: false), _tool('echo_host2')]);
      expect(h.projectionChangedSinceBaseline(), isTrue);
      expect(h.projectionChangedSinceBaseline(), isFalse,
          reason: '广播后快照已更新，重复变更不重复广播');
    });
  });
  group('§单轴化（2026-10-23 裁决 D1）· policy 为主名 / strategy 为兼容别名', () {
    bool accessible(String id) => id == 'host' || id == 'goodshare';
    bool isPrivate(String id) => id == 'privA';

    test('policy=single&server=host → single（与旧 strategy= 同义）', () {
      final p = ProjectionPolicy.parse(
          {'policy': 'single', 'server': 'host'}, isAccessible: accessible);
      expect(p.isSingle, isTrue);
      expect(p.targetServerId, 'host');
    });

    test('旧键 strategy= 继续工作（兼容别名，零改动即生效）', () {
      final p = ProjectionPolicy.parse(
          {'strategy': 'single', 'server': 'host'}, isAccessible: accessible);
      expect(p.isSingle, isTrue);
    });

    test('policy 与 strategy 同传时 policy 优先', () {
      final p = ProjectionPolicy.parse(
        {'policy': 'full', 'strategy': 'single', 'server': 'host'},
        isAccessible: accessible,
      );
      expect(p.strategy, ProjectionStrategy.full);
    });

    test('policy=private&server=<私有> → 私有叠加档', () {
      final p = ProjectionPolicy.parse(
        {'policy': 'private', 'server': 'privA'},
        isAccessible: (id) => true,
        isPrivate: isPrivate,
      );
      expect(p.isPrivate, isTrue);
      expect(p.targetServerId, 'privA');
    });

    test('policy=private 目标非私有 / 缺 server / 未挂载 → 抛（不静默降级）', () {
      expect(
        () => ProjectionPolicy.parse(
          {'policy': 'private', 'server': 'pubB'},
          isAccessible: (id) => true,
          isPrivate: isPrivate,
        ),
        throwsA(isA<ProjectionPolicyException>()),
      );
      expect(
        () => ProjectionPolicy.parse(
          {'policy': 'private'},
          isAccessible: accessible,
          isPrivate: isPrivate,
        ),
        throwsA(isA<ProjectionPolicyException>()),
      );
      expect(
        () => ProjectionPolicy.parse(
          {'policy': 'private', 'server': 'ghost'},
          isAccessible: accessible,
          isPrivate: isPrivate,
        ),
        throwsA(isA<ProjectionPolicyException>()),
      );
    });

    test('policy=owner → 拒绝（宿主内部档不经网关暴露，防 MO6 崩塌）', () {
      expect(
        () => ProjectionPolicy.parse(
          {'policy': 'owner'},
          isAccessible: accessible,
        ),
        throwsA(isA<ProjectionPolicyException>()),
      );
    });

    test('policy=pruned&tag=core → tags 集（pruned 仍只在连接建立期可用）', () {
      final p = ProjectionPolicy.parse(
          {'policy': 'pruned', 'tag': 'core'}, isAccessible: accessible);
      expect(p.isPruned, isTrue);
      expect(p.tags, {'core'});
    });

    test('未知字面量 → 抛且话术列出四档合法值', () {
      expect(
        () => ProjectionPolicy.parse({'policy': 'wide'}, isAccessible: accessible),
        throwsA(isA<ProjectionPolicyException>()),
      );
      try {
        ProjectionPolicy.parse({'policy': 'wide'}, isAccessible: accessible);
        fail('应抛 ProjectionPolicyException');
      } on ProjectionPolicyException catch (e) {
        expect(e.message, contains('single'));
        expect(e.message, contains('private'));
        expect(e.message, contains('full'));
        expect(e.message, contains('pruned'));
      }
    });
  });

}
