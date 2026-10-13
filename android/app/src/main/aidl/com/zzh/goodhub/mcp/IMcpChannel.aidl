package com.zzh.goodhub.mcp;

import com.zzh.goodhub.mcp.IMcpCallback;

interface IMcpChannel {
    // 同步 JSON-RPC 请求-响应：GoodHub 发裸请求，插件回裸 JSON-RPC 响应字符串。
    // 用于 initialize / tools/list / tools/call / resources/* / prompts/*。
    // 必须在 Binder 事务预算内返回（见 §1.2.3）；长任务改 _async 异步（见下）。
    String call(String jsonRpcRequest);

    // 注册事件回调（进度/反向请求）。首次 bindService 后、首次 call 前调用一次；
    // 传 null 注销。DeathRecipient 触发视为断开。
    void registerCallback(IMcpCallback callback);

    // GoodHub 回答插件经 onEvent 发来的反向请求：把 JSON-RPC 响应字符串回插件。
    // oneway：应答不阻塞 GoodHub。插件按 id 关联原请求。
    oneway void answerReverse(String jsonRpcResponse);
}
