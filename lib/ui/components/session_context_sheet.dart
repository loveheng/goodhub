/// Composer Menu 底部弹层布局体（步 4 对账 Epic C 外提，纯视图件——零状态，
/// 数据与重渲染由调用方 StatefulBuilder + 回调驱动）。
///
/// 契约：调用方传 live 快照（bound/defaultId 等在每次 setSheet 重建时重读），
/// 交互经回调回页面（绑定写回三态契约、全局钉选写回），本文件不持状态。
///
/// **信息架构（P1-6，2026-10-22）**：本弹层是「会话统一挂载入口」，装三类
/// 生命周期不同的挂载物，必须分组到肉眼可辨——① 本次会话绑定（session 级，
/// 跨轮有效、切会话重置）；② 本次发送附件（run 级，随发送即焚、移除不删
/// 资源库）；③ 资源中心（应用级，跨会话持久、仅显式删除才消失）。分组功底
/// 于 chat-interaction §1 #11：禁让用户凭「都在输入框上面一条」自行推断。
library;

import 'package:flutter/material.dart';

import '../../mcp/local_plugin_discovery.dart';
import '../../mcp/server_endpoints.dart';
import '../tokens/console_tokens.dart';

/// 挂载弹层的分组标题（P1-6：三级生命周期分组标题 + 期限说明）。
///
/// 视觉走 ui-design §2/§4.7：microSm 等宽组名 + note 灰阶期限说明，不与列表抢
/// 视觉重量；`dense` 供组内二级分组（本地插件）使用。
class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    required this.title,
    required this.hint,
    this.dense = false,
  });

  final String title;
  final String hint;

  /// true = 二级分组（缩进更浅的行间距，不加分组前留白）。
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final t = consoleTokens(context);
    return Padding(
      padding: EdgeInsets.only(bottom: 4, top: dense ? 0 : 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            style: TextStyle(
              fontFamily: t.monoFamily,
              fontSize: dense ? Fsz.microSm : Fsz.micro,
              fontWeight: FontWeight.w600,
              color: t.terminalMuted,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            hint,
            style: TextStyle(fontSize: Fsz.note, color: t.terminalMuted),
          ),
        ],
      ),
    );
  }
}

class SessionContextSheetBody extends StatelessWidget {
  const SessionContextSheetBody({
    super.key,
    required this.t,
    required this.bound,
    required this.privEndpoints,
    required this.localPlugins,
    required this.defaultId,
    required this.endpointName,
    required this.onBind,
    required this.onClear,
    this.onPickResource,
    this.onManageResources,
    this.scrollController,
    this.bindLocked = false,
  });

  final ConsoleTokens t;

  /// 本会话三态绑定：null=未绑定 / ''=显式公共 / id=锁定。
  final String? bound;
  final List<ServerEndpoint> privEndpoints;
  final List<LocalPluginInfo> localPlugins;
  final String? defaultId;

  /// id → 展示名（页面端点缓存查表）。
  final String Function(String id) endpointName;

  final ValueChanged<String> onBind;
  final VoidCallback onClear;

  /// 附加资源（composer「+」统一挂载菜单入口）；null = 不渲染该项。
  final VoidCallback? onPickResource;

  /// 2026-10-19：弹层升级半屏起步/可上推全屏——外层 DraggableScrollableSheet
  /// 把自己的滚动控制器注入进来，内容区拖拽即联动展开/收起；null = 独立滚动
  /// （测试直渲染时行为不变）。
  final ScrollController? scrollController;

  /// 跳转资源中心管理页（导入/改名/删除/外部打开）；null = 不渲染该项。
  final VoidCallback? onManageResources;

  /// P1-8（承 A5）：运行中**只锁会话绑定**——它会改写会话 slot、扰动在途 Run
  /// 的装配语义。true = 绑定项置灰 + 说明行；「查看」与「挂载资源/管理资源」
  /// （视图态/其他面的动作）不受影响（曾一并置灰，纯添堵且策略不一致）。
  final bool bindLocked;

