import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../tokens/console_tokens.dart';
import 'status_capsule.dart';
import 'status_strip.dart';

/// 底部输入集群（断点③ step2：从 `chat_page.build` 抽出，传数据与回调，
/// 不依赖 `_ChatPageState` 私有态）。含状态带 + 输入条 + 发送/中止单槽复用钮。
class ChatComposer extends StatefulWidget {
  const ChatComposer({
    super.key,
    required this.inputCtrl,
    required this.running,
    required this.hasContext,
    required this.contextId,
    required this.endpointName,
    required this.hasEndpoints,
    required this.localPluginCount,
    required this.pillTone,
    required this.pillLabel,
    required this.runStartedAt,
    required this.onOpenMenu,
    required this.onSend,
    required this.onAbort,
    this.pendingResources = const [],
    this.onPickResource,
    this.onRemoveResource,
  });

  final TextEditingController inputCtrl;
  final bool running;
  final bool hasContext;
  final String? contextId;
  final String Function(String id) endpointName;
  final bool hasEndpoints;
  final int localPluginCount;
  final CapsuleTone pillTone;
  final String pillLabel;
  final DateTime? runStartedAt;
  final VoidCallback onOpenMenu;
  final VoidCallback onSend;
  final VoidCallback onAbort;

  /// 已附加资源药丸（resource-center M1-T3；record 类型零 resources 域依赖）。
  final List<({String id, String name})> pendingResources;

  /// 附件入口回调（null = 不显示资源行）；选择 sheet 在 chat_page 侧弹出。
  final VoidCallback? onPickResource;

  /// 移除附件（仅注销本次会话的附件待发项，严禁触资源库删除）。
  final ValueChanged<String>? onRemoveResource;

  @override
  State<ChatComposer> createState() => _ChatComposerState();
}

class _ChatComposerState extends State<ChatComposer> {
  /// C3（page-beautify P2）：输入框焦点节点——聚焦时药丸边框 hairline →
  /// l1Info 180ms 过渡（原恒 hairline：输入态无任何视觉确认，focus 反馈缺失）。
  final _focusNode = FocusNode(debugLabel: 'chat-composer-input');

