/// elicitation 交互卡（MCP 2025-06-18 `elicitation/create` 宿主侧表单）。
///
/// 按 [ElicitationRequest.requestedSchema] 动态渲染字段：
/// boolean → 开关；string + enum → 下拉；number/integer → 数字输入；
/// 其余 string → 文本输入。必填项缺省/类型非法时禁止提交；提交回 accept+content，
/// 「跳过」回 decline。终态（lockedAnswer 非空）锁定为灰阶展示。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../mcp/elicitation.dart';
import '../tokens/console_tokens.dart';

class ElicitationCard extends StatefulWidget {
  const ElicitationCard({
    required this.request,
    this.onDecision,
    this.lockedAnswer,
    this.lockedAt,
    super.key,
  }) : assert(
          (onDecision == null) == (lockedAnswer != null),
          '交互态给 onDecision，终态给 lockedAnswer',
        );

  final ElicitationRequest request;

  /// 交互态回调（终态时为 null）。
  final void Function(ElicitationAnswer answer)? onDecision;

  /// 终态锁定：已作出的应答（灰阶展示，无按钮）。
  final ElicitationAnswer? lockedAnswer;
  final DateTime? lockedAt;

  @override
  State<ElicitationCard> createState() => _ElicitationCardState();
}

class _ElicitationCardState extends State<ElicitationCard> {
  final Map<String, Object?> _values = {};
  final Map<String, String> _errors = {};
  final Map<String, TextEditingController> _controllers = {};
  final Map<String, FocusNode> _focusNodes = {};

  @override
  void initState() {
    super.initState();
    for (final f in widget.request.fields) {
      if (f.isBoolean) {
        _values[f.name] = false;
      } else if (f.enumValues != null) {
        _values[f.name] = f.enumValues!.first;
      } else {
        _controllers[f.name] = TextEditingController();
        _values[f.name] = '';
        // P1：文本/数字字段聚焦 → 滚动入视，避移动端键盘遮挡。
        final node = FocusNode();
        _focusNodes[f.name] = node;
        node.addListener(() {
          if (node.hasFocus) _scrollIntoView();
        });
      }
    }
    if (widget.onDecision != null) {
      // §4.1：L2 中断卡弹出 → 双击警示震动（同步连发，不挂 Timer）。
      HapticFeedback.heavyImpact();
      HapticFeedback.heavyImpact();
    }
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    for (final n in _focusNodes.values) {
      n.dispose();
    }
    super.dispose();
  }

  static String _hhmm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  /// P1：字段聚焦时滚动入视——移动端弹键盘会遮挡输入框，alignment 0.3 让
  /// 聚焦字段略偏视口上方，露出其后续字段与提交按钮。
  void _scrollIntoView() {
    Scrollable.ensureVisible(
      context,
      duration: consoleTokens(context).fastDuration,
      curve: Curves.easeOut,
      alignment: 0.3,
    );
  }

  void _submit() {
    final errors = <String, String>{};
    for (final f in widget.request.fields) {
      if (widget.request.required.contains(f.name) &&
          (_values[f.name] == null ||
              (_values[f.name] is String &&
                  (_values[f.name] as String).isEmpty))) {
        errors[f.name] = '必填';
        continue;
      }
      if (f.isNumeric) {
        final raw = _values[f.name];
        if (raw is String && raw.isNotEmpty) {
          final n = num.tryParse(raw);
          if (n == null) errors[f.name] = '需数字';
        }
      }
    }
    setState(() => _errors
      ..clear()
      ..addAll(errors));
    if (errors.isNotEmpty) return;

    final content = <String, Object?>{};
    for (final f in widget.request.fields) {
      final v = _values[f.name];
      if (f.isNumeric && v is String && v.isNotEmpty) {
        content[f.name] = f.type == 'integer' ? int.parse(v) : double.parse(v);
      } else if (f.isBoolean) {
        content[f.name] = v is bool ? v : false;
      } else {
        content[f.name] = v is String ? v : (v?.toString() ?? '');
      }
    }
    widget.onDecision?.call(ElicitationAnswer.accept(content));
  }

  Widget _field(ElicitationField f, ConsoleTokens t) {
    final err = _errors[f.name];
    final label = '${f.title ?? f.name}${widget.request.required.contains(f.name) ? ' *' : ''}';
    if (f.isBoolean) {
      return SwitchListTile(
        title: Text(label, style: const TextStyle(fontSize: Fsz.body)),
        subtitle: f.description != null
            ? Text(f.description!, style: TextStyle(fontSize: Fsz.note, color: t.terminalMuted))
            : null,
        value: _values[f.name] is bool ? _values[f.name] as bool : false,
        onChanged: (v) => setState(() => _values[f.name] = v),
      );
    }
    if (f.enumValues != null) {
      return DropdownButtonFormField<String>(
        initialValue: _values[f.name] as String?,
        decoration: InputDecoration(labelText: label, errorText: err),
        items: [
          for (final e in f.enumValues!)
            DropdownMenuItem(value: e, child: Text(e)),
        ],
        onChanged: (v) => setState(() => _values[f.name] = v),
      );
    }
    final c = _controllers[f.name]!;
    return TextFormField(
      controller: c,
      focusNode: _focusNodes[f.name],
      keyboardType: f.isNumeric ? TextInputType.number : TextInputType.text,
      decoration: InputDecoration(
        labelText: label,
        errorText: err,
        hintText: f.description,
      ),
      onChanged: (v) => _values[f.name] = v,
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = consoleTokens(context);
    final locked = widget.lockedAnswer;
    if (locked != null) {
      final at = widget.lockedAt ?? DateTime.now();
      final text = locked.accepted
          ? '✓ 已于 ${_hhmm(at)} 填写'
          : '✕ 已于 ${_hhmm(at)} 跳过（decline）';
      return _frame(
        context,
        barColor: t.terminalMuted,
        child: Text(text, style: TextStyle(color: t.terminalMuted, fontSize: Fsz.body)),
      );
    }
    return _frame(
      context,
      barColor: t.l2Warn,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // P0-3 双通道状态（§6）：语义色须伴随图标/文字——琥珀竖条之外，
          // 显式「需要你的输入」图标标题，色弱/强光下仅凭第二通道可判态。
          Row(
            children: [
              Icon(Icons.input, size: 16, color: t.l2Warn),
              const SizedBox(width: 6),
              Text(
                '需要你的输入',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: Fsz.note,
                  color: t.l2Warn,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(widget.request.message,
              style: const TextStyle(fontSize: Fsz.reading, height: 1.5)),
          const SizedBox(height: 8),
          for (final f in widget.request.fields) ...[
            _field(f, t),
            const SizedBox(height: 6),
          ],
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () =>
                    widget.onDecision?.call(ElicitationAnswer.decline()),
                child: const Text('跳过'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _submit,
                child: const Text('提交'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _frame(BuildContext context, {required Color barColor, required Widget child}) {
    final t = consoleTokens(context);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      // P0-1：与确认/熔断/围栏卡同族——带 cardColor 填充 + ClipRRect + Material
      // 包裹（内部按钮/开关的 ink 与主题继承一致），竖条宽 4 同范本。
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(t.cardRadius),
        border: Border.all(color: t.hairline),
        color: Theme.of(context).cardColor,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(t.cardRadius),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(width: 4, color: barColor),
              const SizedBox(width: 8),
              Expanded(
                child: Material(
                  type: MaterialType.transparency,
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: child,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
