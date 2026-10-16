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

/// 网关当前是否运行。
bool get gatewayRunning => GatewayController.shared.running;

/// 局域网地址列表（PC 配置展示：`http://<IP>:8766/mcp`）。
Future<List<String>> gatewayLanAddresses() => GatewayController.lanAddresses();

/// 启动网关（G4 前台保活由内部 `GatewayServiceChannel` 托管）。
Future<void> startGateway({int port = 8766, String? token}) =>
    GatewayController.shared.start(port: port, token: token);

/// 停止网关。
Future<void> stopGateway() => GatewayController.shared.stop();

/// 宿主激活私有域变化 → 同步网关默认投影（PC 只读镜像，host-level）。
void syncGatewayActivePrivate(String? id) =>
    GatewayController.shared.syncActivePrivate(id);
