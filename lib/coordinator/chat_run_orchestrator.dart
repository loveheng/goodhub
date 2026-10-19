/// Run 编排下沉件（window-slim P1-A，设计稿 §1-P1-A/§2-1）：chat_page._send
/// 内联的「记忆内核接线 + 记忆冷热分层 + 系统前缀组装 + 归因数据 + maskTool +
/// slot 写回 + governor 生命周期」收口至此——窗口回归收集配置、实现 UI 端口、
/// 把 Loop 事件流映射到轨道三件事。
///
/// - **纯编排，零 UI**：本件不 import ui/，UI 交互经回调签名（key/value/action/
///   scope/undo）回窗口；`MemoryGovernor` 所有权随迁（窗口字段删除）；
/// - **边界纪律**：不新增反向边（coordinator 只出向 core/llm/mcp/sandbox 已有
///   面）；信任闸门等 UI 决策仍由窗口先行裁剪后传入（window-kernel-split §7.1）。
library;

import '../core/tokens.dart';
import '../llm/cloud/cloud_llm.dart';
import '../sandbox/memory_store.dart';
import '../sandbox/workspace_state_store.dart';
import 'context_governor.dart' show estimateTokens;
import 'mcp_runtime.dart';
import 'memory_governor.dart';
import 'memory_kernel.dart';
import 'skill_registry.dart';
import 'tool_router.dart';
import 'workspace_stream_filter.dart';

/// 一次 Run 的编排产物：窗口拿它喂 `assembly.loop.run` 与归因轨道。
class ChatRunPlan {
  ChatRunPlan({
    required this.workspaceFilter,
    required this.systemPrompt,
    required this.memSection,
    required this.contextFooter,
    required this.maskTool,
    required this.memoryEntries,
    required this.droppedCount,
    this.slotNotice,
  });

  /// In-band 提取面（P2-6）：落盘在内核，胶囊/写失败经构造期回调回窗口。
  final WorkspaceStreamFilter workspaceFilter;

  /// 静态前缀（P1-3b 断点 A）：skills 组合 + 已挂载服务段 + 提取指令。
  final String systemPrompt;

  /// 记忆冷热分层的 systemTail 与增量区沉底（context-stepped-pruning §6）。
  final String memSection;
  final String? contextFooter;

  /// P3-2：已让位私有域的历史调用发送边界合成桩脱敏。
  final bool Function(String name) maskTool;

  /// 归因轨道数据（展示 only）：本轮注入的记忆与超限丢弃数。
  final List<MemoryEntry> memoryEntries;
  final int droppedCount;

  /// 断连降级通告（prompt-mgmt §8.2.1）：Run 边界收敛发现激活私有服务掉线 →
  /// 槽位置 null 降级纯公共模式，通告文本经本位回窗口（TrackNote）。
  /// null = 无降级。
  final String? slotNotice;
}

/// Run 编排 owner：每次 Run 由窗口经 [plan] 取编排产物、经 [writebackSlot]
/// 收尾、经 [markRunEnded] 交还 TTL 判定起点。实例无跨 Run 态（除 governor）。
class ChatRunOrchestrator {
  ChatRunOrchestrator({MemoryGovernor? governor})
      : memGovernor = governor ?? MemoryGovernor();

  /// 记忆冷热分层策略 owner（§6 滑窗高水位/TTL/体量突发）。
  final MemoryGovernor memGovernor;

