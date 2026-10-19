/// 会话侧边栏（D13，步 4 对账 Epic C 外提）：会话历史列表 + 标题搜索 +
/// 重命名 + 删除 + 全局入口（设置 / 资源中心 / 任务对账 / 记忆库，2026-10-19
/// 起为底部横排工具带——竖排 ListTile 改横排，空间让位会话列表）。交互经
/// 回调回页面（运行守卫/删除确认对话框/导航编排留窗口）；搜索词与重命名
/// 对话框为本地 UI 态。
///
/// ux-hardening P1-5：补重命名 + 搜索 + 列表元信息（时间 · 条数）——原仅
/// 删除，标题自动截首句导致会话一多无法辨认。
library;

import 'package:flutter/material.dart';

import '../../coordinator/skill_registry.dart';
import '../../sandbox/conversation_store.dart';
import '../memory_board_page.dart';
import '../resource_center_page.dart';
import '../settings_page.dart';
import '../task_ledger_page.dart';
import '../tokens/console_tokens.dart';

class ConversationDrawer extends StatefulWidget {
  const ConversationDrawer({
    super.key,
    required this.conversations,
    required this.currentId,
    required this.onNew,
    required this.onLoad,
    required this.onDelete,
    required this.onRename,
    this.skillsProvider,
  });

  /// 会话列表快照（updatedAt 倒序，页面侧边栏投影）。
  final List<ConversationMeta> conversations;

  /// 当前会话 id（Archive 内核读）。
  final String? currentId;

  final VoidCallback onNew;
  final ValueChanged<ConversationMeta> onLoad;
  final ValueChanged<ConversationMeta> onDelete;

  /// 重命名（meta + 对话框内已 trim 的新标题）；空标题由对话框挡掉。
  final void Function(ConversationMeta meta, String newTitle) onRename;

  /// 连接态 SkillRegistry 提供者（页面注入 `() => session.skills`，其
  /// globals()/appScoped() 反映当前已连接服务与静态预置，与具体会话无关）——
  /// 透传给记忆看板「提示词」Tab；null = 注册表不可用，看板展示离线基线。
  final SkillRegistry? Function()? skillsProvider;

  /// epoch 毫秒 → 人话时间（今天 HH:mm，否则 M/d HH:mm）。
  static String fmtTime(int epochMs) {
    final d = DateTime.fromMillisecondsSinceEpoch(epochMs);
    final now = DateTime.now();
    return d.year == now.year && d.month == now.month && d.day == now.day
        ? '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}'
        : '${d.month}/${d.day} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  @override
  State<ConversationDrawer> createState() => _ConversationDrawerState();
}

class _ConversationDrawerState extends State<ConversationDrawer> {
  final _searchCtrl = TextEditingController();
  final _renameCtrl = TextEditingController();
  var _query = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    _renameCtrl.dispose();
    super.dispose();
  }

  /// 标题子串匹配（大小写不敏感；本地过滤，会话量小无需后端检索）。
  List<ConversationMeta> get _visible {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return widget.conversations;
    return widget.conversations
        .where((m) => m.title.toLowerCase().contains(q))
        .toList();
  }

