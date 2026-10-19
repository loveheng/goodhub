/// 设置页 · 全局 Prompt 管理段（prompt-mgmt §3.3/§8.2.4，2026-10-19 新建：
/// user 来源全局 prompt 的 UI 编辑/持久化入口）：
/// appScoped 覆写管 server 模板（CoW），本段管 **user 全局 prompt**——
/// `SkillSource.user` × `SkillScope.global`，注册名 `user/<name>`，随基础
/// SkillRegistry 落盘装载，对新会话生效。
///
/// 纪律（口径 SSOT：docs/design/prompt-mgmt.md）：
/// - **Token 水位单源**（§8.2.4）：实时 `N/300 Tokens` 复用 core/tokens.dart
///   字符级粗估（与 kGlobalSkillBudgetTokens 注册闸同源），禁 UI 侧另写估算；
///   超限实时变红 + 禁用保存，拦截时严禁清空输入框；
/// - **存盘边界清洗**（§8.2.5）：伪造系统边界标记在 store 落盘前转义/剥除，
///   清洗计数回传经 toast 可见通告；
/// - **fail-closed 容灾**（§8.2.3）：存储损坏不打死面板——备份警示 + 按空表
///   显示（对齐 cow_section P2-1 口径）；
/// - 面板级错误态（ux-hardening P0-3：Rose + 重试），ListView 懒构建 keepAlive。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../coordinator/skill_registry.dart';
import '../../coordinator/user_prompt_store.dart';
import '../../core/tokens.dart';
import '../tokens/console_tokens.dart';

/// 段 widget：注入 [storeOverride]（生产 = `UserGlobalPromptsStore(dir: documents)`，
/// 测试传假件）、[onFlash]（页面级 toast 口径）、[errorRowBuilder]（面板级错误态统一件）。
class UserPromptsSection extends StatefulWidget {
  const UserPromptsSection({
    super.key,
    this.storeOverride,
    required this.onFlash,
    required this.errorRowBuilder,
  });

  /// 测试注入位；null = 生产路径（应用文档目录）。
  final UserGlobalPromptsStore? storeOverride;

  final void Function(String message) onFlash;

  /// 面板级错误态（ux-hardening P0-3 口径：Rose 文案 + 重试入口）。
  final Widget Function(ConsoleTokens t, String message, VoidCallback onRetry,
      {ValueKey<String>? key}) errorRowBuilder;

  @override
  State<UserPromptsSection> createState() => _UserPromptsSectionState();
}

