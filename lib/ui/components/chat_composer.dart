import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
    this.modelSummary,
    this.onOpenModelPicker,
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

  /// 模型入口（2026-11-07 方案 B 输入区双行重设计）：底栏左侧动作行，
  /// [modelSummary] = 当前来源/模型短名（药丸常显，可发现性优于藏菜单）。
  /// null 回调 = 不渲染模型药丸。
  final String? modelSummary;
  final VoidCallback? onOpenModelPicker;

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
                        // —— 方案 B（2026-11-07 用户裁决）输入区双行重设计：——
                        // 上行 = TextField 独占全宽（原左右两枚 48dp 动作钮
                        // 吃掉约 120dp 横向面积）；下行 = 底栏动作行：左
                        // [+ 挂载] [模型药丸（来源短名常显）]，右 [发送/中止]。
                        // [SSOT 修正] B6「+ + 文本 + 发送」三件式随之修订——
                        // 其本意（药丸不因新增能力占行）经方案 B 评审保留：
                        // 动作聚一行、文本不与之混排，且模型短名属有效状态
                        // 信息（菜单入口同步保留，双入口不冲突）。
                        TextField(
                          controller: inputCtrl,
                          focusNode: _focusNode,
                          // 运行中保持可预输入（发送由按钮/_guard 挡 running）。
                          minLines: 1,
                          maxLines: 4,
                          // B1：移动 Enter=换行 / 桌面 Enter=发送（onSubmitted
                          // 仅桌面 send 动作触发；移动 newline 由平台直接插入）。
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
                                const EdgeInsets.fromLTRB(14, 12, 14, 6),
                          ),
                          onSubmitted: (_) => onSend(),
                        ),
                        // 底栏动作行（Gemini 对齐精修 2026-11-07）：左簇去
                        // 容器（裸图标，去双框叠弧的贴边感）；模型药丸/主钮
                        // 全胶囊统一（半径=高一半）；行内 10dp 边距离弧不贴边。
                        Padding(
                          padding:
                              const EdgeInsets.fromLTRB(6, 4, 6, 4),
                          child: Row(
                            children: [
                              // 左簇①：「+」裸图标（Gemini 同款）——去 hairline
                              // 容器；热区 48×44（透明 padding 补足红线）。
                              GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: onOpenMenu,
                                child: Tooltip(
                                  message: '会话上下文（绑定 MCP 服务）',
                                  child: SizedBox(
                                    width: 48,
                                    height: 44,
                                    // 图标 l1Info：与模型药丸同色族（2026-11-07
                                    // 用户反馈底栏要有点颜色）——不套底，避免
                                    // 复发双框贴边；主钮实底仍是最重一档。
                                    child: Icon(Icons.add,
                                        size: 22, color: t.l1Info),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 2),
                              // 左簇②：模型入口药丸——icon + 来源短名常显，
                              // 长名 maxWidth 140 + ellipsis 防顶穿 Spacer。
                              if (widget.onOpenModelPicker != null)
                                // 弹性占位：窄视口下药丸随父宽收缩（140 只是
                                // 上限），防长名顶爆底栏 Row（smoke 测试实证）。
                                Flexible(
                                  child: GestureDetector(
                                  key: const ValueKey('composer-model-picker'),
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () {
                                    unawaited(HapticFeedback.selectionClick());
                                    widget.onOpenModelPicker!();
                                  },
                                  child: Tooltip(
                                    message: '切换模型（端侧 / 云端）',
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 4),
                                      child: Container(
                                      height: 36,
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 12),
                                      decoration: BoxDecoration(
                                        // 全胶囊（半径=高一半）：与外框同形状
                                        // 语言，Material chip 语义（Gemini
                                        // Flash 药丸同款）。
                                        borderRadius:
                                            BorderRadius.circular(18),
                                        border:
                                            Border.all(color: t.hairline),
                                        color: t.l1Info.withValues(alpha: 0.14),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(Icons.memory,
                                              size: 14, color: t.l1Info),
                                          const SizedBox(width: 4),
                                          // 来源切换 crossfade（180ms 紧凑
                                          // 减速，同 §4.2 相位过渡口径）；
                                          // 文本随父宽收缩 + ellipsis。
                                          Flexible(
                                            child: AnimatedSwitcher(
                                            duration: t.fastDuration,
                                            child: Text(
                                              widget.modelSummary ?? '模型',
                                              key: ValueKey(
                                                  widget.modelSummary),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontFamily: t.monoFamily,
                                                fontSize: Fsz.micro,
                                                color: t.l1Info,
                                              ),
                                            ),
                                          ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              ),
                              const Spacer(),
                              // 主操作槽（方案 1 实底化）：全屏最常用单一动
                              // 作落拇指热区，视觉权重回归——可发送=l1Info
                              // 实底白箭头、运行=danger 实底、空输入=
                              // hairline 灰（禁用双通道保留）。视觉 40×36，
                              // 透明 padding 补足 44dp 热区。
                              GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: running ? onAbort : onSend,
                                child: Padding(
                                  // 热区 48×48 满规格（视觉胶囊 40×36 不变）：
                                  // 发送/中止是全屏最高频单动作，热区给满
                                  // §4.4 上限——2026-11-07 用户反馈「有点小」。
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 4, vertical: 6),
                                  child: Tooltip(
                                    message: running ? '中止' : '发送',
                                    child: _MainActionButton(
                                        abort: running, ready: _hasText),
                                  ),
                                ),
                              ),
                            ],
                          ),
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

/// 主操作槽（方案 1 实底化，2026-11-07）：40×40 圆角胶囊——全屏最常用
/// 单一动作落拇指热区，视觉权重回归主次层级。三态：
/// 可发送 = l1Info 实底白箭头 / 运行 = danger 实底 / 空输入 = hairline
/// 边框灰图标（禁用双通道：形状 + 置灰，§6）。中止↔发送交叉缩放淡入
/// （180ms）；空输入⇄可发送容器色/glyph 平滑过渡。
class _MainActionButton extends StatelessWidget {
  const _MainActionButton({required this.abort, required this.ready});

  final bool abort;
  final bool ready;

  @override
  Widget build(BuildContext context) {
    final t = consoleTokens(context);
    final Color bg;
    final Color fg;
    if (abort) {
      bg = t.danger;
      fg = Colors.white;
    } else if (ready) {
      bg = t.l1Info;
      fg = Colors.white;
    } else {
      bg = Colors.transparent;
      fg = t.terminalMuted;
    }
    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(end: bg),
      duration: t.fastDuration,
      curve: Curves.easeOut,
      builder: (context, bgc, _) => AnimatedSwitcher(
        duration: t.fastDuration,
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.75, end: 1).animate(animation),
            child: child,
          ),
        ),
        child: Container(
          key: ValueKey(abort), // 仅中止↔发送换 glyph 时交叉过渡
          // 视觉 52×36 药丸（2026-11-07 用户反馈：面积要更大更醒目）——
          // 主操作槽权重再升一档，宽度给 glyph 左右呼吸。
          width: 52,
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            // 全胶囊（半径=高一半）：与模型药丸/外框同形状语言。
            borderRadius: BorderRadius.circular(18),
            color: bgc,
            border: Border.all(
                color: ready || abort ? (bgc ?? bg) : t.hairline),
          ),
          child: Icon(
            abort ? Icons.stop : Icons.arrow_upward,
            size: 20,
            color: fg,
          ),
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
          // 删除交互按既定待办落地（盘点 2026-11-06 #12）：长按 chip 移除——
          // 原 32×32 删除钮低于 44dp 红线且与文件名相邻易误触；×仅作视觉
          // 指示（非按钮），Tooltip 说明长按语义。
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onLongPress: onDelete,
            child: Tooltip(
              message: '长按移除附件（不删资源库）',
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Icon(Icons.close, size: 14, color: t.terminalMuted),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
