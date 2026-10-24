/// 联调 Run 编排件单测（window-slim P1-B）：编排自 `ui/gateway_loop_debug_page`
/// 下沉后必须有内核侧回归网——此前该 300 行装配**零用例**（真机联调是唯一验证
/// 路径），本次搬进 coordinator 后即可纯 Dart 验证。
///
/// 覆盖：
/// 1. 事件流契约：能力协商文本 → 引擎注记 → 调用卡生命周期（Started/Finished）
///    → 收尾（脚本引擎确定性走环，不经云端）；
/// 2. 故障注入开关：每工具前 2 次强制 isError → Finished(isError=true)；
/// 3. 目录解析器注入生效 + **释放卫生**：Run 结束 RefStore 临时目录清空
///    （§9 Session 结束即焚，编排件 finally 负责）；
/// 4. 异常路径：挂载失败 → 末事件为 danger 注记 + 状态带转 danger（窗口侧
///    据此展示失败药丸）。
library;

import 'dart:convert' as json;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/debug_run_orchestrator.dart';
import 'package:goodhub/coordinator/fenced_cloud_engine.dart';
import 'package:goodhub/coordinator/permission_gateway.dart';
import 'package:goodhub/coordinator/tool_breaker.dart';
import 'package:goodhub/mcp/mcp_client.dart';
import 'package:goodhub/mcp/sampling.dart';
import 'package:goodhub/mcp/transport/mcp_transport.dart';

/// 最小假传输（协议面）：initialize / tools/list / tools/call 三问三答。
class _FakeTransport implements McpTransport {
  _FakeTransport({this.failNegotiate = false});

  final bool failNegotiate;

  /// F4 用：close 计数（Run 焚释放断言的观测点——句柄封死只能从传输层观测）。
  int closeCount = 0;

  @override
  Future<TransportResponse> send(String requestBody) async {
    final req = json.jsonDecode(requestBody) as Map<dynamic, dynamic>;
    final method = req['method'] as String?;
    if (failNegotiate && method == 'initialize') {
      throw Exception('联调注入：握手指失败');
    }
    final Object result = switch (method) {
      'initialize' => <String, Object?>{
          'protocolVersion': '2025-06-18',
          'capabilities': <String, Object?>{'tools': <String, Object?>{}},
          'serverInfo': <String, Object?>{'name': 'fake', 'version': '1.0'},
        },
      'tools/list' => <String, Object?>{
          'tools': <Object?>[
            <String, Object?>{'name': 'list_items', 'description': '列出条目'},
          ],
        },
      'tools/call' => <String, Object?>{
          'content': <Object?>[
            <String, Object?>{'type': 'text', 'text': 'ok'},
          ],
          'isError': false,
        },
      _ => <String, Object?>{},
    };
    return TransportResponse(
      statusCode: 200,
      contentType: 'application/json',
      body: json.jsonEncode(<String, Object?>{
        'jsonrpc': '2.0',
        'id': req['id'] ?? 1,
        'result': result,
      }),
    );
  }

  @override
  Future<StreamedTransportResponse> sendStream(String requestBody) async {
    final req = json.jsonDecode(requestBody) as Map<dynamic, dynamic>;
    final method = req['method'] as String?;
    final Object result = switch (method) {
      'initialize' => <String, Object?>{
          'protocolVersion': '2025-06-18',
          'capabilities': <String, Object?>{'tools': <String, Object?>{}},
          'serverInfo': <String, Object?>{'name': 'fake', 'version': '1.0'},
        },
      'tools/list' => <String, Object?>{
          'tools': <Object?>[
            <String, Object?>{'name': 'list_items', 'description': '列出条目'},
          ],
        },
      'tools/call' => <String, Object?>{
          'content': <Object?>[
            <String, Object?>{'type': 'text', 'text': 'ok'},
          ],
          'isError': false,
        },
      _ => <String, Object?>{},
    };
    // contentType = application/json → McpClient.callWithProgress 走「单 JSON
    // 回退」分支（不要求 SSE data: 帧），假传输只回一帧即可。
    return StreamedTransportResponse(
      statusCode: 200,
      contentType: 'application/json',
      lines: Stream<String>.value(
        json.jsonEncode(<String, Object?>{
          'jsonrpc': '2.0',
          'id': req['id'] ?? 1,
          'result': result,
        }),
      ),
    );
  }

  @override
  Future<StreamedTransportResponse> getStream() async =>
      StreamedTransportResponse(
        statusCode: 200,
        contentType: 'text/event-stream',
        lines: const Stream<String>.empty(),
      );

  @override
  void close() => closeCount++;
}

/// 全放行端口（联调流不测裁决策略，只测编排接线）。
class _AllowGate implements GateDelegate {
  @override
  Future<GateDecision> confirm(ToolPendingConfirmation pending) async =>
      const GateDecision(approved: true);
}

class _AllowBlock implements BlockDelegate {
  @override
  Future<BreakerResolution> onBreakerTripped(BreakerReport report) async =>
      const SkipOnce();

  @override
  Future<bool> onStepWallReached(StepWallReport report) async => false;
}