class _UserPromptsSectionState extends State<UserPromptsSection>
    with AutomaticKeepAliveClientMixin {
  /// ListView 懒构建会把滚出视口的 sliver child 销毁重建——段内领域态
  /// （表单输入/错误态）随之丢失。故段一律申请 keepAlive（对齐 cow_section）。
  @override
  bool get wantKeepAlive => true;

  UserGlobalPromptsStore? _store;
  List<UserGlobalPrompt> _entries = const [];
  String? _editingName;
  var _creating = false;
  final _editCtrl = TextEditingController();
  final _newNameCtrl = TextEditingController();
  final _newDescCtrl = TextEditingController();
  final _newContentCtrl = TextEditingController();
  // 面板级错误态（ux-hardening P0-3）：初始化失败不打死整页。
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_bootstrap());
  }

  @override
  void dispose() {
    _editCtrl.dispose();
    _newNameCtrl.dispose();
    _newDescCtrl.dispose();
    _newContentCtrl.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    try {
      final store = widget.storeOverride ??
          UserGlobalPromptsStore(
            dir: await getApplicationDocumentsDirectory(),
          );
      await _reload(store);
      if (mounted) setState(() => _error = null);
    } catch (e) {
      // ignore: avoid_print
      if (mounted) setState(() => _error = '全局 Prompt 库读取失败：$e');
    }
  }

  Future<void> _reload(UserGlobalPromptsStore store) async {
    final entries = await store.load();
    if (mounted) {
      setState(() {
        _store = store;
        _entries = entries;
        _creating = false;
        _editingName = null;
      });
    }
  }

  /// 水位计（§8.2.4）：超预算变红，正常遥测灰。
  Widget _waterLevel(ConsoleTokens t, String content, {String? suffixKey}) {
    final tokens = estimateTokens(content);
    return Text(
      '$tokens/$kGlobalSkillBudgetTokens Tokens',
      key: suffixKey == null ? null : Key(suffixKey),
      style: TextStyle(
        fontFamily: t.monoFamily,
        fontSize: Fsz.telemetrySm,
        color: tokens > kGlobalSkillBudgetTokens ? t.danger : t.terminalMuted,
      ),
    );
  }

  Future<void> _create() async {
    final store = _store;
    if (store == null) return;
    final name = _newNameCtrl.text.trim();
    final invalid = validateUserPromptName(name);
    if (invalid != null) {
      widget.onFlash(invalid);
      return;
    }
    final content = _newContentCtrl.text;
    if (content.trim().isEmpty) {
      widget.onFlash('Prompt 正文不能为空');
      return;
    }
    // §8.2.4：超限禁用保存已由按钮 onPressed 承守；此处双闸防竞态。
    if (estimateTokens(content.trim()) > kGlobalSkillBudgetTokens) {
      widget.onFlash('超 $kGlobalSkillBudgetTokens Tokens 常驻预算，注册将被拒绝');
      return;
    }
    try {
      final sanitized = await store.save(
        name: name,
        content: content,
        description: _newDescCtrl.text,
      );
      _newNameCtrl.clear();
      _newDescCtrl.clear();
      _newContentCtrl.clear();
      await _reload(store);
      widget.onFlash(sanitized > 0
          ? '✓ 已创建 user/$name（已清洗 $sanitized 处伪造边界标记）'
          : '✓ 已创建 user/$name');
    } on ArgumentError catch (e) {
      widget.onFlash('创建失败：${e.message}');
    }
  }

  Future<void> _saveEdit(String name) async {
    final store = _store;
    if (store == null) return;
    final content = _editCtrl.text;
    if (content.trim().isEmpty) {
      widget.onFlash('Prompt 正文不能为空');
      return;
    }
    if (estimateTokens(content.trim()) > kGlobalSkillBudgetTokens) {
      widget.onFlash('超 $kGlobalSkillBudgetTokens Tokens 常驻预算，注册将被拒绝');
      return;
    }
    final desc = _entries
        .firstWhere(
          (e) => e.name == name,
          orElse: () => _entries.first,
        )
        .description;
    try {
      final sanitized = await store.save(
        name: name,
        content: content,
        description: desc,
      );
      await _reload(store);
      widget.onFlash(sanitized > 0
          ? '✓ 已保存 user/$name（已清洗 $sanitized 处伪造边界标记）'
          : '✓ 已保存 user/$name');
    } on ArgumentError catch (e) {
      widget.onFlash('保存失败：${e.message}');
    }
  }

  Future<void> _delete(String name) async {
    final store = _store;
    if (store == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除全局 Prompt'),
        content: Text('删除「user/$name」？下一会话起不再注入系统提示。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await store.delete(name);
    await _reload(store);
    widget.onFlash('✓ 已删除 user/$name');
  }

  Future<void> _loadForEdit(String name) async {
    final content = (_entries.firstWhere((e) => e.name == name)).content;
    if (mounted) {
      setState(() {
        _editCtrl.text = content;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final t = consoleTokens(context);
    final store = _store;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  '全局 Prompt 管理',
                  style: const TextStyle(
                    fontSize: Fsz.sectionTitle,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Text(
                  'user/ ${_entries.length} 项',
                  style: TextStyle(
                    fontFamily: t.monoFamily,
                    fontSize: Fsz.telemetrySm,
                    color: t.terminalMuted,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '用户自定义全局 prompt（注册名 user/<名称>），常驻注入系统提示，'
              '受 $kGlobalSkillBudgetTokens Tokens 常驻预算约束；新建/修改后'
              '对新会话生效。',
              style: TextStyle(
                fontSize: Fsz.telemetrySm,
                color: Theme.of(context).hintColor,
              ),
            ),
            const SizedBox(height: 8),
            // §8.2.3：存储损坏备份警示——不静默按空库，用户可手动找回。
            if (store != null && store.corruptBackupPath != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  '⚠ 配置文件损坏，已隔离备份为 ${store.corruptBackupPath}；'
                  '当前按空表显示，可手动找回备份或重建。',
                  style: TextStyle(fontSize: Fsz.telemetry, color: t.danger),
                ),
              ),
            if (_error != null)
              widget.errorRowBuilder(
                t,
                _error!,
                _bootstrap,
                key: const ValueKey('userprompt-error'),
              )
            else if (store == null)
              const Padding(
                padding: EdgeInsets.all(8),
                // 静态文案不用 spinner（对齐 cow_section：无限动画会让
                // pumpAndSettle 永不收口）。
                child: Center(
                  child: Text(
                    '读取全局 Prompt 库…',
                    style: TextStyle(fontSize: Fsz.telemetry),
                  ),
                ),
              )
            else ...[
              for (final e in _entries) _item(context, t, e),
              if (_entries.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text(
                    '（暂无用户全局 prompt——系统提示仅含内置指令）',
                    style: TextStyle(
                      fontSize: Fsz.telemetry,
                      color: Theme.of(context).hintColor,
                    ),
                  ),
                ),
              if (_creating) _newEditor(context, t),
              if (!_creating)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    key: const Key('userprompt-new'),
                    onPressed: () => setState(() => _creating = true),
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('新建全局 Prompt'),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _item(BuildContext context, ConsoleTokens t, UserGlobalPrompt e) {
    final editing = _editingName == e.name;
    return Container(
      key: Key('userprompt-item-${e.name}'),
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(t.cardRadius),
        border: Border.all(color: t.hairline),
      ),
      child: editing
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'user/${e.name}',
                  style: TextStyle(
                    fontFamily: t.monoFamily,
                    fontSize: Fsz.telemetry,
                  ),
                ),
                const SizedBox(height: 6),
                TextField(
                  key: const Key('userprompt-edit-field'),
                  controller: _editCtrl,
                  maxLines: 6,
                  onChanged: (_) => setState(() {}), // 水位计实时刷新
                  style: TextStyle(
                    fontFamily: t.monoFamily,
                    fontSize: Fsz.telemetry,
                  ),
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    isDense: true,
                    hintText: '全局 prompt 正文（将常驻注入系统提示）',
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    _waterLevel(t, _editCtrl.text,
                        suffixKey: 'userprompt-edit-tokens'),
                    const Spacer(),
                    TextButton(
                      onPressed: () => setState(() => _editingName = null),
                      child: const Text('取消'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      key: const Key('userprompt-save'),
                      // §8.2.4：超预算禁用保存（输入框内容保留，禁清空）。
                      onPressed: estimateTokens(_editCtrl.text.trim()) >
                              kGlobalSkillBudgetTokens
                          ? null
                          : () => _saveEdit(e.name),
                      child: const Text('保存'),
                    ),
                  ],
                ),
              ],
            )
          : Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'user/${e.name}',
                        style: TextStyle(
                          fontFamily: t.monoFamily,
                          fontSize: Fsz.telemetry,
                        ),
                      ),
                      Text(
                        e.description.isEmpty ? '（无描述）' : e.description,
                        style: TextStyle(
                          fontSize: Fsz.telemetrySm,
                          color: Theme.of(context).hintColor,
                        ),
                      ),
                      Text(
                        '${estimateTokens(e.content)}/$kGlobalSkillBudgetTokens Tokens'
                        ' · 更新于 ${e.updatedAt.toIso8601String()}',
                        style: TextStyle(
                          fontFamily: t.monoFamily,
                          fontSize: Fsz.micro,
                          color: t.terminalMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  key: Key('userprompt-edit-${e.name}'),
                  tooltip: '编辑',
                  iconSize: 18,
                  onPressed: () {
                    _editingName = e.name;
                    _loadForEdit(e.name);
                  },
                  icon: const Icon(Icons.edit_outlined),
                ),
                IconButton(
                  key: Key('userprompt-delete-${e.name}'),
                  tooltip: '删除',
                  iconSize: 18,
                  onPressed: () => _delete(e.name),
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
    );
  }

  Widget _newEditor(BuildContext context, ConsoleTokens t) {
    final nameInvalid = _newNameCtrl.text.trim().isNotEmpty &&
        validateUserPromptName(_newNameCtrl.text) != null;
    final overBudget =
        estimateTokens(_newContentCtrl.text.trim()) > kGlobalSkillBudgetTokens;
    return Container(
      key: const Key('userprompt-new-editor'),
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(t.cardRadius),
        border: Border.all(color: t.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const Key('userprompt-new-name'),
            controller: _newNameCtrl,
            onChanged: (_) => setState(() {}),
            style: TextStyle(fontFamily: t.monoFamily, fontSize: Fsz.telemetry),
            decoration: InputDecoration(
              labelText: '名称（注册名 user/<名称>）',
              border: const OutlineInputBorder(),
              isDense: true,
              errorText: nameInvalid ? validateUserPromptName(_newNameCtrl.text) : null,
            ),
          ),
          const SizedBox(height: 6),
          TextField(
            key: const Key('userprompt-new-desc'),
            controller: _newDescCtrl,
            style: TextStyle(fontFamily: t.monoFamily, fontSize: Fsz.telemetry),
            decoration: const InputDecoration(
              labelText: '一句话描述（可选）',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 6),
          TextField(
            key: const Key('userprompt-new-content'),
            controller: _newContentCtrl,
            maxLines: 6,
            onChanged: (_) => setState(() {}), // 水位计实时刷新
            style: TextStyle(
              fontFamily: t.monoFamily,
              fontSize: Fsz.telemetry,
            ),
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              isDense: true,
              hintText: '全局 prompt 正文（将常驻注入系统提示）',
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              _waterLevel(t, _newContentCtrl.text,
                  suffixKey: 'userprompt-new-tokens'),
              const Spacer(),
              TextButton(
                onPressed: () => setState(() => _creating = false),
                child: const Text('取消'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                key: const Key('userprompt-create'),
                // §8.2.4：超预算/名称非法禁用保存（输入保留，禁清空）。
                onPressed: nameInvalid || overBudget ? null : _create,
                child: const Text('创建'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
