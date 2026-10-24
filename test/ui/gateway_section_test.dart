/// PC 远程网关设置段行为测试（产品裁决 2026-10-23：消除「默认无鉴权」）。
///
/// 锁住三条口径：
/// - **默认安全**：Token 留空即自动生成并落盘，起服必带 `Authorization: Bearer`
///   （原实现「留空 = 不鉴权」且默认监听 0.0.0.0 → 同局域网任意主机可无鉴权
///   访问只读工具面）；
/// - **显式逃生口**：用户主动关掉「自动生成」且留空 → 免鉴权（仅 ADB 转发场景）；
/// - **用户优先**：手填的 Token 不被自动生成覆盖。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/core/security/secure_key_value.dart';
import 'package:goodhub/ui/sections/gateway_section.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  /// F11：Token 走安全存储——测试统一注入内存件（含迁移断言的观测位）；
  /// setUp 每用例重建（内存件跨用例会串 Token 态）。
  late InMemorySecureKeyValue secure;

  setUp(() {
    secure = InMemorySecureKeyValue();
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> pumpSection(
    WidgetTester tester, {
    GatewayStartFn? start,
    BatteryStatusFn? batteryStatus,
    BatteryRequestFn? batteryRequest,
    void Function(String message)? flash,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        // ListView 提供 keep-alive 祖先（段混 AutomaticKeepAliveClientMixin）。
        body: ListView(children: [
          GatewaySection(
            onFlash: flash ?? (String _) {},
            startOverride: start,
            batteryStatusOverride: batteryStatus,
            batteryRequestOverride: batteryRequest,
            secureOverride: secure,
          ),
        ]),
      ),
    ));
    await tester.pumpAndSettle();
  }

  String? tokenField(WidgetTester tester) => tester
      .widget<TextField>(find.byKey(const Key('gateway-token')))
      .controller!
      .text;

  testWidgets('默认开启：Token 留空 → 自动生成 + 落盘 + 起服带 Bearer',
      (tester) async {
    var startCalls = 0;
    String? gotToken;
    await pumpSection(tester, start: ({required int port, String? token}) async {
      startCalls++;
      gotToken = token;
    });

    await tester.tap(find.byKey(const Key('gateway-toggle')));
    await tester.pumpAndSettle();

    expect(startCalls, 1);
    expect(gotToken, isNotNull);
    expect(gotToken, isNotEmpty,
        reason: '默认路径必须带 Bearer——不得静默免鉴权暴露 :8766');
    expect(await secure.read('gateway.token'), gotToken,
        reason: 'F11：Token 落安全存储（明文 prefs 即红）');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('gateway.token'), isNull,
        reason: 'F11：明文位不得再写');
    expect(prefs.getString('gateway.token.authMode'), 'auto');
    expect(tokenField(tester), gotToken,
        reason: '生成的 Token 回填输入框——用户要复制到 PC 端');
    final field = tester.widget<TextField>(
        find.byKey(const Key('gateway-token')));
    expect(field.obscureText, isFalse,
        reason: '自动生成后立即可见，便于核对与复制');
  });

  testWidgets('显式关闭「自动生成」且留空 → 免鉴权（用户显式选择的逃生口）',
      (tester) async {
    var startCalls = 0;
    String? gotToken;
    await pumpSection(tester, start: ({required int port, String? token}) async {
      startCalls++;
      gotToken = token;
    });

    await tester.tap(find.byKey(const Key('gateway-token-auto')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('gateway-toggle')));
    await tester.pumpAndSettle();

    expect(startCalls, 1);
    expect(gotToken, isNull, reason: '显式关自动生成 + 留空 = 免鉴权');
    expect(await secure.read('gateway.token'), '');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('gateway.token.authMode'), 'open',
        reason: '免鉴权意图须落盘——否则下次开启会被自动补 Token 静默推翻');
  });

  testWidgets('电池优化白名单：未加入时提示 + 「去设置」可跳；已加入则隐藏提示',
      (tester) async {
    // 用户症状「无线用过一段时间连接自动掉」的三因之一：未加电池优化白名单 →
    // 息屏进 Doze 限网。设置页必须给出可见提示与一键跳转。
    var requestCalls = 0;
    await pumpSection(
      tester,
      batteryStatus: () async => false,
      batteryRequest: () async {
        requestCalls++;
        return true;
      },
    );

    expect(find.byKey(const Key('gateway-battery-exempt')), findsOneWidget,
        reason: '未加白名单必须给出去设置入口');
    expect(find.textContaining('电池优化白名单'), findsWidgets);

    await tester.tap(find.byKey(const Key('gateway-battery-exempt')));
    await tester.pumpAndSettle();
    expect(requestCalls, 1, reason: '点击须触发系统申请');
  });

  testWidgets('电池优化白名单：已加入则不显示提示行', (tester) async {
    await pumpSection(tester, batteryStatus: () async => true);
    expect(find.byKey(const Key('gateway-battery-exempt')), findsNothing,
        reason: '已在白名单不必再打扰用户');
  });

  testWidgets('用户手填的 Token 优先于自动生成', (tester) async {
    String? gotToken;
    await pumpSection(tester, start: ({required int port, String? token}) async {
      gotToken = token;
    });

    await tester.enterText(
        find.byKey(const Key('gateway-token')), 'my-token');
    await tester.tap(find.byKey(const Key('gateway-toggle')));
    await tester.pumpAndSettle();

    expect(gotToken, 'my-token', reason: '用户显式指定优先于自动生成');
  });

  // F11（review-fix-2026-10）：Bearer Token 属凭证，明文落 prefs 违反 §6.3
  // 零明文留痕——本地取证即得。首启从旧明文键迁移到安全存储并删除明文残留。
  testWidgets('F11：旧明文 Token 首启迁移至安全存储 + 明文键删除', (tester) async {
    SharedPreferences.setMockInitialValues({
      'gateway.token': 'legacy-secret-token',
      'gateway.token.authMode': 'auto',
    });
    await pumpSection(tester);
    // bootstrap 已完成迁移。
    expect(tokenField(tester), 'legacy-secret-token');
    expect(await secure.read('gateway.token'), 'legacy-secret-token',
        reason: '旧值须迁入安全存储');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('gateway.token'), isNull,
        reason: 'F11：明文残留必须删除（撤迁移清理即红）');
    expect(prefs.getString('gateway.token.authMode'), 'auto',
        reason: '非机密模式标记不动');
  });
}