class _AllowFence implements PiiFenceDelegate {
  @override
  Future<bool> onMaskBlocked(PiiMaskBlockInfo info) async => false;
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('debug_run_orch');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<Directory> tempDirFor(String name) async {
    final d = Directory('${tmp.path}/$name');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  DebugRunConfig buildConfig({
    required McpClient client,
    required List<String> pills,
    bool injectFaults = false,
  }) => DebugRunConfig(
    serverId: 'goodshare',
    systemPrompt: 'sys',
    userPrompt: 'do it',
    clientFactory: () => client,
    gate: _AllowGate(),
    block: _AllowBlock(),
    fence: _AllowFence(),
    crossSource: (handle, from, to, preview) async => true,
    majorJump: (name, from, to) async => false,
    onPill: (label, tone) => pills.add(label),
    injectFaults: injectFaults,
    useScriptedEngine: true, // 确定性走环，不经云端/模型
    quota: SamplingQuota(),
    supportDirResolver: () => tempDirFor('support'),
    tempDirResolver: () => tempDirFor('temp'),
    documentsDirResolver: () => tempDirFor('docs'),
  );

  test('脚本引擎走环：能力协商 → 引擎注记 → 调用卡生命周期 → 收尾', () async {
    final pills = <String>[];
    final orch = DebugRunOrchestrator();
    final events = await orch
        .run(
          buildConfig(
            client: McpClient(_FakeTransport()),
            pills: pills,
          ),
        )
        .toList();

    expect(events.first, isA<DebugRunText>());
    expect(
      (events.first as DebugRunText).text,
      contains('能力协商'),
      reason: '挂载原语握手结果先进轨道',
    );
    expect(
      events.whereType<DebugRunNote>().map((e) => e.text),
      contains(startsWith('引擎:')),
    );
    final started =
        events.whereType<DebugRunCallStarted>().map((e) => e.tool).toList();
    final finished =
        events.whereType<DebugRunCallFinished>().map((e) => e.tool).toList();
    expect(started, ['list_items', 'list_items'], reason: '脚本引擎前两轮各发一次调用');
    expect(finished, ['list_items', 'list_items']);
    expect(
      events.whereType<DebugRunCallFinished>().every((e) => !e.isError),
      isTrue,
      reason: '脚本引擎两轮调用都走真实执行（故障注入未开启），不应 isError',
    );
    expect(events.last, isA<DebugRunFinished>());
    expect(pills, contains('thinking'));
    expect(pills.last, 'done');
  });

  test('故障注入：每个工具前 2 次强制 isError（联调熔断卡前置）', () async {
    final pills = <String>[];
    final orch = DebugRunOrchestrator();
    final events = await orch
        .run(
          buildConfig(
            client: McpClient(_FakeTransport()),
            pills: pills,
            injectFaults: true,
          ),
        )
        .toList();

    expect(
      events.whereType<DebugRunNote>().map((e) => e.text),
      contains(startsWith('⚠ 故障注入开启')),
      reason: '开启即以危险注记告知用户（非静默）',
    );
    final calls = events.whereType<DebugRunCallFinished>().toList();
    expect(calls, isNotEmpty);
    expect(calls.every((e) => e.isError), isTrue, reason: '脚本引擎两轮都在注入额度内');
  });

  test('释放卫生：RefStore 临时目录 Run 结束即清空（§9 会话结束直清）', () async {
    final orch = DebugRunOrchestrator();
    await orch
        .run(
          buildConfig(client: McpClient(_FakeTransport()), pills: <String>[]),
        )
        .toList();

    final temp = Directory('${tmp.path}/temp');
    await temp.create(recursive: true);
    expect(
      await temp.list().isEmpty,
      isTrue,
      reason: 'run 的 finally 已 expireAll，临时句柄不残留',
    );
  });

  // F4（review-fix-2026-10）：Run 焚释放挂载的 client——此前 mount 未传
  // release（close 退化为 noop）且 finally 只焚 refStore，每次联调 Run 泄一个
  // client。成功路径经 release 统一关；握手指失败路径（mounted 为 null）由
  // finally 兜底关。撤修复即红（closeCount 恒 0）。
  test('F4 释放卫生：Run 焚关闭挂载 client（成功与握手指失败两路）', () async {
    final orch = DebugRunOrchestrator();
    final okTransport = _FakeTransport();
    await orch
        .run(buildConfig(client: McpClient(okTransport), pills: <String>[]))
        .toList();
    expect(okTransport.closeCount, 1,
        reason: 'F4：正常 Run 结束须关 client（经 mount release）');

    final failTransport = _FakeTransport(failNegotiate: true);
    await orch
        .run(buildConfig(client: McpClient(failTransport), pills: <String>[]))
        .toList();
    expect(failTransport.closeCount, 1,
        reason: 'F4：握手指失败路径 mounted 为 null，finally 兜底关 client');
  });

  test('异常路径：握手指失败 → 危险注记 + 状态带转 danger', () async {
    final pills = <String>[];
    final tones = <DebugPillTone>[];
    final orch = DebugRunOrchestrator();
    final events = await orch
        .run(
          DebugRunConfig(
            serverId: 'goodshare',
            systemPrompt: 'sys',
            userPrompt: 'do it',
            clientFactory: () => McpClient(_FakeTransport(failNegotiate: true)),
            gate: _AllowGate(),
            block: _AllowBlock(),
            fence: _AllowFence(),
            crossSource: (handle, from, to, preview) async => true,
            majorJump: (name, from, to) async => false,
            onPill: (label, tone) {
              pills.add(label);
              tones.add(tone);
            },
            useScriptedEngine: true,
            supportDirResolver: () => tempDirFor('support'),
            tempDirResolver: () => tempDirFor('temp'),
            documentsDirResolver: () => tempDirFor('docs'),
          ),
        )
        .toList();

    expect(events, hasLength(1));
    final note = events.single as DebugRunNote;
    expect(note.danger, isTrue);
    expect(note.text, contains('✕'));
    expect(pills.last, 'failed');
    expect(tones.last, DebugPillTone.danger);
    // 柄已归还（窗口 Abort 不再指向悬空 loop/face）。
    expect(orch.loop, isNull);
    expect(orch.face, isNull);
  });
}
