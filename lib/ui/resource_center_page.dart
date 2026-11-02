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
/// **Tab 演进**：① 2026-10-21 双 tab（文件资源 / MCP 工具目录）② **2026-11-02
/// 能力中心四 tab（用户拍板 B 方案）**：文件资源 / 端侧模型 / 云端引擎 /
/// 节点与插件——云端引擎与节点/插件管理面自设置页全迁（原独立「MCP 工具目录」
/// 段按 serverId 拆解嵌回对应「Server 节点」卡与「本地插件」卡，段数收敛）。
/// tab 形态规范 = ui-design §3.4；内嵌段 = 既有 section 原样复用（禁复制精简副本）。
///
/// **2026-11-02 二次归位（用户拍板：配置归设置、资产归资源中心）**：端侧模型
/// 段拆为「资产面」（本页「端侧模型」tab：导入/选择/删除）+「配置面」
/// （`OnDeviceConfigSection`，回设置页：启用偏好 / GenieX 增配运行库 / 电池
/// 白名单）；PC 远程网关（`GatewaySection`）亦回设置页，不在本页「节点与插件」
/// tab。故「节点与插件」= 节点卡 + 本地插件（各卡内嵌自身工具列表，可折叠 +
/// 三态 pill，均为连接/能力面）。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../app/service_directory.dart';
import '../coordinator/tool_catalog.dart';
import '../mcp/default_private_server.dart';
import '../mcp/local_plugin_discovery.dart';
import 'components/panel_error_row.dart';
import 'sections/byok_section.dart';
import 'sections/local_plugins_section.dart';
import 'sections/nodes_section.dart';
import 'sections/on_device_model_section.dart';
import 'sections/resource_center_section.dart';
import 'tokens/console_tokens.dart';

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
  /// 页面级四 Tab：文件资源 / 端侧模型 / 云端引擎 / 节点与插件
  /// （ui-design §3.4：≤4，超限先合并职责）。
  late final TabController _tabs = TabController(length: 4, vsync: this);

  /// 工具目录取数收口（生产默认；测试可整体替换内部 discovery/endpointStore/runtime）。
  // F16：endpointStore 注入（coordinator 不再回退 app 工厂——反向边斩断）。
  final McpCatalog _catalog = McpCatalog(endpointStore: serverEndpointStore);

  /// 默认私有服务 id（节点/插件段 pin 回调的状态源——自设置页 lifting；
  /// 读写单源 = default_private_server.dart，与设置页时期同款）。
  var _defaultPrivateId = '';

  /// 段内动作反馈（导入成功/失败等）走页面级 toast，与设置页口径一致。
  void _flash(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  @override
  void initState() {
    super.initState();
    unawaited(_loadDefaultPrivate());
  }

  Future<void> _loadDefaultPrivate() async {
    try {
      final def = await readDefaultPrivateServerId();
      if (mounted) setState(() => _defaultPrivateId = def ?? '');
    } on Object catch (e) {
      debugPrint('[DEGRADE] resource-center: default private id: $e');
    }
  }

  bool _isDefaultPrivate(String id) => id.isNotEmpty && _defaultPrivateId == id;

  Future<void> _setDefaultPrivate(String id, String label) async {
    try {
      await writeDefaultPrivateServerId(id);
      if (mounted) setState(() => _defaultPrivateId = id);
      _flash('✓ 已设默认私有服务：$label');
    } on Object catch (e) {
      _flash('⚠ 默认私有服务保存失败: $e');
    }
  }

  Future<void> _clearDefaultPrivate() async {
    try {
      await writeDefaultPrivateServerId('');
      if (mounted) setState(() => _defaultPrivateId = '');
      _flash('✓ 已取消默认私有服务（新会话按纯公共/首私有回退）');
    } on Object catch (e) {
      _flash('⚠ 默认私有服务保存失败: $e');
    }
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = consoleTokens(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('资源中心'),
        bottom: TabBar(
          controller: _tabs,
          // ui-design §3.4：选中 = l2Accent 文字 + 2dp accent 下划线；
          // 未选中 = terminalMuted；标签遥测轨字号（compact，窄栏不挤）。
          labelColor: t.l2Accent,
          unselectedLabelColor: t.terminalMuted,
          indicatorColor: t.l2Accent,
          indicatorWeight: 2,
          labelStyle: const TextStyle(fontSize: Fsz.telemetry),
          unselectedLabelStyle: const TextStyle(fontSize: Fsz.telemetry),
          tabs: const [
            Tab(text: '文件资源'),
            Tab(text: '端侧模型'),
            Tab(text: '云端引擎'),
            Tab(text: '节点与插件'),
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
          ListView(
            padding: const EdgeInsets.all(12),
            children: [
              OnDeviceModelSection(
                onFlash: _flash,
                errorRowBuilder: panelErrorRow,
              ),
            ],
          ),
          ListView(
            padding: const EdgeInsets.all(12),
            children: [
              ByokSection(
                store: byokStore(),
                onFlash: _flash,
                errorRowBuilder: panelErrorRow,
              ),
            ],
          ),
          ListView(
            padding: const EdgeInsets.all(12),
            children: [
              NodesSection(
                catalog: _catalog,
                isDefaultPrivate: _isDefaultPrivate,
                onPinToggle: (id, label, isDefault) =>
                    isDefault ? _clearDefaultPrivate() : _setDefaultPrivate(id, label),
                onFlash: _flash,
                errorRowBuilder: panelErrorRow,
              ),
              const SizedBox(height: 12),
              LocalPluginsSection(
                catalog: _catalog,
                scan: localPluginDiscovery.scan,
                changes: localPluginDiscovery.changes,
                isDefaultPrivate: _isDefaultPrivate,
                onPinToggle: (id, label, isDefault) =>
                    isDefault ? _clearDefaultPrivate() : _setDefaultPrivate(id, label),
                onFlash: _flash,
                errorRowBuilder: panelErrorRow,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
