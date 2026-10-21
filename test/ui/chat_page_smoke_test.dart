/// ChatPage（60KB 装配中枢，首页）widget 冒烟测试。
///
/// 目的不是覆盖业务逻辑（业务由各域单测承担），而是钉住**首屏可装配**：
/// 依赖面（path_provider / SharedPreferences）用通道与官方 mock 兜住，一旦
/// 装配链被改动而崩在 initState，本测试立即咬人——此前该页面零 widget 测试。
///
/// 说明：页面已具备 `endpointStoreOverride` / `engineOverride` 注入位
/// （window-kernel-split 移交 misc#17）；本测试首两个用例仍走平台 mock 验首屏
/// 装配，第三个用例演示经 store 注入位绕过文件系统，可升级为覆盖发送链路的交互测试。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/core/security/flutter_secure_key_value.dart';
import 'package:goodhub/mcp/server_endpoints.dart';
import 'package:goodhub/ui/chat_page.dart';
import 'package:goodhub/ui/settings_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  // 本地插件发现通道（thirdconnect T-trans-4）：无 mock handler 时测试环境
  // 永不回包，`LocalPluginDiscovery.scan()` 的 Future 挂起 → initState 装配链
  // （_loadEndpoints）走不到尾。回 null = 零本地插件，装配链完整跑完。
  const binderChannel = MethodChannel('goodhub/binder_mcp');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory dir;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    dir = await Directory.systemTemp.createTemp('goodhub-chat');
    messenger.setMockMethodCallHandler(
      pathChannel,
      (call) async => dir.path, // 支持目录 / 临时目录 / 文档目录统一回临时根
    );
    messenger.setMockMethodCallHandler(binderChannel, (call) async => null);
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(pathChannel, null);
    messenger.setMockMethodCallHandler(binderChannel, null);
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  testWidgets('首屏装配：AppBar 标题 + 输入区 + 发送按钮', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ChatPage()));
    await tester.pump(); // 首帧
    await tester.pump(); // initState 的异步装配（配置/会话）完成后的重建

    expect(find.text('GoodHub'), findsOneWidget); // AppBar 标题（无会话时）
    expect(find.byType(TextField), findsOneWidget); // 输入区
    expect(find.byIcon(Icons.arrow_upward), findsOneWidget); // 发送按钮
  });

  testWidgets('输入区可写入（桌面限宽布局下 TextField 正常挂载）', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ChatPage()));
    await tester.pump();
    await tester.pump();

    await tester.enterText(find.byType(TextField), '你好 GoodHub');
    await tester.pump();
    expect(find.text('你好 GoodHub'), findsOneWidget);
  });

  testWidgets('注入 endpointStoreOverride：首屏装配经注入位绕过文件系统',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: ChatPage(endpointStoreOverride: _FakeEpStore())),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('GoodHub'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('未配置：首屏入轨引导卡（含「去配置」按钮），不整页跳转',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: ChatPage(endpointStoreOverride: _FakeEpStore())),
    );
    await _settleAssembly(tester);

    // ux-hardening P0-1：空 store + 测试环境无本地插件 → 轨道内引导卡
    expect(find.textContaining('尚未配置'), findsOneWidget);
    expect(find.text('去配置'), findsOneWidget);
    expect(find.byType(SettingsPage), findsNothing); // 不整页 push
  });

  // P1-9（2026-10-22）：桌面端 Enter = 发送（composer B1 平台语义），空输入时
  // 曾一路走到 `_send` 的空 return —— 点了/敲了零反馈 = 死控件（违反 SSOT §1
  // 「禁止静默禁用」）。现在由 composer 的 onSend 在页面层给一次性说明。
  testWidgets('空输入发送：给一次性反馈，不静默无反应', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: ChatPage(endpointStoreOverride: _FakeEpStore())),
    );
    await _settleAssembly(tester);

    await tester.tap(find.byIcon(Icons.arrow_upward));
    await _settleAssembly(tester);
    expect(find.text('先说点什么再发送'), findsOneWidget);
    expect(find.byType(SettingsPage), findsNothing,
        reason: '空发送不触发「未配置」引导流程');
  });

  // P2-11（2026-10-22）：本轮记忆入口**常驻且恒可点**——原先「首颗胶囊入轨才
  // 出现」让 AppBar 布局跳变；若改为常驻置灰则成了死控件（违反 SSOT §1「禁止
  // 静默禁用」），故无记忆时点开是同一个汇总列表的空态说明。
  testWidgets('本轮记忆入口常驻可点：无记忆时点开空态说明（非死控件）',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: ChatPage(endpointStoreOverride: _FakeEpStore())),
    );
    await _settleAssembly(tester);

    final btn = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.bolt),
    );
    expect(btn.onPressed, isNotNull, reason: '无记忆时也不得置灰（静默禁用）');

    await tester.tap(find.widgetWithIcon(IconButton, Icons.bolt));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('模型从对话里认出稳定事实'), findsOneWidget,
        reason: '空态必须回答「什么时候这里会有东西」');
  });

  testWidgets('未配置时发送：留在聊天页、输入保留、引导卡不重复', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: ChatPage(endpointStoreOverride: _FakeEpStore())),
    );
    await _settleAssembly(tester);

    await tester.enterText(find.byType(TextField), '帮我查待办');
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await _settleAssembly(tester);

    expect(find.byType(ChatPage), findsOneWidget); // 未整页跳走
    expect(find.byType(SettingsPage), findsNothing);
    expect(find.text('帮我查待办'), findsOneWidget); // 输入保留，返回可续发
    expect(find.text('去配置'), findsOneWidget); // 幂等：不重复插卡
  });
}

/// initState 异步装配链（store 加载 / 本地插件通道 / SharedPreferences /
/// 网关同步）多轮 Future + 平台通道响应——单次 pump 不保证跑完，定帧多轮
/// 冲刷（禁 pumpAndSettle：状态带高度动画有 180ms 过渡，会拉满超时）。
Future<void> _settleAssembly(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

/// 内存假 [ServerEndpointStore]：覆盖 load/save/apiKey，构造不触平台通道。
class _FakeEpStore extends ServerEndpointStore {
  _FakeEpStore() : super(file: File(''), secure: FlutterSecureKeyValue());
  @override
  Future<List<ServerEndpoint>> load() async => [];
  @override
  Future<void> save(List<ServerEndpoint> endpoints) async {}
  @override
  Future<String?> apiKey(String id) async => null;
}
