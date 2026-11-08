---
memo: todos
format: v3
---

- [ ] [2026-11-08] (缺陷)(层:L3)(重:重) **litertlm 0.16.0（NPU 档·Gemma3-1B）生成不稳定：原语一次性 Conversation 间歇性/内容敏感静默零产出与退化输出**——真机实证（2026-11-08 多轮）：① executor 原语路径对特定内容族（即时摘要任务）恒 status=0 bytes=0 瞬时 EOS（700ms 真实 prefill + 零 token），池 requeue 连续吃同一硬币；② 同内容族输出 0/4/97B 乱跳（内容敏感非确定）；③ **对照锚：同 epoch 同模型聊天持久会话 5/5 正常**（chunks 6-233）；④ 简单问句 ladder（100-300 字）4/4 正常。**调用侧变量已全排除**（载荷指纹/prompt 逐字对账/装载沉降窗/后端/采样双档/requestId 唯一化/close 时序两轮生命周期修复实验均证伪，证据链 = on-device devlog 2026-11-08 五条 + goodshare ai-app-split todos 同日条）——归 SDK 内部（模板/分词/NPU 管线），宿主无可修缝位。**已落缓解层**：原语空产出单次即时重试 + AIDL onCancel 完成态守卫 + traceId 唯一化（litertlm 档减压不治愈）。**产品口径**：Qwen3.5-2B（llama_cpp 栈）为验收基准档（goodshare e2e --case ondevice 3/3 绿）；Gemma3-1B 档暂停验收跟踪（e2e 保持红作回归门）。**求方案方向**：① 升级 litertlm AAR 0.16.0→0.18.1（Gallery 同版，代码内既有备注同判，R4 升版需拍板）后 e2e 应转绿；② 凭证据链向上游 litertlm/Gallery 报 issue；③ 若 ①② 均不通，评估 Gemma3 档改走 GenieSession 栈（GGUF 转档）或下架该档。验收 = e2e --case ondevice 连续 3 轮全绿 (src: 2026-11-08 executor 空产出诊断定音轮，用户拍板挂 misc 找方案)