  /// 当前是否处于公共态（''=显式公共；null=遗留「未绑定」，2026-10-18 起
  /// 新会话一律公共起步，null 在弹层按公共显示）。公共项据此不可再点。
  bool get _isPublic => bound == null || bound!.isEmpty;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: 16 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        controller: scrollController,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // P1-6（2026-10-22）：单一入口里混装三类挂载物，标题不能再叫「本次
            // 会话上下文」——三层生命周期必须肉眼可辨（chat-interaction §1 #11）。
            Text('挂载',
                style: TextStyle(
                    fontSize: Fsz.telemetry, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(
              bound != null && bound!.isNotEmpty
                  ? '已锁定：${endpointName(bound!)}（$bound）'
                  : (localPlugins.isNotEmpty
                      ? '本地插件自动挂载（${localPlugins.length}）· 未锁定私有服务'
                      : '纯公共模式（无私有域）'),
              style: TextStyle(fontSize: Fsz.note, color: t.terminalMuted),
            ),
            if (defaultId != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '默认私有服务：${endpointName(defaultId!)}（在「设置」可改）',
                  style: TextStyle(fontSize: Fsz.note, color: t.terminalMuted),
                ),
              ),
            const Divider(height: 16),
            // P1-8（2026-10-22）：锁定说明**点名被锁的对象**——原「暂不可切换
            // 绑定」笼统，且实际只有服务绑定被锁（它会改写会话 slot、扰动在途
            // Run 的装配），挂载资源不受影响。A5「可查看」语义保留。
            if (bindLocked)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('任务运行中：服务绑定暂不可切换（挂载资源不受影响）',
                    style: TextStyle(fontSize: Fsz.note, color: t.l2Warn)),
              ),
            // —— 组 1：会话级挂载（跨轮有效 / 切会话重置）——————————————
            const _GroupHeader(
              title: '本次会话绑定',
              hint: '跨轮有效 · 切会话或新建会话即重置',
            ),
            if (privEndpoints.isEmpty && localPlugins.isEmpty)
              Text('无可用私有服务（私有端点请在侧边栏 → 设置页添加）',
                  style: TextStyle(fontSize: Fsz.note, color: t.terminalMuted)),
            // 2026-10-18（用户拍板）：「公共」为常驻首项、单选语义、不可取消
            // ——列表恒有一项选中（消灭空选态）；绑定服务后再点一次 = 回显式
            // 公共（解除覆盖），底部「清空」行随之移除（接近性：取消动作回到
            // 对象本身）。
            ListTile(
              leading: const Icon(Icons.public),
              title: const Text('公共'),
              trailing: _isPublic ? const Icon(Icons.check, size: 18) : null,
              enabled: !bindLocked,
              onTap: _isPublic ? null : () => onBind(''),
            ),
            for (final e in privEndpoints)
              ListTile(
                leading: const Icon(Icons.lock_outline),
                title: Text(e.name),
                subtitle: Text(e.id),
                trailing: (bound != null && bound == e.id)
                    ? const Icon(Icons.check, size: 18)
                    : null,
                enabled: !bindLocked,
                // 选中项再点 = 取消回公共；未选中 = 绑定（radio 语义）。
                onTap: () => (bound != null && bound == e.id)
                    ? onClear()
                    : onBind(e.id),
              ),
            if (localPlugins.isNotEmpty) ...[
              const SizedBox(height: 8),
              const _GroupHeader(
                title: '本地私有插件',
                hint: '零配置自动发现 · 须选定后占用单槽，未选中则对本会话隐藏',
                dense: true,
              ),
              for (final lp in localPlugins)
                ListTile(
                  leading: const Icon(Icons.lock_outline),
                  title: Text(
                      lp.serverTitle.isEmpty ? lp.serverId : lp.serverTitle),
                  subtitle: Text(lp.packageName),
                  trailing: (bound != null && bound == lp.serverId)
                      ? const Icon(Icons.check, size: 18)
                      : null,
                  enabled: !bindLocked,
                  // 选中项再点 = 取消回公共；未选中 = 绑定（radio 语义）。
                  onTap: () => (bound != null && bound == lp.serverId)
                      ? onClear()
                      : onBind(lp.serverId),
                ),
            ],
            if (bound != null &&
                bound!.isNotEmpty &&
                defaultId != null &&
                defaultId != bound)
              Padding(
                padding: const EdgeInsets.only(bottom: 4, top: 2),
                child: Text(
                  '已为本会话覆盖默认：${endpointName(defaultId!)}',
                  style: TextStyle(fontSize: Fsz.note, color: t.terminalMuted),
                ),
              ),
            // —— 组 2：运行级附件（随本次发送即焚）——————————————————
            if (onPickResource != null) ...[
              const Divider(height: 16),
              const _GroupHeader(
                title: '本次发送附件',
                hint: '随本次发送后即清空 · 移除只注销待发项，不删资源库',
              ),
              ListTile(
                key: const ValueKey('menu-attach'),
                leading: const Icon(Icons.attach_file),
                title: const Text('附加资源…'),
                subtitle: const Text('从资源中心或系统文件选择，随本次发送'),
                // P1-8：不再随 bindLocked 置灰——挂载资源只是「预备下一次发送」
                // 的视图态动作，不改写会话绑定、不扰动在途 Run 的领域态；与
                // 「管理资源中心」同为资源入口，策略必须一致（原先一灰一可点）。
                onTap: () {
                  Navigator.pop(context);
                  onPickResource?.call();
                },
              ),
            ],
            // —— 组 3：应用级资源库（跨会话持久）——————————————————
            if (onManageResources != null) ...[
              const Divider(height: 16),
              const _GroupHeader(
                title: '资源中心',
                hint: '跨会话持久 · 仅在此显式删除才消失',
              ),
              ListTile(
                key: const ValueKey('menu-resource-center'),
                leading: const Icon(Icons.folder_open_outlined),
                title: const Text('管理资源中心…'),
                onTap: () {
                  Navigator.pop(context);
                  onManageResources?.call();
                },
              ),
            ],
          ],
        ),
      ),
    );
  }
}
