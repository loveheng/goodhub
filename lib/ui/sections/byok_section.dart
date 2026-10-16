/// 设置页 · 云端引擎（BYOK）段（window-slim P1-A 分段拆解，2026-10-17 自
/// settings_page 迁出）：store 读写、生效位、密钥安全存储编排、表单与卡片
/// 渲染全部自持——settings_page 只透传 store 注入位（测试假件）与 flash/错误
/// 行回调。
///
/// 迁移语义原样保留（含测试锚点 Key）：
/// - 装配语义：hybrid_assembly 取列表首个 profile 为生效云端引擎——首位即
///   「生效中」，置顶动作即切换生效配置（不改装配线，零回归面）；
/// - 密钥纪律：profile 明文不含密钥，密钥走安全存储；编辑留空 = 保持已存；
/// - save 自带孤儿密钥连带清理；失败置面板级错误态（P0-3）+ 重试。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../llm/cloud/byok_store.dart';
import '../../llm/cloud/cloud_llm.dart' show CloudProtocol;
import '../tokens/console_tokens.dart';

/// 段 widget：注入 [store]（生产 = `ByokStore()`，测试传假件）、[onFlash]
/// （页面级 toast 口径）、[errorRowBuilder]（面板级错误态统一件）。
class ByokSection extends StatefulWidget {
  const ByokSection({
    super.key,
    required this.store,
    required this.onFlash,
    required this.errorRowBuilder,
  });

  final ByokStore store;
  final void Function(String message) onFlash;
  final Widget Function(ConsoleTokens t, String message, VoidCallback onRetry,
      {ValueKey<String>? key}) errorRowBuilder;

  @override
  State<ByokSection> createState() => _ByokSectionState();
}

class _ByokSectionState extends State<ByokSection> {
  var _profiles = const <ByokProfile>[];
  final _hasKey = <String>{}; // 安全存储已有密钥的 profileId（真值不入内存明文）
  String? _preferredId; // 生效 profile id（用户显式选择；未选=列表首位）
  String? _editingId;
  var _creating = false;
  String? _error;

