/// MCP 工具目录（资源中心 Tab · 服务工具快照）：已注册服务清单 + 单服务工具拉取。
///
/// **定位**：UI 取数的唯一收口（goodhub-ui §8.1 注入位范式——段不持领域单例，经
/// 本类取数）。复用 `McpRuntime` 挂载原语（与 chat/gateway 同口径，不开特权分支，
/// §8.1-11）；纯浏览面不审计（opsLog 不传），拉完即释放连接（无需常驻 face）。
///
/// **三态可见性**：`ToolVisibility` 仅 shared/private（缺失即 private），但 UI 需
/// 区分「显式声明私有」与「未声明（SDK<0.2.0 存量插件兜底）」——[McpCatalogTool]
/// 额外保留 [declared]，从 `tools/list` 条目的 `_meta.goodhub.visibility` 是否显式
/// 出现判定（对齐 tool_visibility.dart 兜底口径，勿把兜底当「用户刻意私有」）。
library;

import 'package:goodhub/coordinator/mcp_runtime.dart';
import 'package:goodhub/core/tool_visibility.dart';
import 'package:goodhub/llm/cloud/cloud_llm.dart';
import 'package:goodhub/mcp/local_plugin_discovery.dart';
import 'package:goodhub/mcp/server_endpoints.dart';

/// 服务来源（MC4：远程/本地只是标注，不作分组维度）。
enum CatalogSource {
  /// 同机 Binder 插件（系统托管，零配置，PackageManager 发现）。
  localPlugin,

  /// 用户手填的远端 HTTP 端点（ServerEndpointStore）。
  remoteEndpoint,
}

/// 已注册 MCP 服务（注册态快照，不含工具；工具经 [McpCatalog.loadServerTools] 按需拉）。
class McpCatalogService {
  const McpCatalogService({
    required this.serverId,
    required this.label,
    required this.source,
    this.local,
    this.remote,
  });

  /// 路由主键。
  final String serverId;

  /// 展示名（serverTitle / name 缺省回退 serverId）。
  final String label;
  final CatalogSource source;

  /// 本地插件实体（source==localPlugin 时非空；拉工具用 createClient）。
  final LocalPluginInfo? local;

  /// 远端端点实体（source==remoteEndpoint 时非空；含隐私分层 tier）。
  final ServerEndpoint? remote;

  /// 来源/隐私标注文案（MC4：「远程和私有只是一个标注」）。
  String get sourceLabel => switch (source) {
        CatalogSource.localPlugin => '本地',
        CatalogSource.remoteEndpoint =>
          remote!.tier == ServerPrivacyTier.private ? '远程·私有' : '远程·公开',
      };

  /// 是否可信（本地同签名私有生态自动信任）。
  bool get trusted =>
      source == CatalogSource.localPlugin && (local?.sameSignature ?? false);
}

/// 工具条目（含三态可见性）。
class McpCatalogTool {
  const McpCatalogTool({
    required this.name,
    required this.description,
    required this.visibility,
    required this.declared,
  });

  /// 从 `tools/list` Schema 投影（保留「是否显式声明」以撑三态 pill）。
  factory McpCatalogTool.fromSchema(CloudToolSchema s) {
    final meta = s.meta;
    final goodhub = meta is Map<String, Object?> ? meta['goodhub'] : null;
    final declared = goodhub is Map && goodhub['visibility'] is String;
    return McpCatalogTool(
      name: s.name,
      description: s.description,
      visibility: s.visibility,
      declared: declared,
    );
  }

  final String name;
  final String description;
  final ToolVisibility visibility;

  /// 是否在 `tools/list` 显式声明了 `_meta.goodhub.visibility`。
  /// false = SDK<0.2.0 存量插件兜底（行为同 private，但 UI 标「未声明」防误判插件坏）。
  final bool declared;
}

/// 目录取数收口（注入位：测试可整体替换 discovery / endpointStore / runtime）。
/// F16（review-fix-2026-10）：[endpointStore] **必传**——原缺省回退引
/// app/service_directory（coordinator→app 反向边，矩阵红灯）；装配属窗口职责
/// （ui→app 合法），调用方显式传入。
class McpCatalog {
  McpCatalog({
    required this.endpointStore,
    LocalPluginSource? discovery,
    McpRuntime? runtime,
  })  : discovery = discovery ?? localPluginDiscovery,
        runtime = runtime ?? const McpRuntime();

  final LocalPluginSource discovery;
  final Future<ServerEndpointStore> Function({String? supportPath}) endpointStore;
  final McpRuntime runtime;

  /// 已注册服务清单（静态注册态，不依赖连接）：本地插件 + 远端端点。
  Future<List<McpCatalogService>> loadRegisteredServices() async {
    final locals = await discovery.scan();
    final store = await endpointStore();
    final remotes = await store.load();
    return [
      for (final info in locals)
        if (info.serverId.isNotEmpty)
          McpCatalogService(
            serverId: info.serverId,
            label: info.serverTitle.isEmpty ? info.serverId : info.serverTitle,
            source: CatalogSource.localPlugin,
            local: info,
          ),
      for (final ep in remotes)
        if (ep.id.isNotEmpty && ep.enabled)
          McpCatalogService(
            serverId: ep.id,
            label: ep.name.isEmpty ? ep.id : ep.name,
            source: CatalogSource.remoteEndpoint,
            remote: ep,
          ),
    ];
  }

  /// 单服务工具拉取：挂载 → listTools → 释放（纯浏览，不常驻连接）。
  ///
  /// 失败上抛，由调用方（UI 卡片）按单服务降级（不阻断其他服务）。
  Future<List<McpCatalogTool>> loadServerTools(McpCatalogService svc) async {
    final List<CloudToolSchema> schemas;
    switch (svc.source) {
      case CatalogSource.localPlugin:
        final info = svc.local!;
        final client = discovery.createClient(info);
        try {
          // 步 2-1：挂载原语收敛（client→negotiate→face→listTools）。
          final m = await runtime.mount(
            serverId: info.serverId,
            client: client,
            release: client.close,
          );
          schemas = m.schemas;
          m.close(); // 浏览面拉完即释放，无需常驻 face
        } on Object {
          client.close(); // 挂载失败 → 释放本方创建的 client
          rethrow;
        }
      case CatalogSource.remoteEndpoint:
        final ep = svc.remote!;
        final store = await endpointStore();
        final m = await runtime.mountEndpoint(
          ep,
          apiKeyReader: store.apiKey,
        );
        schemas = m.schemas;
        m.close();
    }
    return [for (final s in schemas) McpCatalogTool.fromSchema(s)];
  }
}
