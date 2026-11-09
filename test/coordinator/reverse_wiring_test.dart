// 反向请求接线回归钉（收编后形态，2026-11-09）：推理入口 = 标准原语
// `ai/complete`（统一受理链）；私有 method `host/onDeviceComplete` **已退役**
// （响应删除，本文件钉退役 + 防复活）。
//
// 红线：① sampling 反向请求并存不互替（D2 保留兼容，云端引擎路径零扰动）；
// ② K17 死亡联动经 ai/complete 受理链保持（身份键 = 包名同源）；
// ③ 双装配点（McpRuntime / Gateway）同款接线（Binder/HTTP 插件路径双路可达）。
import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/ai_complete_service.dart';
import 'package:goodhub/coordinator/caller_death_interrupt.dart';
import 'package:goodhub/coordinator/reverse_wiring.dart';
import 'package:goodhub/coordinator/supply_quota.dart';
import 'package:goodhub/core/errors/mcp_error.dart';
import 'package:goodhub/llm/cloud/cloud_llm.dart';
import 'package:goodhub/llm/on_device_capability.dart';
import 'package:goodhub/llm/on_device_engine.dart';
import 'package:goodhub/mcp/mcp_client.dart';
import 'package:goodhub/mcp/transport/binder_transport.dart';
import 'package:goodhub/mcp/transport/mcp_transport.dart';
import 'package:goodhub/mcp/sampling.dart';
import 'package:goodhub/coordinator/mcp_tool_face.dart';

class _FakeTransport implements McpTransport {
  _FakeTransport(this.tools);

  final List<Map<String, Object?>> tools;

  @override
  Future<TransportResponse> send(String requestBody) async {
    final req = jsonDecode(requestBody) as Map<String, Object?>;
    return TransportResponse(
      statusCode: 200,
      contentType: 'application/json',
      body: jsonEncode({
        'jsonrpc': '2.0',
        'id': req['id'],
        'result': {
          'tools': tools,
        },
      }),
    );
  }

  @override
  Future<StreamedTransportResponse> sendStream(String requestBody) async {
    final req = jsonDecode(requestBody) as Map<String, Object?>;
    return StreamedTransportResponse(
      statusCode: 200,
      contentType: 'application/json',
      lines: Stream<String>.fromIterable([
        jsonEncode({
          'jsonrpc': '2.0',
          'id': req['id'],
          'result': {'tools': tools},
        })
      ]),
    );
  }

  @override
  Future<StreamedTransportResponse> getStream() =>
      throw UnsupportedError('假传输无 GET SSE');

  @override
  Future<void> close() async {}
}

class _StubCapability implements OnDeviceCapabilityService {
  _StubCapability({this.output = '端侧产出'});

  String output;
  Object? error;

  @override
  Future<String> complete({
    required String instruction,
    required String input,
    OnDevicePrimitiveConfig config = const OnDevicePrimitiveConfig(),
    PrimitiveFallbackPolicy fallback = PrimitiveFallbackPolicy.failFast,
    String? traceId,
  }) async {
    final e = error;
    if (e != null) throw e as Exception;
    return output;
  }

  @override
  Future<OnDeviceCapabilityAvailability> availability() async =>
      OnDeviceCapabilityAvailability.ready;

  @override
  Future<void> loadExplicit() async {}

  @override
  Stream<EngineChunk> completeStream({
    required String instruction,
    required String input,
    OnDevicePrimitiveConfig config = const OnDevicePrimitiveConfig(),
    String? traceId,
  }) => const Stream.empty();
}

/// 云端引擎假件（sampling 分派不触达——method 分流先行）。
class _NoopCloudEngine implements CloudLlmEngine {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError('不应触达');
}

