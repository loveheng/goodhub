/// 设置页（2026-10-16 合并改名词：原「服务大厅」，名词映射见
/// docs/design/page-revamp.md）。M3-T4 建页（architecture §5「服务与配置大厅」
/// 的 M3 交付面；形态 = ui-design §3.3 控制台式卡片阵列），M4-T5 增 BYOK /
/// 节点卡面板，2026-10-16 合并聊天页 ⚙ 设置弹层后定稿六段；**2026-10-16 方案 A
/// 撤销「默认私有服务」独立 radio 面板**（HCI 评估：该面板无独立数据源，候选集
/// 是 ②③ 的二次渲染，同屏双份+四层作用域过载）——默认钉选降级为 ②③ 卡片行内
/// 「图钉按钮 + 默认私有 pill」，存储键 `default.private.server` 与回退链不变。
///
/// **本页 scope（边界声明——防无边界膨胀）**：设置 = **服务与引擎配置**，仅收纳
/// 下列六段。记忆看板（`MemoryBoardPage`）、应用更新（`UpdatePage`）、会话历史
/// 均为独立页，入口在聊天页侧边栏 / AppBar，**不并入本页**——名字变宽不等于
/// 职责变宽。
///
/// ① **云端模型（BYOK）**——段 widget `sections/byok_section.dart`；
/// ② **MCP 服务端点（节点卡）**——段 widget `sections/nodes_section.dart`；
/// ③ **本地插件**——段 widget `sections/local_plugins_section.dart`；
/// ④ **PC 远程网关**——段 widget `sections/gateway_section.dart`；
/// ⑤ **Skill 覆写（CoW 编辑面）**——段 widget `sections/cow_section.dart`；
/// ⑥ **跨源授权语义**——段 widget `sections/cross_source_section.dart`；
/// ⑦ **关于**——段 widget `sections/about_section.dart`。
///
/// **window-slim P1-A（2026-10-17）：六段全部抽出，本页只留两类职责**——
/// ① 页面骨架（ListView 顺序/间距 + AppBar）；② **跨段共享 owner**：默认私有
/// 服务钉选的持久读写（②③ 共用同一默认键）与 toast/错误行口径。各段自持领域
/// 态与编排，页面不再持有任何 TextEditingController / store / 探活状态。
/// 详见各段文件头的「迁移语义原样保留」声明与 `docs/design/window-slim.md`。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../coordinator/cow_sync.dart';
import '../../llm/cloud/byok_store.dart';
import '../../mcp/default_private_server.dart';
import '../../mcp/local_plugin_discovery.dart';
import '../../mcp/server_endpoints.dart';
import 'sections/about_section.dart';
import 'sections/byok_section.dart';
import 'sections/cow_section.dart';
import 'sections/cross_source_section.dart';
import 'sections/gateway_section.dart';
import 'sections/local_plugins_section.dart';
import 'sections/nodes_section.dart';
import 'sections/appearance_section.dart';
import 'tokens/console_tokens.dart';

