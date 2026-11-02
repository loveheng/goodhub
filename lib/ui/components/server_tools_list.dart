/// 资源中心 · 单服务工具区（server-tools-list，2026-11-02 二次改版：卡头合并）。
///
/// 原独立「MCP 工具目录」段拆解归并进各服务卡（`CatalogSource.remoteEndpoint`
/// 节点卡 / `CatalogSource.localPlugin` 本地插件卡，按 serverId 一一对应，
/// `McpCatalogService.serverId` = `ServerEndpoint.id` / `LocalPluginInfo.serverId`）。
///
/// **改版动因（人机）**：原「工具」ExpansionTile 是卡内第二块展开条，与卡头
/// 割裂（用户感知「两截」）。现组件只渲染**工具体**（无头部展开条），展开
/// 由父卡接管——整行卡头可点 + 钉选后箭头 + 来源标识右上角 + 「共享 x / 共 y
/// 个工具」并入卡头信息行。装载概要经 [ServerToolsList.onSummary] 上抛卡头。
///
/// **取数（§8.1 注入位范式）**：经注入的 [McpCatalog] 收口（页面级单例，段不持领域
/// 单例）；纯浏览面，复用 `McpRuntime` 挂载原语拉完即释放（catalog 内 mount→
/// listTools→release，不常驻 face）；单服务失败独立降级不阻断同卡其余态。
/// **排序（MC2 内层）**：shared→private→未声明，同级按名升序。**三态（MC3）**：
/// 显式 shared / 显式 private / 未声明兜底（SDK<0.2.0 存量插件，防把兜底当刻意私有）。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../coordinator/tool_catalog.dart';
import '../../core/tool_visibility.dart';
import '../tokens/console_tokens.dart';

/// 工具区装载概要（上抛卡头信息行用）：loading / error / done(total, shared)。
class ServerToolsSummary {
  const ServerToolsSummary({
    required this.loading,
    required this.error,
    required this.total,
    required this.shared,
  });
  const ServerToolsSummary.loading()
      : this(loading: true, error: false, total: 0, shared: 0);
  const ServerToolsSummary.error()
      : this(loading: false, error: true, total: 0, shared: 0);
  const ServerToolsSummary.done({required int total, required int shared})
      : this(loading: false, error: false, total: total, shared: shared);

  final bool loading;
  final bool error;
  final int total;

  /// 显式声明 shared 的工具数（未声明兜底不计入）。
  final int shared;
}

/// 单服务工具装载态（loading / done / error 三态，单服务独立降级）。
class _ToolsLoadState {
  const _ToolsLoadState._({this.loading = false, this.tools, this.error});
  factory _ToolsLoadState.loading() => const _ToolsLoadState._(loading: true);
  factory _ToolsLoadState.done(List<McpCatalogTool> t) =>
      _ToolsLoadState._(tools: t);
  factory _ToolsLoadState.error(String e) => _ToolsLoadState._(error: e);

  final bool loading;
  final List<McpCatalogTool>? tools;
  final String? error;
}

/// 单服务工具区组件（**纯工具体**，无头部）：注入 [catalog] / [svc]（服务实体
/// 投影）/ [changes]（可选，包变更流热刷新）/ [onSummary]（概要上抛卡头）/
/// [errorRowBuilder]。装载与展开态解耦——折叠也装载（卡头需显示工具计数）。
class ServerToolsList extends StatefulWidget {
  const ServerToolsList({
    super.key,
    required this.catalog,
    required this.svc,
    this.changes,
    this.onSummary,
    required this.errorRowBuilder,
  });

  final McpCatalog catalog;
  final McpCatalogService svc;

  /// 包变更广播（本地插件安装/卸载 → 重拉工具）；远端节点可传 null（不订阅）。
  final Stream<void>? changes;

  /// 装载概要上抛（loading/error/done），卡头据此渲染「共享 x / 共 y 个工具」。
  final void Function(ServerToolsSummary summary)? onSummary;

  final Widget Function(ConsoleTokens t, String message, VoidCallback onRetry,
      {ValueKey<String>? key}) errorRowBuilder;

  @override
  State<ServerToolsList> createState() => _ServerToolsListState();
}

class _ServerToolsListState extends State<ServerToolsList> {
  var _state = _ToolsLoadState.loading();
  StreamSubscription<void>? _changesSub;

  @override
  void initState() {
    super.initState();
    // 包变更（安装/卸载插件）→ 重拉工具热刷新（重试路径防重复订阅）。
    final changes = widget.changes;
    if (changes != null) {
      _changesSub = changes.listen((_) {
        if (mounted) unawaited(_reload());
      });
    }
    unawaited(Future<void>.microtask(_reload));
  }

  @override
  void dispose() {
    _changesSub?.cancel();
    super.dispose();
  }

