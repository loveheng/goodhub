/// goodhub 应用入口与全局装配（平台实现仅在此装配，coding-standards §1）：
/// 端侧引擎生命周期策略 + 记忆沙盒启动清扫 + `$ref` 暂存池启动清池（§9）
/// + 首页挂载（M4-T3/D9：ChatPage）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'app/task_consume_bootstrap.dart';
import 'coordinator/ref_store.dart';
import 'task/task_consume_ledger.dart';
import 'llm/llm.dart';
import 'sandbox/memory_store.dart';
import 'ui/chat_page.dart';
import 'ui/navigator_key.dart';
import 'ui/tokens/app_theme.dart';

void main() async {
  // 三态主题（暗/亮/暖）持久化于 SharedPreferences，启动期读取后注入单例，
  // 再 runApp——避免首帧用错主题闪一下。
  WidgetsFlutterBinding.ensureInitialized();
  final initial = await readAppTheme();
  AppThemeController.instance = AppThemeController(initial);
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
    _startTaskConsume();
  }

  @override
  void dispose() {
    taskConsumeBootstrap.dispose(); // §3.12.2-7 生命周期解绑（清定时器 + 释放 client）
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

  /// M4-2：宿主上线即接管 goodshare 任务消费（契约 §3.12「catch-up 是地基」）。
  /// 拉模型下 goodshare 不推任务——宿主不主动 claim 则任务永久滞留 pending。
  /// 启动触发一次 catch-up（后续由跨仓通知加速，无通知也能靠本路径工作）。
  /// 失败仅 DEGRADE 留痕（插件未安装 / 未发现 / 引擎未配置均不阻断启动）。
  Future<void> _startTaskConsume() async {
    // 对账账本（跨会话持久化）：支持目录异步获取后再装配，与设置页对账分区
    // 共享同一实例；装配失败仅 DEGRADE（不记账不影响消费）。
    try {
      final support = await getApplicationSupportDirectory();
      taskConsumeBootstrap.ledger =
          TaskConsumeLedger.underSupportDir(support.path);
    } on Object catch (e) {
      debugPrint('[DEGRADE] task-ledger attach: $e');
    }
    unawaited(taskConsumeBootstrap.start().then((loop) {
      debugPrint('[task-consume] ${loop == null ? 'skip' : 'started'}');
    }));
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
    // page-revamp P0：tokens 唯一在 App 级注入（三套主题随用户选择），页面不再
    // 自拼 ThemeData（goodhub-ui skill 纪律：consoleTokens 从 Theme 取值）。
    //
    // C2（page-beautify）：统一色彩源——原 ColorScheme.fromSeed(indigo) 派生
    // 的 primary 与 ConsoleTokens.dataRef（Indigo 400）过近，用户轮卡的数据
    // 指针竖条被误读为「选中态」；且默认 Material 组件（FilledButton/AppBar/
    // ListTile selected） indigo 主色与「语义色只给系统状态」的 ui-design §1
    // 纪律冲突。修法 = seed 降中性 Zinc 500（暖=Stone 500）+ surface 系列显式
    // 贴 §1 底色表；业务语义色唯一出处仍是 ConsoleTokens，Material scheme 只
    // 承担中性基底与默认组件外观。主题装配见 `ui/tokens/app_theme.dart`。
    //
    // 三态主题（暗/亮/暖）由 [AppThemeController] 驱动：监听其变化重建
    // MaterialApp，themeMode 恒为 light（theme 已含正确 brightness 与 surface），
    // 故单套 theme 即可覆盖三态，无需 darkTheme 分流。
    return AnimatedBuilder(
      animation: AppThemeController.instance,
      builder: (context, _) => MaterialApp(
        title: '拾圆',
        navigatorKey: appNavigatorKey, // 网关 L2 远程确认卡等后台弹层入口
        theme: buildAppTheme(AppThemeController.instance.value),
        themeMode: ThemeMode.light,
        home: const ChatPage(),
      ),
    );
  }
}
