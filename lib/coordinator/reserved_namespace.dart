/// 保留命名空间断言（架构债 #15 · 门禁 3）——**独立小件**。
///
/// **为什么独立成件**：断言逻辑只服务「宿主保留 serverId 防挤占」一件事，原先
/// 寄生在 `McpRuntime`（该文件在「只减不增」超标清单内）→ 抽出后核心装配文件
/// 只留调用点，规则本体有独立 owner 与独立单测面。
///
/// **门禁语义**：`host` 是宿主虚拟服务（`HostTransport`）的系统保留 serverId，
/// **仅限内置 [HostTransport]**；外部插件（Binder）/ 手填 HTTP 端点声明 `host`
/// 一律拒装（抛 [ReservedNamespaceException]）。
///
/// 命名仲裁（thirdconnect §9.3）未落地前重名走静默跳过，本断言是防挤占的
/// 唯一手段——故三路装配（`McpRuntime.mount` / `mountEndpoint` 委托 /
/// `_assembleInner` 两段直挂循环）必须同点设防（只守 `mount` 会被绕过）。
library;

import '../core/errors/mcp_error.dart';
import '../mcp/mcp_client.dart';
import '../mcp/transport/host_transport.dart';

/// 断言 [serverId] 可被挂载：`host` 仅限内置 [HostTransport]，其余一律拒装。
///
/// 抛 [ReservedNamespaceException] = 拒装（调用方按「宁缺勿炸」口径 DEGRADE
/// 跳过并通告，不得因一条误配端点炸掉整轮装配）。
void assertServerIdMountable(String serverId, McpClient client) {
  if (serverId != kHostServerId) return;
  if (client.transport is HostTransport) return;
  throw ReservedNamespaceException(
    'serverId "$kHostServerId" 为宿主保留命名空间，仅限内置 HostTransport 装配'
    '（当前传输 ${client.transport.runtimeType}）——外部插件 / 手填端点不得占用',
  );
}
