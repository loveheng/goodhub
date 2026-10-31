package com.zzh.goodhub;

import android.os.Bundle;
import android.os.ParcelFileDescriptor;
import android.os.SharedMemory;
import com.zzh.goodhub.IOnDeviceEngineListener;

// 端侧引擎控制面 AIDL 契约（立法源 = docs/design/on-device-capability.md §2 v2.7）。
// 控制面低频（次/分钟级），数据面 token 流走 UDS socketpair
//（on-device-npu-deployment.md §6.1 v3.1，读端 fd 经本接口一次性移交）。
interface IOnDeviceEngineService {
    // 初始化引擎，返回 EngineStatus 枚举序数（0=ready .. 5=unsupportedDevice）。
    // 契约细化（S1-2）：v2.7 §2 要求 EngineDied 由 :engine 侧主动通知但未指定
    // 传输面，此处以 listener 入参承载（AIDL 标准做法）。
    int initEngine(in Bundle config, IOnDeviceEngineListener listener);

    // 数据面句柄（S3-7 UDS 化）：契约细化——数据面 = AF_UNIX SOCK_STREAM
    // socketpair，:engine 持写端（SocketTokenWriter 长度前缀成帧），读端经
    // Binder 以 ParcelFileDescriptor 传主进程（detachFd 移交所有权后由
    // native worker（libgdw）持有读循环）。成帧协议 = [4B 大端 len][payload]，
    // len==0 = EOS 流终结帧；对端关闭（EOF）= 数据面死亡，读端自愈重建。
    ParcelFileDescriptor getDataSocketFd();

    // 模型装载（S2 正式接线）：:engine 后台线程创建 Genie 持久会话（幂等——
    // 已就绪/创建中重复调用不重建）。modelDir = 模型资产目录（genie_config.json
    // + ctx-bins 所在，Dart 侧 OTA/冒烟通道落位）。立即返回 EngineStatus 序数：
    // ready=已就绪 / loading=受理异步创建中（M4）/ reloading=拒绝同进程重载、
    // 进程将自杀重启装载（Fix1 追加序数 8，**可重试中断非终态**——主进程按
    // 短退避重试接住冷启动后的新进程）/ assetMissing=资产不全（终态，M4 起
    // 回归真·缺失语义）/ unsupportedDevice=驱动基线未过或参数缺失。
    // 创建耗时秒级（Dialog_create 暖机）。
    // 契约细化（M2 §2.5 I3）：modelId = 资产面单点计算的资产身份
    //（目录名@meta版本摘要）——票据回显此值，主进程据「票据 modelId ≠ 目标
    // modelId」判资产变更重装（换模型/重导入无需事件）。空值退化为目录名。
    int loadModel(String modelDir, String modelId);

    // 启动生成。promptJson 语义（2026-10-31 设计修正）= **消息序列 JSON**
    // `[{"role":"system"|"user"|"assistant","content":"..."}]`——:engine 侧
    // GenieSession 经 ChatMLComposer 按原生多轮交替模板构造（角色由模板
    // 承载；旧「单发压平 + 文字标注」因复读环退役）。generationParams 承载
    // GenerationConfig（总纲 §2）：
    // maxTokens(int) / temperature(double) / topP(double) /
    // stopTokenIds(int[]) / stopTokenSequences(int[][]，Serializable)——
    // 停用词一律预编码 id（§6.7，禁字符串级匹配）。
    // 契约细化（F3 2026-10-31）：promptJson 超内联上限（kPromptInlineBinderLimitChars）
    // 时 Dart 侧落临时文件、generationParams 携 promptFilePath 短元数据，:engine
    // 读后即删（Binder 只传短元数据，§8 载荷上限立法）。maxTokens 经
    // GenieDialog_setMaxNumTokens 逐请求生效；temperature/topP 已接线（2026-10-30
    // 复读环修复采样接线）；stopTokenIds 预编码 id 直传。
    // 契约细化（M3 Atomic，on-device-lifecycle-single-source.md §2.2/§2.3）：
    // expectInstanceId/expectSeq = 主进程最近见证票据的 epoch 复合键
    //（instanceId UUID + 实例内代次 seq）——:engine 在**同一入口内原子比对**
    //（I4 禁先查后发两步）。不匹配 → 抛 message 前缀 `SESSION_EPOCH_MISMATCH:`
    // 的异常（携带当前票据快照）；匹配但装载中 → `SESSION_LOADING:`（有界等待
    // 语义，主进程经装载链路复核）。epoch 是入口闸门非在途吊销令（I6）：
    // 受理后中途代次递增不影响本次在途生成。
    // 契约细化（F2，2026-10-31 ADR：S2 补齐 §2.5 I3 兑现的另一半）：expectModelId
    // = 主进程最近见证票据的资产身份（modelIdOf 指纹）——与 epoch **同入口原子
    // 比对**，失配 → `SESSION_MODEL_MISMATCH:`（资产变更 → 主进程作废镜像走
    // 重装；禁消费侧前置 Assert 复活 TOCTOU，禁全盘 sha256 身份）。
    void startGenerate(String requestId, String promptJson, in Bundle generationParams,
            String expectInstanceId, long expectSeq, String expectModelId);

    // 取消指定生成（§6.3：atomic stop_requested 下沉，清空在途 Token 后
    // 下发 finishReason="cancelled" 收尾）。
    void cancelGenerate(String requestId);

    // KV-Cache 回滚（§2.4 Prefix Cache 唯一主路线；keepTokens=0 等价旧 resetContext）。
    void truncateContext(int keepTokens);

    // 主动回收 → COLD-EVICTED（§4.1）。
    void releaseEngine();

    // M4 Contract：checkStatus 轮询面已删除——状态唯一来源 = checkSession()
    // 票据面（一次取回权威状态 + 代次 + 资产身份，on-device-lifecycle-single-source.md
    // §2.2）。

    // S3-2 FGS 前台预挂（NPU 稿 §6.2 v2.7 挂载时序硬约束）：主进程在 Activity
    // 前台时发起生成前调用——:engine 内 startForeground(dataSync) 挂极简
    // 「正在本地生成」通知。Android 12+ 后台调 startForeground 抛
    // ForegroundServiceStartNotAllowedException，故**必须前台预挂、严禁退后台
    // 补救**（主进程侧以前台态判定作闸，本方法仅执行）。卸载由 :engine 在生成
    // 收尾（startGenerate 的 finally）自动 stopForeground，不设 demote 面。
    void promoteForeground();

    // 会话票据查询（M1 Expand；设计 = docs/design/on-device-lifecycle-single-source.md
    // §2.2）：一次返回权威状态 + 代次 + 资产身份 = {instanceId(String, 进程实例
    // UUID) / seq(long, 实例内代次) / status(int, EngineStatus 序数) /
    // modelId(String) / runtime(String) / issuedAtMs(long)}。与 checkStatus 并存
    // （M4 Contract 收口时移除后者）；M1 阶段主进程仅作**影子对账**，票据不参与
    // 任何判定（设计 §4 第一步 Expand）。
    Bundle checkSession();

    // S2-5 熔断验证 diagPanic PATCH 已退役（F5 清账 2026-10-31）：模拟炸驱动
    // 诊断口与熔断消费链（kEngineInterruptCodes）职责分离，验证收口即摘除。
}
