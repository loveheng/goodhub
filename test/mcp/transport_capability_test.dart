import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/mcp/mcp_client.dart';
import 'package:goodhub/mcp/transport/binder_transport.dart';
import 'package:goodhub/mcp/transport/host_transport.dart';
import 'package:goodhub/mcp/transport/mcp_transport.dart';

/// S1c（extensibility-hardening）：传输能力接口探测——三处 isinstance 消费点
/// 换按能力接口分派后的语义钉子：能力归属正确 + 新传输实现接口即被消费方接纳
/// （「禁再 is 具体类」的结构性验证 = 本文件对真实传输的 is 断言）。

/// 非 Binder 的新传输假件：实现 [CallerIdentityTransport] 即具备调用方身份能力
/// ——证明消费方按接口分派后可接纳任意同能力传输（不只 Binder）。
class _FakeCallerTransport implements McpTransport, CallerIdentityTransport {
  @override
  Future<Map<String, Object?>?> Function(
    String method,
    Object? params,
    ResolvedCallerIdentity caller,
  )? onServerRequestWithCaller;

  @override
  String get callerKey => 'fake.pkg';

  @override
  Future<TransportResponse> send(String requestBody) async => TransportResponse(
      statusCode: 200, contentType: 'application/json', body: '{}');

  @override
  Future<StreamedTransportResponse> sendStream(String requestBody) async =>
      StreamedTransportResponse(
          statusCode: 200,
          contentType: 'application/json',
          lines: const Stream.empty());

  @override
  Future<StreamedTransportResponse> getStream() async =>
      StreamedTransportResponse(
          statusCode: 200,
          contentType: 'text/event-stream',
          lines: const Stream.empty());

  @override
  void close() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('HttpTransport：可轮询（PollableTransport），非保留承载 / 非身份面', () {
    final t = HttpTransport(baseUrl: 'http://127.0.0.1:1/mcp');
    expect(t, isA<PollableTransport>());
    expect(t, isNot(isA<ReservedNamespaceTransport>()));
    expect(t, isNot(isA<CallerIdentityTransport>()));
    t.close();
  });

  test('HostTransport：保留命名空间承载（ReservedNamespaceTransport）', () {
    final t = HostTransport(
      invoker: ({required String name, required String argumentsJson}) async =>
          throw UnimplementedError(),
    );
    expect(t, isA<ReservedNamespaceTransport>());
    expect(t, isNot(isA<PollableTransport>()));
  });

  test('BinderTransport：调用方身份能力（callerKey = 包名，K17 同源）', () async {
    const channelName = 'goodhub/binder_mcp';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(channelName),
            (call) async {
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
    });
    final client = McpClient.binder(
      transportId: 'local:com.zzh.goodshare_goodshare',
      packageName: 'com.zzh.goodshare',
      serviceClassName: 'com.zzh.goodshare.McpBinderService',
    );
    addTearDown(client.close);
    final transport = client.transport;
    expect(transport, isA<CallerIdentityTransport>());
    expect(transport, isNot(isA<PollableTransport>()));
    expect(
        (transport as CallerIdentityTransport).callerKey, 'com.zzh.goodshare');
  });

  test('能力接口可被任意新传输实现（消费方按接口接纳，非具体类）', () {
    final fake = _FakeCallerTransport();
    expect(fake, isA<CallerIdentityTransport>());
    expect(fake.callerKey, 'fake.pkg');
  });
}