  final _nameCtrl = TextEditingController();
  final _urlCtrl = TextEditingController();
  final _modelCtrl = TextEditingController();
  final _tempCtrl = TextEditingController();
  final _keyCtrl = TextEditingController();
  var _proto = CloudProtocol.openaiCompatible;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _urlCtrl.dispose();
    _modelCtrl.dispose();
    _tempCtrl.dispose();
    _keyCtrl.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    try {
      final profiles = await widget.store.load();
      final withKey = <String>{};
      for (final p in profiles) {
        if (await widget.store.apiKey(p.id) != null) withKey.add(p.id);
      }
      final preferred = await widget.store.preferredProfileId();
      if (!mounted) return;
      setState(() {
        _profiles = profiles;
        _hasKey
          ..clear()
          ..addAll(withKey);
        _preferredId =
            preferred ?? (profiles.isNotEmpty ? profiles.first.id : null);
        _creating = false;
        _editingId = null;
        _error = null;
      });
    } catch (e) {
      debugPrint('[DEGRADE] byok-panel: 配置读取失败: $e');
      if (mounted) setState(() => _error = '模型配置读取失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = consoleTokens(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  // P1-7：标题去首字母缩略语——BYOK 对普通用户是黑话。
                  '云端引擎（自带 API Key）',
                  style: const TextStyle(
                    fontSize: Fsz.sectionTitle,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Text(
                  '配置 ${_profiles.length} 项',
                  style: TextStyle(
                    fontFamily: t.monoFamily,
                    fontSize: Fsz.telemetrySm,
                    color: t.terminalMuted,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '用你自己的 API Key 接入云端模型（OpenAI 兼容 / Anthropic）。'
              '标注「生效中」的是当前实际使用的模型，可点「设为生效引擎」切换。',
              style: TextStyle(
                fontSize: Fsz.telemetrySm,
                color: Theme.of(context).hintColor,
              ),
            ),
            const SizedBox(height: 8),
            if (_error != null)
              widget.errorRowBuilder(
                t,
                _error!,
                _reload,
                key: const ValueKey('byok-error'),
              )
            else ...[
              for (final p in _profiles) _item(context, t, p),
              if (_profiles.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text(
                    // P1-7：空态文案去「装配」黑话。
                    '（暂无模型配置——未接入云端模型，仅端侧路径）',
                    style: TextStyle(
                      fontSize: Fsz.telemetry,
                      color: Theme.of(context).hintColor,
                    ),
                  ),
                ),
              if (_creating) _editor(context, t, null),
              if (!_creating)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    key: const Key('byok-new'),
                    onPressed: () => setState(() => _creating = true),
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('添加模型'),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _item(BuildContext context, ConsoleTokens t, ByokProfile p) {
    final editing = _editingId == p.id;
    final hasKey = _hasKey.contains(p.id);
    final active = _preferredId == p.id;
    return Container(
      key: Key('byok-item-${p.id}'),
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(t.cardRadius),
        // 生效中 = L1 就绪语义（Amber 是写操作警示，不挪用）。
        border: Border.all(
          color: active ? t.l1Ok : t.hairline,
          width: active ? 1.2 : 1,
        ),
      ),
      child: editing
          ? _editor(context, t, p)
          : Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              p.name,
                              style: TextStyle(
                                fontFamily: t.monoFamily,
                                fontSize: Fsz.telemetry,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (active) ...[
                            const SizedBox(width: 6),
                            Text(
                              '生效中',
                              style: TextStyle(
                                fontSize: Fsz.microSm,
                                color: t.l1Ok,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ],
                      ),
                      Text(
                        '${_protoLabel(p.protocol)} · ${p.model}\n'
                        '${p.baseUrl}${hasKey ? ' · 已存密钥' : ' · ⚠ 未存密钥'}',
                        style: TextStyle(
                          fontFamily: t.monoFamily,
                          fontSize: Fsz.micro,
                          color: t.terminalMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                if (!active)
                  IconButton(
                    key: Key('byok-top-${p.id}'),
                    tooltip: '设为生效引擎',
                    iconSize: 18,
                    onPressed: () => _moveTop(p),
                    icon: const Icon(Icons.vertical_align_top_outlined),
                  ),
                IconButton(
                  key: Key('byok-edit-${p.id}'),
                  tooltip: '编辑',
                  iconSize: 18,
                  onPressed: () => setState(() {
                    _editingId = p.id;
                    _nameCtrl.text = p.name;
                    _proto = p.protocol;
                    _urlCtrl.text = p.baseUrl;
                    _modelCtrl.text = p.model;
                    _tempCtrl.text = p.temperature?.toString() ?? '';
                    _keyCtrl.clear();
                  }),
                  icon: const Icon(Icons.edit_outlined),
                ),
                IconButton(
                  key: Key('byok-del-${p.id}'),
                  tooltip: '删除',
                  iconSize: 18,
                  onPressed: () => _delete(p),
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
    );
  }

  /// 新增（profile == null）与编辑共用表单；编辑模式密钥留空 = 保持已存密钥。
  Widget _editor(BuildContext context, ConsoleTokens t, ByokProfile? profile) {
    final isEdit = profile != null;
    return Container(
      key: Key(isEdit ? 'byok-edit-form' : 'byok-new-form'),
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(t.cardRadius),
        border: Border.all(color: t.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const Key('byok-field-name'),
            controller: _nameCtrl,
            style: TextStyle(fontFamily: t.monoFamily, fontSize: Fsz.telemetry),
            decoration: const InputDecoration(
              labelText: '显示名',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 6),
          SegmentedButton<CloudProtocol>(
            segments: const [
              ButtonSegment(
                value: CloudProtocol.openaiCompatible,
                label: Text('OpenAI 兼容'),
              ),
              ButtonSegment(
                value: CloudProtocol.anthropic,
                label: Text('Anthropic'),
              ),
            ],
            selected: {_proto},
            onSelectionChanged: (s) => setState(() => _proto = s.first),
          ),
          const SizedBox(height: 6),
          TextField(
            key: const Key('byok-field-url'),
            controller: _urlCtrl,
            style: TextStyle(fontFamily: t.monoFamily, fontSize: Fsz.telemetry),
            decoration: const InputDecoration(
              labelText: 'Base URL',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 6),
          TextField(
            key: const Key('byok-field-model'),
            controller: _modelCtrl,
            style: TextStyle(fontFamily: t.monoFamily, fontSize: Fsz.telemetry),
            decoration: const InputDecoration(
              labelText: '模型 ID（如 deepseek-chat / claude-sonnet-4-5）',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 6),
          TextField(
            key: const Key('byok-field-temp'),
            controller: _tempCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Temperature（可空）',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 6),
          TextField(
            key: const Key('byok-field-key'),
            controller: _keyCtrl,
            obscureText: true,
            style: TextStyle(fontFamily: t.monoFamily, fontSize: Fsz.telemetry),
            decoration: InputDecoration(
              labelText: isEdit ? 'API Key（留空 = 保持已存密钥）' : 'API Key',
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => setState(() {
                  if (isEdit) {
                    _editingId = null;
                  } else {
                    _creating = false;
                  }
                }),
                child: const Text('取消'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                key: Key(isEdit ? 'byok-save' : 'byok-create'),
                onPressed: () => isEdit ? _saveEdit(profile) : _create(),
                child: Text(isEdit ? '保存' : '创建'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _protoLabel(CloudProtocol p) => switch (p) {
    CloudProtocol.openaiCompatible => 'OpenAI 兼容',
    CloudProtocol.anthropic => 'Anthropic',
  };

  /// 表单 → profile 校验（name/baseUrl/model 必填；temperature 容错解析）。
  /// 返回 null = 校验失败（已 flash 提示）。
  ByokProfile? _collectForm(String id) {
    final name = _nameCtrl.text.trim();
    final url = _urlCtrl.text.trim();
    final model = _modelCtrl.text.trim();
    final tempText = _tempCtrl.text.trim();
    if (name.isEmpty || url.isEmpty || model.isEmpty) {
      widget.onFlash('显示名 / Base URL / 模型 ID 均必填');
      return null;
    }
    double? temp;
    if (tempText.isNotEmpty) {
      temp = double.tryParse(tempText);
      if (temp == null) {
        widget.onFlash('Temperature 须为数字（如 0.2）');
        return null;
      }
    }
    return ByokProfile(
      id: id,
      name: name,
      protocol: _proto,
      baseUrl: url,
      model: model,
      temperature: temp,
    );
  }

  Future<void> _create() async {
    final key = _keyCtrl.text.trim();
    if (key.isEmpty) {
      widget.onFlash('API Key 必填（走安全存储，不落明文）');
      return;
    }
    var id = 'byok_${DateTime.now().millisecondsSinceEpoch}';
    while (_profiles.any((p) => p.id == id)) {
      id = 'byok_${DateTime.now().microsecondsSinceEpoch}';
    }
    final profile = _collectForm(id);
    if (profile == null) return;
    await widget.store.save([..._profiles, profile]);
    await widget.store.setApiKey(id, key);
    await _reload();
    widget.onFlash('✓ 已添加 ${profile.name}');
  }

  Future<void> _saveEdit(ByokProfile old) async {
    final profile = _collectForm(old.id);
    if (profile == null) return;
    final key = _keyCtrl.text.trim();
    await widget.store.save([
      for (final p in _profiles)
        if (p.id == old.id) profile else p,
    ]);
    if (key.isNotEmpty) await widget.store.setApiKey(old.id, key);
    await _reload();
    widget.onFlash('✓ 已更新 ${profile.name}');
  }

  Future<void> _moveTop(ByokProfile p) async {
    // 重排（首位展示惯例）+ 写生效位：装配以 preferred 为准（未选才回退首位）。
    await widget.store.save([p, ..._profiles.where((e) => e.id != p.id)]);
    await widget.store.setPreferredProfileId(p.id);
    await _reload();
    widget.onFlash('✓ 已切换生效引擎：${p.name}');
  }

  Future<void> _delete(ByokProfile p) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除模型配置'),
        content: Text('删除「${p.name}」（${p.model}）？其已存密钥将一并清除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: consoleTokens(ctx).danger,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    // save 自带孤儿密钥连带清理（被移除 profile 的密钥删除）。
    await widget.store.save(_profiles.where((e) => e.id != p.id).toList());
    await _reload();
    widget.onFlash('✓ 已删除 ${p.name}');
  }
}
