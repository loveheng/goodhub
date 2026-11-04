/// 调用方进程死亡联动打断（task-capability W5 · 调用方进程死亡联动打断，
/// K17）。
///
/// **问题面**：跨 App 调用经同机 IPC，调用方进程可能被系统回收或被用户强退；
/// 若无死亡感知，宿主会继续跑完剩余推理——占着算力空转发热，回写时才察觉
/// 对端已消失（孤儿执行算力泄漏）。
///
/// **红线（设计稿 §6）**：既有方向的死亡代理（宿主作**客户端**感知插件死亡
/// ——`binder_transport` 的 `binderDied` 死亡信封，收敛宿主 client 在途请求）
/// **不覆盖反向路径**（宿主作**算力提供方**时感知**调用方**死亡）。本件是
/// **新增链路**：平台侧为调用方链路注册**独立**死亡代理 → 推 `onCallerDied`
/// → 本注册表按调用方身份键**协作式打断**其名下在途的端侧执行
/// （`completeStream` 订阅取消 → 透传 `cancel(requestId)` 让槽）并**作废本次
/// 调用**（产出即弃，不回程）。
///
/// **依赖方向**：本件住 coordinator；`binder_transport`（mcp 层）经
/// [BinderTransport.onCallerDeath] 静态钩子通知（mcp 不反向依赖 coordinator
/// ——钩子由本件的装配接线注入）。
///
/// **单例铁律**：注册表必须**全进程唯一**。两个实例意味着死亡通知只打到其中
/// 一个，另一份在途注册永不被打断——漏打断 = 孤儿算力空跑，K17 目标落空。
/// 故 [ensureCallerDeathInterruptWired] 复用既有单例而非覆盖（覆盖会丢掉已
/// 注册的在途条目）。
library;

import 'dart:async';

import '../mcp/transport/binder_transport.dart';

/// 调用方死亡打断注册表（单实例，装配层持有）。
class CallerDeathInterrupt {
  final Map<String, List<_ActiveCall>> _active = {};

  /// 注册一个在途调用：[callerKey] = 调用方身份键（Binder 路径 = 插件包名，
  /// 物理主键——**必须与平台侧死亡事件携带的键同源**，混用即匹配不上），
  /// [cancel] = 协作式打断回调（订阅取消 → 引擎 cancel(requestId) 让槽）。
  /// 返回注销函数（finally 恒调；幂等）。
  void Function() register(String callerKey, Future<void> Function() cancel) {
    final entry = _ActiveCall(cancel);
    (_active[callerKey] ??= <_ActiveCall>[]).add(entry);
    return () {
      entry.done = true;
      final list = _active[callerKey];
      if (list == null) return;
      list.remove(entry);
      if (list.isEmpty) _active.remove(callerKey);
    };
  }

  /// 调用方进程死亡通知：协作式打断该 callerKey 名下全部在途执行（订阅
  /// 取消 → 引擎让槽）——产出由执行器作废，不回程。未知 callerKey 无操作
  /// （该调用方无在途执行）。注销过的条目不重复打断。
  Future<void> notifyDeath(String callerKey) async {
    final list = _active.remove(callerKey);
    if (list == null || list.isEmpty) return;
    for (final entry in List.of(list)) {
      if (entry.done) continue; // 已正常收尾（竞态防御）
      entry.done = true;
      try {
        await entry.cancel();
      } on Object {
        // 打断回调失败不阻断其余条目（best-effort；引擎让槽由引擎层兜底）。
      }
    }
  }

  /// 观测面：callerKey 名下在途数（测试/遥测用）。
  int activeCount(String callerKey) => _active[callerKey]?.length ?? 0;

  /// 观测面：在途条目总数（测试/遥测用）。
  int get totalActiveCount =>
      _active.values.fold(0, (sum, list) => sum + list.length);
}

/// mcp 层死亡事件 → 本注册表的桥接（装配层注入；mcp 不反向依赖 coordinator）。
CallerDeathInterrupt? callerDeathInterruptSingleton;

/// 装配接线（**单点、幂等**）：把调用方死亡注册表挂到 mcp 层**新增**死亡链路
/// （[BinderTransport.onCallerDeath]，来源 = 平台侧独立死亡代理推来的
/// `onCallerDied` 事件）。
///
/// 由宿主装配层调用（McpRuntime 与 Gateway 两装配点经 `wireSampling` 共享件
/// 同款调用，消第二副本）；重复调用复用同一注册表（**禁覆盖**——覆盖会丢掉
/// 已注册的在途条目，导致死亡通知打空）。
///
/// 已存在外部自定义钩子时**不覆盖**（`??=`）——外部注入优先。
CallerDeathInterrupt ensureCallerDeathInterruptWired() {
  final registry = callerDeathInterruptSingleton ??= CallerDeathInterrupt();
  BinderTransport.onCallerDeath ??= (String callerKey) {
    // 未 await：钩子为同步签名（mcp 层不依赖 coordinator），打断为 best-effort
    // 异步执行；未捕获错误由注册表内部收口。
    unawaited(registry.notifyDeath(callerKey));
  };
  return registry;
}

/// 测试隔离用：清空全局接线（生产代码禁调用）。
void resetCallerDeathInterruptForTest() {
  callerDeathInterruptSingleton = null;
  BinderTransport.onCallerDeath = null;
}

class _ActiveCall {
  _ActiveCall(this.cancel);

  final Future<void> Function() cancel;
  bool done = false;
}
