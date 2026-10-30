/// 日志查看页（开发调试用，2026-10-30）。
///
/// 数据源 = `AppLog` 内存环形缓冲（debugPrint sink 捕获，见
/// `lib/core/app_log.dart`）。入口 = 设置页「关于」段长按 debug 联调菜单
/// （kDebugMode 自闸，与网关联调入口同点）。
///
/// 能力：文本过滤（命中时间/级别/正文）、复制全部、清空。等宽遥测样式
/// （ConsoleTokens monoFamily + Fsz.telemetry，goodhub-ui §2）；监听
/// `revision` 节拍刷新，自动滚底可暂停（上滚即停跟）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_log.dart';
import 'tokens/console_tokens.dart';

class LogViewerPage extends StatefulWidget {
  const LogViewerPage({super.key});

  @override
  State<LogViewerPage> createState() => _LogViewerPageState();
}

class _LogViewerPageState extends State<LogViewerPage> {
  final ScrollController _scroll = ScrollController();
  final TextEditingController _filter = TextEditingController();
  String _query = '';
  bool _autoFollow = true;

  @override
  void initState() {
    super.initState();
    AppLog.instance.revision.addListener(_onLogChanged);
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    AppLog.instance.revision.removeListener(_onLogChanged);
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _filter.dispose();
    super.dispose();
  }

  /// 缓冲有新日志：跟随态下滚底；非跟随态仅刷新列表内容。
  void _onLogChanged() {
    if (!mounted) return;
    setState(() {});
    if (_autoFollow) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients && _autoFollow) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
  }

  /// 上滚即停跟随（用户回看历史时不被新日志打断）；滚到底恢复跟随。
  void _onScroll() {
    final atBottom = _scroll.position.pixels >=
        _scroll.position.maxScrollExtent - 24;
    if (!atBottom && _autoFollow) {
      setState(() => _autoFollow = false);
    } else if (atBottom && !_autoFollow) {
      setState(() => _autoFollow = true);
    }
  }

  List<LogEntry> get _filtered {
    final all = AppLog.instance.entries;
    if (_query.isEmpty) return all;
    return all.where((e) => e.line.contains(_query)).toList();
  }

  @override
  Widget build(BuildContext context) {
    final t = consoleTokens(context);
    final logs = _filtered;
    return Scaffold(
      appBar: AppBar(
        title: Text('运行日志 (${logs.length}/${AppLog.instance.length})'),
        actions: [
          IconButton(
            key: const Key('log-copy-all'),
            tooltip: '复制全部',
            icon: const Icon(Icons.copy_all_outlined),
            onPressed: () {
              Clipboard.setData(ClipboardData(
                text: logs.map((e) => e.line).join('\n'),
              ));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('已复制到剪贴板')),
              );
            },
          ),
          IconButton(
            key: const Key('log-clear'),
            tooltip: '清空',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => setState(AppLog.instance.clear),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              key: const Key('log-filter'),
              controller: _filter,
              style: TextStyle(fontFamily: t.monoFamily, fontSize: Fsz.body),
              decoration: const InputDecoration(
                isDense: true,
                prefixIcon: Icon(Icons.search, size: 18),
                hintText: '过滤（时间 / 级别 / 正文关键字）',
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => setState(() => _query = v.trim()),
            ),
          ),
          if (!_autoFollow)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: TextButton.icon(
                key: const Key('log-follow'),
                onPressed: () {
                  setState(() => _autoFollow = true);
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (_scroll.hasClients) {
                      _scroll.jumpTo(_scroll.position.maxScrollExtent);
                    }
                  });
                },
                icon: const Icon(Icons.arrow_downward, size: 16),
                label: const Text('跟随最新'),
              ),
            ),
          Expanded(
            child: logs.isEmpty
                ? Center(
                    child: Text(
                      '暂无日志（debug 构建运行期 debugPrint 均入此）',
                      style: TextStyle(
                        fontSize: Fsz.note,
                        color: t.terminalMuted,
                      ),
                    ),
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    itemCount: logs.length,
                    itemBuilder: (ctx, i) {
                      final e = logs[i];
                      final color = switch (e.level) {
                        LogLevel.error => t.danger,
                        LogLevel.warning => t.l2Warn,
                        LogLevel.info => t.l1Info,
                        LogLevel.debug => t.terminalMuted,
                      };
                      return SelectableText(
                        e.line,
                        style: TextStyle(
                          fontFamily: t.monoFamily,
                          fontSize: Fsz.telemetrySm,
                          height: 1.35,
                          color: color,
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
