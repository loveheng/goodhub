/// goodhub 应用入口与全局装配（平台实现仅在此装配，coding-standards §1）：
/// 端侧引擎生命周期策略 + 记忆沙盒启动清扫 + `$ref` 暂存池启动清池（§9）
/// + 首页挂载（M4-T3/D9：ChatPage）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'app/task_consume_bootstrap.dart';
import 'core/app_log.dart';
import 'coordinator/ref_store.dart';
import 'task/task_consume_ledger.dart';
import 'llm/on_device_bench.dart';
import 'llm/on_device_engine_aidl.dart';
import 'llm/geniex_runtime_binding.dart';
import 'llm/on_device_asset_manager.dart';
import 'llm/on_device_model_catalog.dart';
import 'sandbox/memory_store.dart';
import 'ui/chat_page.dart';
import 'ui/navigator_key.dart';
import 'ui/tokens/app_theme.dart';

/// S2-5 一次性熔断复位触发（测量期构建专用，PATCH 验证收口后退役）：
///   --dart-define=ON_DEVICE_BREAKER_RESET=true
/// §6.5 reset 语义 = 手动清缓存/模型版本更新路径；用于验证轮间清锁。
const bool kOnDeviceBreakerReset =
    bool.fromEnvironment('ON_DEVICE_BREAKER_RESET', defaultValue: false);

/// P2 验收触发（测量期构建专用，验收后退役）：启动引导期自动安装 GenieX
/// 增配（写新指纹 marker），用于「正常装」场景自动化——
///   --dart-define=ON_DEVICE_GENIEX_INSTALL=true
const bool kGeniexAutoInstall =
    bool.fromEnvironment('ON_DEVICE_GENIEX_INSTALL', defaultValue: false);

/// P3 弱网演练触发（测量期构建专用）：先卸载（删指纹 marker + 运行目录）
/// 再安装——绕过 installed() 短路，演练「干净装/断点续传/换版清理」全链。
///   --dart-define=ON_DEVICE_GENIEX_REINSTALL=true
const bool kGeniexAutoReinstall =
    bool.fromEnvironment('ON_DEVICE_GENIEX_REINSTALL', defaultValue: false);

