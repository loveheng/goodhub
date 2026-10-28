/// S2 装配 Profile 化（施工稿 `docs/design/arch-consolidation.md` §S2）：
/// ① 三 profile 的**能力上限**由声明表钉死；
/// ② 装配真的按 profile 接线（不是只多了个参数）——反向能力、elicitation、
///    编排围栏随 profile 关闸；
/// ③ chat 行为零变更（S0 golden 之外的回归面）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/mcp_runtime.dart';
import 'package:goodhub/coordinator/run_profile.dart';
import 'package:goodhub/coordinator/skill_registry.dart';
import 'package:goodhub/coordinator/task_plan.dart';
import 'package:goodhub/llm/cloud/cloud_llm.dart';
import 'package:goodhub/mcp/elicitation.dart';
import 'package:goodhub/mcp/mcp_client.dart';
import 'package:goodhub/mcp/server_endpoints.dart';
import 'package:goodhub/mcp/transport/mcp_transport.dart';
import 'package:goodhub/sandbox/memory_store.dart';

/// 最小假传输：只答 initialize / tools/list（与 mcp_runtime_test 同口径）。
class _CountingTransport implements McpTransport {
  _CountingTransport();

  int closeCount = 0;

  @override
  Future<TransportResponse> send(String requestBody) async {
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
      throw UnsupportedError('no GET SSE');

  @override
  void close() => closeCount++;
}

class _FakeEngine implements CloudLlmEngine {
  @override
  String get name => 'fake';

  @override
  Stream<CloudStreamEvent> send(CloudChatRequest request,
          {void Function()? onActivity}) =>
      const Stream<CloudStreamEvent>.empty();
}

/// 恒拒绝的 elicitation 委托（只用于验证「是否接线」，不参与决策语义）。
class _DeclineElicitation implements ElicitationDelegate {
  @override
  Future<ElicitationAnswer> request(ElicitationRequest req) async =>
      ElicitationAnswer.decline();
}

Future<Directory> _tmp() async {
  final d = await Directory.systemTemp.createTemp('run_profile_test');
  addTearDown(() => d.delete(recursive: true));
  return d;
}

Future<McpAssembly> _assemble({
  RunProfile profile = RunProfile.chat,
  required List<McpClient> clients,
  required List<McpTransport> transports,
  PlanRunState? planState,
  bool withElicitationDelegate = true,
}) async {
  final tmp = await _tmp();
  return const McpRuntime().assemble(
    context: SessionContext(),
    endpoints: const [
      ServerEndpoint(id: 'good', name: 'g', endpoint: 'http://x/good/mcp'),
    ],
    locals: const [],
    apiKeyReader: (id) async => 'key-$id',
    memoryStore: MemoryStore.underSupportDir(tmp.path),
    skills: SkillRegistry()..registerAll(builtinSkills()),
    engine: _FakeEngine(),
    tempDirResolver: _tmp,
    documentsDirResolver: _tmp,
    clientFactory: (endpoint, apiKey) {
      final t = _CountingTransport();
      transports.add(t);
      final c = McpClient(t);
      clients.add(c);
      return c;
    },
    delegates: RuntimeDelegates(
      elicitationDelegate: withElicitationDelegate ? _DeclineElicitation() : null,
    ),
    planState: planState,
    profile: profile,
  );
}

void main() {
  group('S2 · 能力上限声明表', () {
    test('三 profile 的能力集逐项钉死', () {
      final chat = capabilitiesFor(RunProfile.chat);
      final gw = capabilitiesFor(RunProfile.gateway);
      final hl = capabilitiesFor(RunProfile.headless);

      expect((chat.sampling, chat.elicitation, chat.cowSync, chat.planFence),
          (true, true, true, true));
      expect((gw.sampling, gw.elicitation, gw.cowSync, gw.planFence),
          (true, false, false, false),
          reason: '网关常驻：可反向推理，但无 UI 委托故不接 elicitation，不做模板同步');
      expect((hl.sampling, hl.elicitation, hl.cowSync, hl.planFence),
          (false, false, false, false),
          reason: '无人值守单任务：不外借宿主推理');
    });
  });

  group('S2 · 装配真的按 profile 接线', () {
    test('chat：采样与 elicitation 均接线，编排元工具在场', () async {
      final clients = <McpClient>[];
      final transports = <McpTransport>[];
      final assembly = await _assemble(
        clients: clients,
        transports: transports,
        planState: PlanRunState(),
      );

      expect(clients.single.onServerRequest, isNotNull, reason: 'chat 接采样');
      expect(clients.single.elicitationEnabled, isTrue, reason: 'chat 有 UI 委托');
      expect(
        assembly.loop.toolsProvider!().map((t) => t.name),
        contains('propose_task_plan'),
      );
      await assembly.close();
    });

    test('gateway：采样保留，elicitation 恒不接、编排围栏不下传（即使传了 planState）',
        () async {
      final clients = <McpClient>[];
      final transports = <McpTransport>[];
      final assembly = await _assemble(
        profile: RunProfile.gateway,
        clients: clients,
        transports: transports,
        planState: PlanRunState(),
      );

      expect(clients.single.onServerRequest, isNotNull, reason: '网关仍供反向推理');
      expect(clients.single.elicitationEnabled, isFalse,
          reason: '网关无 UI：接线即悬挂，恒不接');
      expect(
        assembly.loop.toolsProvider!().map((t) => t.name),
        isNot(contains('propose_task_plan')),
        reason: 'planFence 关闸——编排元工具不进能力面',
      );
      await assembly.close();
    });

    test('headless：采样不接线，不产生对外反向能力', () async {
      final clients = <McpClient>[];
      final transports = <McpTransport>[];
      final assembly = await _assemble(
        profile: RunProfile.headless,
        clients: clients,
        transports: transports,
      );

      expect(clients.single.onServerRequest, isNull);
      expect(clients.single.elicitationEnabled, isFalse);
      await assembly.close();
    });

    test('释放不随 profile 退化：close 仍全覆盖且幂等', () async {
      final clients = <McpClient>[];
      final transports = <McpTransport>[];
      final assembly = await _assemble(
        profile: RunProfile.gateway,
        clients: clients,
        transports: transports,
      );
      await assembly.close();
      await assembly.close();
      expect(
        transports.cast<_CountingTransport>().map((t) => t.closeCount).toList(),
        everyElement(1),
      );
    });
  });
}