/// 挂起不产出的端侧原语桩（打断路径的被测面：模拟长生成在途）。
/// 实现 [OnDeviceInterruptible]——打断经取消钩子下沉（退订 → onCancel）。
class _HangingCapability
    implements OnDeviceCapabilityService, OnDeviceInterruptible {
  final StreamController<EngineChunk> _ctrl = StreamController<EngineChunk>();

  /// 订阅是否被取消（= 引擎 cancel 透传的下沉信号）。
  bool cancelled = false;

  @override
  Future<String> complete({
    required String instruction,
    required String input,
    OnDevicePrimitiveConfig config = const OnDevicePrimitiveConfig(),
    PrimitiveFallbackPolicy fallback = PrimitiveFallbackPolicy.failFast,
    String? traceId,
  }) async =>
      'unused';

  @override
  Future<OnDeviceCapabilityAvailability> availability() async =>
      OnDeviceCapabilityAvailability.ready;

  @override
  Future<void> loadExplicit() async {}

  @override
  Stream<EngineChunk> completeStream({
    required String instruction,
    required String input,
    OnDevicePrimitiveConfig config = const OnDevicePrimitiveConfig(),
    String? traceId,
  }) {
    _ctrl.onCancel = () {
      cancelled = true;
    };
    return _ctrl.stream;
  }

  @override
  Future<String> completeInterruptible({
    required String instruction,
    required String input,
    OnDevicePrimitiveConfig config = const OnDevicePrimitiveConfig(),
    PrimitiveFallbackPolicy fallback = PrimitiveFallbackPolicy.failFast,
    String? traceId,
    void Function(Future<void> Function() cancel)? onSubscribed,
  }) async {
    final done = Completer<String>();
    late StreamSubscription<EngineChunk> sub;
    sub = _ctrl.stream.listen(
      (_) {},
      onError: (Object e) {
        if (!done.isCompleted) done.completeError(e);
      },
      onDone: () {
        if (!done.isCompleted) done.complete('');
      },
    );
    _ctrl.onCancel = () {
      cancelled = true;
    };
    onSubscribed?.call(() async {
      await sub.cancel(); // 退订 → onCancel → 引擎让槽信号
      if (!done.isCompleted) {
        done.completeError(const OnDeviceInterruptedException());
      }
    });
    return done.future;
  }
}

