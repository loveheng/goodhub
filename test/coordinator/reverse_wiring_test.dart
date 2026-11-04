// W5 跨 App 转发端侧算力（Binder 路径）回归钉：reverse_wiring 扩派私有反向
// method `host/onDeviceComplete`。
//
// 红线：① 与 sampling 反向请求并存不互替（云端引擎路径零扰动）；② 降级语义
// 显式可知（isError 结果转 McpRpcException error 帧，message 原文透传）；
// ③ 与 `host__on_device_complete` 工具面同源执行器（K22 配额单源）；
// ④ 双装配点（McpRuntime / Gateway）同款接线（Binder/HTTP 插件路径双路可达）。
import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/caller_death_interrupt.dart';
import 'package:goodhub/coordinator/host_on_device_tool.dart';
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
  Future<McpToolFace> face(String serverId) async {
    final f = McpToolFace(
        client: McpClient(_FakeTransport(<Map<String, Object?>>[])),
        serverId: serverId);
    await f.listTools();
    return f;
  }

  test('host/onDeviceComplete 反向分派：转发端侧产出（同源执行器）', () async {
    final f = await face('goodshare');
    wireSampling(
      faces: {'goodshare': f},
      engine: _NoopCloudEngine(),
      quota: SamplingQuota(),
      onDeviceCapability: _StubCapability(output: '端侧结果'),
      supplyQuota: SupplyQuota(),
    );
    final r = await f.client.onServerRequest!(
      HostOnDeviceToolExecutor.reverseMethodName,
      {'instruction': '提取', 'input': '原文'},
    );
    final content = r!['content'] as Map;
    expect(content['text'], '端侧结果');
    expect(r['role'], 'assistant');
    expect(r['model'], 'goodhub-on-device');
  });

  test('sampling 反向请求不受扰：并存不互替（method 分流先行）', () async {
    final f = await face('goodshare');
    var samplingCalled = false;
    wireSampling(
      faces: {'goodshare': f},
      engine: _NoopCloudEngine(),
      quota: SamplingQuota(),
      onDeviceCapability: _StubCapability(),
      supplyQuota: SupplyQuota(),
    );
    // sampling/createMessage 走云端 handler（引擎 noop 炸 = 证明被分派到它）。
    try {
      await f.client.onServerRequest!('sampling/createMessage', {
        'messages': [
          {'role': 'user', 'content': {'type': 'text', 'text': 'x'}},
        ],
      });
    } on Object {
      samplingCalled = true; // 引擎 noop 抛错 = 分派到达云端 handler
    }
    expect(samplingCalled, isTrue, reason: 'sampling 分派不受 W5 扩派影响');
  });

  test('降级语义显式可知：执行器 isError → McpRpcException(-32000) 原文透传',
      () async {
    final f = await face('goodshare');
    wireSampling(
      faces: {'goodshare': f},
      engine: _NoopCloudEngine(),
      quota: SamplingQuota(),
      onDeviceCapability: _StubCapability()
        ..error = const OnDevicePrimitiveException('端侧会话未就绪'),
      supplyQuota: SupplyQuota(),
    );
    Object? caught;
    try {
      await f.client.onServerRequest!(
        HostOnDeviceToolExecutor.reverseMethodName,
        {'instruction': 'i', 'input': 'x'},
      );
    } on McpRpcException catch (e) {
      caught = e;
    }
    expect(caught, isA<McpRpcException>(), reason: 'isError → error 帧（显式可知）');
    expect((caught as McpRpcException).code, -32000);
    expect(caught.message, contains('不兜底云端'));
  });

  test('参数语义同源：params 结构化 {instruction, input} 经同一 execute 校验',
      () async {
    final f = await face('goodshare');
    wireSampling(
      faces: {'goodshare': f},
      engine: _NoopCloudEngine(),
      quota: SamplingQuota(),
      onDeviceCapability: _StubCapability(),
      supplyQuota: SupplyQuota(),
    );
    Object? caught;
    try {
      await f.client.onServerRequest!(
          HostOnDeviceToolExecutor.reverseMethodName, {'input': 'x'});
    } on McpRpcException catch (e) {
      caught = e;
    }
    expect((caught as McpRpcException).message, contains('instruction'),
        reason: '缺 instruction → 执行器参数校验（与工具面同源）');
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

      final pending = binderFace.client.onServerRequest!(
        HostOnDeviceToolExecutor.reverseMethodName,
        {'instruction': 'i', 'input': 'x'},
      );
      final settled = expectLater(pending, throwsA(isA<McpRpcException>()));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // 死亡通知按 serverId（错键）→ 匹配不上 → 不打断（证明键必须同源：
      // 混用即漏打断 = 孤儿算力空跑）。
      BinderTransport.onCallerDeath!('goodshare');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(cap.cancelled, isFalse, reason: 'serverId ≠ 包名 → 匹配不上（漏打断）');

      // 死亡通知按包名（正确键）→ 打断生效 + 本次调用作废（-32000 显式可知）。
      BinderTransport.onCallerDeath!('com.zzh.goodshare');
      await settled;
      expect(cap.cancelled, isTrue,
          reason: '订阅取消 → 透传 cancel(requestId) → 引擎让槽（协作式打断）');
    });
  });
}
