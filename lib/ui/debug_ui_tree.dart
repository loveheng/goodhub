/// 控件语义树导出（实现已迁至公共包 `app_debug_bridge`；本文件保留原 import 路径）。
library;

export 'package:app_debug_bridge/app_debug_bridge.dart'
    show
        collectDebugUiTree,
        findUsableRenderBox,
        kDebugUiTreeMaxNodes,
        kDebugUiTreeMaxTextLength;