void main() async {
  // 三态主题（暗/亮/暖）持久化于 SharedPreferences，启动期读取后注入单例，
  // 再 runApp——避免首帧用错主题闪一下。
  WidgetsFlutterBinding.ensureInitialized();
  // 日志捕获 sink（调试页数据源）：先装再跑，启动期 debugPrint 即入缓冲。
  AppLog.install();
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
    _bootstrapOnDeviceEngine();
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
        // **退后台不再主动释放端侧权重**（路线 B 裁决 2026-10-30）。
        //
        // 旧行为 = 无条件 `release()`（释放 `:engine` 权重内存），与「端侧必须
        // 服务后台任务」这一核心用例**直接冲突**：后台任务跑到一半被退后台
        // 钩子 abort + 释放权重，下次请求还得重装（~2.7s 暖机 + ~3.2GB 峰值），
        // 且退后台瞬间击杀在途属高频必现路径。
        //
        // 新口径 = 权重回收**完全交给 `:engine` 侧**：TTL（空闲 5min 驱逐）+
        // 内存预算护栏（逼近 LMK 即使 TTL 内也提前驱逐）；`:engine` 常驻期间
        // 由 FGS 提权保护（**绑定即挂**，见 `EngineService.initEngine`），
        // 使其免于 OEM 冻结 / mem-pressure 回收。
        //
        // 显式停用（用户 disable / 切模型）仍走 [AidlOnDeviceEngine.release]
        // 强制释放。
        break;
      case AppLifecycleState.inactive:
        break; // 系统弹层等瞬态，不折腾引擎
    }
  }

  /// 端侧引擎预热（§2 前台驻留策略）：resumed 时后台预热 AIDL `:engine` 进程
  /// （bind + 等就绪事件，由 `sharedOnDeviceEngine` 承接）。已热时幂等 no-op；
  /// 预热失败只留痕不阻断（端侧为兜底路径，下一次 generate 自有懒加载兜底）。
  Future<void> _warmEngine() async {
    await sharedOnDeviceEngine.warmup();
    debugPrint('[on-device] warmup requested');
  }

  /// 端侧引擎启动引导（S2 正式接线，接替 S2-1 冒烟）：bind + 等就绪事件
  /// （bind 竞态正式收口，无固定 sleep）→ 查询结构化状态 → assetMissing 时
  /// 经 S2-2 正式 OTA 通道（OnDeviceAssetManager：manifest 分发 + sha256
  /// 校验 + ≥5GB 门禁 + 原子替换，NPU 稿 §4.5/§4.6）补齐模型资产；已装资产
  /// 先过驱动指纹漂移自愈（§4.8：系统 OTA 更新 DSP 驱动 → 脏删重拉，不计
  /// 熔断）→ 受理 loadModel 异步会话创建。失败 DEGRADE 留痕不阻断启动
  /// （端侧为可选加速路径，云端默认通路不受影响）。
  Future<void> _bootstrapOnDeviceEngine() async {
    try {
      if (kOnDeviceBreakerReset) {
        // §6.5 reset 语义（手动清缓存路径）：测量轮间清 L1/L2 锁。
        await sharedOnDeviceEngine.breaker.reset();
        debugPrint('[on-device-breaker-diag] reset done state=${await sharedOnDeviceEngine.diagBreakerState()}');
      }
      // 端侧改为「按需显式加载」：启动**不再**自动 bind / loadModel——模型权重
      // （~1.9GB）不驻留、:engine 进程不预启，端侧默认不启用。仅做轻量驱动指纹
      // 漂移自愈（脏资产标记，首次 enable 重拉），不占内存。实际装载 + 数据面
      // worker 推迟到首次命中端侧路径（HybridCloudEngine 懒加载兜底 + 显式
      // loading 指示，见 on_device_engine_aidl.enable）。
      final model = await OnDeviceModelSelection.read();
      await OnDeviceAssetManager.instance.recoverIfDriverChanged(model: model);
      final engine = sharedOnDeviceEngine;
      if (kOnDeviceBenchOnReady) {
        // §1.2 吞吐正式测量：先显式加载（bind→就绪→资产→loadModel→worker），
        // 就绪后跑测量（enable 已保证 ready，无需额外就绪轮询）。
        // P2 验收（测量期）：启动引导期自动安装 GenieX 增配（写新指纹
        // marker），受理后轮询就绪——bench 装载须在安装完成后。
        if (kGeniexAutoInstall || kGeniexAutoReinstall) {
          if (kGeniexAutoReinstall) {
            // 演练口径：连 AAR 缓存一起清 → 强制全新下载（可被断网打断造
            // partial），供断点续传/缓存复用两场景分别演练。
            await GenieXRuntimeControl.uninstall(deleteCache: true);
          }
          final mirrors = await GenieXRuntimeControl.loadMirrors();
          await GenieXRuntimeControl.install(mirrors);
          for (var i = 0; i < 60; i++) {
            final st = await GenieXRuntimeControl.status();
            if (st.installed) { debugPrint('[geniex-auto] installed after ~${i * 2}s'); break; }
            await Future.delayed(const Duration(seconds: 2));
          }
        }
        // 显式指定 MODEL_DIR 时跳过 enable（否则 bootstrap 会话先 ready，
        // EngineService.loadModel 幂等闸拒绝重建 → 显式装载被短路）。
        if (kOnDeviceBenchModelDir.isEmpty) {
          await engine.enable();
        }
        await OnDeviceBench.run();
      }
    } catch (e) {
      debugPrint('[DEGRADE] on-device bootstrap: $e');
    }
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
