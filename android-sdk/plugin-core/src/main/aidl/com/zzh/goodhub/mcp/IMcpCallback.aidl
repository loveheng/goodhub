package com.zzh.goodhub.mcp;

interface IMcpCallback {
    // 插件主动推给 GoodHub 的事件，内容为单条 JSON-RPC 消息字符串：
    //  - 通知帧：notifications/progress
    //  - 反向请求帧：server→client request（带 method + id，如 sampling/createMessage）
    // oneway：投递不阻塞插件；GoodHub 侧经 EventChannel 桥回 Dart。
    oneway void onEvent(String jsonRpcMessage);
}
