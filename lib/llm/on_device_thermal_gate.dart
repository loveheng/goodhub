/// 端侧引擎热切云闸门（on-device S3-1，NPU 稿 §5.2/§5.3）。
///
/// 状态由 `:engine` 侧 `PowerManager.addThermalStatusListener` 驱动（热状态
/// 权威在 :engine 进程，§5.3 公共 API），经 AIDL `onThermalCutover(active)`
/// 同步到主进程：
///  - active=true（热状态 ≥ SEVERE）：闸门关闭——generate 以
///    [EngineDiedException] 快速失败，混合引擎捕获即无缝切云（§5.2
///    Thermal→Cloud 行「达 SEVERE 级经 HybridCloudEngine 收口云端」）；
///    **禁 CPU 分流**（§5.2 决策行：CPU 能效差 5~10×，分流加剧发热）。
///  - active=false（热状态回落 MODERATE 及以下）：闸门复开，端侧恢复。
///
/// 迟滞由 :engine 侧状态机承载（进入沿 ≥SEVERE / 退出沿 ≤MODERATE，滞回带
/// = POWERSAVE 档继续端侧），本闸门只持布尔沿，不重复判档。
///
/// 独立于熔断器（§6.5）：热切云是**环境降级**非引擎故障——不计入熔断计数、
/// 无冷却窗口、无持久化锁；恢复由热状态自然驱动。`checkStatus` 同期返回
/// circuitBroken（环境降级可自愈语义，禁 TTL 缓存 v2.6 同样适用）。
class EngineThermalGate {
  bool _cutoffActive = false;

  /// 切云闸当前态（进程内存态：热状态本就随进程生命周期，无需持久化）。
  bool get cutoffActive => _cutoffActive;

  /// 切云沿回调（:engine AIDL onThermalCutover 直通；初态由 initEngine 后
  /// 的即时回报对齐，覆盖绑定晚于升温的时序）。
  void setCutoff({required bool active}) => _cutoffActive = active;
}
