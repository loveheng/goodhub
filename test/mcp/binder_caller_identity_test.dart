// S07/S07b 调用方身份平台侧解析链路（Dart 消费面回归钉）：
// 机制：Kotlin 侧在 onEvent（Binder 事务线程）经 Binder.getCallingUid() →
// CallerIdentityResolver 解析包名 + 签名指纹，随事件信封 `caller` 字段下发；
// Dart 侧 [BinderTransport._resolvedCallerOf] 解析、[BinderTransport._handleReverseRequest]
// 分派。
//
// 红线钉：① 帧未携带 caller（平台侧解析失败）→ onServerRequestWithCaller
// **不被调用**，回 -32001 拒绝（禁匿名放行——载荷自声明身份不可信）；
// ② 帧携带 caller → 处理器收到已解析身份（Dart 只接收，禁伪造通道）；
// ③ caller 形状异常（缺字段）= 解析失败同口径拒绝。
//
// 真机场次（S07 验收）：同机 App 调宿主主体可辨——待用户执行（平台侧
// getCallingUid 真内核路径无法在宿主单测内覆盖）。
import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/mcp/transport/binder_transport.dart';

const channelName = 'goodhub/binder_mcp';

/// 模拟原生经 MethodChannel 推帧（与 binder_event_stream_test 同口径）。
Future<Object?> pushMethodCall(MethodCall call) {
  final codec = const StandardMethodCodec();
  final done = Completer<Object?>();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
    channelName,
    codec.encodeMethodCall(call),
    (ByteData? reply) {
      if (!done.isCompleted) {
        done.complete(reply == null ? null : codec.decodeEnvelope(reply));
      }
    },
  );
  return done.future;
}

/// 反向请求事件信封（带 id 带 method = server→client 反向请求）。
Map<String, Object?> reverseRequestEnvelope(
  String tid,
  int id, {
  Map<String, Object?>? caller,
}) =>
    <String, Object?>{
      'transportId': tid,
      'message': jsonEncode(<String, Object?>{
        'jsonrpc': '2.0',
        'id': id,
        'method': 'sampling/createMessage',
        'params': <String, Object?>{'messages': <Object?>[]},
      }),
      'caller': ?caller,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BinderTransport t;
  final answered = <Map<String, Object?>>[];

  setUp(() {
    answered.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(channelName), (call) async {
      switch (call.method) {
        case 'bind':
        case 'resetAllTransports':
          return null;
        case 'answerReverse':
          final body = call.arguments['responseBody'] as String?;
          if (body != null) {
            answered.add(jsonDecode(body) as Map<String, Object?>);
          }
          return null;
        default:
          throw MissingPluginException(call.method);
      }
    });
    t = BinderTransport(
      transportId: 'identity-t',
      packageName: 'com.zzh.goodshare',
      serviceClassName: 'com.zzh.goodshare.McpBinderService',
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(channelName), null);
    t.close();
  });

  test('拒绝红线：帧未携带 caller（平台侧解析失败）→ 处理器不调用，回 -32001',
      () async {
    await Future<void>.delayed(Duration.zero); // 等路由表就绪
    var handlerCalled = false;
    t.onServerRequestWithCaller = (method, params, caller) async {
      handlerCalled = true;
      return null;
    };
    await pushMethodCall(MethodCall('onNativeEvent', reverseRequestEnvelope(
      'identity-t',
      1,
      caller: null, // 平台侧解析失败：信封无 caller 字段
    )));
    await Future<void>.delayed(Duration.zero);
    expect(handlerCalled, isFalse, reason: '身份缺失禁匿名放行（S07b 红线）');
    expect(answered, hasLength(1));
    final err = answered.single['error'] as Map;
    expect(err['code'], -32001);
    expect(err['message'], contains('按拒绝处置'));
  });

  test('身份投递：帧携带 caller → 处理器收到已解析身份', () async {
    await Future<void>.delayed(Duration.zero);
    ResolvedCallerIdentity? seen;
    t.onServerRequestWithCaller = (method, params, caller) async {
      seen = caller;
      return <String, Object?>{'ok': true};
    };
    await pushMethodCall(MethodCall('onNativeEvent', reverseRequestEnvelope(
      'identity-t',
      2,
      caller: <String, Object?>{
        'packageName': 'com.zzh.goodshare',
        'signatureSha256': 'aa'.padRight(64, '0'),
      },
    )));
    await Future<void>.delayed(Duration.zero);
    expect(seen, isNotNull, reason: 'Dart 只接收已解析身份（内核 UID 推导）');
    expect(seen!.packageName, 'com.zzh.goodshare');
    expect(answered.single['result'], isNotNull);
  });

  test('形状异常同口径：caller 缺字段 = 解析失败 → -32001 拒绝', () async {
    await Future<void>.delayed(Duration.zero);
    var handlerCalled = false;
    t.onServerRequestWithCaller = (method, params, caller) async {
      handlerCalled = true;
      return null;
    };
    await pushMethodCall(MethodCall('onNativeEvent', reverseRequestEnvelope(
      'identity-t',
      3,
      caller: <String, Object?>{'packageName': ''}, // 包名空 = 形状异常
    )));
    await Future<void>.delayed(Duration.zero);
    expect(handlerCalled, isFalse);
    expect((answered.single['error'] as Map)['code'], -32001);
  });

  test('既有行为零变化：仅设 onServerRequest（无身份钩子）时照常分派', () async {
    await Future<void>.delayed(Duration.zero);
    var called = false;
    t.onServerRequest = (method, params) async {
      called = true;
      return <String, Object?>{'ok': true};
    };
    await pushMethodCall(MethodCall('onNativeEvent', reverseRequestEnvelope(
      'identity-t',
      4,
      caller: null, // 既有钩子无身份语义，不拒绝
    )));
    await Future<void>.delayed(Duration.zero);
    expect(called, isTrue, reason: 'Expand-Contract：既有钩子路径零变化');
    expect(answered.single['result'], isNotNull);
  });
}
