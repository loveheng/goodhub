/// B2 基线测试（window-kernel-split 步 0）+ 步 1 装配测试：会话绑定默认回退链
/// 纯函数、装配产物等价性、资源释放（close/abort 两段语义 + 装配异常回收）。
///
/// 回退链（plan.md §2.1 B2，「最易改错的一段」）：
/// 已显式绑定直接用（'' → null = 显式公共）→ 全局钉选 isDefault →
/// 首个 private → null。（2026-10-18：chat_page 的同名回退链已随「新会话
/// 一律公共起步」废除；本纯函数保留为遗留兜底语义锚。）
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/mcp_runtime.dart';
import 'package:goodhub/coordinator/task_plan.dart';
import 'package:goodhub/coordinator/mcp_tool_face.dart';
import 'package:goodhub/coordinator/skill_registry.dart';
import 'package:goodhub/llm/cloud/cloud_llm.dart';
import 'package:goodhub/mcp/mcp_client.dart';
import 'package:goodhub/mcp/server_endpoints.dart';
import 'package:goodhub/mcp/transport/mcp_transport.dart';
import 'package:goodhub/sandbox/memory_store.dart';

ServerEndpoint ep(
  String id, {
  ServerPrivacyTier tier = ServerPrivacyTier.private,
  bool isDefault = false,
}) =>
    ServerEndpoint(id: id, name: id, endpoint: 'http://x/mcp', tier: tier, isDefault: isDefault);

void main() {
  group('resolveBinding 回退链（B2）', () {
    test('已显式绑定 serverId：直接锁定，无视 isDefault 与顺序', () {
      final eps = [ep('a', isDefault: true), ep('b')];
      expect(resolveBinding(eps, bound: 'b'), 'b');
    });

    test('显式公共（''）→ null（不再回退私有——三态语义防回跳）', () {
      final eps = [ep('a', isDefault: true)];
      expect(resolveBinding(eps, bound: ''), isNull);
    });

    test('未绑定 + 全局钉选：isDefault 优先，与排列顺序无关', () {
      expect(resolveBinding([ep('a'), ep('d', isDefault: true)]), 'd');
      expect(resolveBinding([ep('d', isDefault: true), ep('a')]), 'd');
    });

    test('未绑定 + 无钉选：首个 private（保持列表序）', () {
      expect(resolveBinding([ep('p2'), ep('p1')]), 'p2');
    });

    test('public 端点不参与回退', () {
      expect(
        resolveBinding([
          ep('pub', tier: ServerPrivacyTier.public),
          ep('pub2', tier: ServerPrivacyTier.public, isDefault: true),
        ]),
        isNull,
        reason: 'public（含 isDefault）不得进私有槽位回退链',
      );
    });

    test('无 private 端点 → null（纯公共）', () {
      expect(resolveBinding(const <ServerEndpoint>[]), isNull);
    });

    test('钉选优先于首个 private（同列表两私有）', () {
      expect(resolveBinding([ep('first'), ep('pinned', isDefault: true)]), 'pinned');
    });
  });

  _assembleTests();
  _assemblyEquivalenceTests();
}

// ---------------------------------------------------------------------------
// S0 保护网 · 装配产物等价性（施工稿 docs/design/arch-consolidation.md §S0）
// ---------------------------------------------------------------------------

