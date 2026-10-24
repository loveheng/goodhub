/// 资源中心页（resource-center，2026-10-19 自设置页段迁出为独立页）。
///
/// **迁出理由（IA 归位）**：`settings_page` 文件头边界声明写明「设置 = 服务与
/// 引擎**配置面**」；资源中心是用户资产**数据面**（导入 / 改名 / 删除 / 外部
/// 打开 / 占用展示），二者性质不同。塞在设置页第七段导致：① 高频管理动作
/// 沉在二级配置页；② 为绕开该倒挂在 composer 上另开常驻资源行 → 输入条
/// 堆到 3 行。迁出后职责收敛——**使用面在 composer（run 级），管理面在本页
/// （持久）**，二者不再互为前置。
///
/// **入口** = 会话侧边栏底部横排工具带（「设置」右侧，与 `TaskLedgerPage`
/// 同款先例：原为设置页段，迁出后由抽屉直达）。
///
/// **Tab（2026-10-21 mcp-tools-catalog）**：① 文件资源（原管理面）② MCP 工具
/// 目录（按服务分组展示已注册服务的工具 + 三态可见性；取数经 [McpCatalog]）。
///
/// 内容 widget = [ResourceCenterSection]（与设置页时期同一 widget，store
/// 经注入位传入——视图不持领域单例；生产装配在段内，CowSection 同款）。
library;

import 'package:flutter/material.dart';

import '../app/service_directory.dart';
import '../coordinator/tool_catalog.dart';
import '../mcp/local_plugin_discovery.dart';
import 'components/panel_error_row.dart';
import 'sections/mcp_tools_catalog_section.dart';
import 'sections/resource_center_section.dart';

class ResourceCenterPage extends StatefulWidget {
  const ResourceCenterPage({super.key, this.cachePathOverride});

  /// 测试注入位；null = 生产路径（应用缓存目录，external 临时件挂其下）。
  /// 透传给段——页面不自行解析平台路径（ui 禁 dart:io，goodhub-ui §2-B）。
  final String? cachePathOverride;

  @override
  State<ResourceCenterPage> createState() => _ResourceCenterPageState();
}

class _ResourceCenterPageState extends State<ResourceCenterPage>
    with SingleTickerProviderStateMixin {
  /// 页面级双 Tab：文件资源 / MCP 工具目录（与 memory_board_page AppBar Tab 同先例）。
  late final TabController _tabs =
      TabController(length: 2, vsync: this);

  /// 工具目录取数收口（生产默认；测试可整体替换内部 discovery/endpointStore/runtime）。
  // F16：endpointStore 注入（coordinator 不再回退 app 工厂——反向边斩断）。
  final McpCatalog _catalog = McpCatalog(endpointStore: serverEndpointStore);

  /// 段内动作反馈（导入成功/失败等）走页面级 toast，与设置页口径一致。
  void _flash(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('资源中心'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: '文件资源'),
            Tab(text: 'MCP 工具'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          ListView(
            padding: const EdgeInsets.all(12),
            children: [
              ResourceCenterSection(
                cachePathOverride: widget.cachePathOverride,
                onFlash: _flash,
                errorRowBuilder: panelErrorRow,
              ),
            ],
          ),
          McpToolsCatalogSection(
            catalog: _catalog,
            changes: localPluginDiscovery.changes,
            onFlash: _flash,
            errorRowBuilder: panelErrorRow,
          ),
        ],
      ),
    );
  }
}
