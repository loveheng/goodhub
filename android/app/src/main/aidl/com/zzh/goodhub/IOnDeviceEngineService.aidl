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
    // ready=已就绪 / assetMissing=已受理异步创建中或资产不全 /
    // unsupportedDevice=驱动基线未过或参数缺失。创建耗时秒级（Dialog_create 暖机）。
    int loadModel(String modelDir);

    // 启动生成。generationParams 承载 GenerationConfig（总纲 §2）：
    // maxTokens(int) / temperature(double) / topP(double) /
    // stopTokenIds(int[]) / stopTokenSequences(int[][]，Serializable)——
    // 停用词一律预编码 id（§6.7，禁字符串级匹配）。
    // 契约细化（S2 正式接线）：promptJson 现承载**纯文本 prompt**（过渡口径——
    // Genie 对话模板由资产 config 内置；结构化 chat 模板归 Prompt 编排层，
    // NPU 稿 v2.7「Prompt 拓扑正规化」）。maxTokens 经 GenieDialog_setMaxNumTokens
    // 逐请求生效；temperature/topP 过渡期取资产 config 默认（sampler 参数面
    // 随 S2 后续确证键名后启用）；stopTokenIds 过渡期不下沉（Genie 停用词为
    // 字符串级 setStopSequence，与 §6.7 预编码 id 口径不符，正式停用词下沉归 S3）。
    void startGenerate(String requestId, String promptJson, in Bundle generationParams);

    // 取消指定生成（§6.3：atomic stop_requested 下沉，清空在途 Token 后
    // 下发 finishReason="cancelled" 收尾）。
    void cancelGenerate(String requestId);

    // KV-Cache 回滚（§2.4 Prefix Cache 唯一主路线；keepTokens=0 等价旧 resetContext）。
    void truncateContext(int keepTokens);

    // 主动回收 → COLD-EVICTED（§4.1）。
    void releaseEngine();

    // 结构化状态查询（EngineStatus 枚举序数）。busy/ready 禁 TTL 缓存（v2.6）。
    int checkStatus();

    // S3-2 FGS 前台预挂（NPU 稿 §6.2 v2.7 挂载时序硬约束）：主进程在 Activity
    // 前台时发起生成前调用——:engine 内 startForeground(dataSync) 挂极简
    // 「正在本地生成」通知。Android 12+ 后台调 startForeground 抛
    // ForegroundServiceStartNotAllowedException，故**必须前台预挂、严禁退后台
    // 补救**（主进程侧以前台态判定作闸，本方法仅执行）。卸载由 :engine 在生成
    // 收尾（startGenerate 的 finally）自动 stopForeground，不设 demote 面。
    void promoteForeground();

    // S2-5 熔断全链验证专用（PATCH：诊断接口，验证收口后退役）：模拟驱动
    // Panic 上报——经真实 listener.onEngineDied() 信号链（AIDL→binding→
    // breaker.report(countable:true)）驱动熔断计数，真机侧不要求真实炸驱动。
    oneway void diagPanic();
}