/// 测试兼容位：既有节点卡面板测试经 `ui/settings_page.dart` 引用探活入口类型
/// （`server_nodes_panel_test.dart:60`）——typedef 已随段迁至 nodes_section，
/// 此处转出以保持等价回归网零改动，勿在测试中改引路径。
export 'sections/nodes_section.dart' show NodeProbeFn;

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    this.storeOverride,
    this.byokStoreOverride,
    this.endpointStoreOverride,
    this.probeOverride,
    this.autoProbe = true,
    this.localScanOverride,
    this.localChangesOverride,
  });

  /// 测试注入位；null = 生产路径（应用文档目录）。透传 CoW 段。
  final CowOverridesStore? storeOverride;

  /// 测试注入位（M4-T5 BYOK 面板）；null = 生产路径（默认安全存储装配）。
  /// 透传云端引擎段。
  final ByokStore? byokStoreOverride;

  /// 测试注入位（M4-T5 节点卡）；null = 生产路径（应用支持目录
  /// /mcp_servers.json，与聊天页 ⚙ 设置同一文件）。透传节点卡段。
  final ServerEndpointStore? endpointStoreOverride;

  /// 测试注入位（M4-T5 节点卡）；null = 生产路径（[ServerProber] 真探活）。
  final NodeProbeFn? probeOverride;

  /// 进入页面自动探活一次（P2；测试注入假探活时置 false 关掉，免干扰计数断言）。
  final bool autoProbe;

  /// 测试注入位（本地插件面板）：null = 生产路径（[localPluginDiscovery] 经
  /// Binder 通道拉扫同机插件）；测试传假 scan 免去真机通道依赖。
  final Future<List<LocalPluginInfo>> Function()? localScanOverride;

  /// 测试注入位（本地插件面板）；null = 生产路径（[localPluginDiscovery.changes]）。
  final Stream<void>? localChangesOverride;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  // —— 默认私有服务（统一钉选，覆盖手动端点 + 本地插件；持久于 SharedPreferences）——
  // 方案 A（2026-10-16）：独立 radio 面板撤销，钉选态降级为 ②③ 卡片行内
  // （图钉按钮 + 「默认私有」pill）——空 = 无默认（纯公共回退）。
  // **本态是页面最后一个领域态**：②③ 两段共用同一默认键，钉选 owner 留在页面
  // （跨段一致的唯一裁定点），渲染仍在各段卡片行内。
  var _defaultPrivateId = '';

  @override
  void initState() {
    super.initState();
    unawaited(_loadDefaultPrivate());
  }

  /// 默认私有服务钉选读取（独立初始化：失败按空，不拖垮页面）。
  Future<void> _loadDefaultPrivate() async {
    try {
      final def = await readDefaultPrivateServerId();
      if (mounted) setState(() => _defaultPrivateId = def ?? '');
    } on Object catch (e) {
      debugPrint('[DEGRADE] default-private: 读取失败按无默认: $e');
    }
  }

  /// 当前卡片是否为持久默认（空 id 永假——防空串与「无默认」初始态误判）。
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
      await writeDefaultPrivateServerId(null);
      if (mounted) setState(() => _defaultPrivateId = '');
      _flash('✓ 已取消默认私有服务（新会话按纯公共/首私有回退）');
    } on Object catch (e) {
      _flash('⚠ 默认私有服务保存失败: $e');
    }
  }

  void _flash(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  /// 面板级错误态（ux-hardening P0-3）：Rose 文案 + 重试按钮。替代两种历史
  /// 病：一处初始化失败打死整页（其余面板可用被替换）；store 读取失败后
  /// `store == null` 永显「读取中…」（错误不可见、无恢复入口）。
  Widget _panelError(
    ConsoleTokens t,
    String message,
    VoidCallback onRetry, {
    ValueKey<String>? key,
  }) {
    return Padding(
      key: key,
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '⚠ $message',
            style: TextStyle(fontSize: Fsz.telemetry, color: t.danger),
          ),
          const SizedBox(height: 2),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              key: key == null ? null : ValueKey('${key.value}-retry'),
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('重试'),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // ignore: avoid_print
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      // ux-hardening P0-3：面板初始化失败不再打死整页——各面板自持错误态
      // （Rose + 重试），此处恒渲染完整面板列表。
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          // 全局外观（暗/亮/暖）置于顶部：跨段、最先被用户调整。
          const AppearanceSection(),
          const SizedBox(height: 12),
          // 顺序按使用频率：先选引擎，再接服务，后管放行与覆写。
          ByokSection(
            store: widget.byokStoreOverride ?? ByokStore(),
            onFlash: _flash,
            errorRowBuilder: _panelError,
          ),
          const SizedBox(height: 12),
          NodesSection(
            endpointStoreOverride: widget.endpointStoreOverride,
            probeOverride: widget.probeOverride,
            autoProbe: widget.autoProbe,
            isDefaultPrivate: _isDefaultPrivate,
            onPinToggle: (id, label, isDefault) =>
                isDefault ? _clearDefaultPrivate() : _setDefaultPrivate(id, label),
            onFlash: _flash,
            errorRowBuilder: _panelError,
          ),
          const SizedBox(height: 12),
          LocalPluginsSection(
            scan: widget.localScanOverride ?? localPluginDiscovery.scan,
            changes: widget.localChangesOverride ?? localPluginDiscovery.changes,
            isDefaultPrivate: _isDefaultPrivate,
            onPinToggle: (id, label, isDefault) =>
                isDefault ? _clearDefaultPrivate() : _setDefaultPrivate(id, label),
            onFlash: _flash,
            errorRowBuilder: _panelError,
          ),
          const SizedBox(height: 12),
          GatewaySection(onFlash: _flash),
          const SizedBox(height: 12),
          CowSection(
            storeOverride: widget.storeOverride,
            onFlash: _flash,
            errorRowBuilder: _panelError,
          ),
          const SizedBox(height: 12),
          const CrossSourceSection(),
          const SizedBox(height: 12),
          const AboutSection(),
        ],
      ),
    );
  }
}
