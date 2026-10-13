/// 网关装配与生命周期控制（G1/G2）：本地插件（Binder）+ 远端 HTTP 端点
/// 全量装配为 face 喂给网关；包变更重扫 → tools/list_changed 下行联动。
///
/// - **双源装配**：本地插件零配置发现（`localPluginDiscovery.scan`，系统托管）
///   + 手填 HTTP 端点（`ServerEndpointStore`，用户托管）——同一套
///   negotiate → listTools → face 挂载口径（与 chat_page 装配等价，但独立于
///   聊天会话生命周期）；
/// - **反向请求接线**：每 face 的 `client.onServerRequest` 接
///   samplingRequestHandler（best-effort——引擎装配失败仅降级为 -32601 拒绝，
///   不阻断网关起服）；
/// - **热同步（§9.2）**：包变更广播 → 全量重扫重建 face 集 → 目录变更下行。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path_provider/path_provider.dart';

import '../coordinator/hybrid_assembly.dart';
import '../coordinator/mcp_tool_face.dart';
import '../mcp/local_plugin_discovery.dart';
import '../mcp/mcp_client.dart';
import '../mcp/trusted_plugins.dart';
import '../mcp/sampling.dart';
import '../mcp/server_endpoints.dart';
import '../sandbox/memory_store.dart';
import 'gateway_security.dart';
import 'gateway_server.dart';
import 'gateway_service_channel.dart';
import 'mcp_gateway_handler.dart';

class GatewayController {
  GatewayController._() {
    handler = GatewayHandler(faces: {}, security: security);
    server = McpGatewayServer(handler);
  }

  static final GatewayController shared = GatewayController._();

  /// 入站安全闭环（G3）：L2 确认卡（手机屏全屏醒目呼叫，TC12）+ PII 出站过滤 + ops.log 审计。
  final GatewaySecurity security = GatewaySecurity(
    delegate: const NativeConsentDelegate(),
  );

  late final GatewayHandler handler;
  late final McpGatewayServer server;
  StreamSubscription<void>? _pkgSub;
  var _starting = false;

  bool get running => server.running;

  /// 局域网 IPv4 地址列表（G5：PC 配置展示用，`http://<IP>:8766/mcp`；
  /// ADB 转发场景免 IP 用 127.0.0.1）。失败 DEGRADE 返空（UI 回退占位文案）。
  static Future<List<String>> lanAddresses() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
      return [
        for (final i in interfaces)
          for (final a in i.addresses) a.address,
      ];
    } on Object catch (e) {
      debugPrint('[DEGRADE] gateway: lan addresses failed: $e');
      return const [];
    }
  }

  /// 起服：装配 face → 绑定 :8766 → 订阅包变更重扫。
  Future<void> start({
    InternetAddress? address,
    int port = 8766,
    String? token,
  }) async {
    if (running || _starting) return;
    _starting = true;
    try {
      await _assemble();
      server.requiredToken = (token == null || token.isEmpty) ? null : token;
      await server.start(address: address, port: port);
      await GatewayServiceChannel.start(); // G4：前台保活（失败 DEGRADE 不阻断）
      handler.notifyToolsListChanged();
      _pkgSub ??= localPluginDiscovery.changes.listen((_) async {
        try {
          await _assemble();
          handler.notifyToolsListChanged();
        } on Object catch (e) {
          debugPrint('[DEGRADE] gateway: rescan failed: $e');
        }
      });
    } finally {
      _starting = false;
    }
  }

  Future<void> stop() async {
    await _pkgSub?.cancel();
    _pkgSub = null;
    await server.stop();
    await GatewayServiceChannel.stop(); // G4：停保活（失败 DEGRADE 不阻断）
    security.resetSessionGrants(); // C7：豁免不跨网关生命周期存活
  }

  /// 装配 face 集：本地插件扫描挂载 + 手填 HTTP 端点挂载 + sampling 反向接线。
  /// 单源挂载失败 [DEGRADE] 跳过不阻断其余源（网关宁缺勿炸）。
  Future<void> _assemble() async {
    handler.faces.clear();
    final support = (await getApplicationSupportDirectory()).path;
    final opsLog = MemoryStore.underSupportDir(support);
    security.opsLog = opsLog; // G3 入站审计与 face 级审计同汇

    // —— 本地插件（Binder，系统托管，零配置）——
    final trusted = await TrustedPlugins.instance;
    for (final info in await localPluginDiscovery.scan()) {
      if (info.serverId.isEmpty || handler.faces.containsKey(info.serverId)) {
        continue;
      }
      // §1.2.6 信任闸门：同签名私有生态默认自动信任；第三方非同签名且未入白名单
      // 则 headless 跳过（网关无 UI 无法弹信任卡片，需先在聊天页/设置中信任，持久化后
      // 下次装配即生效）。
      if (!info.sameSignature && !trusted.isTrusted(info.packageName)) {
        debugPrint(
            '[DEGRADE] gateway: 跳过未信任第三方插件 ${info.serverId}'
            '（${info.packageName}）；请先在聊天页或 ⚙ 设置中信任');
        continue;
      }
      final client = localPluginDiscovery.createClient(info);
      try {
        await client.negotiate();
        final face = McpToolFace(
          client: client,
          serverId: info.serverId,
          opsLog: opsLog,
        );
        await face.listTools();
        handler.faces[info.serverId] = face;
      } on Object catch (e) {
        debugPrint(
            '[DEGRADE] gateway: local plugin ${info.serverId} mount failed: $e');
        client.close();
      }
    }

    // —— 手填 HTTP 端点（用户托管，Streamable HTTP）——
    final epStore = ServerEndpointStore(file: File('$support/mcp_servers.json'));
    for (final ep in await epStore.load()) {
      if (ep.endpoint.isEmpty || handler.faces.containsKey(ep.id)) continue;
      final client = McpClient.http(
        baseUrl: ep.endpoint,
        apiKey: await epStore.apiKey(ep.id),
      );
      try {
        await client.negotiate();
        final face = McpToolFace(
          client: client,
          serverId: ep.id,
          opsLog: opsLog,
        );
        await face.listTools();
        handler.faces[ep.id] = face;
      } on Object catch (e) {
        debugPrint('[DEGRADE] gateway: endpoint ${ep.id} mount failed: $e');
        client.close();
      }
    }

    // —— sampling 反向请求接线（best-effort；失败仅 -32601 拒绝，不起服失败）——
    try {
      final engine = await assembleDefaultHybridEngine();
      final quota = SamplingQuota();
      for (final entry in handler.faces.entries) {
        entry.value.client.onServerRequest = samplingRequestHandler(
          engine: engine,
          quota: quota,
          serverKey: entry.key,
        );
      }
    } on Object catch (e) {
      debugPrint('[DEGRADE] gateway: sampling wiring skipped: $e');
    }
  }
}