  Future<ChatRunPlan> plan({
    required McpAssembly assembly,
    required MemoryStore memoryStore,
    required WorkspaceStateStore? wsStates,
    required String conversationId,
    required List<CloudChatMessage> transcript,
    required SkillRegistry skills,
    required String baseSystemPrompt,
    required void Function(String key, String value, String action, String scope,
            void Function() undo)
        onCapsule,
    required void Function(String key, String scope)? onWriteFailure,
  }) async {
    final router = assembly.router;
    // Run 边界收敛（prompt-mgmt §8.2.1）：断连 pending 降级生效 + 未提交
    // pending 兜底收敛 + 捕获本 Run 不可变槽位快照——快照后 focusedSchemas()
    // （toolsProvider 经 effectiveSlot）与本处 composeSystemPrompt / maskTool
    // 同源同拍，本 Run 内任何中途变异（切域/断连）不再撕裂投影。
    final slotNotice = router.beginRun();
    final slot = router.effectiveSlot;
    // In-band 提取面（archive-memory-claim 步 2）：session 域落 wsStates
    //（所有权仍在 Session，按调用传入）；user/srv 域走 MemoryStore keyed 映射
    //（G1）；UI 胶囊与写失败经回调回窗口（window-slim P1-C 通道）。
    final workspaceFilter = MemoryKernel(memoryStore).buildFilter(
      wsStates: wsStates,
      conversationId: conversationId,
      onCapsule: (key, value, action, scope, undo) {
        // 记忆增量日志（context-stepped-pruning §6.3/§6.7）：user/srv 域入
        // pending 池（journal 覆盖注入 prompt 的域，单向栅栏）；session 域
        // 不进 prompt、不入 journal。
        if (scope != 'session') {
          memGovernor.record(
            action: action,
            scope: scope,
            key: key,
            value: value,
          );
        }
        onCapsule(key, value, action, scope, undo);
      },
      onWriteFailure: onWriteFailure,
    );

    // M4-T2 记忆注入（D8 三层作用域）+ 超限可观测：作用域 = 全部已连服务。
    final memView = await memoryStore.memoryView(
      serverScopes: router.serverIds,
    );
    // 记忆冷热分层（§6）：窗口只测量 transcript（轮数/体量），systemTail +
    // 沉底增量区由 governor 投影——Tick（滑窗高水位/TTL/体量突发）时压实，
    // 非 Tick 时快照字节冻结、delta 只追加。
    final transcriptRounds =
        transcript.whereType<AssistantMessage>().length;
    // 估算口径 = 字符级粗估（core/tokens 同族），消息 content 逐条拼接。
    final transcriptTokens = estimateTokens(
      transcript.map((m) {
        if (m is UserMessage) return m.content;
        if (m is AssistantMessage) return m.content ?? '';
        if (m is ToolResultMessage) return m.content;
        if (m is SystemMessage) return m.content;
        return '';
      }).join('\n'),
    );
    final memSection = await memGovernor.assembleSystemTail(
      store: memoryStore,
      serverScopes: router.serverIds,
      transcriptRounds: transcriptRounds,
      transcriptTokens: transcriptTokens,
    );
    final contextFooter = memGovernor.renderFooter();
    // T6：静态首级摘要「## 已挂载服务」（自动生成，标注工具名前缀格式）。
    final mountedSection = mountedServicesSection(
      router,
      assembly.serverSummaries,
    );

    return ChatRunPlan(
      workspaceFilter: workspaceFilter,
      // P1-3b（§8.1 断点 A）：静态角色+skills+mountedSection 为静态前缀
      //（挂 ephemeral 断点），记忆区走 systemTail 置尾。P2-4（§3.2）：
      // workspace_update 提取指令为固定静态区追加（含「tool-call 轮严禁输出」铁律）。
      // prompt-mgmt Phase 2 接入点：投影三元与 focusedSchemas() 同源同拍——
      // 公共集 = 已挂载非私有；私有槽位 = 激活私有（null 即纯公共模式）。
      systemPrompt: skills.composeSystemPrompt(
            baseSystemPrompt,
            publicServerIds: router.serverIds
                .where((id) => !router.privateServerIds.contains(id))
                .toList(),
            activePrivateSlotId: slot,
            mountedSection: mountedSection,
          ) +
          WorkspaceStreamFilter.promptInstructions,
      memSection: memSection,
      contextFooter: contextFooter.isEmpty ? null : contextFooter,
      // P3-2（D-H/§9.1）：已让位私有域的历史调用发送边界合成桩脱敏。
      // 判定源 = Run 启动快照（§8.2.1）——Run 中途切域不改写本 Run 投影。
      maskTool: (name) {
        final sid = router.serverFor(name);
        return sid != null &&
            router.privateServerIds.contains(sid) &&
            slot != sid;
      },
      memoryEntries: memView.entries,
      droppedCount: memView.droppedCount,
      slotNotice: slotNotice,
    );
  }

