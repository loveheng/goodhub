// goodshare 真机 Binder 联调 e2e（交接文档「附：真机联调前置」步骤 3~4）：
//
//   发现 → bind（sameSignature=true）→ tools/list → tools/call list_items（短工具）。
//
// 前置纪律（出包）：goodhub + goodshare 必须同机同一 debug keystore 构建并同批安装，
// 否则 signature 权限校验失败 → bind 必挂。
//
// 运行（真机，先确保 goodshare 已启动至少一次初始化 DB）：
//   flutter test integration_test/goodshare_binder_e2e_test.dart -d <device>
//
// force-stop 自愈（步骤 5）：本测试跑通后，另开终端
//   adb shell am force-stop com.zzh.goodshare
// 再跑一次本测试，应仍 bind 成功（宿主 BIND_AUTO_CREATE 随调随起重拉服务）。

library;

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:goodhub/coordinator/mcp_tool_face.dart';
import 'package:goodhub/mcp/local_plugin_discovery.dart';

Future<T> _withTimeout<T>(Future<T> f, String label) => f.timeout(
      const Duration(seconds: 30),
      onTimeout: () =>
          throw TimeoutException('超时: $label', const Duration(seconds: 30)),
    );

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('goodshare binder: discovery(sameSignature) + bind + list_items',
      (tester) async {
    // ---- 步骤 3：发现 goodshare，断言同签名（出包纪律的落地校验）----
    final plugins = await _withTimeout(localPluginDiscovery.scan(), 'scan');
    final gs = plugins.where((p) => p.serverId == 'goodshare').toList();
    expect(gs, isNotEmpty,
        reason: '应扫描到 goodshare 本地插件（serverId=goodshare）');
    final info = gs.first;
    debugPrint(
        '[gs-e2e] discovered goodshare: pkg=${info.packageName} sig=${info.signatureSha256} sameSignature=${info.sameSignature}');
    expect(info.sameSignature, isTrue,
        reason: '两包须同签名（同机同 debug keystore 构建），否则 signature 权限拒绝 bind');
    expect(info.packageName, 'com.zzh.goodshare');

    // ---- 步骤 3 续：bind（negotiate）→ READY ----
    final client = localPluginDiscovery.createClient(info);
    try {
      await _withTimeout(client.negotiate(), 'negotiate goodshare');
      final face = McpToolFace(client: client, serverId: info.serverId);

      // ---- 步骤 4：tools/list 聚合含短工具 list_items ----
      final tools = await _withTimeout(face.listTools(), 'listTools goodshare');
      final names = tools.map((t) => t.name).toList();
      debugPrint('[gs-e2e] goodshare tools: $names');
      expect(names, contains('list_items'),
          reason: 'tools/list 应返回 goodshare 的 list_items（短工具）');

      // ---- 步骤 4 续：tools/call list_items 走通（短工具，无 sampling/长任务）----
      final raw = await _withTimeout(
        client.call(
          'tools/call',
          params: {
            'name': 'list_items',
            'arguments': <String, Object?>{'limit': 5},
          },
        ),
        'list_items',
      );
      expect(raw, isA<Map>(), reason: 'list_items 应返回 JSON-RPC result object');
      final r = raw as Map<String, Object?>;
      expect(r['isError'], isNot(true),
          reason: 'list_items 不应返回 isError（短工具应秒回）');
      expect(r['content'], isA<List>(),
          reason: 'list_items 应返回 content 列表');
      debugPrint('[gs-e2e] list_items content=${(r['content'] as List).length} 项');
      debugPrint('[gs-e2e] PASS: discovery+bind+list_items 全链路通');
    } finally {
      client.close();
    }
  });
}
