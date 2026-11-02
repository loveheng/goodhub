/// `lib/ui/components/server_tools_list.dart` 单测（2026-11-02 卡头合并改版）：
/// 组件 = **纯工具体**（无头部展开条，展开由父卡接管），故验证口径改为——
/// 四态工具体（loading/错误/空/工具行）+ 三态 pill（MC3）+ 组内排序（MC2 内层）
/// + 概要上抛（`onSummary` = 卡头「共享 x / 共 y 个工具」信息行的渲染源）。
///
/// 原 `mcp_tools_catalog_section_test` 随 2026-11-02 段拆解归并迁移：跨服务
/// 排序维度取消（每个卡只列自身工具），只验单服务内层排序与三态。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/tool_catalog.dart';
import 'package:goodhub/core/tool_visibility.dart';
import 'package:goodhub/mcp/local_plugin_discovery.dart';
import 'package:goodhub/ui/components/server_tools_list.dart';
import 'package:goodhub/ui/tokens/console_tokens.dart';

Widget _errorRow(
  ConsoleTokens t,
  String message,
  VoidCallback onRetry, {
  ValueKey<String>? key,
}) =>
    Text('⚠ $message');

/// 假目录：直接返回预设工具，不触真实挂载原语（无平台通道）。
class _FakeCatalog extends McpCatalog {
  _FakeCatalog({this.tools = const {}, this.fail = false})
      : super(endpointStore: ({String? supportPath}) async {
          throw UnsupportedError('假目录不走端点装配');
        });

  final Map<String, List<McpCatalogTool>> tools;
  final bool fail;

  @override
  Future<List<McpCatalogTool>> loadServerTools(McpCatalogService s) async {
    if (fail) throw Exception('boom');
    return tools[s.serverId] ?? const [];
  }
}

McpCatalogService _localService(String id, String label) => McpCatalogService(
      serverId: id,
      label: label,
      source: CatalogSource.localPlugin,
      local: LocalPluginInfo(
        serverId: id,
        serverTitle: label,
        packageName: 'p',
        serviceClassName: 'c',
        sameSignature: true,
      ),
    );

/// 直泵组件（纯工具体，无展开交互）；返回 onSummary 收到的概要序列。
Future<List<ServerToolsSummary>> pump(
  WidgetTester tester,
  McpCatalog catalog,
  McpCatalogService svc,
) async {
  final summaries = <ServerToolsSummary>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ServerToolsList(
          catalog: catalog,
          svc: svc,
          onSummary: summaries.add,
          errorRowBuilder: _errorRow,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return summaries;
}

void main() {
  final svc = _localService('sA', 'Sample');

  testWidgets('空态：工具体提示该服务未声明工具，概要 total=0', (tester) async {
    final summaries = await pump(tester, _FakeCatalog(), svc);
    expect(find.textContaining('该服务未声明工具'), findsOneWidget);
    expect(summaries.last.loading, isFalse);
    expect(summaries.last.error, isFalse);
    expect(summaries.last.total, 0);
  });

  testWidgets('三态 pill（MC3）+ 组内排序（MC2 内层）+ 概要上抛（共享计数）',
      (tester) async {
    final catalog = _FakeCatalog(tools: {
      'sA': [
        McpCatalogTool(
          name: 'legacy',
          description: '',
          visibility: ToolVisibility.private,
          declared: false,
        ),
        McpCatalogTool(
          name: 'echo',
          description: '',
          visibility: ToolVisibility.shared,
          declared: true,
        ),
        McpCatalogTool(
          name: 'p1',
          description: '',
          visibility: ToolVisibility.private,
          declared: true,
        ),
      ],
    });
    final summaries = await pump(tester, catalog, svc);

    // 纯工具体：无展开条，工具行常显。
    expect(find.text('echo'), findsOneWidget);
    // 三态 pill 文案齐备（shared / 私有 / 未声明）。
    expect(find.text('共享'), findsOneWidget);
    expect(find.text('私有'), findsOneWidget);
    expect(find.text('未声明'), findsOneWidget);

    // 组内排序：shared(echo) → 私有(p1) → 未声明(legacy，兜底 private 但 declared=false)。
    final echo = tester.getTopLeft(find.text('echo'));
    final p1 = tester.getTopLeft(find.text('p1'));
    final legacy = tester.getTopLeft(find.text('legacy'));
    expect(echo.dy, lessThan(p1.dy), reason: 'shared 工具应在私有前');
    expect(p1.dy, lessThan(legacy.dy), reason: '私有工具应在未声明前');

    // 概要上抛：首帧 loading → 终态 done(total=3, shared=1)。
    expect(summaries.first.loading, isTrue, reason: '装载起点上抛 loading');
    expect(summaries.last.total, 3);
    expect(summaries.last.shared, 1, reason: '仅显式 shared 计入共享数');
  });

  testWidgets('加载失败 → 错误态工具体（boom）+ 概要 error', (tester) async {
    final summaries = await pump(tester, _FakeCatalog(fail: true), svc);
    expect(find.textContaining('boom'), findsOneWidget);
    expect(summaries.last.error, isTrue);
  });
}