  void _report() {
    final onSummary = widget.onSummary;
    if (onSummary == null) return;
    final st = _state;
    if (st.loading) return onSummary(const ServerToolsSummary.loading());
    if (st.error != null) return onSummary(const ServerToolsSummary.error());
    final tools = st.tools!;
    onSummary(ServerToolsSummary.done(
      total: tools.length,
      shared: tools
          .where((x) => x.declared && x.visibility == ToolVisibility.shared)
          .length,
    ));
  }

  /// 单服务工具拉取（挂载→listTools→释放；失败仅降级该卡）。
  Future<void> _reload() async {
    if (!mounted) return;
    setState(() => _state = _ToolsLoadState.loading());
    _report();
    try {
      final tools = await widget.catalog.loadServerTools(widget.svc);
      if (!mounted) return;
      setState(() => _state = _ToolsLoadState.done(tools));
      _report();
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _state = _ToolsLoadState.error('$e'));
      _report();
    }
  }

  /// 组内工具排序（MC2 内层）：shared(0)→private(1)→未声明(2)，同级按名升序。
  int _toolRank(McpCatalogTool t) =>
      t.declared ? (t.visibility == ToolVisibility.shared ? 0 : 1) : 2;

  List<McpCatalogTool> _sortedTools(List<McpCatalogTool> tools) {
    final list = List<McpCatalogTool>.of(tools);
    list.sort((a, b) {
      final r = _toolRank(a).compareTo(_toolRank(b));
      return r != 0 ? r : a.name.compareTo(b.name);
    });
    return list;
  }

  /// 三态可见性文案（MC3：未声明单独标，防把兜底当刻意私有）。
  String _visLabel(McpCatalogTool t) =>
      !t.declared ? '未声明' : t.visibility == ToolVisibility.shared ? '共享' : '私有';

  Color _visColor(ConsoleTokens t, McpCatalogTool tool) => !tool.declared
      ? t.l2Warn
      : tool.visibility == ToolVisibility.shared
          ? t.l1Ok
          : t.terminalMuted;

  Widget _pill(ConsoleTokens t, String label, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          border: Border.all(color: color.withValues(alpha: 0.5)),
          borderRadius: BorderRadius.circular(t.cardRadius),
        ),
        child: Text(label, style: TextStyle(fontSize: Fsz.microSm, color: color)),
      );

  List<Widget> _toolRows(ConsoleTokens t, List<McpCatalogTool> tools) => [
        for (final tool in tools)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(tool.name,
                          style: TextStyle(
                              fontFamily: t.monoFamily, fontSize: Fsz.telemetry)),
                      if (tool.description.isNotEmpty)
                        Text(
                          tool.description,
                          style: TextStyle(
                              fontSize: Fsz.note, color: t.terminalMuted),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _pill(t, _visLabel(tool), _visColor(t, tool)),
              ],
            ),
          ),
      ];

  /// 工具体：loading / 单服务错误 / 空态 / 工具行四态（与段级错误态口径一致）。
  Widget _body(ConsoleTokens t) {
    final st = _state;
    if (st.loading) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text('加载工具…',
            style: TextStyle(fontSize: Fsz.note, color: t.terminalMuted)),
      );
    }
    if (st.error != null) {
      return widget.errorRowBuilder(t, st.error!, () => unawaited(_reload()));
    }
    final tools = st.tools!;
    if (tools.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text('（该服务未声明工具）',
            style: TextStyle(fontSize: Fsz.note, color: t.terminalMuted)),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: _toolRows(t, _sortedTools(tools)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = consoleTokens(context);
    return _body(t);
  }
}

/// 来源/隐私标注 pill（MC4：远程/本地只是标注，不作分组维度）。
///
/// 改版后渲染位置在**卡头右上角**（钉选按钮左侧），由两个 section 复用——
/// 提出为顶层函数避免节点/插件卡各抄一份。
Widget serverSourcePill(ConsoleTokens t, String label) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: t.terminalMuted.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(t.cardRadius),
      ),
      child: Text(label,
          style: TextStyle(fontSize: Fsz.microSm, color: t.terminalMuted)),
    );

/// 工具装载概要 → 卡头信息行文案（折叠态带「点击展开」示意，展开态收敛）。
String serverToolsMetaText(ServerToolsSummary? s, {required bool expanded}) {
  if (s == null || s.loading) return '工具加载中…';
  if (s.error) return '工具加载失败';
  if (s.total == 0) return '未声明工具';
  final base = '共享 ${s.shared} / 共 ${s.total} 个工具';
  return expanded ? base : '$base · 点击展开';
}

/// 展开箭头（钉选按钮后，AnimatedRotation 180° 翻转，§4.2 紧凑时长）。
Widget serverExpandChevron(ConsoleTokens t, {required bool expanded}) =>
    AnimatedRotation(
      turns: expanded ? 0.5 : 0,
      duration: t.fastDuration,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Icon(Icons.expand_more, size: 20, color: t.l1Info),
      ),
    );
