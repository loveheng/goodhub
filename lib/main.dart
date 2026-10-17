/// goodhub 应用入口与全局装配（平台实现仅在此装配，coding-standards §1）：
/// 端侧引擎生命周期策略 + 记忆沙盒启动清扫 + `$ref` 暂存池启动清池（§9）
/// + 首页挂载（M4-T3/D9：ChatPage）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'coordinator/ref_store.dart';
import 'llm/llm.dart';
import 'sandbox/memory_store.dart';
import 'ui/chat_page.dart';
import 'ui/navigator_key.dart';
import 'ui/tokens/console_tokens.dart';

void main() {
  runApp(const GoodHubApp());
}

/// 端侧引擎生命周期策略（§2 预热：前台活跃期预加载驻留，Doze/后台期释放）：
/// resumed 时后台预热引擎（「唤醒中」窗口 = warmup 完成前），paused 时释放权重内存。
/// 预热失败只留痕不打扰（端侧本就是兜底路径，下次 generate 自有懒加载兜底）。
class GoodHubApp extends StatefulWidget {
  const GoodHubApp({super.key});

  @override
  State<GoodHubApp> createState() => _GoodHubAppState();
}

class _GoodHubAppState extends State<GoodHubApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _warmEngine();
    _sweepMemoryStartup();
    _sweepRefStoreStartup();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _warmEngine();
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        unawaited(ChannelLlmEngine().release());
      case AppLifecycleState.inactive:
        break; // 系统弹层等瞬态，不折腾引擎
    }
  }

  Future<void> _warmEngine() async {
    final engine = ChannelLlmEngine();
    if (!await engine.isAvailable) return;
    final ok = await engine.warmup();
    debugPrint('[LlmEngine] warmup(${ok ? 'done' : 'no model'})');
  }

  /// M4-T2 记忆沙盒启动清扫（architecture §11「启动时清理超限旧档」+ 崩溃
  /// 残留 tmp）：维护性动作，失败 DEGRADE 留痕不阻断启动。
  Future<void> _sweepMemoryStartup() async {
    try {
      final support = await getApplicationSupportDirectory();
      await MemoryStore.underSupportDir(support.path).sweepStartup();
    } catch (e) {
      debugPrint('[DEGRADE] memory-sweep: $e');
    }
  }

  /// §9 启动幂等清池（C-3 定案 + 对账轮 #10 闭环）：`sweepStartupOrphans`
  /// API 与单测早就在位但从未挂启动——进程被杀（OOM/系统清理）后 TTL GC 停摆，
  /// 残留 `ref_*.tmp` 孤儿由冷启动兜底全清。维护性动作，失败 DEGRADE 留痕。
  Future<void> _sweepRefStoreStartup() async {
    try {
      final cache = await getTemporaryDirectory();
      await RefStore(cacheDir: cache, gcInterval: null).sweepStartupOrphans();
    } catch (e) {
      debugPrint('[DEGRADE] refstore-sweep: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    // page-revamp P0：tokens 唯一在 App 级注入（浅/深双套随系统），页面不再
    // 自拼 ThemeData（goodhub-ui skill 纪律：consoleTokens 从 Theme 取值）。
    //
    // C2（page-beautify）：统一色彩源——原 ColorScheme.fromSeed(indigo) 派生
    // 的 primary 与 ConsoleTokens.dataRef（Indigo 400）过近，用户轮卡的数据
    // 指针竖条被误读为「选中态」；且默认 Material 组件（FilledButton/AppBar/
    // ListTile selected） indigo 主色与「语义色只给系统状态」的 ui-design §1
    // 纪律冲突。修法 = seed 降中性 Zinc 500 + surface 系列显式贴 §1 底色表
    // （浅 Slate 50/100，深 Zinc 900/950）；业务语义色唯一出处仍是
    // ConsoleTokens，Material scheme 只承担中性基底与默认组件外观。
    return MaterialApp(
      title: 'GoodHub',
      navigatorKey: appNavigatorKey, // 网关 L2 远程确认卡等后台弹层入口
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: _consoleScheme(Brightness.light),
        extensions: [ConsoleTokens.light],
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: _consoleScheme(Brightness.dark),
        extensions: [ConsoleTokens.dark],
      ),
      themeMode: ThemeMode.system,
      home: const ChatPage(),
    );
  }

  /// C2（page-beautify）：中性控制台基底——Zinc 500 中性种子（交互色由种子
  /// 派生的近灰阶，杜绝「两个 indigo」）+ surface 家族贴 ui-design §1：
  /// 浅色 Slate 50/100（白卡 Slate 100），深色 Zinc 950 底 / Zinc 900 容器。
  static ColorScheme _consoleScheme(Brightness brightness) {
    final seeded = ColorScheme.fromSeed(
      seedColor: const Color(0xFF71717A), // Zinc 500
      brightness: brightness,
    );
    final light = brightness == Brightness.light;
    return seeded.copyWith(
      surface: light ? const Color(0xFFF8FAFC) : const Color(0xFF09090B),
      surfaceContainerLowest:
          light ? Colors.white : const Color(0xFF09090B),
      surfaceContainerLow:
          light ? const Color(0xFFF1F5F9) : const Color(0xFF18181B),
      surfaceContainer:
          light ? const Color(0xFFF1F5F9) : const Color(0xFF18181B),
      surfaceContainerHigh:
          light ? const Color(0xFFE2E8F0) : const Color(0xFF27272A),
      surfaceContainerHighest:
          light ? const Color(0xFFE2E8F0) : const Color(0xFF27272A),
      onSurface:
          light ? const Color(0xFF0F172A) : const Color(0xFFFAFAFA),
      onSurfaceVariant:
          light ? const Color(0xFF475569) : const Color(0xFFA1A1AA),
      outline: light ? const Color(0xFFCBD5E1) : const Color(0xFF3F3F46),
      outlineVariant:
          light ? const Color(0xFFE2E8F0) : const Color(0xFF27272A),
    );
  }
}
