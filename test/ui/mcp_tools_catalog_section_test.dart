/// `lib/ui/sections/mcp_tools_catalog_section.dart` 单测：排序（MC2 两层都排）+
/// 三态 pill（MC3）+ 按服务分组来源标注（MC4）+ keepAlive + 空态/错误态。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/tool_catalog.dart';
import 'package:goodhub/core/tool_visibility.dart';
import 'package:goodhub/mcp/local_plugin_discovery.dart';
import 'package:goodhub/mcp/server_endpoints.dart';
import 'package:goodhub/ui/sections/mcp_tools_catalog_section.dart';
import 'package:goodhub/ui/tokens/console_tokens.dart';

Widget _errorRow(
  ConsoleTokens t,
  String message,
  VoidCallback onRetry, {
  ValueKey<String>? key,
}) =>
    Text('⚠ $message');

/// 假目录：直接返回预设服务/工具，不触真实挂载原语（无平台通道）。
class _FakeCatalog extends McpCatalog {
  _FakeCatalog({
    this.services = const [],
    this.tools = const {},
    this.fail = false,
  }) : super(endpointStore: ({String? supportPath}) async {
          throw UnsupportedError('假目录不走端点装配');
        });

  final List<McpCatalogService> services;
  final Map<String, List<McpCatalogTool>> tools;
  final bool fail;

  @override
  Future<List<McpCatalogService>> loadRegisteredServices() async {
    if (fail) throw Exception('boom');
    return services;
  }

  @override
  Future<List<McpCatalogTool>> loadServerTools(McpCatalogService s) async =>
      tools[s.serverId] ?? const [];
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

McpCatalogService _remoteService(String id, String label) => McpCatalogService(
      serverId: id,
      label: label,
      source: CatalogSource.remoteEndpoint,
      remote: ServerEndpoint(id: id, name: label, endpoint: 'http://x/mcp'),
    );

void main() {
  Future<void> pump(WidgetTester tester, McpCatalog catalog) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: McpToolsCatalogSection(
            catalog: catalog,
            changes: const Stream.empty(),
            onFlash: (_) {},
            errorRowBuilder: _errorRow,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('空态：无已注册服务时提示', (tester) async {
    await pump(tester, _FakeCatalog());
    expect(find.textContaining('暂无可展示的 MCP 服务'), findsOneWidget);
  });

  testWidgets('排序（MC2 两层都排）+ 三态 pill（MC3）+ 来源标注（MC4）',
      (tester) async {
    final sA = _localService('sA', 'SharedFirst'); // 含 1 shared → 排前
    final sB = _remoteService('sB', 'PrivFirst'); // 含 0 shared → 排后
    final catalog = _FakeCatalog(
      services: [sA, sB],
      tools: {
        'sA': [
          McpCatalogTool(
            name: 'echo',
            description: '',
            visibility: ToolVisibility.shared,
            declared: true,
          ),
          McpCatalogTool(
            name: 'legacy',
            description: '',
            visibility: ToolVisibility.private,
            declared: false,
          ),
        ],
        'sB': [
          McpCatalogTool(
            name: 'p1',
            description: '',
            visibility: ToolVisibility.private,
            declared: true,
          ),
        ],
      },
    );
    await pump(tester, catalog);

    // 服务组排序：shared 多者（SharedFirst）在前。
    final a = tester.getTopLeft(find.text('SharedFirst'));
    final b = tester.getTopLeft(find.text('PrivFirst'));
    expect(a.dy, lessThan(b.dy),
        reason: '含 shared 工具的服务应排在纯私有服务之前');

    // 组内排序：shared → 未声明（legacy 兜底 private 但 declared=false）。
    final echo = tester.getTopLeft(find.text('echo'));
    final legacy = tester.getTopLeft(find.text('legacy'));
    expect(echo.dy, lessThan(legacy.dy),
        reason: '组内 shared 工具应在未声明工具之前');

    // 三态 pill 文案齐备。
    expect(find.text('共享'), findsWidgets);
    expect(find.text('未声明'), findsOneWidget);
    expect(find.text('私有'), findsOneWidget);

    // 来源标注：本地 / 远程·私有（MC4：仅标注不作维度）。
    expect(find.text('本地'), findsOneWidget);
    expect(find.text('远程·私有'), findsOneWidget);
  });

  testWidgets('整体加载失败 → 错误态可见', (tester) async {
    await pump(tester, _FakeCatalog(fail: true));
    expect(find.textContaining('服务清单加载失败'), findsOneWidget);
  });

  testWidgets('段申请 keepAlive（TabBarView 切走保态）', (tester) async {
    await pump(tester, _FakeCatalog());
    final state = tester.state(find.byType(McpToolsCatalogSection));
    expect((state as dynamic).wantKeepAlive, isTrue);
  });
}
