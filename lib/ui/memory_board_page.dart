/// 记忆看板（M4-T5，F5.3+F4.3：查看/编辑/导出/粉碎；D7 ops.log 人类可读
/// 渲染位）。形态 = ui-design §3.3 控制台式卡片，三 Tab：
/// ① **记忆条目**——memory.md 全量（落盘态直读，无缓存）；条目级编辑
///    （锚点保留，防破坏 D8 作用域与 FC1 迁移锚）与删除；
/// ② **踩坑教训**——lessons.md 同构（D5 同解析器）；
/// ③ **操作审计**——ops.log JSONL 最新优先渲染（D7 拍板：机器可查可筛的
///    人类可读面在此）。
/// AppBar 动作：**导出**（全量原文含锚点进剪贴板，FC1 备份可恢复）+
/// **粉碎**（user 级全清，srv 绑定条目保留——danger 二次确认）。
/// UI 层零 dart:io（Rule 1）：store 经 [MemoryStore.underSupportDir] 装配，
/// 测试注入 [storeOverride]。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../sandbox/memory_store.dart';
import 'tokens/console_tokens.dart';

class MemoryBoardPage extends StatefulWidget {
  const MemoryBoardPage({super.key, this.storeOverride});

  /// 测试注入位；null = 生产路径（应用支持目录/memory）。
  final MemoryStore? storeOverride;

  @override
  State<MemoryBoardPage> createState() => _MemoryBoardPageState();
}

