/// 设置页（2026-10-16 合并改名词：原「服务大厅」，名词映射见
/// docs/design/page-revamp.md）。M3-T4 建页（architecture §5「服务与配置大厅」
/// 的 M3 交付面；形态 = ui-design §3.3 控制台式卡片阵列），M4-T5 增 BYOK /
/// 节点卡面板，2026-10-16 合并聊天页 ⚙ 设置弹层后定稿六段；**2026-10-16 方案 A
/// 撤销「默认私有服务」独立 radio 面板**（HCI 评估：该面板无独立数据源，候选集
/// 是 ②③ 的二次渲染，同屏双份+四层作用域过载）——默认钉选降级为 ②③ 卡片行内
/// 「图钉按钮 + 默认私有 pill」，存储键 `default.private.server` 与回退链不变。
///
/// **本页 scope（边界声明——防无边界膨胀）**：设置 = **服务与引擎配置**，仅收纳
/// 下列八段。记忆看板（`MemoryBoardPage`）、资源中心（`ResourceCenterPage`）、
/// 任务对账（`TaskLedgerPage`）、应用更新（`UpdatePage`）、会话历史均为独立页，
/// 入口在聊天页侧边栏 / AppBar，**不并入本页**——名字变宽不等于职责变宽。
///
/// 本页 ListView 顺序（自上而下）与各段落点：
/// ① **全局外观**——段 widget `sections/appearance_section.dart`；
/// ② **端侧模型配置**——段 widget `sections/on_device_config_section.dart`；
/// ③ **PC 远程网关**——段 widget `sections/gateway_section.dart`；
/// ④ **Skill 覆写（CoW 编辑面）**——段 widget `sections/cow_section.dart`；
/// ⑤ **全局 Prompt（user 来源管理面）**——段 widget `sections/user_prompts_section.dart`；
/// ⑥ **跨源授权语义**——段 widget `sections/cross_source_section.dart`；
/// ⑦ **关于**——段 widget `sections/about_section.dart`。
///
/// **2026-11-02 IA 二次归位（用户拍板：配置归设置、资产归资源中心）**：云端模型
/// （BYOK）、MCP 服务端点（节点卡）、本地插件、MCP 工具目录已迁资源中心四 tab
/// （见 `resource_center_page.dart`）；端侧模型拆为资产面（资源中心「端侧模型」
/// tab）+ 配置面（本页 ②）；PC 远程网关自资源中心回本页 ③。
///
/// **window-slim P1-A（2026-10-17）：八段全部抽出，本页只留两类职责**——
/// ① 页面骨架（ListView 顺序/间距 + AppBar）；② **跨段共享 owner**：默认私有
/// 服务钉选的持久读写（③④ 共用同一默认键）与 toast/错误行口径。各段自持领域
/// 态与编排，页面不再持有任何 TextEditingController / store / 探活状态。
/// 详见各段文件头的「迁移语义原样保留」声明与 `docs/design/window-slim.md`。
///
/// **2026-10-19 资源中心迁出**：原第七段 `ResourceCenterSection` 移出本页，
/// 独立为 `lib/ui/resource_center_page.dart`（数据管理面）——高频管理动作不该
/// 沉在二级配置页；入口在会话侧边栏底部横排工具带（设置右侧）。
///
/// **2026-10-24 安全存储升级提示**：列表顶部按健康检查插入「安全存储旧密钥
/// 不可读」提示行（检查件 `core/security/secure_storage_upgrade.dart`，注入位
/// `secureHealthOverride`）——flutter_secure_storage 9→11 直升丢密钥事故的
/// 显性化，不占加载态、失败按正常降级。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../coordinator/cow_sync.dart';
import '../../coordinator/user_prompt_store.dart';
import '../../core/security/secure_storage_upgrade.dart';
import 'sections/about_section.dart';
import 'sections/cow_section.dart';
import 'sections/cross_source_section.dart';
import 'sections/gateway_section.dart';
import 'sections/on_device_config_section.dart';
import 'sections/user_prompts_section.dart';
import 'components/panel_error_row.dart';
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
    this.userPromptsStoreOverride,
    this.secureHealthOverride,
  });

  /// 测试注入位；null = 生产路径（应用文档目录）。透传 CoW 段。
  final CowOverridesStore? storeOverride;

  /// 测试注入位（prompt-mgmt §3.3）；null = 生产路径（应用文档目录
  /// /user_global_prompts.json，与 chat_page 装配同一文件）。透传全局 Prompt 段。
  final UserGlobalPromptsStore? userPromptsStoreOverride;

  /// 测试注入位（安全存储升级健康检查，2026-10-24）；null = 生产路径
  /// （[checkSecureStorageHealth]）。判定 legacyDataLost 时列表顶部出行内提示。
  final SecureStorageHealthCheck? secureHealthOverride;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  /// 安全存储升级健康（null = 检查中/未检查；不占加载态，正常态无渲染痕迹）。
  SecureStorageHealth? _secureHealth;

  @override
  void initState() {
    super.initState();
    unawaited(_checkSecureHealth());
  }

  /// 安全存储升级健康检查（独立初始化：失败按正常，不拖垮页面；命中
  /// legacyDataLost 时 build 顶部出行内提示，重试钮 = 重跑本检查）。
  Future<void> _checkSecureHealth() async {
    try {
      final check = widget.secureHealthOverride ?? checkSecureStorageHealth;
      final health = await check();
      if (mounted) setState(() => _secureHealth = health);
    } on Object catch (e) {
      debugPrint('[DEGRADE] secure-storage-health: 设置页检查失败按正常: $e');
    }
  }

  void _flash(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  /// 面板级错误态（ux-hardening P0-3 口径）：统一收敛至 [panelErrorRow]，本页
  /// 只注入自己的 onRetry——避免设置页与资源中心独立页各抄一份实现。
  Widget _panelError(
    ConsoleTokens t,
    String message,
    VoidCallback onRetry, {
    ValueKey<String>? key,
  }) =>
      panelErrorRow(t, message, onRetry, key: key);

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
          // 安全存储升级提示（2026-10-24 事故显性化）：升级后旧密文不可解时
          // 全页置顶 Rose 行——重录密钥后重试检查（或重进页面）即消失。
          if (_secureHealth == SecureStorageHealth.legacyDataLost) ...[
            panelErrorRow(
              consoleTokens(context),
              '应用升级导致安全存储旧密钥不可读：MCP 服务令牌与云端模型密钥需重新录入',
              () => unawaited(_checkSecureHealth()),
              key: const ValueKey('secure-storage-notice'),
            ),
            const SizedBox(height: 12),
          ],
          // 全局外观（暗/亮/暖）置于顶部：跨段、最先被用户调整。
          const AppearanceSection(),
          const SizedBox(height: 12),
          // 端侧模型配置（2026-11-02 自资源中心回迁：用户拍板配置归设置）——
          // 启用偏好 / GenieX 增配运行库 / 电池白名单；资产面（导入/选择/删除）
          // 留在资源中心「端侧模型」tab。
          OnDeviceConfigSection(onFlash: _flash),
          const SizedBox(height: 12),
          // PC 远程网关（2026-11-02 回迁设置：连接配置归设置，不再混在资源中心
          // 「节点与插件」tab）。
          GatewaySection(onFlash: _flash),
          const SizedBox(height: 12),
          // 引擎/服务管理面已迁资源中心四 tab（2026-11-02 能力中心拍板）：
          // 端侧模型→「端侧模型」(资产) / BYOK→「云端引擎」/ 节点/插件→
          // 「节点与插件」。本页保留：外观 / 端侧配置 / PC 远程网关 / CoW /
          // 全局 Prompt / 跨源 / 关于。
          CowSection(
            storeOverride: widget.storeOverride,
            onFlash: _flash,
            errorRowBuilder: _panelError,
          ),
          const SizedBox(height: 12),
          // 全局 Prompt（user 来源）：⑥ CoW 管 server 模板覆写，本段管 user
          // 全局 prompt（prompt-mgmt §3.3）——注册名 user/<name>，新会话生效。
          UserPromptsSection(
            storeOverride: widget.userPromptsStoreOverride,
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
