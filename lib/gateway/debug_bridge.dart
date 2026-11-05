/// 观测桥（实现已迁至公共包 `app_debug_bridge`；本文件保留原 import 路径）。
///
/// 宿主侧只做「薄适配」：公共包不依赖任何宿主专有件，日志源 / 状态快照 /
/// 控件树 / 动作执行均由装配期注入（见 `lib/ui/debug_wiring.dart`）。
library;

export 'package:app_debug_bridge/app_debug_bridge.dart'
    show
        DebugBridge,
        DebugStateProvider,
        DebugUiTreeProvider,
        DebugActionHandler,
        DebugResetHandler,
        DebugLogSink,
        DebugLogEntry,
        kDebugBridgeDefaultPort,
        kDebugBridgeEndpoints;
