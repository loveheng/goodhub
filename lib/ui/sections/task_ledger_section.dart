/// 设置页 · 任务对账段（M4-2 对账能力）。
///
/// 定位：**执行侧对账**——宿主从各 MCP server 认领并处理的任务实况，按来源服务
/// 分组、以列表为主（聚合降级为组头元信息）。与 goodshare 侧任务队列页（DB 全量
/// 历史账）分工：那边看「任务在不在」，这边看「宿主处理了没有、成功还是失败」。
///
/// UI 纪律（goodhub-ui §2）：零魔法值（色/字号全取 ConsoleTokens 与 Fsz）、
/// 遥测字段（任务 id / 动作 / 条目 id）走等宽、设置页有状态段必混 KeepAlive。
library;

import 'package:flutter/material.dart';

import '../../task/task_consume_ledger.dart';
import '../tokens/console_tokens.dart';

class TaskLedgerSection extends StatefulWidget {
  const TaskLedgerSection({super.key, this.ledger});

  /// 对账账本（注入位：生产由 `main` 装配共享实例；null = 未启用）。
  final TaskConsumeLedger? ledger;

  @override
  State<TaskLedgerSection> createState() => _TaskLedgerSectionState();
}

class _TaskLedgerSectionState extends State<TaskLedgerSection>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true; // 设置页 ListView 滚动复用防丢态（§8.1）

  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await widget.ledger?.load();
    if (!mounted) return;
    setState(() => _loaded = true);
  }

  Future<void> _clear() async {
    await widget.ledger?.clear();
    if (!mounted) return;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final t = consoleTokens(context);
    final ledger = widget.ledger;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '任务对账',
              style: const TextStyle(
                fontSize: Fsz.sectionTitle,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '宿主从 goodshare 认领并处理的 AI 任务实况（历史全量账见 goodshare '
              '任务队列页）。',
              style: TextStyle(fontSize: Fsz.telemetrySm, color: t.terminalMuted),
            ),
            const SizedBox(height: 8),
            if (ledger == null)
              Text(
                '未启用（未装配账本）',
                style: TextStyle(fontSize: Fsz.telemetry, color: t.terminalMuted),
              )
            else if (!_loaded)
              Text(
                '读取中…',
                style: TextStyle(fontSize: Fsz.telemetry, color: t.terminalMuted),
              )
            else ...[
              if (ledger.recentEntries.isEmpty)
                Text(
                  '今天还没有处理记录',
                  style: TextStyle(fontSize: Fsz.telemetry, color: t.terminalMuted),
                )
              else
                for (final g in ledger.groupedByServer.entries)
                  _serverGroup(context, g.key, g.value),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: ledger.recentEntries.isEmpty ? null : _clear,
                  child: const Text('清空对账'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 来源服务组（组头 = 域名 + 该组今日计数小字；聚合降级为组头元信息）。
  Widget _serverGroup(
    BuildContext context,
    String serverId,
    List<TaskLedgerEntry> items,
  ) {
    final t = consoleTokens(context);
    final name = items.first.serverName ?? _serverName(serverId);
    final done = items.where((e) => e.ok).length;
    final failed = items.length - done;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 4),
        Row(
          children: [
            Text(
              name,
              style: TextStyle(
                fontSize: Fsz.telemetry,
                fontWeight: FontWeight.w600,
                color: t.terminalMuted,
              ),
            ),
            const Spacer(),
            Text(
              '今日 $done${failed > 0 ? ' · 失败 $failed' : ''}',
              style: TextStyle(
                fontSize: Fsz.micro,
                color: failed > 0 ? t.danger : t.terminalMuted,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        const Divider(height: 1),
        for (final e in items.reversed) _entryRow(context, e),
      ],
    );
  }

  Widget _entryRow(BuildContext context, TaskLedgerEntry e) {
    final t = consoleTokens(context);
    final mono = TextStyle(
      fontFamily: t.monoFamily,
      fontSize: Fsz.micro,
      color: t.terminalMuted,
    );
    final mark = e.ok ? '✓' : '✗';
    final markColor = e.ok ? t.l1Ok : t.danger;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(mark, style: TextStyle(fontSize: Fsz.micro, color: markColor)),
          const SizedBox(width: 6),
          Text(_hhmmss(e.atMs), style: mono),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '${e.action} · ${_shortId(e.itemId)}'
              '${e.reason == null ? '' : ' · ${e.reason}'}',
              style: mono,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

String _hhmmss(int atMs) {
  final t = DateTime.fromMillisecondsSinceEpoch(atMs);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}

/// 条目 id 缩写（uuid 全长过宽，保留前缀即可定位）。
String _shortId(String id) => id.length <= 8 ? id : '${id.substring(0, 8)}…';

/// 来源服务展示名（包名末段：com.zzh.goodshare → goodshare）。
String _serverName(String id) => id.contains('.') ? id.split('.').last : id;
