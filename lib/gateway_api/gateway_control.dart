/// UI 网关控制面 facade（arch-hardening 断点①：斩断 `ui → gateway` 反向边）。
///
/// UI 只依赖本层，不直接 import [gateway] 服务域；本层委托
/// [GatewayController.shared]。依赖方向 `ui → gateway_api → gateway` 合法且无环
/// （[gateway] 不反向依赖本层，其反向依赖落在 `app/service_directory` 而非此处）。
///
/// 收敛条件：若未来 [GatewayController] 需要被替换/多实例，本 facade 应升级为
/// 接口 + 注入位（已在 module 装配处留 `gatewayControlOverride` 注入位）。
library;

import '../gateway/gateway_controller.dart';
import '../gateway/gateway_server.dart' show kGatewayDefaultPort;
import '../gateway/gateway_service_channel.dart';
import '../coordinator/mcp_tool_face.dart';
import '../mcp/server_endpoints.dart';

/// Token 生成与起服决策（纯函数）同层导出——UI 只 import 本门面一个入口。
export 'gateway_token.dart';

/// 网关默认端口（门面转出：UI 侧文案与起服入参共用同一常量，且 UI 不必直连
/// gateway 服务域——「ui → gateway_api → gateway」的单向依赖纪律不破）。
export '../gateway/gateway_server.dart' show kGatewayDefaultPort;

/// 网关当前是否运行。
bool get gatewayRunning => GatewayController.shared.running;

/// 局域网地址列表（PC 配置展示：`http://<IP>:8766/mcp`）。
Future<List<String>> gatewayLanAddresses() => GatewayController.lanAddresses();

/// 启动网关（G4 前台保活由内部 `GatewayServiceChannel` 托管）。
/// 端口缺省引 `kGatewayDefaultPort` 单源（禁本地再写一份 8766——drift-guard
/// CONST 登记项，双声明即漂移）。
Future<void> startGateway({int port = kGatewayDefaultPort, String? token}) =>
    GatewayController.shared.start(port: port, token: token);

/// 停止网关。
Future<void> stopGateway() => GatewayController.shared.stop();

/// 电池优化白名单状态（true = 已加入；false = 未加入 / 查询失败）。
///
/// 未加白名单时息屏进 Doze 会限网 → PC 侧表现为「过段时间连接掉了」。
Future<bool> gatewayBatteryExemptionStatus() =>
    GatewayServiceChannel.batteryExemptionStatus();

/// 跳系统申请电池优化白名单（需用户在系统弹窗确认）。
Future<bool> requestGatewayBatteryExemption() =>
    GatewayServiceChannel.requestBatteryExemption();

/// 宿主激活私有域变化 → 同步网关默认投影（PC 只读镜像，host-level）。
void syncGatewayActivePrivate(String? id) =>
    GatewayController.shared.syncActivePrivate(id);

// —— 共享能力源消费视图（装配层合一 · Contract 件）：chat 经本门面间接
// 访问 GatewayController 的 face 表，遵守 R7「ui 不直 import gateway_controller」
// 的单向依赖纪律（ui → gateway_api → gateway）。——

/// 共享能力源 face 表（只读视图）：装配时借用已挂载 face，消同源双实例。
Map<String, McpToolFace> get sharedFaces => GatewayController.shared.faces;

/// 幂等确保端点已挂载（face 表命中直返，未挂载触发一次重扫）。
Future<McpToolFace?> ensureEndpointMounted(ServerEndpoint ep) =>
    GatewayController.shared.ensureEndpointMounted(ep);
