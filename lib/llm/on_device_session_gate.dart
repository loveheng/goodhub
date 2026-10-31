import 'on_device_engine.dart';
import 'on_device_session_ticket.dart';

/// 生成前会话闸门（M2 第一刀；设计 =
/// `docs/design/on-device-lifecycle-single-source.md` §2.3/§2.4）。
///
/// 权威在 `:engine`：**票据说未就绪就不许直接生成**——2026-10-31 真机两类
/// 事故的共同解药：
///  1. 主进程 `loadState` 说谎 ready → `HybridCloudEngine` 跳过 `enable()` →
///     撞 `genie session not ready`；
///  2. `:engine` 冷启动 / 被回收后退避重启 → 绑定握手 3s 未连接 → 此前**原地
///     判死**为 `StateError`（既不重试也不切云，还被读成「设备不支持」）。
///
/// 两者在机制上是同一件事：**拿不到权威票据 = 状态未知**（I2）。未知的唯一
/// 正解是「交给装载链路重新对账」，而不是本地推断或判死。判定与装载分离：
/// 本件只做「取票据 → 非就绪/未知则调 [load]」，装载语义（重连 / 单飞 / 资产
/// / 内存门禁 / B-2 退避重试）**全部由 [load]（= `enable`）承载**，不引入第二
/// 套装载路径（I7）。
///
/// 返回 null = 放行；否则返回待上抛的错误对象：
///  - [OnDeviceLoadException] 终态（不可重试）→ 上层显式报错、不切云（q-1）；
///  - [EngineDiedException] 可自愈中断 / 装载后仍未就绪 → 上层切云完成本轮。
Future<Object?> ensureSessionReadyForGenerate({
  required Future<SessionTicket?> Function() fetch,
  required Future<EngineStatus> Function() load,
  required bool connected,
  void Function(String)? log,
}) async {
  if (!connected) {
    // 未连接 → 票据必然取不到（I2）：交装载链路（内含 bind + 有界等待 +
    // 退避重试）接管，**绝不原地判死**。
    log?.call('[on-device] session-gate: :engine 未连接 → 交装载链路重连装载');
    return _loadAndVerify(fetch: fetch, load: load, log: log);
  }
  SessionTicket? ticket;
  try {
    ticket = await fetch();
  } catch (e) {
    // M2 判定口径（I2）：通道异常 = 票据取不到 = 未知态——交装载链路重新
    // 对账（内含 bind/有界等待/退避），不猜测放行（expectEpoch 空票会被
    // :engine 权威拒绝，兜底已就位）。
    log?.call('[DEGRADE] session-gate: ticket fetch failed: $e → 交装载链路');
    return _loadAndVerify(fetch: fetch, load: load, log: log);
  }
  if (ticket == null) return _loadAndVerify(fetch: fetch, load: load, log: log);
  if (ticket.status == EngineStatus.ready ||
      ticket.status == EngineStatus.busy) {
    return null; // 权威说就绪 → 放行（零额外开销：一次 AIDL 取票据）
  }
  log?.call('[on-device] session-gate: :engine=${ticket.status.name} '
      '(ticket=${ticket.instanceId}#${ticket.seq}) → 装载后再生成');
  return _loadAndVerify(fetch: fetch, load: load, log: log);
}

/// 装载 + 复核（I1：装载完仍以**权威票据**裁定，不信本地态）。
Future<Object?> _loadAndVerify({
  required Future<SessionTicket?> Function() fetch,
  required Future<EngineStatus> Function() load,
  void Function(String)? log,
}) async {
  try {
    await load();
  } on OnDeviceLoadException catch (e) {
    // 可自愈（进程中断 / 热降级）→ 切云信号；终态 → 原样显式报错。
    if (e.retryable || e.degraded) {
      return EngineDiedException('端侧装载未完成：${e.reason} → cloud fallback');
    }
    return e;
  } catch (e) {
    return StateError('端侧装载失败：$e');
  }
  try {
    final after = await fetch();
    if (after != null &&
        after.status != EngineStatus.ready &&
        after.status != EngineStatus.busy) {
      return EngineDiedException(
          '端侧装载后仍未就绪（:engine=${after.status.name}）→ cloud fallback');
    }
  } catch (e) {
    log?.call('[DEGRADE] session-gate: post-load verify failed: $e');
  }
  return null;
}
