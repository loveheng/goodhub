/// 网关系统工具面（`gateway__` 命名空间）——**声明与文案的单一 owner**。
///
/// **独立成件的缘由（架构债 #18 体量治理）**：系统工具的 JSON 声明、命名空间
/// 常量与投影描述文案原寄生在 `mcp_gateway_handler.dart`（该文件逼近 800 行
/// 软红线）→ 抽出后 handler 只留「接线 + 连接态」，对外契约有独立 owner。
///
/// **命名空间纪律**：网关级系统工具标定其为网关系统工具，不污染业务 MCP 服务
/// 命名空间，且在网关入站路由层做专用拦截（绝不转交任何 face / 宿主槽位机）。
///
/// **文案纪律（2026-10-23 P0 教训）**：面向 PC 的系统工具文案禁引用**未声明**的
/// `gateway__*` 工具名——工具名是 PC 侧模型的唯一契约面，文案里的悬空引用 =
/// 幻觉调用源（改名后文案残留旧名，PC 会照抄调用一个不存在的工具）。改任一
/// 系统工具名须同轮扫全文案并挂断言钉子（见
/// `test/gateway/projection_server_switch_test.dart` 的文案扫描用例）。
library;

import 'projection_pipeline.dart';

/// 网关级系统工具命名空间前缀（零泄漏判定与分派共用）。
const String kGatewayToolPrefix = 'gateway__';

/// 连接投影切换（Connection Projection Switch）：只改**本连接**的服务面。
const String kGatewaySelectPrivate = 'gateway__select_private';

/// 列出宿主**当前已挂载的全部 MCP 服务**（用户裁决 2026-10-23）。
///
/// **为什么列全部而非只列「私有」**（术语纠错）：宿主侧「私有」有两种含义——
/// ① 端点隐私级别 `tier=private`（仅手填端点，本地插件恒 public）；② 用户口语
/// 的「我自己单独用的服务」。PC 侧要的是 ②，故列**全部已挂载服务**并逐条标注
/// `tier`，由 PC 按需选——否则本地插件（goodshare 等）在清单里恒缺席，PC 会误判
/// 「宿主没有服务可用」。
const String kGatewayListServers = 'gateway__list_servers';

/// 已声明的系统工具名集合（分派与文案扫描共用）。
const Set<String> kGatewaySystemToolNames = <String>{
  kGatewaySelectPrivate,
  kGatewayListServers,
};

/// 网关级系统工具声明 JSON（PC 可见的目录条目）。
List<Map<String, Object?>> buildGatewaySystemToolJson() => [
      {
        'name': kGatewayListServers,
        'description':
            '列出宿主当前已挂载的全部 MCP 服务（server_id、隐私级别 tier、来源 source、'
                '只读工具数、是否当前目标）。怎么用才对：① 不确定宿主有哪些服务时先调'
                '本工具，**不要凭猜测拼 server_id**；② 只想跟其中一个服务打交道'
                '（上下文最小、工具名无前缀）→ 再调 gateway__select_private'
                '(server_id=<id>, policy=single)；③ 宿主刚装完插件或改完端点配置，'
                '复查本工具即可看到最新清单（实时现算，无需重连会话）。'
                '只列 id 与计数，不含凭据、端点地址或服务内容。',
        'inputSchema': {'type': 'object'},
      },
      {
        'name': kGatewaySelectPrivate,
        'description':
            '切换本 MCP 连接的服务面（Connection Projection Switch），'
                '**只改本连接**，不影响宿主与其他连接。'
                '怎么用才对：① 想只用一个服务（上下文最小、无前缀裸名工具）→ '
                'server_id 传该服务 + policy=single；'
                '② 想用完整联邦面 + 其中一个私有服务 → server_id 传该私有服务 + '
                'policy=private；③ 回到完整联邦面 → server_id 传 "all" + '
                'policy=full。server_id 取 gateway__list_servers 所列。'
                '（policy 四档：single / private / full / pruned；pruned 仅在连接'
                '建立期 ?policy=pruned&tag=… 可用，连接内不支持切换。）',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'server_id': {
              'type': 'string',
              'description': '目标服务 id（取自 gateway__list_servers；'
                  'policy=private 仅限其中 tier=private 的服务）；'
                  '"all" 或空串 = 公共面/完整联邦面',
            },
            'policy': {
              'type': 'string',
              'enum': ['single', 'private', 'full', 'pruned'],
              'description':
                  'single=只看该服务（剥前缀裸名）；private=完整联邦面+该私有服务；'
                      'full=只看完整联邦面；pruned=按 tag 白名单（仅连接建立期）。'
                      '缺省 private（既有行为）。',
            },
          },
          'required': ['server_id'],
        },
      },
    ];
/// 当前连接投影的人话描述（切换后的回执，供模型自纠下一步）。
String describeGatewayProjection(
  ProjectionPolicy policy, {
  String? activePrivateServerId,
}) {
  switch (policy.strategy) {
    case ProjectionStrategy.single:
      return '本连接已切到 single 模式：只可见服务 ${policy.targetServerId} 的'
          '无前缀工具（公共面与其余私有服务已隐匿）；'
          '调 gateway__select_private(server_id="all", policy=full) 可回到完整联邦面。';
    case ProjectionStrategy.pruned:
      return '本连接为 pruned 模式：只可见打标 ${policy.tags.join(',')} 的工具'
          '（带 server_id 前缀）。';
    case ProjectionStrategy.private:
      return '本连接为完整联邦面 + 私有服务 ${policy.targetServerId} 的工具'
          '（其余私有服务仍隐匿）。';
    case ProjectionStrategy.full:
      final active = activePrivateServerId;
      return active == null
          ? '本连接为完整联邦面（无私有投影）。'
          : '本连接为完整联邦面 + 私有服务 $active 的工具'
              '（其余私有服务仍隐匿）。';
    case ProjectionStrategy.owner:
      // 不可达守卫：owner 是宿主内部档（ProjectionPolicy.parse 已拒网关侧
      // 构造），若此回执被触发 = 内部接线错误，fail-loud 不给 PC 任何话术。
      throw StateError(
          'describeGatewayProjection: owner 档不经网关暴露（宿主内部档）');
  }
}