/// S0 的两条判据：① 同输入 → 同产物（顺序敏感的工具面快照）；② 释放幂等且
/// 全覆盖。二者是 S1（owner 注册中心）与 S3（发送链路下沉）重构的回滚判据。
void _assemblyEquivalenceTests() {
  group('S0 装配产物等价性', () {
    test('同输入两次装配：工具面快照逐项一致（顺序敏感）', () async {
      final eps = <ServerEndpoint>[
        ServerEndpoint(id: 'good', name: 'g', endpoint: 'http://x/good/mcp'),
        ServerEndpoint(id: 'todo', name: 't', endpoint: 'http://x/todo/mcp'),
      ];

      final a = await _assemble(
        endpoints: eps,
        clients: <String, McpClient>{},
        transports: <McpTransport>[],
      );
      final b = await _assemble(
        endpoints: eps,
        clients: <String, McpClient>{},
        transports: <McpTransport>[],
      );

      final toolsA = a.loop.toolsProvider!().map((t) => t.name).toList();
      final toolsB = b.loop.toolsProvider!().map((t) => t.name).toList();
      expect(toolsA, toolsB, reason: '装配产物必须可复现，含顺序');
      expect(toolsA, contains('good__a'));
      expect(a.serverSummaries, b.serverSummaries);

      await a.close();
      await b.close();
    });

    test('两次装配互不串扰：refStore 各持一份，planState 为显式透传', () async {
      final eps = <ServerEndpoint>[
        ServerEndpoint(id: 'good', name: 'g', endpoint: 'http://x/good/mcp'),
      ];
      final plan = PlanRunState();

      final a = await _assemble(
        endpoints: eps,
        clients: <String, McpClient>{},
        transports: <McpTransport>[],
        planState: plan,
      );
      final b = await _assemble(
        endpoints: eps,
        clients: <String, McpClient>{},
        transports: <McpTransport>[],
      );

      expect(identical(a.refStore, b.refStore), isFalse,
          reason: 'refStore 恒 Run 级，两次装配不得共享');
      expect(identical(a.planState, plan), isTrue, reason: 'planState 会话级，装配期透传');
      expect(b.planState, isNull);

      await a.close();
      await b.close();
    });

    test('close 幂等且释放全覆盖：每个传输恰好关一次', () async {
      final transports = <McpTransport>[];
      final clients = <String, McpClient>{};
      final assembly = await _assemble(
        endpoints: <ServerEndpoint>[
          ServerEndpoint(id: 'good', name: 'g', endpoint: 'http://x/good/mcp'),
          ServerEndpoint(id: 'todo', name: 't', endpoint: 'http://x/todo/mcp'),
        ],
        clients: clients,
        transports: transports,
      );

      await assembly.close();
      await assembly.close(); // 幂等：第二次不得再关、不得抛

      final counted = transports.cast<_CountingTransport>();
      expect(counted.length, 2);
      expect(
        counted.map((t) => t.closeCount).toList(),
        everyElement(1),
        reason: '每个挂载的传输恰好释放一次（多关=重复释放，少关=泄漏）',
      );
    });
  });
}

// ---------------------------------------------------------------------------
// 步 1 · 装配测试（plan §3 单测：装配产物等价性 + 资源释放）
// ---------------------------------------------------------------------------

/// 计数 fake 传输：协议面最小实现（initialize / tools/list），close 计数可观测
/// （句柄封死，只能从 transport 层观测——plan 步 1 单测断言手段）。
class _CountingTransport implements McpTransport {
  _CountingTransport({this.failSend = false});

  int closeCount = 0;
  final bool failSend;

  @override
  Future<TransportResponse> send(String requestBody) async {
    if (failSend) throw StateError('boom');
    final method = (jsonDecode(requestBody) as Map)['method'] as String?;
    Object? result;
    if (method == 'initialize') {
      result = {
        'protocolVersion': '2025-06-18',
        'capabilities': {'tools': {}},
        'serverInfo': {'name': 'fake', 'version': '1.0'},
      };
    } else if (method == 'tools/list') {
      result = {
        'tools': [
          {'name': 'a'},
        ],
      };
    } else {
      result = {};
    }
    return TransportResponse(
      statusCode: 200,
      contentType: 'application/json',
      body: jsonEncode({'jsonrpc': '2.0', 'id': 1, 'result': result}),
    );
  }

  @override
  Future<StreamedTransportResponse> sendStream(String requestBody) async =>
      StreamedTransportResponse(
        statusCode: 200,
        contentType: 'text/event-stream',
        lines: const Stream<String>.empty(),
      );

  @override
  Future<StreamedTransportResponse> getStream() =>
      throw UnsupportedError('no GET SSE（非 HTTP 传输口径，协议层退化不监听）');

  @override
  void close() => closeCount++;
}

class _FakeEngine implements CloudLlmEngine {
  @override
  String get name => 'fake';

  @override
  Stream<CloudStreamEvent> send(CloudChatRequest request, {void Function()? onActivity}) =>
      const Stream<CloudStreamEvent>.empty();
}

Future<Directory> _tmpDir() async {
  final d = await Directory.systemTemp.createTemp('mcp_runtime_test');
  addTearDown(() => d.delete(recursive: true));
  return d;
}

