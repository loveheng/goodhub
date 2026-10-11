/// token 字符级粗估（口径 SSOT）。
///
/// CJK 主场 1 字符 ≈ 1 token 的上界口径（与 hybrid_inference `maxInputChars`
/// 同族），阈值初值 T7 真机实测调参。原实现住 context_governor（M2-T6 上下文
/// 治理），M4-T1 记忆沙盒预算截断需同口径但层级更低（沙盒 ④ 不得逆向依赖编排
/// ②），下沉至 core；context_governor 原位 re-export 保持既有 import 兼容。
library;

/// 估算 [text] 的 token 数（字符级上界，禁用于计费口径）。
int estimateTokens(String text) => text.length;
