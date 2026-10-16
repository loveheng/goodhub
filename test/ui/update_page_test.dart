/// ux-hardening P0-3：更新页初始化失败可见 + 可重试。
///
/// 历史病：`_bootstrap` 无 try/catch——PackageInfo 等任一环节失败即抛穿，
/// `_ready` 永假、按钮全灰且无任何报错，用户面对一片死按钮。
/// 测试环境 PackageInfo.fromPlatform 抛 MissingPluginException——正好驱动
/// 失败路径，无需注入位。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/ui/update_page.dart';

void main() {
  testWidgets('初始化失败：Rose 错误 + 重试入口（替代按钮永久灰死无报错）', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: UpdatePage()));
    // PackageInfo 平台通道的 MissingPluginException 经真实事件循环交付——
    // fake async 的 pump 不驱动平台通道响应，须 runAsync 让路（同 settings
    // 测试 settleIo 口径）。
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();

    expect(find.text('更新'), findsOneWidget, reason: 'AppBar 在');
    expect(find.textContaining('更新页初始化失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget, reason: '失败态带重试入口');
    // 按钮仍在（disabled 态可见）——页面不是一片死灰，错误可读、可重试。
    expect(find.text('检查更新'), findsOneWidget);
  });
}
