// 外联探针：设备上起网关绑 0.0.0.0:8766（anyIPv4），保活 120s 供 PC 经
// `adb forward tcp:8766 tcp:8766` + curl 真实打 /mcp（验证 thirdconnect.md §7 物理通道 1）。
// 非断言测试，仅打印 [probe] READY 后空转，由外部 curl 驱动。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:goodhub/coordinator/mcp_tool_face.dart';
import 'package:goodhub/coordinator/permission_gateway.dart';
import 'package:goodhub/gateway/gateway_security.dart';
import 'package:goodhub/gateway/mcp_gateway_handler.dart';
import 'package:goodhub/gateway/gateway_server.dart';
import 'package:goodhub/mcp/local_plugin_discovery.dart';

class _AutoApproveDelegate implements GateDelegate {
  const _AutoApproveDelegate();
  @override
  Future<GateDecision> confirm(ToolPendingConfirmation pending) async =>
      const GateDecision(approved: true, rememberSession: true);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('gateway external probe (anyIPv4:8766, idle 120s)', (tester) async {
    final plugins = await localPluginDiscovery.scan();
    final handler = GatewayHandler(
      faces: <String, McpToolFace>{},
      security: GatewaySecurity(delegate: const _AutoApproveDelegate()),
    );
    for (final info in plugins) {
      if (info.serverId.isEmpty || handler.faces.containsKey(info.serverId)) continue;
      final client = localPluginDiscovery.createClient(info);
      try {
        await client.negotiate();
        final face = McpToolFace(client: client, serverId: info.serverId);
        await face.listTools();
        handler.faces[info.serverId] = face;
      } on Object {
        client.close();
      }
    }
    final server = McpGatewayServer(handler);
    await server.start(address: InternetAddress.anyIPv4, port: 8766);
    // ignore: avoid_print
    print('[probe] READY faces=${handler.faces.keys.toList()}');
    await Future.delayed(const Duration(seconds: 120));
    await server.stop();
  });
}
