/// 同机本地插件发现（thirdconnect T-trans-4，§1.2.4 / §4）。
///
/// 零配置热插拔：经宿主侧 [BinderTransportBridge] 的 `discover` 拉扫已安装且声明
/// `com.zzh.goodhub.action.MCP_SERVER` 的插件 Service（读 meta-data：SERVER_ID /
/// SERVER_TITLE → packageName / serviceClassName），并订阅系统包变更（安装/卸载/替换）
/// 经 `goodhub/binder_discovery` 通道通知重扫。
///
/// 发现即挂：由装配层（chat_page / gateway 调试页）把 [LocalPluginInfo] 经
/// [createClient] 构造成 Binder 传输的 [McpClient] 并接入 ToolRouter（系统托管，
/// 不进用户手填配置）；反向请求接线（如 samplingRequestHandler）由装配层统一接管。
library;

import 'dart:async';
import 'dart:convert' show jsonDecode;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';

import 'mcp_client.dart';

/// 一个已发现的本地插件（来自宿主 PackageManager 扫描）。
class LocalPluginInfo {
  const LocalPluginInfo({
    required this.serverId,
    required this.serverTitle,
    required this.packageName,
    required this.serviceClassName,
    this.signatureSha256 = '',
    this.sameSignature = false,
  });

  factory LocalPluginInfo.fromJson(Map<String, Object?> j) => LocalPluginInfo(
        serverId: j['serverId'] as String? ?? '',
        serverTitle: j['serverTitle'] as String? ?? '',
        packageName: j['packageName'] as String? ?? '',
        serviceClassName: j['serviceClassName'] as String? ?? '',
        signatureSha256: j['signatureSha256'] as String? ?? '',
        sameSignature: j['sameSignature'] == true,
      );

  /// 插件声明的服务 id（路由前缀；物理主键仍是 packageName）。
  final String serverId;

  /// 展示名（meta-data SERVER_TITLE）。
  final String serverTitle;

  /// 物理主键：插件包名（§9.3）。
  final String packageName;

  /// 插件 Service 全限定类名（如 com.zzh.goodhub.sample.dummy.DummyPluginService）。
  final String serviceClassName;

  /// 插件签名 SHA-256 指纹（宿主提取，§1.2.6 信任卡片展示用）。
  final String signatureSha256;

  /// 是否与宿主同签名（私有生态零弹窗自动信任，§1.2.6）。
  final bool sameSignature;

  /// 区分多插件的 transport key（与宿主侧 transports Map 对齐）。
  String get transportId => 'local:${packageName}_$serverId';

  @override
  String toString() =>
      'LocalPluginInfo($serverId @ $packageName/$serviceClassName)';
}

/// 本地插件发现门面（单例）：拉扫 + 包变更订阅。
/// 本地插件来源——**装配侧的消费面**（2026-10-17 P0-B 引入）。
///
/// 原状：`GatewayController` 直依赖顶层全局 `localPluginDiscovery`，该类私有
/// 构造且平台通道内聚，测试无从注入假件 → 重扫释放、起服失败回滚两条关键
/// 路径只能真机验收（债 #14）。本接口只暴露装配期真正消费的三个成员，
/// 生产实现 = [LocalPluginDiscovery]。
abstract interface class LocalPluginSource {
  /// 包变更广播（安装/卸载/替换本地插件 → 装配层据此重扫）。
  Stream<void> get changes;

  /// 扫描当前已安装的本地插件。
  Future<List<LocalPluginInfo>> scan();

  /// 为该插件建传输客户端（Binder）。
  McpClient createClient(LocalPluginInfo info);
}

class LocalPluginDiscovery implements LocalPluginSource {
  LocalPluginDiscovery._();

  static final LocalPluginDiscovery instance = LocalPluginDiscovery._();

  static const MethodChannel _binderChannel =
      MethodChannel('goodhub/binder_mcp');
  static const MethodChannel _discoveryChannel =
      MethodChannel('goodhub/binder_discovery');

  final StreamController<void> _changes = StreamController<void>.broadcast();
  bool _listening = false;

  /// 包变更流（安装/卸载/替换本地插件 → 触发，装配层据此重扫/推送 tools/list_changed）。
  @override
  Stream<void> get changes {
    _ensureListening();
    return _changes.stream;
  }

  void _ensureListening() {
    if (_listening) return;
    _listening = true;
    _discoveryChannel.setMethodCallHandler((call) async {
      if (call.method == 'onPluginsChanged') _changes.add(null);
      return null;
    });
  }

  /// 拉扫已安装本地插件（宿主 PackageManager 扫描 + meta-data 解析）。
  /// 失败（通道不可用/宿主未就绪）→ 返回空目录，不抛（§1.2.4 零配置，失败即无）。
  @override
  Future<List<LocalPluginInfo>> scan() async {
    try {
      final result = await _binderChannel.invokeMethod<String>('discover');
      if (result == null || result.isEmpty) return const [];
      final decoded = jsonDecode(result);
      if (decoded is! List) return const [];
      return [
        for (final e in decoded)
          if (e is Map<String, Object?>) LocalPluginInfo.fromJson(e),
      ];
    } on PlatformException catch (e) {
      debugPrint('[DEGRADE] local-plugin-discovery: scan failed: $e');
      return const [];
    }
  }

  /// 为本地插件构造同机 Binder 传输的 [McpClient]（零端口）。
  /// 调用方负责接线 [McpClient.onServerRequest]（如 [samplingRequestHandler]）。
  @override
  McpClient createClient(LocalPluginInfo info) => McpClient.binder(
        transportId: info.transportId,
        packageName: info.packageName,
        serviceClassName: info.serviceClassName,
      );
}

/// 进程级单例（装配层共享）。
final LocalPluginDiscovery localPluginDiscovery = LocalPluginDiscovery.instance;