  /// 会话绑定捕获（收尾）：模型可能在本轮经 use_server/activate 改写私有槽位，
  /// 经三态写回契约落到会话元数据（免每轮重选）。
  void writebackSlot({
    required ToolRouter router,
    required ConversationSession session,
  }) {
    router.endRun(); // Run 收尾：丢快照 + 丢弃未提交 pending（§8.2.2 前置 Abort）
    final slot = router.activePrivateServerId;
    if (slot != null) {
      session.bindPrivateServer(slot);
    } else if ((session.activePrivateServerId ?? '').isNotEmpty) {
      session.unbindToPublic(); // 曾绑定 → 本轮 use_server('all') 清空 = 显式公共
    }
  }

  /// §6.4 TTL 机会主义压实的判定起点：Run 结束时刻（governor 持有）。
  void markRunEnded() => memGovernor.markRunEnded();

  /// T6 静态首级摘要「## 已挂载服务」（原 chat_page 静态助手上收）。
  ///
  /// 状态分叉（2026-10-19，防幻觉直调熔断链）：只列服务不给状态，模型会以为
  /// 「挂载即可调」——私有服务未占槽时其工具根本不在工具面，直调被前缀守门
  /// 拦成 isError，两次相同失败即两步熔断。故完全无锁槽时按**纯聊天模式**
  /// 定性（用户拍板：未选中私有服务就当纯聊天，挂载的插件只是背景里可锁定
  /// 的选项，提供给模型的仅基础服务；其余未锁私有由行级标记 + router 单槽
  /// 守门话术覆盖）：
  /// ① 明示「工具不可用 + 可直接纯对话」，给模型「什么工具都不调」的正向
  /// 出路（基础 system prompt 同向解压）；② 服务行按私有看槽位、公共看
  /// 激活集标注状态；③ 尾句动词对齐（私有 = use_server 锁定）。
  static String mountedServicesSection(
    ToolRouter router,
    Map<String, String> summaries,
  ) {
    final slot = router.effectiveSlot;
    final lines = [
      for (final id in router.serverIds)
        '- $id: ${summaries[id] ?? '(无摘要)'}${_lockMark(router, id)}',
    ];
    final unboundPrivate = router.serverIds
        .where((id) => router.privateServerIds.contains(id) && id != slot)
        .toList();
    // 纯对话出路段仅在「完全无锁槽」时注入：有槽位 = 私有域已定、工具面
    // 非空，模型该用工具而非被劝退；其余未锁私有由行级标记 + router 单槽
    // 守门话术覆盖。
    final noPrivateLocked = slot == null && unboundPrivate.isNotEmpty;
    final first = router.serverIds.isEmpty ? 'server_id' : router.serverIds.first;
    final buffer = StringBuffer('\n\n## 已挂载服务（自动生成）\n')
      ..write('工具名带服务前缀，格式 `<server_id>__<tool>`，'
          '例如 `${first}__get_item`。\n');
    if (noPrivateLocked) {
      buffer.write('当前会话未锁定私有服务，按纯聊天模式处理：能直接回答的'
          '直接以自然语言文本回答，不主动调用工具；宿主基础能力（公共面'
          '工具、记忆、技能）常驻可用。仅当任务确需某插件能力时，才用 '
          'use_server(server_id) 锁定其中一个后调用。\n');
    }
    buffer
      ..write('服务列表：\n${lines.join('\n')}\n')
      ..write(noPrivateLocked
          ? '未锁定服务用 get_connected_apps 查看、use_server 锁定。'
          : '未激活服务用 get_connected_apps 查看、activate_server_tools 激活。');
    return buffer.toString();
  }

  /// 服务行状态标记：私有看槽位（占槽无标记；未锁 = use_server），公共看
  /// 激活集（挂载即默认全激活，异常未激活才标）。快照读 [ToolRouter.effectiveSlot]
  /// ——与 composeSystemPrompt 同拍同源（Run 启动后调用）。
  static String _lockMark(ToolRouter router, String id) {
    if (router.privateServerIds.contains(id)) {
      return router.effectiveSlot == id ? '' : ' ［未锁定，需 use_server］';
    }
    return router.activatedServers.contains(id)
        ? ''
        : ' ［未激活，需 activate_server_tools］';
  }
}
