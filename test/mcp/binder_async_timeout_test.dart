/// BinderTransport `_async` 终帧 idle 超时兜底单测（义务①防悬挂回归钉）。
///
/// 场景：插件回 `_async` 占位帧后漏推同 id 终帧（进程死亡/通道断连）——
/// send() 必须在 idle 超时内抛 McpNetworkException，而非永久悬挂 completer。
library;


import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/core/errors/mcp_error.dart';
import 'package:goodhub/mcp/transport/binder_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channelName = 'goodhub/binder_mcp';
  late BinderTransport transport;

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(channelName), (call) async {
      switch (call.method) {
        case 'bind':
          return null;
        case 'send':
          // _async 占位帧：之后永远不推终帧（模拟插件进程死亡）。
          return '{"jsonrpc":"2.0","id":7,"result":{"_async":true}}';
        default:
          throw MissingPluginException(call.method);
      }
    });
    transport = BinderTransport(
      transportId: 't1',
      packageName: 'app.shiguang.shiguang',
      serviceClassName: 'app.shiguang.shiguang.ShiguangMcpBinderService',
      asyncTerminalTimeout: const Duration(milliseconds: 50),
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(channelName), null);
  });

  test('send：_async 占位后终帧漏推 → idle 超时抛 McpNetworkException（不悬挂）', () async {
    await Future<void>.delayed(Duration.zero); // 等 bind 触发
    await expectLater(
      transport.send('{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{}}'),
      throwsA(isA<McpNetworkException>()),
    );
  });
}
