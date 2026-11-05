/// 控件语义树导出回归：Key / Semantics label / 文本 / bounds 由 RenderBox 现算。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/ui/debug_ui_tree.dart';

void main() {
  testWidgets('导出 key、label、text 与四元 bounds', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Semantics(
                label: '提交任务',
                child: Text('hello', key: const ValueKey('greeting')),
              ),
              ElevatedButton(
                key: const ValueKey('send'),
                onPressed: () {},
                child: const Text('提交'),
              ),
            ],
          ),
        ),
      ),
    ));

    final nodes = collectDebugUiTree(tester.element(find.byType(Scaffold)));
    expect(nodes, isNotEmpty);
    expect(nodes.any((n) => n['key'] == 'greeting'), isTrue,
        reason: 'ValueKey 是后续 tap_node 的稳定寻址锚点');
    expect(nodes.any((n) => n['label'] == '提交任务'), isTrue,
        reason: 'Semantics label 用于无 Key 控件定位');
    expect(nodes.any((n) => n['text'] == 'hello'), isTrue);
    expect(
      nodes.any((n) =>
          n['bounds'] is List && (n['bounds']! as List).length == 4),
      isTrue,
      reason: 'bounds 让调用方免于截图 + 分辨率换算',
    );
    expect(nodes.any((n) => n['interactive'] == true), isTrue,
        reason: '交互控件须可枚举（Scaffold 树的按钮/手势件）');
  });

  test('context 为空返回空树（App 未挂载的事实，不抛异常）', () {
    expect(collectDebugUiTree(null), isEmpty);
  });

  testWidgets('内部实现件被收敛，不进候选列表', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: IconButton(onPressed: () {}, icon: const Icon(Icons.add)),
      ),
    ));

    final nodes = collectDebugUiTree(tester.element(find.byType(Scaffold)));
    expect(nodes.any((n) => n['type'] == 'IconButton'), isTrue);
    expect(nodes.any((n) => n['type'] == '_IconButtonM3'), isFalse,
        reason: '内部实现件只增噪音，须过滤');
  });

  testWidgets('零尺寸容器借后代矩形并标注 boundsSource', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SizedBox(
              key: const ValueKey('zero'),
              width: 0,
              child: const Text('inner'),
            ),
          ],
        ),
      ),
    ));

    final nodes = collectDebugUiTree(tester.element(find.byType(Scaffold)));
    final zero = nodes.firstWhere((n) => n['key'] == 'zero');
    final bounds = zero['bounds']! as List;
    expect(bounds[2], greaterThan(0), reason: '宽不能为 0，否则按坐标点击必落空');
    expect(bounds[3], greaterThan(0), reason: '高不能为 0');
    expect(zero['boundsSource'], isNot('self'),
        reason: '借来的矩形必须显式标注来源，不能冒充自身矩形');
  });
}
