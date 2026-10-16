/// 设置页 · Skill 覆写（CoW 编辑面）段（window-slim P1-A 分段拆解，
/// 2026-10-17 自 settings_page 迁出）：覆写库读取、编辑保存（setOverride）、
/// 一键重置、新建表单与卡片渲染全部自持——settings_page 只透传 store 注入位
/// （测试假件）与 flash/错误行回调。
///
/// 迁移语义原样保留（含测试锚点 Key）：
/// - 初始化失败置**面板级**错误态（ux-hardening P0-3：Rose + 重试），不再打死
///   整页；成功即清错误，重试入口 = [_bootstrap] 自身；
/// - 覆写优先级最高（同步需 Server 连接，属节点卡段范围，此处不建同步入口）；
/// - 正文空/超防呆上限在写盘前拒绝（保留用户原输入，仅弹提示）；
/// - P2-1：覆写文件损坏 → 备份路径明示，不再无声按空库。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../coordinator/cow_sync.dart';
import '../tokens/console_tokens.dart';

/// appScoped 覆写正文的防呆上限（无硬预算闸，防呆防手滑）。
const kCowOverrideMaxChars = 10000;

/// 段 widget：注入 [storeOverride]（生产 = `CowOverridesStore(dir: documents)`，
/// 测试传假件）、[onFlash]（页面级 toast 口径）、[errorRowBuilder]（面板级
/// 错误态统一件）。
class CowSection extends StatefulWidget {
  const CowSection({
    super.key,
    this.storeOverride,
    required this.onFlash,
    required this.errorRowBuilder,
  });

  /// 测试注入位；null = 生产路径（应用文档目录）。
  final CowOverridesStore? storeOverride;

  final void Function(String message) onFlash;

  /// 面板级错误态（ux-hardening P0-3 口径：Rose 文案 + 重试入口）。
  final Widget Function(ConsoleTokens t, String message, VoidCallback onRetry,
      {ValueKey<String>? key}) errorRowBuilder;

  @override
  State<CowSection> createState() => _CowSectionState();
}

