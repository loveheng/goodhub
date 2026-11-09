/// goodshare 接缝契约三工具封装——**已泛化退役**（ai-capability-export
/// 「goodshare 独有支持 → 通用支持」2026-11-09）：契约正文迁
/// `mcp_task_queue.dart`（远程任务队列契约，任何 server 实现即可接入）。
/// 本文件仅存过渡别名，存量 import 零改动；新代码禁引本文件（drift 词条防复活）。
@Deprecated('泛化为 mcp_task_queue.dart 的 McpTaskQueueApi / McpTaskQueueContract（2026-11-09）')
library;

import 'mcp_task_queue.dart' show McpTaskQueueApi;

export 'mcp_task_queue.dart' show ApplyPayload, ClaimedTask, McpTaskQueueApi;

/// 过渡别名（存量调用点渐进迁移；新代码用 [McpTaskQueueApi]）。
@Deprecated('泛化为 McpTaskQueueApi（2026-11-09）')
typedef GoodshareTaskApi = McpTaskQueueApi;
