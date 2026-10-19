/// 记忆看板 · 提示词总览段（prompt-mgmt §3.3 透明面，2026-10-19 新建）：
/// 把「全局 Prompt」与「MCP 服务 Prompt」从隐式注入变为**只读可见**——
/// 用户诉求「这些不太透明」的直接回应。编辑仍归设置页两段
/// （`UserPromptsSection` / `CowSection`），本段零写面，防双入口漂移。
///
/// 数据面（不造第二存储，随连接态/落盘）：
/// - **连接态**（MCP 已连接 / 注册表可用）：`SkillRegistry.globals()` /
///   `appScoped()`——实际注入面（官方预置 + user 全局 + CoW 同步产物）；
/// - **离线**（看板先于连接打开 / 注册表不可用）：官方预置 `builtinSkills()`
///   （恒在、静态）+ `UserGlobalPromptsStore`（user 全局，落盘即注册面）+
///   `CowOverridesStore` known_versions/overrides（CoW 上次同步基线；未覆写
///   模板正文来自服务端、不落盘，覆写正文即生效内容——keptLocal 产物携
///   override 正文，见 `cow_sync.dart`）。
///
/// 与「会话」无关：全局提示词随 App 启动即见（内置预置恒在 + user 落盘），
/// MCP 服务提示词随对应服务**连接**出现（appScoped 反映当前已连接服务）。
///
/// 纪律：
/// - UI 零 dart:io（Rule 1）：store 生产路径自解析文档目录（path_provider），
///   测试经 [userStoreOverride]/[cowStoreOverride] 注入（对齐 cow_section）；
/// - 长列表保活：段混 `AutomaticKeepAliveClientMixin`（TabBarView 切走再回
///   不丢加载态，对齐 settings sections 口径）；
/// - 面板级错误态 fail-closed（ux-hardening P0-3）：Rose + 重试，不打死看板；
/// - Token 口径单源：`core/tokens.dart` estimateTokens（与注册闸同源）；
/// - 确定性序：行按 `serverId:name` / 名字典序，注册序/文件枚举序不外泄。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../coordinator/cow_sync.dart';
import '../../coordinator/skill_registry.dart';
import '../../coordinator/user_prompt_store.dart';
import '../../core/tokens.dart';
import '../components/panel_error_row.dart';
import '../tokens/console_tokens.dart';

/// 一条「全局 Prompt」展示行（活态注册面或基线投影统一）。
class _GlobalPromptRow {
  const _GlobalPromptRow({
    required this.name,
    required this.source,
    required this.description,
    required this.content,
    this.updatedAt,
  });

  /// 展示名（`user/<name>` 或官方预置名）。
  final String name;
  final SkillSource source;
  final String description;
  final String content;

  /// user 来源的落盘更新时间（官方预置无）。
  final DateTime? updatedAt;
}

/// 一条「MCP 服务 Prompt」展示行（活态注册面或落盘基线统一投影）。
class _ServerPromptRow {
  const _ServerPromptRow({
    required this.name,
    this.serverId,
    required this.source,
    required this.description,
    required this.content,
    this.version,
    this.overridden = false,
  });

  /// 注册名（`cow/<promptName>` 或官方预置名）。
  final String name;
  final String? serverId;

  /// 来源徽标（builtin 官方预置 / cow CoW 同步）。
  final SkillSource source;
  final String description;

  /// 正文（落盘基线未覆写模板为空串——走占位说明）。
  final String content;
  final String? version;
  final bool overridden;
}

class PromptsOverviewSection extends StatefulWidget {
  const PromptsOverviewSection({
    super.key,
    this.userStoreOverride,
    this.cowStoreOverride,
    this.skillsProvider,
    required this.onFlash,
    required this.errorRowBuilder,
  });

  /// 测试注入位；null = 生产路径（应用文档目录，与设置段同源同规约）。
  final UserGlobalPromptsStore? userStoreOverride;
  final CowOverridesStore? cowStoreOverride;

  /// 连接态 SkillRegistry 提供者（窗口注入 `() => session.skills`——其
  /// globals()/appScoped() 反映当前已连接服务与静态预置，与具体会话内容无关）；
  /// null/返回 null = 注册表不可用（看板先于连接打开）→ 离线模式（官方预置 +
  /// 上次同步落盘基线），非会话概念。
  final SkillRegistry? Function()? skillsProvider;

