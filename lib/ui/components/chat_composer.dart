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

  @override
  State<ChatComposer> createState() => _ChatComposerState();
}

class _ChatComposerState extends State<ChatComposer> {
  /// C3（page-beautify P2）：输入框焦点节点——聚焦时药丸边框 hairline →
  /// l1Info 180ms 过渡（原恒 hairline：输入态无任何视觉确认，focus 反馈缺失）。
  final _focusNode = FocusNode(debugLabel: 'chat-composer-input');

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChanged);
    _focusNode.dispose();
    super.dispose();
  }

  void _onFocusChanged() => setState(() {});

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
                        // 高度收 0，运行态平滑展开；文本输入区始终全宽（D+B 改造）。
                        // [SSOT 修正] 回退 B6（2026-10-17 用户拍板）：上下文
                        // 胶囊不融入输入行——输入行只保留「+ + 文本 + 发送」
                        // 三件式；选中/本地工具信息回到上方状态带显示
                        // （running || hasContext || hasEndpoints 时展开）。
                        AnimatedContainer(
                          duration: t.fastDuration,
                          curve: Curves.easeOut,
                          height:
                              (running || hasContext || hasEndpoints) ? 30 : 0,
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
                            // §3.1 复用发送钮：运行态形变为主操作「中止」键，
                            // 单一槽位内切换 发送↔中止，避免右侧另起红键挤占输入区。
                            // P1-4（§1 高反差拍板）：Crimson 实底 + 白图标 +
                            // 40×40——filledTonal 的 tonal 底在运行态不足以让
                            // 普通用户一眼找到「停止」。
                            // B4（page-beautify P2）：形变过程可感知——底色
                            // 180ms 过渡 + 图标交叉缩放淡入（替代原瞬时切换；
                            // 「任务已启动/已停止」应在动效中被确认，§4.2）。
                            // 视觉对齐 M3 filledTonal 默认（Stadium 形 +
                            // secondaryContainer/onSecondaryContainer，运行态
                            // 覆写 dangerDeep + 白图标）；Material 作 ink 面
                            // 保涟漪，TweenAnimationBuilder 只动画其 color。
                            Tooltip(
                              message: running ? '中止' : '发送',
                              child: TweenAnimationBuilder<Color?>(
                                tween: ColorTween(
                                  end: running
                                      ? t.dangerDeep
                                      : Theme.of(context)
                                          .colorScheme
                                          .secondaryContainer,
                                ),
                                duration: t.fastDuration,
                                curve: Curves.easeOut,
                                builder: (context, color, _) => Material(
                                  color: color,
                                  shape: const StadiumBorder(),
                                  clipBehavior: Clip.antiAlias,
                                  child: InkWell(
                                    customBorder: const StadiumBorder(),
                                    onTap: running ? onAbort : onSend,
                                    child: SizedBox(
                                      width: 40,
                                      height: 40,
                                      child: Center(
                                        child: _SendAbortIcon(running: running),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
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

/// B4（page-beautify P2）：发送↔中止图标交叉缩放淡入（180ms，与底色过渡
/// 同期）——相位切换的「形变」应在动效中被确认，而非瞬时替换（ui-design
/// §4.2：紧凑减速，禁 Spring）。颜色对齐原 filledTonal 口径：idle =
/// onSecondaryContainer，running = 白（Crimson 实底上）。
class _SendAbortIcon extends StatelessWidget {
  const _SendAbortIcon({required this.running});

  final bool running;

  @override
  Widget build(BuildContext context) {
    final t = consoleTokens(context);
    return AnimatedSwitcher(
      duration: t.fastDuration,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.75, end: 1).animate(animation),
          child: child,
        ),
      ),
      child: Icon(
        running ? Icons.stop : Icons.arrow_upward,
        key: ValueKey(running),
        size: 20,
        color: running
            ? Colors.white
            : Theme.of(context).colorScheme.onSecondaryContainer,
      ),
    );
  }
}
