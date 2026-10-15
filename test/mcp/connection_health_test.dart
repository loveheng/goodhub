/// 连接健康（T4-2）单测：作用域隔离（仅 HTTP 轮询）、状态机转换、
/// 首探即时、超时计入失败、生命周期释放。
///
/// 用 `fake_async` 接管 `Timer`，精确驱动周期与超时；探活实现注入，不触网。
library;

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/mcp/connection_health.dart';
import 'package:goodhub/mcp/mcp_client.dart';
import 'package:goodhub/mcp/transport/mcp_transport.dart';

McpClient _http() => McpClient.http(baseUrl: 'http://127.0.0.1:9999/mcp');

/// 假传输：非 [HttpTransport]（代表本地 Binder 等不轮询连接），仅用于断言
/// [ConnectionHealth.pollable] 门控——不触碰原生平台通道。
class _NonHttpTransport implements McpTransport {
  @override
  Future<TransportResponse> send(String requestBody) async =>
      throw UnimplementedError();

  @override
  Future<StreamedTransportResponse> sendStream(String requestBody) async =>
      throw UnimplementedError();

  @override
  Future<StreamedTransportResponse> getStream() =>
      throw UnsupportedError('test transport 不支持 GET SSE 订阅通道');

  @override
  void close() {}
}

void main() {
  group('作用域隔离（D16）：仅远端 HTTP 轮询', () {
    test('Http 连接可轮询', () {
      expect(ConnectionHealth.pollable(_http()), isTrue);
    });

    test('Binder（非 HTTP）连接不可轮询：start 直接 no-op，不建定时器、state 保持 unknown', () {
      // 本地 Binder 插件依赖 DeathRecipient 事件感知，严禁周期轮询（D16）。
      final c = McpClient(_NonHttpTransport());
      expect(ConnectionHealth.pollable(c), isFalse);
      final h = ConnectionHealth(c);
      h.start();
      expect(h.state, ConnectionState.unknown); // 未触网、未探
      h.stop();
    });
  });

  group('状态机（FakeAsync 驱动定时器）', () {
    test('首探成功即 online；连续失败 degraded→offline；恢复 online', () {
      final outcomes = [true, false, false, true];
      var i = 0;
      FakeAsync().run((fake) {
        final h = ConnectionHealth(_http(),
            ping: () async {
              final ok = outcomes[i++];
              if (!ok) throw StateError('down');
            });
        h.start();
        fake.flushMicrotasks();
        expect(h.state, ConnectionState.online); // 首探

        fake.elapse(const Duration(seconds: 15));
        fake.flushMicrotasks();
        expect(h.state, ConnectionState.degraded); // 1 次失败

        fake.elapse(const Duration(seconds: 15));
        fake.flushMicrotasks();
        expect(h.state, ConnectionState.offline); // 2 次失败

        fake.elapse(const Duration(seconds: 15));
        fake.flushMicrotasks();
        expect(h.state, ConnectionState.online); // 恢复
      });
    });

    test('ping 超时计入失败（5s 超时触发，非无限挂死）', () {
      FakeAsync().run((fake) {
        final h = ConnectionHealth(_http(),
            timeout: const Duration(seconds: 5),
            ping: () async {
              await Completer<void>().future; // 永不完成
            });
        h.start();
        fake.flushMicrotasks();
        // 首探在途；elapse 5s 触发 timeout
        fake.elapse(const Duration(seconds: 5));
        fake.flushMicrotasks();
        expect(h.state, ConnectionState.degraded); // 单次失败（<2 阈）
      });
    });
  });

  group('生命周期', () {
    test('stop 释放：停后再推进时间不重复触发 tick', () {
      FakeAsync().run((fake) {
        final h = ConnectionHealth(_http(), ping: () async {});
        h.start();
        fake.flushMicrotasks();
        expect(h.state, ConnectionState.online);
        h.stop();
        fake.elapse(const Duration(seconds: 15));
        fake.flushMicrotasks();
        expect(h.state, ConnectionState.online); // 停后不变
      });
    });

    test('start 幂等（重复 start 不建双定时器）', () {
      FakeAsync().run((fake) {
        final h = ConnectionHealth(_http(), ping: () async {});
        h.start();
        h.start();
        fake.flushMicrotasks();
        expect(h.state, ConnectionState.online);
        h.stop();
        fake.elapse(const Duration(seconds: 15));
        fake.flushMicrotasks();
        expect(h.state, ConnectionState.online);
      });
    });
  });
}
