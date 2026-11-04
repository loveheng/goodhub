// 平台侧新增死亡代理链路回归钉（W5 调用方进程死亡联动打断，K17）。
//
// 红线：① 死亡事件走**新增链路** `onCallerDied`（平台侧为调用方链路注册的
// 独立死亡代理）——既有方向的死亡代理不覆盖反向路径；② 既有 `onTransportError`
// 死亡信封（binderDied）**不**驱动调用方死亡打断（两条链路互不替代）；
// ③ 事件键 = 调用方身份键（包名，物理主键）——必须与在途注册的 callerKey 同源。
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/mcp/transport/binder_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channelName = 'goodhub/binder_mcp';

  late BinderTransport transport;

  /// 模拟原生经 MethodChannel 推帧（与 binder_event_stream_test 同手法）。
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

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(channelName), (call) async {
      switch (call.method) {
        case 'bind':
        case 'resetAllTransports':
          return null;
        default:
          throw MissingPluginException(call.method);
      }
    });
    transport = BinderTransport(
      transportId: 'local:com.zzh.goodshare_goodshare',
      packageName: 'com.zzh.goodshare',
      serviceClassName: 'com.zzh.goodshare.McpBinderService',
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(channelName), null);
    BinderTransport.onCallerDeath = null;
    transport.close();
  });

  test('新增链路 onCallerDied：钩子被调，键 = 调用方身份键（包名）', () async {
    await Future<void>.delayed(Duration.zero);
    final seen = <String>[];
    BinderTransport.onCallerDeath = seen.add;

    final ack = await pushMethodCall(MethodCall('onCallerDied', <Object, Object?>{
      'transportId': 'local:com.zzh.goodshare_goodshare',
      'callerKey': 'com.zzh.goodshare',
    }));
    expect(ack, <String, Object?>{'delivered': true});
    expect(seen, <String>['com.zzh.goodshare'],
        reason: '事件键 = 包名（与在途注册的 callerKey 同源）');
  });

  test('既有 binderDied 死亡信封不驱动调用方死亡打断（两条链路互不替代）',
      () async {
    await Future<void>.delayed(Duration.zero);
    var called = 0;
    BinderTransport.onCallerDeath = (_) => called++;

    await pushMethodCall(MethodCall('onTransportError', <Object, Object?>{
      'transportId': 'local:com.zzh.goodshare_goodshare',
      'error': <Object, Object?>{
        'code': 'SERVER_DIED',
        'message': 'remote MCP server process terminated',
      },
    }));
    expect(called, 0,
        reason: '红线：既有方向的死亡代理不覆盖反向路径，须新增链路');
  });

  test('路由未命中（实例已关闭）→ delivered=false（丢件不静默）', () async {
    await Future<void>.delayed(Duration.zero);
    var called = 0;
    BinderTransport.onCallerDeath = (_) => called++;

    final ack = await pushMethodCall(MethodCall('onCallerDied', <Object, Object?>{
      'transportId': 'no-such-transport',
      'callerKey': 'com.zzh.goodshare',
    }));
    expect(ack, <String, Object?>{'delivered': false});
    expect(called, 0);
  });
}
