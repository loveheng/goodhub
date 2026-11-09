// Binder 传输层真机 e2e（对端 = SDK 仓 sample-dummy-plugin 标准参照插件，
// 2026-11-09 自 goodshare 专属联调改造而来——归属裁决：断言主体是 goodhub 的
// bind 状态机/发现/调用链，对端一律用 dummy，不钉任何真实第三方 App）。
//
//   发现 → bind（sameSignature=true）→ tools/list → tools/call echo（短工具）。
//
// 前置纪律（出包）：goodhub + dummy 插件必须同机同一 debug keystore 构建并同批
// 安装，否则 signature 权限校验失败 → bind 必挂。dummy 插件出包命令见
// goodhub-mcp-sdk 仓（sample-dummy-plugin 模块，applicationId=com.zzh.goodhub.sample.dummy）。
//
// 运行（真机，先确保 dummy 插件已启动至少一次）：
//   flutter test integration_test/dummy_binder_e2e_test.dart -d <device>
//
// force-stop 自愈：本测试跑通后，另开终端
//   adb shell am force-stop com.zzh.goodhub.sample.dummy
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

  testWidgets('dummy binder: discovery(sameSignature) + bind + echo',
      (tester) async {
    // ---- 发现 dummy 插件，断言同签名（出包纪律的落地校验）----
    final plugins = await _withTimeout(localPluginDiscovery.scan(), 'scan');
    final dummies = plugins.where((p) => p.serverId == 'dummy').toList();
    expect(dummies, isNotEmpty,
        reason: '应扫描到 dummy 本地插件（serverId=dummy）');
    final info = dummies.first;
    debugPrint(
        '[dummy-e2e] discovered dummy: pkg=${info.packageName} sig=${info.signatureSha256} sameSignature=${info.sameSignature}');
    expect(info.sameSignature, isTrue,
        reason: '两包须同签名（同机同 debug keystore 构建），否则 signature 权限拒绝 bind');
    expect(info.packageName, 'com.zzh.goodhub.sample.dummy');

    // ---- bind（negotiate）→ READY ----
    final client = localPluginDiscovery.createClient(info);
    try {
      await _withTimeout(client.negotiate(), 'negotiate dummy');
      final face = McpToolFace(client: client, serverId: info.serverId);

      // ---- tools/list 聚合含短工具 echo ----
      final tools = await _withTimeout(face.listTools(), 'listTools dummy');
      final names = tools.map((t) => t.name).toList();
      debugPrint('[dummy-e2e] dummy tools: $names');
      expect(names, contains('echo'),
          reason: 'tools/list 应返回 dummy 的 echo（短工具）');

      // ---- tools/call echo 走通（短工具，无 sampling/长任务）----
      final raw = await _withTimeout(
        client.call(
          'tools/call',
          params: {
            'name': 'echo',
            'arguments': <String, Object?>{'text': 'binder-e2e'},
          },
        ),
        'echo',
      );
      expect(raw, isA<Map>(), reason: 'echo 应返回 JSON-RPC result object');
      final r = raw as Map<String, Object?>;
      expect(r['isError'], isNot(true),
          reason: 'echo 不应返回 isError（短工具应秒回）');
      expect(r['content'], isA<List>(),
          reason: 'echo 应返回 content 列表');
      debugPrint('[dummy-e2e] echo content=${(r['content'] as List).length} 块');
      debugPrint('[dummy-e2e] PASS: discovery+bind+echo 全链路通');
    } finally {
      client.close();
    }
  });
}