void main() {
  // M-B：AiCompleteService 为进程级单例（wireSampling ensureConfigured 注入腿
  // 只填空腿）——逐例重置防上一例的桩腿泄漏进下一例的受理链。
  setUp(AiCompleteService.resetForTest);

  Future<McpToolFace> face(String serverId) async {
    final f = McpToolFace(
        client: McpClient(_FakeTransport(<Map<String, Object?>>[])),
        serverId: serverId);
    await f.listTools();
    return f;
  }

  test('host/onDeviceComplete 退役钉：旧 method 落 -32601（防复活）', () async {
    final f = await face('goodshare');
    wireSampling(
      faces: {'goodshare': f},
      engine: _NoopCloudEngine(),
      quota: SamplingQuota(),
      onDeviceCapability: _StubCapability(output: '端侧结果'),
      supplyQuota: SupplyQuota(),
    );
    Object? caught;
    try {
      await f.client.onServerRequest!(
        'host/onDeviceComplete', // 退役 method（goodshare 已迁 ai/complete）
        {'instruction': '提取', 'input': '原文'},
      );
    } on McpRpcException catch (e) {
      caught = e;
    }
    expect((caught as McpRpcException).code, -32601,
        reason: '退役响应删除 → 未知反向请求（防复活钉）');
  });

  test('ai/complete 反向受理（收编后形态）：受理链产出经单帧钩子回落路径不可达',
      () async {
    // ai/complete 的受理走 **会话钩子**（多帧 _async/phase 承载）——单帧
    // onServerRequest 路径（非会话传输）不受理 ai/*，落 -32601：
    // 消费端必须具备会话能力（:goodhub-ai-runtime / 迁移插件经 Binder）。
    final f = await face('goodshare');
    wireSampling(
      faces: {'goodshare': f},
      engine: _NoopCloudEngine(),
      quota: SamplingQuota(),
      onDeviceCapability: _StubCapability(output: '端侧结果'),
      supplyQuota: SupplyQuota(),
    );
    Object? caught;
    try {
      await f.client.onServerRequest!('ai/complete',
          {'instruction': '提取', 'input': '原文'});
    } on McpRpcException catch (e) {
      caught = e;
    }
    expect((caught as McpRpcException).code, -32601,
        reason: '单帧钩子不承载 ai/*（会话钩子专属——消费端能力探针语义）');
  });

  test('sampling 反向请求不受扰：并存不互替（method 分流先行）', () async {
    final f = await face('goodshare');
    var samplingCalled = false;
    wireSampling(
      faces: {'goodshare': f},
      engine: _NoopCloudEngine(),
      quota: SamplingQuota(),
      // D2 收敛（M-B）：sampling 壳推理走统一受理链（随设备主路由——本例
      // 端腿桩失败 = 分派确实到达 sampling 处理器并执行了推理链）。
      onDeviceCapability: _StubCapability()
        ..error = const OnDevicePrimitiveException('端侧会话未就绪'),
      supplyQuota: SupplyQuota(),
    );
    try {
      await f.client.onServerRequest!('sampling/createMessage', {
        'messages': [
          {'role': 'user', 'content': {'type': 'text', 'text': 'x'}},
        ],
      });
    } on Object {
      samplingCalled = true; // 端腿桩失败经受理链 → McpRpcException = 分派到达
    }
    expect(samplingCalled, isTrue,
        reason: 'sampling 分派不受 ai/complete 收编影响（D2 保留兼容，经统一受理链，端腿失败显式可知）');
  });

  group('W5 调用方进程死亡联动打断（K17）', () {
    test('调用方身份键同源：Binder 面按包名打断（serverId 与包名不同值）',
        () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      const channelName = 'goodhub/binder_mcp';
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel(channelName), (call) async {
        switch (call.method) {
          case 'bind':
          case 'resetAllTransports':
          case 'answerReverse':
            return null;
          default:
            throw MissingPluginException(call.method);
        }
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(const MethodChannel(channelName), null);
        resetCallerDeathInterruptForTest();
      });

      // Binder 面：serverId（'goodshare'）与包名（'com.zzh.goodshare'）不同值。
      final client = McpClient.binder(
        transportId: 'local:com.zzh.goodshare_goodshare',
        packageName: 'com.zzh.goodshare',
        serviceClassName: 'com.zzh.goodshare.McpBinderService',
      );
      addTearDown(client.close);
      final binderFace = McpToolFace(client: client, serverId: 'goodshare');

      final cap = _HangingCapability();
      wireSampling(
        faces: {'goodshare': binderFace},
        engine: _NoopCloudEngine(),
        quota: SamplingQuota(),
        onDeviceCapability: cap,
        supplyQuota: SupplyQuota(),
      );

      // S07/S07b：Binder 面走携带平台侧已解析身份的会话钩子（ai/complete
      // 收编后受理路径；身份经内核 UID 解析随帧到达）。
      final frames = <Map<String, Object?>>[];
      final pending =
          (binderFace.client.transport as BinderTransport)
              .onServerRequestSessionWithCaller!(
        AiWire.methodComplete,
        'srv_k17',
        {'instruction': 'i', 'input': 'x'},
        const ResolvedCallerIdentity(
          packageName: 'com.zzh.goodshare',
          signatureSha256: 'sha256:caller',
        ),
        frames.add,
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // 死亡通知按 serverId（错键）→ 匹配不上 → 不打断（证明键必须同源：
      // 混用即漏打断 = 孤儿算力空跑）。
      BinderTransport.onCallerDeath!('goodshare');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(cap.cancelled, isFalse, reason: 'serverId ≠ 包名 → 匹配不上（漏打断）');

      // 死亡通知按包名（正确键）→ 打断生效 + 本次调用作废。ai/complete
      // 死亡语义 = **零终帧**（调用方已死，不回程——区别于作废 error 帧）。
      BinderTransport.onCallerDeath!('com.zzh.goodshare');
      await pending;
      expect(cap.cancelled, isTrue,
          reason: '订阅取消 → 透传 cancel(requestId) → 引擎让槽（协作式打断）');
      expect(frames.where((f) => f['error'] != null), isEmpty,
          reason: '死亡作废零终帧（ai/complete 收编语义：不回程）');
    });
  });
}
