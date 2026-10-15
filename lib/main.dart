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
    final scheme = ColorScheme.fromSeed(seedColor: Colors.indigo);
    return MaterialApp(
      title: 'GoodHub',
      navigatorKey: appNavigatorKey, // 网关 L2 远程确认卡等后台弹层入口
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        extensions: [ConsoleTokens.light],
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.indigo,
          brightness: Brightness.dark,
        ),
        extensions: [ConsoleTokens.dark],
      ),
      themeMode: ThemeMode.system,
      home: const ChatPage(),
    );
  }
}
