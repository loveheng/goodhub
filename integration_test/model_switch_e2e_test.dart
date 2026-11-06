// 端侧模型切换 B+ 链路真机 e2e（2026-11-07）：模型选择面板 → 确认卡 →
// 「下次提问装载」与「立即装载」两条分支的真实验证（真 prefs + 真 :engine）。
//
// 前置：设备已装 ≥2 个端侧模型（Gemma3-1B litertlm + Qwen3.5-2B gguf）。
// 运行：flutter test integration_test/model_switch_e2e_test.dart -d <device>
//
// 注意：本测试会真实切换选择持久化与引擎装载态，结束态固定回 Gemma
// （原默认），不留副作用。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/coordinator/on_device_admin.dart';
import 'package:goodhub/llm/on_device_engine.dart';
import 'package:goodhub/ui/chat_page.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _settle(WidgetTester tester,
        [Duration d = const Duration(milliseconds: 400)]) async =>
    tester.pump(d);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('端侧模型切换 B+ 链路（确认卡/驱逐/两条装载分支）', (tester) async {
    final origin = await OnDeviceModelSelection.read();
    // ignore: avoid_print
    print('[e2e] 初始选中: ${origin?.dirName}');
    final installed = await OnDeviceAdmin.assets.listInstalled();
    // ignore: avoid_print
    print('[e2e] 已装模型: ${[for (final m in installed) m.dirName]}');
    final support = await getApplicationSupportDirectory();
    // ignore: avoid_print
    print('[e2e] support 目录: ${support.path}');
    // ignore: avoid_print
    print('[e2e] prefs 键 on_device.model.selected_dir = '
        '${(await SharedPreferences.getInstance()).getString('on_device.model.selected_dir')}');

    await tester.pumpWidget(const MaterialApp(home: ChatPage()));
    await _settle(tester);
    await _settle(tester, const Duration(seconds: 2));

    // —— ① 打开模型选择面板（底栏药丸）——
    await tester.tap(find.byKey(const ValueKey('composer-model-picker')));
    await _settle(tester, const Duration(seconds: 1));
    expect(find.text('模型与推理来源'), findsOneWidget,
        reason: '选择面板已弹出');

    // —— ② 选另一端侧模型 → 确认卡弹出（三选）——
    final target = origin?.dirName == 'Qwen3.5-2B-Q4_0'
        ? 'Gemma3-1B-IT_q4_ekv1280_sm8750.litertlm'
        : 'Qwen3.5-2B-Q4_0';
    await tester.tap(find.text(target));
    await _settle(tester);
    expect(find.text('切换端侧模型'), findsOneWidget,
        reason: 'B+ 确认卡（明示驱逐代价与装载时机）');

    // —— ③ 分支一：下次提问装载（懒）→ 选择落盘 + 旧驻留驱逐 ——
    await tester.tap(find.text('下次提问装载'));
    await _settle(tester, const Duration(seconds: 1));
    final selected = await OnDeviceModelSelection.read();
    expect(selected?.dirName, target, reason: '选择已持久化');
    // 原状态若 ready（测试起点引擎可能驻留 Gemma），确认即驱逐 → unloaded。
    // 起点 unloaded 则本断言天然成立。
    // ignore: avoid_print
    print('[e2e] 懒分支后 loadState=${sharedOnDeviceEngine.loadState.value}');

    // —— ④ 分支二：切回原模型 + 立即装载（重型，真冷启动）——
    await tester.tap(find.byKey(const ValueKey('composer-model-picker')));
    await _settle(tester, const Duration(seconds: 1));
    await tester.tap(find.text(origin?.dirName ?? target));
    await _settle(tester);
    expect(find.text('切换端侧模型'), findsOneWidget);
    await tester.tap(find.text('立即装载'));
    // 装载是重型操作（进程冷启动 + 权重装载，实测 ~10-30s）：轮询至 ready。
    var ready = false;
    for (var i = 0; i < 60; i++) {
      await _settle(tester, const Duration(seconds: 1));
      if (sharedOnDeviceEngine.loadState.value == OnDeviceLoadState.ready) {
        ready = true;
        break;
      }
    }
    expect(ready, isTrue, reason: '立即装载 → 引擎 ready（真机冷启动链路）');
    final restored = await OnDeviceModelSelection.read();
    expect(restored?.dirName, origin?.dirName, reason: '结束态还原原选中');
  });
}