  /// §3.1（2026-10-18 修订）：主操作槽三态感知——空输入/可发送/中止。
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_onFocusChanged);
    widget.inputCtrl.addListener(_onInputChanged);
    _hasText = widget.inputCtrl.text.trim().isNotEmpty;
  }

  @override
  void didUpdateWidget(covariant ChatComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.inputCtrl != widget.inputCtrl) {
      oldWidget.inputCtrl.removeListener(_onInputChanged);
      widget.inputCtrl.addListener(_onInputChanged);
      _hasText = widget.inputCtrl.text.trim().isNotEmpty;
    }
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChanged);
    _focusNode.dispose();
    widget.inputCtrl.removeListener(_onInputChanged);
    super.dispose();
  }

  void _onFocusChanged() => setState(() {});

  /// 输入非空 ⇄ 空 → 主操作槽「不可发送 ⇄ 可发送」换色（只重绘本集群）。
  void _onInputChanged() {
    final has = widget.inputCtrl.text.trim().isNotEmpty;
    if (has != _hasText) setState(() => _hasText = has);
  }

  // build 体沿用原字段名读取：经 getter 转发 widget（避免大段前缀改写，
  // 保持 B1/B4 施工痕迹的行号稳定）。
  TextEditingController get inputCtrl => widget.inputCtrl;
  bool get running => widget.running;
  bool get hasContext => widget.hasContext;
  String? get contextId => widget.contextId;
  String Function(String id) get endpointName => widget.endpointName;
  bool get hasEndpoints => widget.hasEndpoints;
  int get localPluginCount => widget.localPluginCount;
  CapsuleTone get pillTone => widget.pillTone;
  String get pillLabel => widget.pillLabel;
  DateTime? get runStartedAt => widget.runStartedAt;
  VoidCallback get onOpenMenu => widget.onOpenMenu;
  VoidCallback get onSend => widget.onSend;
  VoidCallback get onAbort => widget.onAbort;

  @override
  Widget build(BuildContext context) {
    final t = consoleTokens(context);
    // B1（page-beautify P1）：Enter 键平台语义分化——输入框已多行化
    // （maxLines 4），原 textInputAction=send 把移动端软键盘的换行键替换
    // 成发送键，多段任务输不出。移动端 Enter=换行（SDK 语义：multiline
    // 字段 newline 动作由平台直接插入换行、不经 onSubmitted——
    // editable_text.dart:3740）；桌面端保留 Enter=发送肌肉记忆。发送统一
    // 走右下主钮。沿革：2026-10-14 page-revamp 曾因单行输入「newline 动作
    // 触发 onSubmitted」改 send，多行化后该矛盾不复存在，属语义重定。
    final mobileEnterInsertsNewline =
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
    return SafeArea(
      top: false,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
            // 底部控制集群：药丸输入条（状态带 + 相位 + 输入 + 主操作钮）；
            // 运行态发送钮形变复用为「中止」键（§3.1：单一主操作槽切换
            // 发送↔中止，避免右侧另起红键挤占输入区，省一条常驻空行）。
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  // C3（page-beautify P2）：聚焦反馈——药丸边框 hairline →
                  // l1Info 180ms 过渡（原恒 hairline，输入态无视觉确认；
                  // ui-design §4.2 紧凑减速）。失焦即回。
                  child: AnimatedContainer(
                    duration: t.fastDuration,
                    curve: Curves.easeOut,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                        color: _focusNode.hasFocus ? t.l1Info : t.hairline,
                      ),
                      color: Theme.of(context).cardColor,
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // §3.1 状态做在输入框本身上沿（框内顶部状态带），idle
                        // 高度收 0，运行/绑定态平滑展开；文本输入区始终全宽（D+B 改造）。
                        // [SSOT 修正] 回退 B6（2026-10-17 用户拍板）：上下文
                        // 胶囊不融入输入行——输入行只保留「+ + 文本 + 发送」
                        // 三件式；选中/本地工具信息回到上方状态带显示
                        // （running || hasContext 时展开）。
                        // P0-2（2026-10-22）：展开条件**去掉 hasEndpoints**——
                        // 该值是「配置过端点」而非「有启用端点」，导致绝大多数用户
                        // （配过服务即 true）永远挂着一条零信息量的「空闲 · 公共」
                        // 常驻行，白占 30dp 阅读面积，且与 ui-design §3.1
                        // 「空闲态收 0」抵触。有可言说的状态（运行中 / 绑定了私有
                        // 域）才展开，纯空闲就彻底收起（高度 0）。
                        AnimatedContainer(
                          duration: t.fastDuration,
                          curve: Curves.easeOut,
                          height: (running || hasContext) ? 30 : 0,
                          clipBehavior: Clip.antiAlias,
                          decoration: const BoxDecoration(
                            borderRadius: BorderRadius.vertical(
                              top: Radius.circular(24),
                            ),
                          ),
                          child: StatusStrip(
                            t: t,
                            pillTone: pillTone,
                            pillLabel: pillLabel,
                            running: running,
                            runStartedAt: runStartedAt,
                            contextId: contextId,
                            localPluginCount: localPluginCount,
                            hasEndpoints: hasEndpoints,
                            endpointName: endpointName,
                            onOpenMenu: onOpenMenu,
                          ),
                        ),
                        // 资源附件行（2026-10-19 修订）：**按需展开**——仅有待发项
                        // 时展开（AnimatedContainer 0→44）；空态入口收进 composer
                        // 左端「+」统一挂载菜单。守住 B6「输入行只保留 + + 文本 +
                        // 发送」的拍板实质：药丸默认 1 行，不因新增能力持续占位。
                        AnimatedContainer(
                          duration: t.fastDuration,
                          curve: Curves.easeOut,
                          height: widget.pendingResources.isEmpty ? 0 : 44,
                          decoration:
                              const BoxDecoration(), // Container 断言：clip 需 decoration。
                          clipBehavior: Clip.antiAlias,
                          child: Row(
                            children: [
                              Expanded(
                                child: ListView(
                                  scrollDirection: Axis.horizontal,
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 14),
                                  children: [
                                    for (final r in widget.pendingResources)
                                      Padding(
                                        key: ValueKey('attach-${r.id}'),
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 6),
                                        child: _ResourceChip(
                                          t: t,
                                          name: r.name,
                                          onDelete: () =>
                                              widget.onRemoveResource
                                                  ?.call(r.id),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              IconButton(
                                key: const ValueKey('composer-attach'),
                                tooltip: '附加资源…（资源中心 / 本地文件）',
                                icon: const Icon(Icons.attach_file, size: 20),
                                onPressed: widget.onPickResource,
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(
                                    minWidth: 48, minHeight: 44),
                              ),
                            ],
                          ),
                        ),
                        Row(
                          children: [
                            // B3（page-beautify P2）：触达区 36→48dp——原 36dp
                            // 低于 48dp 推荐值，单手盲打误触相邻输入区/发送钮
                            // 概率高；视觉不变（图标 24 居中，仅热区外扩）。
                            IconButton(
                              icon: const Icon(Icons.add),
                              tooltip: '会话上下文（绑定 MCP 服务）',
                              onPressed: onOpenMenu,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                  minWidth: 48, minHeight: 48),
                            ),
                            // [SSOT 修正] 回退 B6：输入行不再嵌入上下文胶囊
                            // （信息在上方状态带），保持「+ + 文本 + 发送」。
                            Expanded(
                              child: TextField(
                                controller: inputCtrl,
                                focusNode: _focusNode,
                                // 运行中保持可预输入（发送由按钮/_guard 挡 running）。
                                minLines: 1,
                                maxLines: 4,
                                // B1：见 build 头部注释——移动 Enter=换行 /
                                // 桌面 Enter=发送（onSubmitted 仅桌面 send
                                // 动作触发；移动 newline 由平台直接插入）。
                                textInputAction: mobileEnterInsertsNewline
                                    ? TextInputAction.newline
                                    : TextInputAction.send,
                                decoration: InputDecoration(
                                  hintText: running
                                      ? '生成中…可先预输入下一轮'
                                      : (mobileEnterInsertsNewline
                                          ? '描述任务…（Enter 换行；如：列出今天的待办）'
                                          : '描述任务…（Enter 发送；如：列出今天的待办）'),
                                  border: InputBorder.none,
                                  contentPadding:
                                      const EdgeInsets.fromLTRB(14, 12, 6, 12),
                                ),
                                onSubmitted: (_) => onSend(),
                              ),
                            ),
                            const SizedBox(width: 4),
                            // §3.1（2026-10-18 二次修订，用户拍板）：主操作槽
                            // 与左端「+」对称——无独立容器，图标融入药丸
                            //（同 48×48 热区）。三态只换图标与颜色：
                            // 空输入=terminalMuted（不可发送）、有输入=l1Info
                            //（可发送）、运行=danger（中止）。色彩 180ms 紧凑
                            // 过渡确认相位（作废 P1-4 Crimson 实底高反差拍板）。
                            IconButton(
                              tooltip: running ? '中止' : '发送',
                              icon: _MainActionIcon(abort: running, ready: _hasText),
                              onPressed: running ? onAbort : onSend,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                  minWidth: 48, minHeight: 48),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// §3.1（2026-10-18 二次修订）主操作槽图标：无独立容器融入药丸，与「+」
/// 对称（同 48×48 热区）；三态只换色与图标——空输入=terminalMuted（不可
/// 发送）、有输入=l1Info（可发送）、运行=danger（中止）。中止↔发送交叉
/// 缩放淡入（180ms）；空输入⇄可发送仅色过渡（glyph 不变，无缩放脉冲）。
/// 双通道（§6）：图标形状即第二通道，禁用态另有置灰。
class _MainActionIcon extends StatelessWidget {
  const _MainActionIcon({required this.abort, required this.ready});

  final bool abort;
  final bool ready;

  @override
  Widget build(BuildContext context) {
    final t = consoleTokens(context);
    final color = abort
        ? t.danger
        : (ready ? t.l1Info : t.terminalMuted);
    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(end: color),
      duration: t.fastDuration,
      curve: Curves.easeOut,
      builder: (context, c, _) => AnimatedSwitcher(
        duration: t.fastDuration,
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.75, end: 1).animate(animation),
            child: child,
          ),
        ),
        child: Icon(
          abort ? Icons.stop : Icons.arrow_upward,
          key: ValueKey(abort), // 仅中止↔发送换 glyph 时交叉过渡
          size: 20,
          color: c,
        ),
      ),
    );
  }
}

/// 附件药丸（挂载点复盘 #7）：弃 Material 默认 `InputChip`（自带 delete 皮与
/// 默认间距，与控制台件族不同源），改自绘——hairline 边框 + `cardRadius` +
/// `codeBg` 微深底 + `dataRef` 文件图标，与 `StatusCapsule` / `ContextChip`
/// 同族（ui-design §3.2 卡片规格 + §4.7 零魔法值）。
class _ResourceChip extends StatelessWidget {
  const _ResourceChip({
    required this.t,
    required this.name,
    required this.onDelete,
  });

  final ConsoleTokens t;
  final String name;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final fg = Theme.of(context).textTheme.bodyMedium?.color;
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 3, 2, 3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(t.cardRadius),
        border: Border.all(color: t.hairline),
        color: t.codeBg,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.description_outlined, size: 12, color: t.dataRef),
          const SizedBox(width: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 132),
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: Fsz.telemetry, color: fg),
            ),
          ),
          // 热区 32×32：受 44dp 行高约束，未达 §4.4 的 44 红线——偏差已
          // 登记（待办：改长按或行内菜单删除，勿再单独提行高）。
          SizedBox(
            width: 32,
            height: 32,
            child: IconButton(
              tooltip: '移除附件（不删资源库）',
              onPressed: onDelete,
              padding: EdgeInsets.zero,
              icon: Icon(Icons.close, size: 14, color: t.terminalMuted),
            ),
          ),
        ],
      ),
    );
  }
}
