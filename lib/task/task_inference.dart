/// 任务推理内核接口（M2，依赖倒置：接口住 task 层，实现住 coordinator 层）。
library;

import '../mcp/goodshare_task_api.dart';

abstract interface class TaskInference {
  /// 产出 apply 回写的 note。
  ///
  /// 失败抛领域异常（InferenceException / CloudLlmException），由 runOnce
  /// 上抛并经 LoopFailed 事件通告——禁止静默兜底空 note（R1：note 必须携带真值）。
  Future<String> infer(ClaimedTask task);
}