  final void Function(String message) onFlash;

  /// 面板级错误态（ux-hardening P0-3 口径：Rose 文案 + 重试入口）。
  final PanelErrorRowBuilder errorRowBuilder;

  @override
  State<PromptsOverviewSection> createState() => _PromptsOverviewSectionState();
}

class _PromptsOverviewSectionState extends State<PromptsOverviewSection>
    with AutomaticKeepAliveClientMixin {
  UserGlobalPromptsStore? _userStore;
  CowOverridesStore? _cowStore;
  var _globalRows = const <_GlobalPromptRow>[];
  var _serverRows = const <_ServerPromptRow>[];

  /// 注册表是否可用（false = 离线模式，无连接/未注入）。
  var _registryConnected = false;
  String? _error;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    unawaited(_bootstrap());
  }

  Future<void> _bootstrap() async {
    try {
      final userStore =
          widget.userStoreOverride ??
          UserGlobalPromptsStore(dir: await getApplicationDocumentsDirectory());
      final cowStore =
          widget.cowStoreOverride ??
          CowOverridesStore(dir: await getApplicationDocumentsDirectory());
      await _reload(userStore, cowStore);
      if (mounted) setState(() => _error = null);
    } catch (e) {
      if (mounted) setState(() => _error = '提示词库读取失败：$e');
    }
  }

  Future<void> _reload(
    UserGlobalPromptsStore userStore,
    CowOverridesStore cowStore,
  ) async {
    final userPrompts = await userStore.load();
    final userByName = {for (final p in userPrompts) p.name: p};
    final overrides = await cowStore.overrideNames();
    final registry = widget.skillsProvider?.call();

    // —— 全局 Prompt 行 ——
    final globalRows = <_GlobalPromptRow>[];
    if (registry != null) {
      for (final s in registry.globals()) {
        final bare = s.name.startsWith('user/') ? s.name.substring(5) : s.name;
        globalRows.add(
          _GlobalPromptRow(
            name: s.name,
            source: s.source,
            description: s.description,
            content: s.content,
            updatedAt: userByName[bare]?.updatedAt,
          ),
        );
      }
    } else {
      // 离线：官方预置 global（恒在）+ user 落盘面（落盘即注册面）。
      for (final s in builtinSkills().where(
        (s) => s.scope == SkillScope.global,
      )) {
        globalRows.add(
          _GlobalPromptRow(
            name: s.name,
            source: s.source,
            description: s.description,
            content: s.content,
          ),
        );
      }
      for (final p in userPrompts) {
        globalRows.add(
          _GlobalPromptRow(
            name: 'user/${p.name}',
            source: SkillSource.user,
            description: p.description.isEmpty ? '用户全局 Prompt' : p.description,
            content: p.content,
            updatedAt: p.updatedAt,
          ),
        );
      }
    }
    globalRows.sort((a, b) => a.name.compareTo(b.name));

    // —— MCP 服务 Prompt 行 ——
    final serverRows = <_ServerPromptRow>[];
    if (registry != null) {
      // 连接态面：实际注册进 system 尾块的 appScoped 全集（官方预置 + CoW，
      // 含 keptLocal 覆写产物——override 正文即生效内容）。
      for (final s in registry.appScoped()) {
        final bare = s.name.startsWith('cow/') ? s.name.substring(4) : s.name;
        serverRows.add(
          _ServerPromptRow(
            name: s.name,
            serverId: s.serverId,
            source: s.source,
            description: s.description,
            content: s.content,
            version: await cowStore.knownVersion(bare),
            overridden: overrides.contains(bare),
          ),
        );
      }
    } else {
      // 离线：官方预置 appScoped（恒在、静态）+ CoW 落盘同步基线。
      for (final s in builtinSkills().where(
        (s) => s.scope == SkillScope.appScoped,
      )) {
        serverRows.add(
          _ServerPromptRow(
            name: s.name,
            serverId: s.serverId,
            source: s.source,
            description: s.description,
            content: s.content,
          ),
        );
      }
      for (final n in await cowStore.knownNames()) {
        // 覆写正文即生效内容（持久数据，可直接展示）；未覆写模板正文来自
        // 服务端、不落盘——占位说明，不伪装成空。
        final override = await cowStore.overrideOf(n);
        serverRows.add(
          _ServerPromptRow(
            name: 'cow/$n',
            source: SkillSource.cow,
            description: 'goodshare 模板（CoW 同步）',
            content: override ?? '',
            version: await cowStore.knownVersion(n),
            overridden: override != null,
          ),
        );
      }
    }
    // 确定性序（与 composeSystemPrompt 段内排序同口径：serverId:name，null
    // 归一化空串）——注册序/文件枚举序不外泄。
    serverRows.sort(
      (a, b) => '${a.serverId ?? ''}:${a.name}'.compareTo(
        '${b.serverId ?? ''}:${b.name}',
      ),
    );

    if (mounted) {
      setState(() {
        _userStore = userStore;
        _cowStore = cowStore;
        _globalRows = globalRows;
        _serverRows = serverRows;
        _registryConnected = registry != null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final t = consoleTokens(context);
    final corruptNotes = <String>[
      if (_userStore?.corruptBackupPath != null)
        '全局 Prompt 库文件损坏，已隔离备份为 ${_userStore!.corruptBackupPath}；'
            '当前按空表显示，可手动找回备份或重建。',
      if (_cowStore?.corruptBackupPath != null)
        'CoW 覆写库文件损坏，已隔离备份为 ${_cowStore!.corruptBackupPath}；'
            '当前按空表显示，可手动找回备份或重建。',
    ];
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '全局 Prompt',
            style: const TextStyle(
              fontSize: Fsz.sectionTitle,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '全局 ${_globalRows.length} 项 · 每个新会话常驻注入'
            '（单条 ≤$kGlobalSkillBudgetTokens Tokens）',
            style: TextStyle(
              fontFamily: t.monoFamily,
              fontSize: Fsz.telemetrySm,
              color: t.terminalMuted,
            ),
          ),
          const SizedBox(height: 8),
          if (_error != null)
            widget.errorRowBuilder(
              t,
              _error!,
              _bootstrap,
              key: const ValueKey('prompts-overview-error'),
            )
          else if (_userStore == null)
            const Padding(
              padding: EdgeInsets.all(8),
              // 静态文案不用 spinner（对齐 cow_section：无限动画会让
              // pumpAndSettle 永不收口）。
              child: Center(
                child: Text(
                  '读取提示词库…',
                  style: TextStyle(fontSize: Fsz.telemetry),
                ),
              ),
            )
          else ...[
            for (final note in corruptNotes)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  '⚠ $note',
                  style: TextStyle(fontSize: Fsz.telemetry, color: t.danger),
                ),
              ),
            for (final row in _globalRows) _globalCard(t, row),
            if (_globalRows.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(
                  '（暂无全局 Prompt——官方预置与用户自建将在此列出）',
                  style: TextStyle(
                    fontSize: Fsz.telemetry,
                    color: Theme.of(context).hintColor,
                  ),
                ),
              ),
          ],
          const Divider(height: 28),
          Text(
            'MCP 服务 Prompt',
            style: const TextStyle(
              fontSize: Fsz.sectionTitle,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            'appScoped ${_serverRows.length} 项 · 连接对应服务时注入'
            '（官方预置 / CoW 同步）',
            style: TextStyle(
              fontFamily: t.monoFamily,
              fontSize: Fsz.telemetrySm,
              color: t.terminalMuted,
            ),
          ),
          const SizedBox(height: 8),
          if (!_registryConnected)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                '当前未连接服务（注册表不可用）——展示官方预置 + 上次同步基线；'
                '未覆写模板正文来自服务端、不落盘，连接后展示实际注入内容。',
                key: const Key('prompts-baseline-note'),
                style: TextStyle(fontSize: Fsz.telemetrySm, color: t.l2Warn),
              ),
            ),
          for (final row in _serverRows) _serverCard(t, row),
          if (_serverRows.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(
                '（暂无 MCP 服务 Prompt——Tier 1 服务连接后经 CoW 同步注入）',
                style: TextStyle(
                  fontSize: Fsz.telemetry,
                  color: Theme.of(context).hintColor,
                ),
              ),
            ),
          const SizedBox(height: 8),
          Text(
            '只读总览：编辑请前往 设置 › 全局 Prompt / Skill 覆写。',
            style: TextStyle(fontSize: Fsz.micro, color: t.terminalMuted),
          ),
        ],
      ),
    );
  }

  // —— 来源徽标（global/server 两卡片共用）——

  Widget _sourceBadge(ConsoleTokens t, SkillSource source) {
    final (label, color) = switch (source) {
      SkillSource.builtin => ('官方预置', t.l1Info),
      SkillSource.cow => ('CoW 同步', t.dataRef),
      SkillSource.user => ('用户', t.l1Ok),
    };
    return _badge(t, label, color);
  }

  // —— 全局 Prompt 卡片（官方预置 / user 落盘，常驻注入）——

  Widget _globalCard(ConsoleTokens t, _GlobalPromptRow row) {
    return Container(
      key: Key('prompt-global-${row.name}'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(t.cardRadius),
        border: Border.all(color: t.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            row.name,
            style: TextStyle(fontFamily: t.monoFamily, fontSize: Fsz.telemetry),
          ),
          const SizedBox(height: 2),
          _sourceBadge(t, row.source),
          const SizedBox(height: 2),
          Text(
            row.description.isEmpty ? '（无描述）' : row.description,
            style: TextStyle(
              fontSize: Fsz.telemetrySm,
              color: Theme.of(context).hintColor,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            row.content,
            style: TextStyle(fontFamily: t.monoFamily, fontSize: Fsz.telemetry),
          ),
          const SizedBox(height: 4),
          Text(
            [
              '${estimateTokens(row.content)}/$kGlobalSkillBudgetTokens Tokens',
              if (row.updatedAt != null)
                '更新于 ${row.updatedAt!.toIso8601String()}',
            ].join(' · '),
            style: TextStyle(
              fontFamily: t.monoFamily,
              fontSize: Fsz.micro,
              color: t.terminalMuted,
            ),
          ),
        ],
      ),
    );
  }

  // —— MCP 服务 Prompt 卡片（appScoped：活态注入面 / 落盘基线）——

  Widget _serverCard(ConsoleTokens t, _ServerPromptRow row) {
    return Container(
      key: Key('prompt-server-${row.name}'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(t.cardRadius),
        border: Border.all(color: t.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            row.name,
            style: TextStyle(fontFamily: t.monoFamily, fontSize: Fsz.telemetry),
          ),
          const SizedBox(height: 2),
          // 徽标行：来源 / 服务 / 模板版本 / 本地覆写。
          Wrap(
            spacing: 6,
            runSpacing: 2,
            children: [
              _sourceBadge(t, row.source),
              if (row.serverId != null)
                _badge(t, '[${row.serverId}]', t.terminalMuted),
              if (row.version != null)
                _badge(t, 'v${row.version}', t.terminalMuted),
              if (row.overridden) _badge(t, '本地覆写', t.l2Warn),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            row.description.isEmpty ? '（无描述）' : row.description,
            style: TextStyle(
              fontSize: Fsz.telemetrySm,
              color: Theme.of(context).hintColor,
            ),
          ),
          const SizedBox(height: 4),
          if (row.content.isEmpty)
            Text(
              '（正文来自服务端，未覆写时不落盘——连接后展示实际注入内容）',
              style: TextStyle(
                fontFamily: t.monoFamily,
                fontSize: Fsz.telemetrySm,
                color: t.terminalMuted,
              ),
            )
          else
            Text(
              row.content,
              style: TextStyle(
                fontFamily: t.monoFamily,
                fontSize: Fsz.telemetry,
              ),
            ),
          if (row.content.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '${estimateTokens(row.content)} Tokens',
                style: TextStyle(
                  fontFamily: t.monoFamily,
                  fontSize: Fsz.micro,
                  color: t.terminalMuted,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _badge(ConsoleTokens t, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: t.monoFamily,
          fontSize: Fsz.microSm,
          color: color,
        ),
      ),
    );
  }
}
