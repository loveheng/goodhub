/// 装配 Profile（施工稿 `docs/design/arch-consolidation.md` §S2）。
///
/// 现状痛点：`McpRuntime.assemble` 只有窗口路径调用，网关与任务管道各自拼装，
/// 三份接线不等价（活跃债 #21）。本件是收口第一步——把「哪些能力该接线」从
/// 代码里的隐式假设（恒按聊天路径接线）变为**显式声明**：
///
/// ```
/// assemble(profile: RunProfile.gateway) → 只接该 profile 声明的能力
/// ```
///
/// **只管能力上限（Capabilities Ceiling），不做主体裁剪**——调用主体（`Actor`）
/// 的每请求裁决在 `ToolDispatcher.call` 运行时校验（§S6），与 profile 正交。
library;

/// 运行场景。
enum RunProfile {
  /// 宿主聊天（有人值守 UI；全量能力）。
  chat,

  /// 聚合网关（headless 常驻；对外服务，无 UI 委托）。
  gateway,

  /// 任务管道（无人值守单任务；最小面）。
  headless,
}

/// 某个 profile 下允许接线的能力集（**只增不减的声明，不做事后裁剪**）。
class RunCapabilities {
  const RunCapabilities({
    required this.sampling,
    required this.elicitation,
    required this.cowSync,
    required this.planFence,
  });

  /// 反向推理（server → 宿主引擎）。无人值守路径关：宿主推理资源不无限外借。
  final bool sampling;

  /// 结构化提问（server → 宿主弹层）。**恒需有人值守 UI**：网关/任务管道无 UI
  /// 委托，接线即悬挂，故恒 false。
  final bool elicitation;

  /// 逐 server 模板（prompts）同步与 CoW 注入。常驻路径关：模板变更由聊天侧驱动。
  final bool cowSync;

  /// 多插件任务编排围栏（计划卡 / 批量授权）。仅在显式传入 `planState` 时生效。
  final bool planFence;

  static const RunCapabilities chat = RunCapabilities(
    sampling: true,
    elicitation: true,
    cowSync: true,
    planFence: true,
  );

  static const RunCapabilities gateway = RunCapabilities(
    sampling: true,
    elicitation: false,
    cowSync: false,
    planFence: false,
  );

  static const RunCapabilities headless = RunCapabilities(
    sampling: false,
    elicitation: false,
    cowSync: false,
    planFence: false,
  );
}

/// profile → 能力集（唯一映射点；新增 profile 必须在此登记）。
RunCapabilities capabilitiesFor(RunProfile profile) => switch (profile) {
      RunProfile.chat => RunCapabilities.chat,
      RunProfile.gateway => RunCapabilities.gateway,
      RunProfile.headless => RunCapabilities.headless,
    };