class _CowSectionState extends State<CowSection>
    with AutomaticKeepAliveClientMixin {
  /// ListView 懒构建会把滚出视口的 sliver child **销毁重建**——段内领域态
  /// （表单输入/错误态/探活结果）随之丢失（拆分前这些态在页面层，天然跨滚动
  /// 存活）。故段一律申请 keepAlive：拆段不得改变「滚动后回到面板仍是原样」
  /// 的用户可见语义。
  @override
  bool get wantKeepAlive => true;


  CowOverridesStore? _store;
  Map<String, DateTime?> _entries = const {};
  String? _editingName;
  final _editCtrl = TextEditingController();
  final _newNameCtrl = TextEditingController();
  final _newContentCtrl = TextEditingController();
  var _creating = false;
  // 面板级错误态（ux-hardening P0-3）：初始化失败不再打死整页——面板内
  // Rose 文案 + 重试入口；面板间无数据依赖，其余照常可用。
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
    _newContentCtrl.dispose();
    super.dispose();
  }

  /// 覆写面板初始化（ux-hardening P0-3）：失败置面板级错误态（Rose + 重试），
  /// 不再打死整页；成功即清错误。重试入口 = 本方法自身。
  Future<void> _bootstrap() async {
    // ignore: avoid_print
    try {
      final store =
          widget.storeOverride ??
          CowOverridesStore(dir: await getApplicationDocumentsDirectory());
      await _reload(store);
      if (mounted) setState(() => _error = null);
    } catch (e) {
      // ignore: avoid_print
      if (mounted) setState(() => _error = '覆写库读取失败：$e');
    }
  }

  Future<void> _reload(CowOverridesStore store) async {
    final names = await store.overrideNames();
    final entries = <String, DateTime?>{};
    for (final n in names) {
      entries[n] = await store.overriddenAt(n);
    }
    if (mounted) {
      setState(() {
        _store = store;
        _entries = entries;
        _creating = false;
        _editingName = null;
      });
    }
  }

  Future<void> _save(String name, String content) async {
    final store = _store;
    if (store == null) return;
    final trimmed = content.trim();
    if (trimmed.isEmpty) {
      widget.onFlash('覆写正文不能为空');
      return;
    }
    if (trimmed.length > kCowOverrideMaxChars) {
      widget.onFlash('覆写正文超防呆上限（$kCowOverrideMaxChars 字符）');
      return;
    }
    await store.setOverride(name, trimmed);
    await _reload(store);
  }

  Future<void> _reset(String name) async {
    final store = _store;
    if (store == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重置覆写'),
        content: Text('弃用「$name」的本地覆写副本？下次模板同步将回 server 版。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('重置'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await store.reset(name);
    await _reload(store);
  }

  Future<void> _loadForEdit(String name) async {
    final content = await _store?.overrideOf(name);
    if (mounted) {
      setState(() {
        _editCtrl.text = content ?? '';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final t = consoleTokens(context);
    final store = _store;
    // ignore: avoid_print
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
                  'Skill 覆写管理',
                  style: const TextStyle(
                    fontSize: Fsz.sectionTitle,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Text(
                  '覆写 ${_entries.length} 项',
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
              '官方模板（goodshare prompts）的本地覆写副本，优先级最高；'
              '官方模板大版本更新时，同步流会弹卡让你选重置或保留本地改法。',
              style: TextStyle(
                fontSize: Fsz.telemetrySm,
                color: Theme.of(context).hintColor,
              ),
            ),
            const SizedBox(height: 8),
            // P2-1：覆写文件损坏备份警示——旧行为是用户手改变的配置被无声
            // 清空（按空库重写），现在备份保留 + 面板明示。
            if (store != null && store.corruptBackupPath != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  '⚠ 覆写文件损坏，已备份为 ${store.corruptBackupPath}；'
                  '当前按空库显示，可手动找回备份。',
                  style: TextStyle(fontSize: Fsz.telemetry, color: t.danger),
                ),
              ),
            if (_error != null)
              widget.errorRowBuilder(
                t,
                _error!,
                _bootstrap,
                key: const ValueKey('cow-error'),
              )
            else if (store == null)
              const Padding(
                padding: EdgeInsets.all(8),
                // 静态文案不用 spinner：无限动画会让 pumpAndSettle 永不收口，
                // 且加载是瞬时路径（本地文件读），控制台风格无 spin 语义。
                child: Center(
                  child: Text(
                    '读取覆写库…',
                    style: TextStyle(fontSize: Fsz.telemetry),
                  ),
                ),
              )
            else ...[
              for (final name in _entries.keys) _cowItem(context, t, name),
              if (_entries.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text(
                    '（暂无覆写——模板按 server 版生效）',
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
                    key: const Key('cow-new'),
                    onPressed: () => setState(() => _creating = true),
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('新建覆写'),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _cowItem(BuildContext context, ConsoleTokens t, String name) {
    final editing = _editingName == name;
    final at = _entries[name];
    return Container(
      key: Key('cow-item-$name'),
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
                  name,
                  style: TextStyle(
                    fontFamily: t.monoFamily,
                    fontSize: Fsz.telemetry,
                  ),
                ),
                const SizedBox(height: 6),
                TextField(
                  key: const Key('cow-edit-field'),
                  controller: _editCtrl,
                  maxLines: 6,
                  style: TextStyle(
                    fontFamily: t.monoFamily,
                    fontSize: Fsz.telemetry,
                  ),
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    isDense: true,
                    hintText: '覆写正文（markdown，与模板同构）',
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => setState(() => _editingName = null),
                      child: const Text('取消'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      key: const Key('cow-save'),
                      onPressed: () => _save(name, _editCtrl.text),
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
                        name,
                        style: TextStyle(
                          fontFamily: t.monoFamily,
                          fontSize: Fsz.telemetry,
                        ),
                      ),
                      if (at != null)
                        Text(
                          '覆写于 ${at.toIso8601String()}',
                          style: TextStyle(
                            fontSize: Fsz.micro,
                            color: t.terminalMuted,
                          ),
                        ),
                    ],
                  ),
                ),
                IconButton(
                  key: Key('cow-edit-$name'),
                  tooltip: '编辑',
                  iconSize: 18,
                  onPressed: () {
                    _editingName = name;
                    _editCtrl.text = '';
                    _loadForEdit(name);
                  },
                  icon: const Icon(Icons.edit_outlined),
                ),
                IconButton(
                  key: Key('cow-reset-$name'),
                  tooltip: '一键重置',
                  iconSize: 18,
                  onPressed: () => _reset(name),
                  icon: const Icon(Icons.restart_alt_outlined),
                ),
              ],
            ),
    );
  }

  Widget _newEditor(BuildContext context, ConsoleTokens t) => Container(
    key: const Key('cow-new-editor'),
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
          key: const Key('cow-new-name'),
          controller: _newNameCtrl,
          style: TextStyle(fontFamily: t.monoFamily, fontSize: Fsz.telemetry),
          decoration: const InputDecoration(
            labelText: '模板名（prompts/list 的 name）',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          key: const Key('cow-new-content'),
          controller: _newContentCtrl,
          maxLines: 6,
          style: TextStyle(fontFamily: t.monoFamily, fontSize: Fsz.telemetry),
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            isDense: true,
            hintText: '覆写正文（markdown，与模板同构）',
          ),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: () => setState(() => _creating = false),
              child: const Text('取消'),
            ),
            const SizedBox(width: 8),
            FilledButton(
              key: const Key('cow-create'),
              onPressed: () {
                final name = _newNameCtrl.text.trim();
                if (name.isEmpty) {
                  widget.onFlash('模板名不能为空');
                  return;
                }
                _save(name, _newContentCtrl.text);
              },
              child: const Text('创建'),
            ),
          ],
        ),
      ],
    ),
  );
}
