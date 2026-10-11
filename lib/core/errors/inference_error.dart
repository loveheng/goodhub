/// 推理域异常：端侧/混合路由与任务推理内核的失败。
/// 与云端协议路径的 [CloudLlmException]（cloud_llm_error.dart）平行分域。
library;

class InferenceException implements Exception {
  const InferenceException(this.message);

  final String message;

  @override
  String toString() => 'InferenceException: $message';
}
