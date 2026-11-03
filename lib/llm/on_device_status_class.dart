import 'on_device_engine.dart';

/// 端侧引擎状态三分类单源（task-capability W1-S01）。
///
/// 此前状态语义散落两处且**相反**：`on_device_load_poll.dart` 把 `reloading`
/// 归入终态轮询出口，`on_device_engine_aidl.dart` 把它判可重试中断——同一
/// 状态两种归属，新增状态时必有一处漂移。本件是唯一分类入口，两处消费方
/// （装载轮询 / 装载受理）一律改读本分类，禁再各自内联判断。
///
/// 三分类口径（与 EngineStatus 逐条注释同源）：
///
/// - **过程态 [OnDeviceStatusClass.inProgress]**：装载尚在进行或状态未知，
///   轮询应继续（I2：未知≠终态，禁猜测终态）——`loading` / `unknownNeedReconcile`。
/// - **可重试中断 [OnDeviceStatusClass.retryable]**：环境性可自愈或预期内的
///   中断，非引擎故障，上层应重试而非判死——`reloading`（`:engine` 拒绝同进程
///   重载，进程自杀冷启动装载）/ `thermalCutoff`（热降级可自愈）。
/// - **终态 [OnDeviceStatusClass.terminal]**：真·失败，如实上抛由上层判生，
///   禁重试掩盖——`assetMissing`（真·未导入）/ `insufficientMemory` /
///   `circuitBroken` / `unsupportedDevice`。
/// - **就绪 [OnDeviceStatusClass.success]**：装载完成出口——`ready` / `busy`。
///   轮询的成功返回值，不参与失败分类；单列以防误归入终态。
enum OnDeviceStatusClass { success, inProgress, retryable, terminal }

/// [EngineStatus] → 三分类的唯一映射。新增枚举值必须同轮补一行，
/// 禁默认分支静默收容（收容即再造一处隐式语义）。
OnDeviceStatusClass onDeviceStatusClass(EngineStatus status) => switch (status) {
      EngineStatus.ready ||
      EngineStatus.busy =>
        OnDeviceStatusClass.success,
      EngineStatus.loading ||
      EngineStatus.unknownNeedReconcile =>
        OnDeviceStatusClass.inProgress,
      EngineStatus.reloading ||
      EngineStatus.thermalCutoff =>
        OnDeviceStatusClass.retryable,
      EngineStatus.assetMissing ||
      EngineStatus.insufficientMemory ||
      EngineStatus.circuitBroken ||
      EngineStatus.unsupportedDevice =>
        OnDeviceStatusClass.terminal,
    };
