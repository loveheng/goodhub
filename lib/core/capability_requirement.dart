/// 能力需求声明值对象（task-capability W2 · S13；设计 SSOT =
/// `docs/design/on-device-task-capability.md` §4.1）。
///
/// **定位**：任务或步骤级的能力适用性契约——声明「这一步需要什么」，
/// 而非它看起来像什么。路由判据改造（S14）从间接推断（有没有工具 /
/// 工具面是否全本地）改读本声明的显式字段。
///
/// **保守缺省红线**：声明缺省时一律取保守侧（宁可选云端，不误判端侧
/// 可用）。缺省行为本身是被测对象（`test/core/capability_requirement_test.dart`
/// 回归钉）：任何新增维度必须显式给出缺省值，缺省变更需同步回归钉。
///
/// **正交性（K10）**：`canRunOffline` 是**下限约束**（云端不可达时仍要
/// 能完成），`localOnly` 是**排除约束**（任何情况下都不许出境）——二者
/// 不互斥也不互相推导，可同时为真（离线且不出境 = 端侧唯一路径）。
library;

/// 数据体量档（决定走对话通道还是大载荷通道；S14 窗口准入维度）。
enum PayloadScale {
  /// 小体量：短文本、单条消息级。
  small,

  /// 中体量（缺省）：常规输入。
  medium,

  /// 大体量：长文档 / 大载荷。
  large,
}

/// 时效档（S14b 时效判定维度）。
enum LatencyClass {
  /// 交互级：结果须即时可见，冷装载等待不可接受（遇冷态按 D3 分流）。
  interactive,

  /// 批处理级（缺省）：可等待装载与排队。
  batch,
}

/// 能力需求声明（不可变值对象）。
class CapabilityRequirement {
  /// 是否需要调用外部工具。**缺省保守取「需要」**（needsTools=true 时
  /// 端侧放行被挡，落云端）。
  final bool needsTools;

  /// 是否需要约束解码 / 结构化产出。缺省「不需要」——K15：结构化场景
  /// 禁截断降级档，声明为真时端侧须有约束解码承载（S17b）方可放行。
  final bool needsStructuredOutput;

  /// 云端不可达时是否仍必须可完成（**下限约束**，非排除约束）。缺省
  /// 不要求。
  final bool canRunOffline;

  /// 该步是否**禁止**使用云端（**排除约束**）。缺省不禁止——端侧是
  /// 可选加速路径、云端是产出基线。为真时路由落空**快速失败不切云**。
  final bool localOnly;

  /// 本步可用的输入 + 输出 token 预算；null = 不预留余量，由对照表与
  /// 资产窗口共同裁决（S14c 接 `lib/core/tokens.dart` 口径）。
  final int? tokenBudget;

  /// 数据体量档，缺省中。
  final PayloadScale payloadScale;

  /// 时效档，缺省批处理级（宁可选云端，不误判端侧可等）。
  final LatencyClass latencyClass;

  /// 是否优先本地算力（用户偏好或策略指定）。缺省不偏好。
  ///
  /// **优先级（S15）**：声明 > 用户偏好 > 准入画像 > 降级链冷却态；
  /// 声明不可满足时显式失败，不被偏好覆盖——本字段不作用于
  /// `needsTools` / `localOnly` 等声明自身的可满足性判定。
  final bool preferLocal;

  const CapabilityRequirement({
    this.needsTools = true,
    this.needsStructuredOutput = false,
    this.canRunOffline = false,
    this.localOnly = false,
    this.tokenBudget,
    this.payloadScale = PayloadScale.medium,
    this.latencyClass = LatencyClass.batch,
    this.preferLocal = false,
  }) : assert(tokenBudget == null || tokenBudget > 0, 'tokenBudget 须为正');

  /// 保守缺省声明：所有维度取缺省侧 = 不误判端侧可用（S14 判定链在
  /// 无声明输入时应当落云端基线）。
  static const CapabilityRequirement conservative = CapabilityRequirement();

  /// 值对象等价：全字段相等（S14 判定链缓存 / 声明去重用）。
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CapabilityRequirement &&
          other.needsTools == needsTools &&
          other.needsStructuredOutput == needsStructuredOutput &&
          other.canRunOffline == canRunOffline &&
          other.localOnly == localOnly &&
          other.tokenBudget == tokenBudget &&
          other.payloadScale == payloadScale &&
          other.latencyClass == latencyClass &&
          other.preferLocal == preferLocal;

  @override
  int get hashCode => Object.hash(needsTools, needsStructuredOutput,
      canRunOffline, localOnly, tokenBudget, payloadScale, latencyClass,
      preferLocal);

  @override
  String toString() => 'CapabilityRequirement('
      'needsTools: $needsTools, needsStructuredOutput: $needsStructuredOutput, '
      'canRunOffline: $canRunOffline, localOnly: $localOnly, '
      'tokenBudget: $tokenBudget, payloadScale: ${payloadScale.name}, '
      'latencyClass: ${latencyClass.name}, preferLocal: $preferLocal)';
}