  Future<void> _openRenameDialog(ConversationMeta meta) async {
    _renameCtrl.text = meta.title;
    final next = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        // 单一 setDialogState 供 TextField onChanged 刷新「保存」禁用态
        // （空标题禁存）。
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('重命名会话'),
          content: TextField(
            key: const Key('rename-field'),
            controller: _renameCtrl,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: '会话标题',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (_) => setDialogState(() {}),
            onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: _renameCtrl.text.trim().isEmpty
                  ? null
                  : () => Navigator.pop(ctx, _renameCtrl.text.trim()),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (next == null || next.isEmpty || next == meta.title) return;
    widget.onRename(meta, next);
  }

  @override
  Widget build(BuildContext context) {
    final t = consoleTokens(context);
    final visible = _visible;
    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '会话',
                      style: TextStyle(
                        fontFamily: t.monoFamily,
                        fontSize: Fsz.body,
                        color: t.terminalMuted,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: widget.onNew,
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('新会话'),
                  ),
                ],
              ),
            ),
            // P1-5：标题搜索（本地过滤；清空钮仅在 Query 非空时出现）。
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                controller: _searchCtrl,
                style: TextStyle(
                  fontFamily: t.monoFamily,
                  fontSize: Fsz.telemetry,
                ),
                decoration: InputDecoration(
                  hintText: '搜索会话标题…',
                  prefixIcon: const Icon(Icons.search, size: 18),
                  isDense: true,
                  border: const OutlineInputBorder(),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close, size: 16),
                          tooltip: '清空搜索',
                          onPressed: () {
                            _searchCtrl.clear();
                            setState(() => _query = '');
                          },
                        ),
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: visible.isEmpty
                  ? Center(
                      child: Text(
                        widget.conversations.isEmpty
                            ? '暂无历史会话\n（首次发送任务后自动保存）'
                            : '无匹配「$_query」的会话',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: Fsz.note,
                          color: t.terminalMuted,
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: visible.length,
                      itemBuilder: (context, i) {
                        final meta = visible[i];
                        return ListTile(
                          leading: Icon(
                            Icons.chat_bubble_outline,
                            size: 18,
                            color: t.terminalMuted,
                          ),
                          title: Text(
                            meta.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          // P1-5：元信息 = 更新时间 · 消息条数（0 条旧数据只显时间）。
                          subtitle: Text(
                            meta.messageCount > 0
                                ? '${ConversationDrawer.fmtTime(meta.updatedAt)} · ${meta.messageCount} 条'
                                : ConversationDrawer.fmtTime(meta.updatedAt),
                            style: const TextStyle(fontSize: Fsz.micro),
                          ),
                          selected: meta.id == widget.currentId,
                          onTap: () => widget.onLoad(meta),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.edit_outlined, size: 18),
                                tooltip: '重命名',
                                onPressed: () {
                                  _openRenameDialog(meta);
                                },
                              ),
                              IconButton(
                                icon: const Icon(
                                  Icons.delete_outline,
                                  size: 18,
                                ),
                                tooltip: '删除会话',
                                onPressed: () => widget.onDelete(meta),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
            const Divider(height: 1),
            // 全局入口横排工具带（2026-10-19 用户拍板，HCI 评估后实施）：设置 /
            // 资源中心 / 任务对账 / 记忆库 由竖排 ListTile（4 项约 260dp）改横排
            // （约 52dp），省出的高度归会话列表——抽屉主任务=会话切换（一级内容），
            // 全局入口为二级内容，空间分配向一级倾斜。规格走 ui-design：热区
            // ≥44dp（§4.4，视觉元素可小、透明 padding 补足）；图标 + 文字标签
            // 双通道保识别（§6，禁纯图标——「任务对账 / 记忆库」为领域词汇）；
            // 色彩/字号全取 tokens 灰阶弱化（§4.7），不与列表抢视觉重量。
            // 导航编排不变（关抽屉 → push 目标页），顺序原样保留保肌肉记忆。
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  _DrawerUtilityItem(
                    icon: Icons.settings_outlined,
                    label: '设置',
                    onTap: () => _openPage(const SettingsPage()),
                  ),
                  // 资源中心（resource-center，2026-10-19 自设置页第七段迁出为
                  // 独立页）：本地文件库的管理面（导入/改名/删除/外部打开/占用
                  // 展示），属用户资产数据面而非配置项。
                  _DrawerUtilityItem(
                    icon: Icons.folder_open_outlined,
                    label: '资源中心',
                    onTap: () => _openPage(const ResourceCenterPage()),
                  ),
                  // M4-2 对账入口（用户拍板：紧随「设置」——goodshare 点完任务
                  // 后来此确认「被处理了没有」）。
                  _DrawerUtilityItem(
                    icon: Icons.fact_check_outlined,
                    label: '任务对账',
                    onTap: () => _openPage(const TaskLedgerPage()),
                  ),
                  // A7（page-beautify P3）：命名与聊天页「本轮记忆」区分——原
                  // 「记忆看板」（全局管理）vs「会话记忆」（本轮提取）两套「记忆」
                  // 用户必混；此处=跨会话持久记忆库的统管入口。
                  _DrawerUtilityItem(
                    icon: Icons.inventory_2_outlined,
                    label: '记忆库',
                    onTap: () => _openPage(
                      MemoryBoardPage(skillsProvider: widget.skillsProvider),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 关抽屉 → 推目标页（原竖排 ListTile 同款导航编排，横排后不变）。
  void _openPage(Widget page) {
    Navigator.pop(context);
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => page),
    );
  }
}

/// 抽屉底部全局入口横排项：图标 + 小字标签双通道（ui-design §6）+ ≥44dp 热区
/// （§4.4）。`Expanded` 四等分抽屉宽（304dp → 每项 76dp）；标签 10.5sp
/// （`Fsz.microSm`）micro 遥测轨，四字中文标签（「资源中心」）不换行不截断。
class _DrawerUtilityItem extends StatelessWidget {
  const _DrawerUtilityItem({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = consoleTokens(context);
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(t.cardRadius),
        child: Padding(
          // 热区补足（§4.4）：icon 20 + 标签 10.5sp 视觉高约 36dp，上下各 8dp
          // 撑到 ≥44dp；水平 4dp 防相邻 ripple 互贴。
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20, color: t.terminalMuted),
              const SizedBox(height: 2),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: t.monoFamily,
                  fontSize: Fsz.microSm,
                  color: t.terminalMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
