/// ChatPage（60KB 装配中枢，首页）widget 冒烟测试。
///
/// 目的不是覆盖业务逻辑（业务由各域单测承担），而是钉住**首屏可装配**：
/// 依赖面（path_provider / SharedPreferences）用通道与官方 mock 兜住，一旦
/// 装配链被改动而崩在 initState，本测试立即咬人——此前该页面零 widget 测试。
///
/// 说明：页面无注入位（构造无参数），故依赖面只能走平台 mock；若日后为其
/// 增加 store/engine 注入位，可把这里升级为覆盖发送链路的交互测试。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/ui/chat_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory dir;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    dir = await Directory.systemTemp.createTemp('goodhub-chat');
    messenger.setMockMethodCallHandler(
      pathChannel,
      (call) async => dir.path, // 支持目录 / 临时目录 / 文档目录统一回临时根
    );
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(pathChannel, null);
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
}
