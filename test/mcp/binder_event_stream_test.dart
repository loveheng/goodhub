/// BinderTransport 事件路由回归钉子（全量 MethodChannel 推挽，T-trans-3）：
/// 覆盖 2026-10-17「发送信息后卡死」根因的结构性根治 + 生命周期语义硬化。
///
/// 机制：原生经 `invokeMethod('onNativeEvent' / 'onTransportError')` 推帧，
/// Dart 路由表按 transportId 分发并回 `{'delivered': bool}` ACK。相比
/// EventChannel（消息处理器按频道名全局单例、任一实例 cancel 即置空）——
/// 无 handler 踩踏、无退订竞态、丢件有回执。
///
/// 钉子：
/// - 多实例并存：后关先建实例，在途实例终帧照常投递（旧 EventChannel 实现
///   在此场景必丢帧 → sendStream 永久悬挂）；
/// - ACK 精准度：命中回 delivered=true，路由未命中回 false（丢件不静默）；
/// - 死亡信封：binderDied → 在途 _async 秒级失败（拒绝干等看门狗）；
/// - close 收敛：迟到终帧路由为 delivered=false，不抛不挂（丢帧无害化）；
/// - 乱序守卫：终帧收尾后迟到的 progress 帧静默丢弃（禁 StateError）。
library;

import 'dart:async';
import 'dart:convert' as json;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/core/errors/mcp_error.dart';
import 'package:goodhub/mcp/transport/binder_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channelName = 'goodhub/binder_mcp';

  late BinderTransport a;
  late BinderTransport b;

  /// 模拟原生经 MethodChannel 推帧，返回 Dart 路由表的 ACK 解码值。
  /// 回执经 messenger 异步回来，用 Completer 等闭环。
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

  Map<String, Object?> terminalEnvelope(String tid, int id) =>
      <String, Object?>{
        'transportId': tid,
        'message': '{"jsonrpc":"2.0","id":$id,"result":{"ok":true}}',
      };

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(channelName), (call) async {
      switch (call.method) {
        case 'bind':
          return null;
        case 'resetAllTransports':
          return null;
        case 'send':
          // _async 占位帧（id 与请求无关：_isAsyncPlaceholder 只认 result._async）。
          return '{"jsonrpc":"2.0","id":0,"result":{"_async":true}}';
        default:
          throw MissingPluginException(call.method);
      }
    });
    // A 先建（先占路由表）→ B 后建 → 用例内 A 先关闭（旧 EventChannel 实现
    // 在此场景下 A 的 cancel 会置空频道名全局 handler，B 的终帧全部丢失）。
    a = BinderTransport(
      transportId: 'stream-a',
      packageName: 'app.shiguang.shiguang',
      serviceClassName: 'app.shiguang.shiguang.ShiguangMcpBinderService',
      asyncTerminalTimeout: const Duration(seconds: 5),
    );
    b = BinderTransport(
      transportId: 'stream-b',
      packageName: 'app.shiguang.shiguang',
      serviceClassName: 'app.shiguang.shiguang.ShiguangMcpBinderService',
      asyncTerminalTimeout: const Duration(seconds: 5),
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(channelName), null);
    a.close();
    b.close();
  });

  test('多实例并存：先关先建实例，在途实例终帧照常投递（handler 踩踏根治）',
      () async {
    await Future<void>.delayed(Duration.zero); // 等 bind / 路由表就绪
    a.close(); // 旧实现：此 cancel 置空频道名全局 handler → b 的事件全丢

    final fut = b.send('{"jsonrpc":"2.0","id":42,"method":"tools/call","params":{}}');
    await Future<void>.delayed(Duration.zero); // 等占位回包入 Dart

    final ack = await pushMethodCall(
      MethodCall('onNativeEvent', terminalEnvelope('stream-b', 42)),
    );
    expect(ack, <String, Object?>{'delivered': true});

    final resp = await fut.timeout(const Duration(seconds: 2));
    expect(json.jsonDecode(resp.body)['result']['ok'], isTrue);
  });

  test('ACK 精准度：路由未命中回 delivered=false（丢件不静默）', () async {
    await Future<void>.delayed(Duration.zero);
    final ack = await pushMethodCall(
      MethodCall('onNativeEvent', terminalEnvelope('no-such-transport', 1)),
    );
    expect(ack, <String, Object?>{'delivered': false});
  });

  test('binderDied 死亡信封：在途 _async 秒级失败（拒绝干等 5s 看门狗）', () async {
    await Future<void>.delayed(Duration.zero);
    final fut = b.send('{"jsonrpc":"2.0","id":43,"method":"tools/call","params":{}}');
    await Future<void>.delayed(Duration.zero); // 占位回包入 Dart，completer 在途
    // 先挂监听再触发失败：避开 future 无监听 error 的未处理异步错误窗口。
    final settled = expectLater(
      fut.timeout(const Duration(seconds: 2)),
      throwsA(isA<McpNetworkException>()),
    );

    final ack = await pushMethodCall(MethodCall('onTransportError', <Object, Object?>{
      'transportId': 'stream-b',
      'error': <Object, Object?>{
        'code': 'SERVER_DIED',
        'message': 'remote MCP server process terminated',
      },
    }));
    expect(ack, <String, Object?>{'delivered': true});

    // 死亡收敛必须远快于 5s 看门狗：2s 外罩超时未触发即证明走了信封路径。
    await settled;
  });

  test('close 秒级收敛在途 _async；迟到终帧 delivered=false（注销竞态正解）',
      () async {
    await Future<void>.delayed(Duration.zero);
    final fut = b.send('{"jsonrpc":"2.0","id":44,"method":"tools/call","params":{}}');
    await Future<void>.delayed(Duration.zero); // completer 在途
    // 先挂监听再触发收敛（同上：避开无监听 error 窗口）。
    final settled = expectLater(
      fut.timeout(const Duration(seconds: 2)),
      throwsA(isA<McpNetworkException>()),
    );
    b.close(); // 秒级收敛：等待者立即失败，而非干等 5s 看门狗
    await settled;

    // 迟到终帧：实例已摘除 → 路由 delivered=false 静默丢弃，不得抛。
    final ack = await pushMethodCall(
      MethodCall('onNativeEvent', terminalEnvelope('stream-b', 44)),
    );
    expect(ack, <String, Object?>{'delivered': false});
  });

  test('终帧收尾后迟到的 progress 帧静默丢弃（乱序防御，禁 StateError）', () async {
    await Future<void>.delayed(Duration.zero);
    final streamed = await b.sendStream(
      '{"jsonrpc":"2.0","id":45,"method":"tools/call","params":{}}',
    );

    // 终帧先到（收尾关闭控制器）→ 乱序迟到的 progress 帧后到。
    await pushMethodCall(MethodCall(
      'onNativeEvent',
      <Object, Object?>{
        'transportId': 'stream-b',
        'message': '{"jsonrpc":"2.0","id":45,"result":{"ok":true}}',
      },
    ));
    await pushMethodCall(MethodCall(
      'onNativeEvent',
      <Object, Object?>{
        'transportId': 'stream-b',
        'message': '{"jsonrpc":"2.0","method":"notifications/progress",'
            '"params":{"progressToken":1,"progress":5}}',
      },
    ));

    final lines = await streamed.lines.timeout(const Duration(seconds: 2)).toList();
    // 仅终帧一个 data 帧；迟到 progress 被守卫静默丢弃（无 StateError、无附加帧）。
    expect(lines.where((l) => l.startsWith('data: ')).length, 1);
  });
}
