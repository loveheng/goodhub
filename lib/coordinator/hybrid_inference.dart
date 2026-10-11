/// 任务 note 推理内核（M2-T2）：混合引擎上的单发提取式推理。
///
/// 正文不预截断契约（workflow 速查口径）：goodshare 给全文，宿主按引擎上下文
/// 自行截断，且截断事实必须写进 note（自有降级 + note）——禁静默截断。
library;

import '../core/errors/inference_error.dart';
import '../llm/cloud/cloud_llm.dart';
import '../llm/cloud/tool_call_accumulator.dart';
import '../mcp/goodshare_task_api.dart';
import '../task/task_inference.dart';

class HybridTaskInference implements TaskInference {
  HybridTaskInference({
    required this.engine,
    this.maxInputChars = 6000,
    this.noteMaxTokens = 512,
  });

  /// 混合引擎（云端主力 + 端侧兜底，路由在引擎内完成）。
  final CloudLlmEngine engine;

  /// 输入截断护栏（字符级粗估；4096 ctx 引擎的安全余量，T7 实测调参）。
  final int maxInputChars;
  final int noteMaxTokens;

  static const _systemPrompt =
      '你是 GoodHub 宿主的任务处理引擎。根据任务类型对给定文本产出处理结果：'
      '输出直接可用的结果正文（摘要/关键词/回答等），不要输出解释、前言或代码块包裹。';

  @override
  Future<String> infer(ClaimedTask task) async {
    var text = task.text;
    var truncated = false;
    if (text.length > maxInputChars) {
      text = text.substring(0, maxInputChars);
      truncated = true;
    }
    final userPrompt = '任务类型：${task.taskAction}\n'
        '${truncated ? '（原文超长，以下仅为前 $maxInputChars 字）\n' : ''}'
        '任务内容：\n$text';
    final acc = await CloudStreamAccumulator.drain(engine.send(CloudChatRequest(
      messages: [
        const SystemMessage(_systemPrompt),
        UserMessage(userPrompt),
      ],
      maxTokens: noteMaxTokens,
    )));
    final note = acc.text.trim();
    if (note.isEmpty) {
      throw InferenceException('推理产出为空（引擎：${engine.name}）');
    }
    return truncated
        ? '$note\n\n（宿主注：原文超长，本次仅处理前 $maxInputChars 字）'
        : note;
  }
}
