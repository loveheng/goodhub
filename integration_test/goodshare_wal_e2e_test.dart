// goodshare 真机 WAL 写路径并发压测（交接文档「附：真机联调前置」步骤 6 的自动化代理）。
//
// 说明：binder isolate 对 goodshare.db 是「单连接」，并发 add_item 在 Dart 侧串行落库，
// 故本测验证的是「binder 写路径在并发下无死锁/无库内 locked、全部提交成功」。
// 真正的「主 isolate + binder isolate 双连接」争写（R1）需 UI 同时加 item，无法纯自动化，
// 见报告中的手动步骤与 busy_timeout 缓解建议。

library;

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:goodhub/mcp/local_plugin_discovery.dart';

Future<T> _withTimeout<T>(Future<T> f, String label) => f.timeout(
      const Duration(seconds: 30),
      onTimeout: () =>
          throw TimeoutException('超时: $label', const Duration(seconds: 30)),
    );

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('goodshare WAL: concurrent add_item via binder (write path)',
      (tester) async {
    final plugins = await _withTimeout(localPluginDiscovery.scan(), 'scan');
    final info = plugins.where((p) => p.serverId == 'goodshare').first;
    expect(info.sameSignature, isTrue, reason: '两包须同签名');
    final client = localPluginDiscovery.createClient(info);
    try {
      await _withTimeout(client.negotiate(), 'negotiate');
      const n = 12;
      debugPrint('[gs-wal] firing $n concurrent add_item via binder...');
      final futures = <Future<Object?>>[];
      for (var i = 0; i < n; i++) {
        futures.add(_withTimeout(
          client.call(
            'tools/call',
            params: {
              'name': 'add_item',
              'arguments': <String, Object?>{
                'content': 'WAL 压测 #$i ${DateTime.now().microsecondsSinceEpoch}',
              },
            },
          ),
          'add_item#$i',
        ));
      }
      final results = await Future.wait(futures);
      var ok = 0;
      for (final r in results) {
        final m = r is Map<String, Object?> ? r : <String, Object?>{};
        final err = m['isError'];
        if (err != true) ok++;
      }
      debugPrint('[gs-wal] add_item 成功 $ok/$n');
      expect(ok, n, reason: '并发 add_item 应全部成功（无库内 locked/死锁）');
      debugPrint('[gs-wal] PASS: binder 写路径并发安全');
    } finally {
      client.close();
    }
  });
}