Future<McpAssembly> _assemble({
  required List<ServerEndpoint> endpoints,
  required Map<String, McpClient> clients,
  required List<McpTransport> transports,
  SessionContext? context,
  Map<String, McpToolFace> sharedFaces = const {},
  Set<String> failFor = const {},
  PlanRunState? planState,
}) async {
  final tmp = await _tmpDir();
  return const McpRuntime().assemble(
    context: context ?? SessionContext(),
    endpoints: endpoints,
    locals: const [],
    apiKeyReader: (id) async => 'key-$id',
    memoryStore: MemoryStore.underSupportDir(tmp.path),
    skills: SkillRegistry()..registerAll(builtinSkills()),
    engine: _FakeEngine(),
    tempDirResolver: _tmpDir,
    documentsDirResolver: _tmpDir,
    sharedFaces: sharedFaces,
    planState: planState,
    clientFactory: (endpoint, apiKey) {
      final transport = _CountingTransport(failSend: failFor.contains(endpoint));
      transports.add(transport);
      final client = McpClient(transport);
      clients[endpoint] = client;
      return client;
    },
  );
}

void _assembleTests() {
  // 编排 B1：聊天装配路径断言——toolsProvider 恒含 propose_task_plan 元工具；
  // 冻结集激活期对冻结集写工具注入 _plan_step_id（非编排态/收口后 Schema 干净）；
  // close = Run 收口 → grant 销毁（phase completed）。
  test('编排 B1 装配：元工具在场 + step-id 注入随 grant 生命周期', () async {
    final transports = <McpTransport>[];
    final clients = <String, McpClient>{};
    final planState = PlanRunState();
    final assembly = await _assemble(
      endpoints: const [
        ServerEndpoint(id: 'good', name: 'good', endpoint: 'http://x/good/mcp'),
      ],
      clients: clients,
      transports: transports,
      planState: planState,
    );
    final tools = assembly.loop.toolsProvider!();
    expect(tools.any((t) => t.name == 'propose_task_plan'), isTrue,
        reason: '聊天装配路径已接 propose_task_plan 元工具');
    bool hasStepId(List<CloudToolSchema> list, String name) {
      final props = list.firstWhere((t) => t.name == name,
          orElse: () => throw StateError('missing $name'));
      return (props.parametersSchema['properties'] as Map?)
              ?.containsKey(kPlanStepIdKey) ??
          false;
    }

    expect(hasStepId(tools, 'good__a'), isFalse,
        reason: '非编排态 Schema 恒干净');
    planState.adoptProposal(
      goal: 'g',
      steps: const [
        FrozenPlanStep(id: 's1', server: 'good', tool: 'a', intent: 'i'),
      ],
    );
    expect(hasStepId(assembly.loop.toolsProvider!(), 'good__a'), isTrue,
        reason: 'propose 回填后的首轮即生效（toolsProvider 每轮重取）');
    await assembly.close();
    expect(planState.phase, PlanRunPhase.completed,
        reason: 'close = Run 收口：grant 销毁、pending 归 skipped');
    expect(planState.grants('good', 'a'), isFalse);
    expect(hasStepId(assembly.loop.toolsProvider!(), 'good__a'), isFalse,
        reason: 'Run 收口后注入自然消失');
  });

  // F3（review-fix-2026-10）：端点装配失败（negotiate/listTools 抛错）路径
  // 此前不 close client——client 未登记进任何回收表（外层兜底只清已登记句柄），
  // 坏端点每轮聊天装配泄一个 client；且单端点失败会炸整轮装配。修复后语义 =
  // 失败即关 + 通告降级继续（对齐 mountEndpoint/保留字分支的宁缺勿炸）。
  test('F3：端点 negotiate 失败 → client 即关 + 好端点照常挂载', () async {
    final transports = <McpTransport>[];
    final clients = <String, McpClient>{};
    final assembly = await _assemble(
      // clientFactory 收到的键是 endpoint URL（非 id）——URL 带 id 便于定向注坏。
      endpoints: const [
        ServerEndpoint(id: 'bad', name: 'bad', endpoint: 'http://x/bad/mcp'),
        ServerEndpoint(id: 'good', name: 'good', endpoint: 'http://x/good/mcp'),
      ],
      clients: clients,
      transports: transports,
      failFor: {'http://x/bad/mcp'},
    );
    addTearDown(assembly.close);

    expect(assembly.router.serverIds, {'good'},
        reason: '坏端点不进路由，单端点失败不炸整轮装配');
    expect((transports[0] as _CountingTransport).closeCount, 1,
        reason: 'F3：装配失败路径必须 close（修复前泄漏，撤修复即红）');
    expect(assembly.serverSummaries.containsKey('good'), isTrue);
  });

  test('装配产物等价性：私有槽位/激活集/回退链/摘要快照', () async {
    final transports = <McpTransport>[];
    final clients = <String, McpClient>{};
    final assembly = await _assemble(
      endpoints: [ep('priv', isDefault: true), ep('pub', tier: ServerPrivacyTier.public)],
      clients: clients,
      transports: transports,
    );
    addTearDown(assembly.close);

    expect(assembly.router.privateServerIds, {'priv'});
    expect(assembly.router.activatedServers, {'pub'}, reason: 'public 默认激活，private 不激活');
    expect(assembly.router.activePrivateServerId, 'priv',
        reason: '未显式绑定 → 全局钉选回退');
    expect(assembly.serverSummaries['priv'], contains('Tier'));
    expect(transports, hasLength(2));
  });

  test('显式公共（bound=""）回退链不回跳私有', () async {
    final assembly = await _assemble(
      endpoints: [ep('priv', isDefault: true)],
      clients: {},
      transports: [],
      context: SessionContext(activePrivateServerId: ''),
    );
    addTearDown(assembly.close);
    expect(assembly.router.activePrivateServerId, isNull);
  });

  test('close() 释放全部传输（计数=1）且幂等；abort 不释放', () async {
    final transports = <McpTransport>[];
    final assembly = await _assemble(
      endpoints: [ep('a'), ep('b')],
      clients: {},
      transports: transports,
    );
    assembly.abort(reason: 'test'); // 不释放
    expect(transports.every((t) => (t as _CountingTransport).closeCount == 0), isTrue);

    await assembly.close();
    expect(transports.every((t) => (t as _CountingTransport).closeCount == 1), isTrue,
        reason: 'close 释放底层传输（T5b：stop 之外的 client.close 既有债）');
    await assembly.close(); // 幂等
    expect(transports.every((t) => (t as _CountingTransport).closeCount == 1), isTrue);
  });

  group('共享能力源借用缝（装配层合一 · Contract 件）', () {
    /// 构造一个已挂载的共享 face（tools/list 预热缓存）。
    Future<(McpToolFace, _CountingTransport)> makeSharedFace(String id) async {
      final transport = _CountingTransport();
      final face = McpToolFace(
        client: McpClient(transport),
        serverId: id,
      );
      await face.listTools();
      return (face, transport);
    }

    test('命中即借用：不经 clientFactory（零新建连接），face 同一实例，摘要标共享', () async {
      final (shared, sharedTransport) = await makeSharedFace('svc');
      final transports = <McpTransport>[];
      final assembly = await _assemble(
        endpoints: [ep('svc')],
        clients: {},
        transports: transports,
        sharedFaces: {'svc': shared},
      );
      addTearDown(assembly.close);

      expect(transports, isEmpty,
          reason: '借用面跳过新建/协商/连接——clientFactory 不被调用');
      expect(sharedTransport.closeCount, 0);
      expect(assembly.router.faceOf('svc'), same(shared),
          reason: '路由使用共享 face 同一实例（能力目录同源）');
      expect(assembly.serverSummaries['svc'], contains('共享能力源'));
      // 借用面不入 _faces：close/abort 不触碰共享 client
      await assembly.close();
      expect(sharedTransport.closeCount, 0,
          reason: 'close 只摘监听不关共享 client——client 归共享能力源所有');
    });

    test('未命中的端点照旧自建（兜底路径不受借用缝影响）', () async {
      final (shared, sharedTransport) = await makeSharedFace('svc');
      final transports = <McpTransport>[];
      final assembly = await _assemble(
        endpoints: [ep('svc'), ep('other')],
        clients: {},
        transports: transports,
        sharedFaces: {'svc': shared},
      );
      addTearDown(assembly.close);

      expect(transports, hasLength(1), reason: '未命中端点走旧自建路径');
      expect(assembly.serverSummaries['other'], contains('Tier'));
      await assembly.close();
      expect(sharedTransport.closeCount, 0);
      expect(
        (transports.single as _CountingTransport).closeCount,
        1,
        reason: '自建端点照常释放',
      );
    });
  });

  // F3（review-fix-2026-10）语义变更：单端点装配失败从「抛错炸整轮 + 外层兜底
  // 回收」改为「失败端点即关 + 通告降级继续」（对齐 mountEndpoint/保留字分支
  // 的宁缺勿炸）——旧用例的 throwsA 断言随语义废弃，防泄漏断言保留并加强：
  // 失败端点当场关、好端点装配态不关（随 assembly.close 释放）。
  test('装配异常路径：单端点失败 → 降级继续，失败端点即关、好端点随 Run 焚释放',
      () async {
    final transports = <McpTransport>[];
    final tmp = await _tmpDir();
    final assembly = await const McpRuntime().assemble(
      context: SessionContext(),
      endpoints: [ep('ok'), ep('boom')],
      locals: const [],
      apiKeyReader: (id) async => 'key-$id',
      memoryStore: MemoryStore.underSupportDir(tmp.path),
      skills: SkillRegistry(),
      engine: _FakeEngine(),
      tempDirResolver: _tmpDir,
      documentsDirResolver: _tmpDir,
      clientFactory: (endpoint, apiKey) {
        final fail = (apiKey ?? '').contains('boom');
        final transport = _CountingTransport(failSend: fail);
        transports.add(transport);
        return McpClient(transport);
      },
    );
    addTearDown(assembly.close);

    final ok = transports.whereType<_CountingTransport>().where((t) => !t.failSend).single;
    final boom =
        transports.whereType<_CountingTransport>().where((t) => t.failSend).single;
    expect(boom.closeCount, 1, reason: 'F3：失败端点装配失败当场 close（撤修复即红）');
    expect(ok.closeCount, 0, reason: '好端点装配态不预关（随 assembly.close 统一释放）');
    expect(assembly.router.serverIds, {'ok'}, reason: '坏端点不进路由，装配不抛错');
    await assembly.close();
    expect(ok.closeCount, 1, reason: 'Run 焚统一释放好端点');
  });

  group('ConversationSession 写回契约（真机验收③降级单测：transcript 不翻倍）', () {
    test('连续两轮 Run 收尾写回：replaceTranscript 全量替换非累积', () {
      final session = ConversationSession();
      final round1 = <CloudChatMessage>[
        UserMessage('q1'),
        AssistantMessage(content: 'a1'),
      ];
      session.replaceTranscript(round1);
      expect(session.transcript.length, 2);

      // 第二轮 Run：事件循环口径 = loop 返回含上轮历史的全量 transcript。
      // 写回必须 clear+addAll；若为 append 则跨轮翻倍（length 4+4=8）。
      final round2 = <CloudChatMessage>[
        ...round1,
        ToolResultMessage(toolCallId: 't1', content: 'r1'),
        UserMessage('q2'),
        AssistantMessage(content: 'a2'),
      ];
      session.replaceTranscript(round2);
      expect(session.transcript.length, round2.length,
          reason: '两轮写回后长度必须等于第二轮全量（不翻倍）');
    });

    test('写回后 transcript 为不可变视图：外部改动不渗入内核态', () {
      final session = ConversationSession();
      session.replaceTranscript([UserMessage('q')]);
      final view = session.transcript;
      expect(() => view.add(AssistantMessage(content: 'x')), throwsA(isA<Object>()));
      expect(session.transcript.length, 1);
    });

    test('第三轮空写回：清空语义成立（replace 非 merge）', () {
      final session = ConversationSession();
      session.replaceTranscript([UserMessage('q'), AssistantMessage(content: 'a')]);
      session.replaceTranscript(const []);
      expect(session.transcript, isEmpty);
    });
  });

  group('ConversationSession 配额归 Session（行为变更①单测：切会话即重置配额）', () {
    test('旧实例配额烧尽后，新实例满额独立（SamplingQuota 实例独立入参）', () {
      final a = ConversationSession();
      final now = DateTime.now();
      for (var i = 0; i < a.samplingQuota.maxPerWindow; i++) {
        expect(a.samplingQuota.tryConsume('srv', now), isNull, reason: '窗口内应放行');
      }
      expect(a.samplingQuota.tryConsume('srv', now), isNotNull, reason: '第 21 次应拒绝');

      final b = ConversationSession();
      expect(
        b.samplingQuota.tryConsume('srv', now),
        isNull,
        reason: '切会话 = 新 ConversationSession = 新 SamplingQuota = 配额重置',
      );
    });
  });
}