class _MemoryBoardPageState extends State<MemoryBoardPage>
    with SingleTickerProviderStateMixin {
  MemoryStore? _store;
  late final TabController _tabs = TabController(length: 3, vsync: this);
  var _memories = const <MemoryEntry>[];
  var _lessons = const <MemoryEntry>[];
  var _ops = const <OpsLogLine>[];
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    try {
      final store =
          widget.storeOverride ??
          MemoryStore.underSupportDir(
            (await getApplicationSupportDirectory()).path,
          );
      await _reload(store);
    } catch (e) {
      if (mounted) setState(() => _error = '记忆库初始化失败: $e');
    }
  }

  Future<void> _reload(MemoryStore store) async {
    final memories = await store.listMemories();
    final lessons = await store.listLessons();
    final ops = await store.listOpsLog();
    if (mounted) {
      setState(() {
        _store = store;
        _memories = memories;
        _lessons = lessons;
        _ops = ops;
      });
    }
  }

  void _flash(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = consoleTokens(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('记忆看板'),
        actions: [
          IconButton(
            key: const Key('mb-export'),
            tooltip: '导出全量（含锚点）',
            icon: const Icon(Icons.ios_share_outlined),
            onPressed: _export,
          ),
          IconButton(
            key: const Key('mb-purge'),
            tooltip: '粉碎用户级记忆',
            icon: Icon(Icons.delete_sweep_outlined, color: t.danger),
            onPressed: _purgeUserScope,
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: '记忆条目'),
            Tab(text: '踩坑教训'),
            Tab(text: '操作审计'),
          ],
        ),
      ),
      body: _error != null
          ? Center(
              child: Text(_error!, style: TextStyle(color: t.danger)),
            )
          : _store == null
          ? const Center(
              child: Text('读取记忆库…', style: TextStyle(fontSize: Fsz.telemetry)),
            )
          : TabBarView(
              controller: _tabs,
              children: [
                _entriesTab(t, _memories, lessons: false),
                _entriesTab(t, _lessons, lessons: true),
                _opsTab(t),
              ],
            ),
    );
  }

  // —— Tab ①②：记忆 / 教训条目面 ——

  Widget _entriesTab(
    ConsoleTokens t,
    List<MemoryEntry> entries, {
    required bool lessons,
  }) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        if (entries.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(
              lessons ? '（暂无教训条目）' : '（暂无记忆条目——Agent 写入后将在此出现）',
              style: const TextStyle(fontSize: Fsz.telemetry),
            ),
          ),
        for (final e in entries.reversed) // 最新在上（与审计 Tab 同视角）
          _entryCard(t, e, lessons: lessons),
      ],
    );
  }

  Widget _entryCard(ConsoleTokens t, MemoryEntry e, {required bool lessons}) {
    final ts = e.ts == null
        ? null
        : _fmtTs(DateTime.fromMillisecondsSinceEpoch(e.ts!));
    final hasAnchor = e.id != null;
    return Container(
      key: Key('mb-item-${e.id ?? 'raw'}-${lessons ? 'l' : 'm'}'),
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
            e.content,
            style: TextStyle(fontFamily: t.monoFamily, fontSize: Fsz.telemetry),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(
                  [
                    hasAnchor ? e.id! : '（无锚点·手写）',
                    e.scope == 'user' ? 'user' : e.scope,
                    if (e.tags.isNotEmpty) '[${e.tags.join(',')}]',
                    ?ts,
                  ].join(' · '),
                  style: TextStyle(
                    fontFamily: t.monoFamily,
                    fontSize: Fsz.microSm,
                    color: t.terminalMuted,
                  ),
                ),
              ),
              if (hasAnchor) ...[
                IconButton(
                  key: Key('mb-edit-${e.id}'),
                  tooltip: '编辑',
                  iconSize: 18,
                  onPressed: () => _editEntry(e, lessons: lessons),
                  icon: const Icon(Icons.edit_outlined),
                ),
                IconButton(
                  key: Key('mb-del-${e.id}'),
                  tooltip: '删除该条',
                  iconSize: 18,
                  onPressed: () => _deleteEntry(e, lessons: lessons),
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _editEntry(MemoryEntry e, {required bool lessons}) async {
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => _EditEntryDialog(
        title: '编辑${lessons ? '教训' : '记忆'} ${e.id}',
        initial: e.content,
      ),
    );
    if (_store == null) return;
    if (text == null) return; // 取消
    if (text.trim().isEmpty) {
      _flash('正文不能为空');
      return;
    }
    final ok = await _store!.updateEntry(e.id!, text, lessons: lessons);
    if (!ok) {
      _flash('条目不存在（可能已被删除）');
    }
    await _reload(_store!);
    _flash(ok ? '✓ 已更新 ${e.id}' : '⚠ 更新失败');
  }

  Future<void> _deleteEntry(MemoryEntry e, {required bool lessons}) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除${lessons ? '教训' : '记忆'} ${e.id}'),
        content: Text('删除该条目？正文：${_preview(e.content)}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('mb-del-confirm'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || _store == null) return;
    final ok = await _store!.deleteEntry(e.id!, lessons: lessons);
    await _reload(_store!);
    _flash(ok ? '✓ 已删除 ${e.id}' : '⚠ 条目不存在');
  }

  // —— Tab ③：操作审计面（D7 JSONL → 人类可读行） ——

  Widget _opsTab(ConsoleTokens t) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        if (_ops.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Text('（暂无审计记录）', style: TextStyle(fontSize: Fsz.telemetry)),
          ),
        for (final line in _ops)
          Container(
            margin: const EdgeInsets.only(bottom: 4),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(t.cardRadius),
              border: Border.all(color: t.hairline),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      line.ok ? '✓' : '✗',
                      style: TextStyle(
                        fontSize: Fsz.telemetry,
                        fontWeight: FontWeight.w600,
                        color: line.ok ? t.l1Ok : t.danger,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${line.tool} @${line.server}',
                        style: TextStyle(
                          fontFamily: t.monoFamily,
                          fontSize: Fsz.telemetry,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (line.durationMs != null)
                      Text(
                        '${line.durationMs}ms',
                        style: TextStyle(
                          fontFamily: t.monoFamily,
                          fontSize: Fsz.microSm,
                          color: t.terminalMuted,
                        ),
                      ),
                  ],
                ),
                Text(
                  [
                    _fmtIso(line.ts),
                    if (line.error != null) 'error: ${line.error}',
                  ].join(' · '),
                  style: TextStyle(
                    fontFamily: t.monoFamily,
                    fontSize: Fsz.microSm,
                    color: t.terminalMuted,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  // —— AppBar 动作：导出 / 粉碎 ——

  Future<void> _export() async {
    final store = _store;
    if (store == null) return;
    final text = await store.exportAll();
    if (text.isEmpty) {
      _flash('暂无可导出内容（记忆库为空）');
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    _flash('✓ 已复制全量记忆+教训（${text.length} 字符，锚点保留可恢复）');
  }

  Future<void> _purgeUserScope() async {
    final store = _store;
    if (store == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('粉碎 user 级记忆'),
        content: const Text(
          '清空全部 user 全局记忆与教训条目？\n\n'
          '服务绑定（srv:）条目保留；此操作不可撤销。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('mb-purge-confirm'),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('粉碎'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final purged = await store.purgeUserScope();
    await _reload(store);
    _flash(purged > 0 ? '✓ 已粉碎 $purged 条 user 级条目' : '（无 user 级条目）');
  }

  // —— 格式化 ——

  static String _fmtTs(DateTime dt) =>
      '${dt.month.toString().padLeft(2, '0')}-'
      '${dt.day.toString().padLeft(2, '0')} '
      '${dt.hour.toString().padLeft(2, '0')}:'
      '${dt.minute.toString().padLeft(2, '0')}';

  static String _fmtIso(String iso) {
    final dt = DateTime.tryParse(iso);
    return dt == null ? iso : _fmtTs(dt);
  }

  static String _preview(String content) {
    final lines = content.trim().split('\n');
    final head = lines.take(2).join(' ⏎ ');
    return head.length > 80 ? '${head.substring(0, 80)}…' : head;
  }
}

/// 条目编辑弹卡（controller 生命周期自持——退场动画期间 TextField 仍挂载，
/// 状态外自行 dispose 会撞「used after disposed」，故封装为独立 StatefulWidget）。
class _EditEntryDialog extends StatefulWidget {
  const _EditEntryDialog({required this.title, required this.initial});

  final String title;
  final String initial;

  @override
  State<_EditEntryDialog> createState() => _EditEntryDialogState();
}

class _EditEntryDialogState extends State<_EditEntryDialog> {
  late final _ctrl = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        key: const Key('mb-edit-field'),
        controller: _ctrl,
        maxLines: 6,
        autofocus: true,
        style: TextStyle(
          fontFamily: consoleTokens(context).monoFamily,
          fontSize: Fsz.telemetry,
        ),
        decoration: const InputDecoration(
          border: OutlineInputBorder(),
          hintText: '正文（锚点 id/scope/tags 由看板保留）',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('mb-edit-save'),
          onPressed: () => Navigator.pop(context, _ctrl.text),
          child: const Text('保存'),
        ),
      ],
    );
  }
}
