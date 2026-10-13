/// 服务大厅（M3-T4，architecture §5「服务与配置大厅」的 M3 交付面；形态 =
/// ui-design §3.3 控制台式卡片阵列）。本期两面板：
/// ① **Skill 覆写管理（CoW 编辑面）**——覆写列表/编辑/保存（setOverride）/
///    一键重置；覆写优先级最高，major 跃迁告警弹卡（CowMajorJumpDelegate）
///    在联调流组件化复用，此处不重复建同步入口（同步需 Server 连接，属
///    Server 节点管理面板范围）；
/// ② **BYOK 云端引擎面板（M4-T5）**——模型配置列表增删改（多 profile）+ 密钥
///    走 SecureKeyValue（编辑留空 = 保持已存密钥）；装配语义 = 列表首位为生效
///    云端引擎（hybrid_assembly 取首个 profile），支持置顶切换生效配置；
/// ③ **跨源授权语义面板**——D5 恒 L2 弹卡不豁免的口径展示 + 联调入口。
/// Server 节点管理不在本期范围，留导航位。
///
/// 保存校验口径（评审注记修正 2026-10-11）：SkillRegistry 300T 闸只管
/// Global scope（常驻预算），覆写 skill 是 appScoped 无该闸——编辑面校验
/// = 非空 + 10000 字符防呆上限，不套 300T。
library;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../coordinator/cow_sync.dart';
import '../llm/cloud/byok_store.dart';
import '../llm/cloud/cloud_llm.dart';
import 'gateway_loop_debug_page.dart';
import 'tokens/console_tokens.dart';

/// appScoped 覆写正文的防呆上限（无硬预算闸，防呆防手滑）。
const kCowOverrideMaxChars = 10000;

class ServicesHallPage extends StatefulWidget {
  const ServicesHallPage({super.key, this.storeOverride, this.byokStoreOverride});

  /// 测试注入位；null = 生产路径（应用文档目录）。
  final CowOverridesStore? storeOverride;

  /// 测试注入位（M4-T5 BYOK 面板）；null = 生产路径（默认安全存储装配）。
  final ByokStore? byokStoreOverride;

  @override
  State<ServicesHallPage> createState() => _ServicesHallPageState();
}

class _ServicesHallPageState extends State<ServicesHallPage> {
  CowOverridesStore? _store;
  Map<String, DateTime?> _entries = const {};
  String? _editingName;
  final _editCtrl = TextEditingController();
  final _newNameCtrl = TextEditingController();
  final _newContentCtrl = TextEditingController();
  var _creating = false;
  String? _error;

  // —— BYOK 面板状态（M4-T5）——
  ByokStore? _byokStore;
  var _byokProfiles = const <ByokProfile>[];
  final _hasByokKey = <String>{}; // 安全存储已有密钥的 profileId（真值不入内存明文）
  String? _editingByokId;
  var _creatingByok = false;
  var _byokProto = CloudProtocol.openaiCompatible;
  final _byokNameCtrl = TextEditingController();
  final _byokUrlCtrl = TextEditingController();
  final _byokModelCtrl = TextEditingController();
  final _byokTempCtrl = TextEditingController();
  final _byokKeyCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _editCtrl.dispose();
    _newNameCtrl.dispose();
    _newContentCtrl.dispose();
    _byokNameCtrl.dispose();
    _byokUrlCtrl.dispose();
    _byokModelCtrl.dispose();
    _byokTempCtrl.dispose();
    _byokKeyCtrl.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    try {
      final store = widget.storeOverride ??
          CowOverridesStore(dir: await getApplicationDocumentsDirectory());
      await _reload(store);
    } catch (e) {
      if (mounted) setState(() => _error = '覆写库初始化失败: $e');
    }
    // BYOK 独立初始化：覆写库失败不拖垮面板（面板间无数据依赖）。
    try {
      final byok = widget.byokStoreOverride ?? ByokStore();
      await _reloadByok(byok);
    } catch (e) {
      debugPrint('[DEGRADE] byok-panel: 配置读取失败按空目录: $e');
    }
  }

  Future<void> _reloadByok(ByokStore store) async {
    final profiles = await store.load();
    final withKey = <String>{};
    for (final p in profiles) {
      if (await store.apiKey(p.id) != null) withKey.add(p.id);
    }
    if (mounted) {
      setState(() {
        _byokStore = store;
        _byokProfiles = profiles;
        _hasByokKey
          ..clear()
          ..addAll(withKey);
        _creatingByok = false;
        _editingByokId = null;
      });
    }
  }

  Future<void> _reload(CowOverridesStore store) async {
    final names = await store.overrideNames();
    final entries = <String, DateTime?>{};
    for (final n in names) {
      entries[n] = await store.overriddenAt(n);
    }
    if (mounted) {
      setState(() {
        _store = store;
        _entries = entries;
        _creating = false;
        _editingName = null;
      });
    }
  }

  Future<void> _save(String name, String content) async {
    final store = _store;
    if (store == null) return;
    final trimmed = content.trim();
    if (trimmed.isEmpty) {
      _flash('覆写正文不能为空');
      return;
    }
    if (trimmed.length > kCowOverrideMaxChars) {
      _flash('覆写正文超防呆上限（$kCowOverrideMaxChars 字符）');
      return;
    }
    await store.setOverride(name, trimmed);
    await _reload(store);
  }

  Future<void> _reset(String name) async {
    final store = _store;
    if (store == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重置覆写'),
        content: Text('弃用「$name」的本地覆写副本？下次模板同步将回 server 版。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('重置')),
        ],
      ),
    );
    if (confirmed != true) return;
    await store.reset(name);
    await _reload(store);
  }

  void _flash(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  @override
  Widget build(BuildContext context) {
    final t = consoleTokens(context);
    return Theme(
      data: ThemeData(
        useMaterial3: true,
        colorScheme: Theme.of(context).colorScheme,
        extensions: const [ConsoleTokens.fallback],
      ),
      child: Scaffold(
        appBar: AppBar(title: const Text('服务大厅')),
        body: _error != null
            ? Center(child: Text(_error!, style: TextStyle(color: t.danger)))
            : ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  _cowPanel(context, t),
                  const SizedBox(height: 12),
                  _byokPanel(context, t),
                  const SizedBox(height: 12),
                  _crossSourcePanel(context, t),
                  const SizedBox(height: 12),
                  _placeholderPanel(t),
                ],
              ),
      ),
    );
  }

  // —— 面板一：Skill 覆写管理（CoW） ——

  Widget _cowPanel(BuildContext context, ConsoleTokens t) {
    final store = _store;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Text('Skill 覆写管理',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              const Spacer(),
              Text('覆写 ${_entries.length} 项',
                  style: TextStyle(
                      fontFamily: t.monoFamily,
                      fontSize: 11.5,
                      color: t.terminalMuted)),
            ]),
            const SizedBox(height: 4),
            Text('官方模板（goodshare prompts）的本地覆写副本，优先级最高；'
                '模板大版本跃迁时同步流会弹卡让你选重置/保留。',
                style: TextStyle(fontSize: 11.5, color: Theme.of(context).hintColor)),
            const SizedBox(height: 8),
            if (store == null)
              const Padding(
                padding: EdgeInsets.all(8),
                // 静态文案不用 spinner：无限动画会让 pumpAndSettle 永不收口，
                // 且加载是瞬时路径（本地文件读），控制台风格无 spin 语义。
                child: Center(
                  child: Text('读取覆写库…',
                      style: TextStyle(fontSize: 12)),
                ),
              )
            else ...[
              for (final name in _entries.keys) _cowItem(context, t, name),
              if (_entries.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text('（暂无覆写——模板按 server 版生效）',
                      style: TextStyle(
                          fontSize: 12, color: Theme.of(context).hintColor)),
                ),
              if (_creating) _newEditor(context, t),
              if (!_creating)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    key: const Key('cow-new'),
                    onPressed: () => setState(() => _creating = true),
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('新建覆写'),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _cowItem(BuildContext context, ConsoleTokens t, String name) {
    final editing = _editingName == name;
    final at = _entries[name];
    return Container(
      key: Key('cow-item-$name'),
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(t.cardRadius),
        border: Border.all(color: t.hairline),
      ),
      child: editing
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    style: TextStyle(fontFamily: t.monoFamily, fontSize: 12)),
                const SizedBox(height: 6),
                TextField(
                  key: const Key('cow-edit-field'),
                  controller: _editCtrl,
                  maxLines: 6,
                  style: TextStyle(fontFamily: t.monoFamily, fontSize: 12),
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    isDense: true,
                    hintText: '覆写正文（markdown，与模板同构）',
                  ),
                ),
                const SizedBox(height: 6),
                Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  TextButton(
                    onPressed: () => setState(() => _editingName = null),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const Key('cow-save'),
                    onPressed: () => _save(name, _editCtrl.text),
                    child: const Text('保存'),
                  ),
                ]),
              ],
            )
          : Row(children: [
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name,
                          style:
                              TextStyle(fontFamily: t.monoFamily, fontSize: 12)),
                      if (at != null)
                        Text('覆写于 ${at.toIso8601String()}',
                            style: TextStyle(
                                fontSize: 11, color: t.terminalMuted)),
                    ]),
              ),
              IconButton(
                key: Key('cow-edit-$name'),
                tooltip: '编辑',
                iconSize: 18,
                onPressed: () {
                  _editingName = name;
                  _editCtrl.text = '';
                  _loadForEdit(name);
                },
                icon: const Icon(Icons.edit_outlined),
              ),
              IconButton(
                key: Key('cow-reset-$name'),
                tooltip: '一键重置',
                iconSize: 18,
                onPressed: () => _reset(name),
                icon: const Icon(Icons.restart_alt_outlined),
              ),
            ]),
    );
  }

  Future<void> _loadForEdit(String name) async {
    final content = await _store?.overrideOf(name);
    if (mounted) {
      setState(() {
        _editCtrl.text = content ?? '';
      });
    }
  }

  Widget _newEditor(BuildContext context, ConsoleTokens t) => Container(
        key: const Key('cow-new-editor'),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(t.cardRadius),
          border: Border.all(color: t.hairline),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(
            key: const Key('cow-new-name'),
            controller: _newNameCtrl,
            style: TextStyle(fontFamily: t.monoFamily, fontSize: 12),
            decoration: const InputDecoration(
              labelText: '模板名（prompts/list 的 name）',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 6),
          TextField(
            key: const Key('cow-new-content'),
            controller: _newContentCtrl,
            maxLines: 6,
            style: TextStyle(fontFamily: t.monoFamily, fontSize: 12),
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              isDense: true,
              hintText: '覆写正文（markdown，与模板同构）',
            ),
          ),
          const SizedBox(height: 6),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            TextButton(
              onPressed: () => setState(() => _creating = false),
              child: const Text('取消'),
            ),
            const SizedBox(width: 8),
            FilledButton(
              key: const Key('cow-create'),
              onPressed: () {
                final name = _newNameCtrl.text.trim();
                if (name.isEmpty) {
                  _flash('模板名不能为空');
                  return;
                }
                _save(name, _newContentCtrl.text);
              },
              child: const Text('创建'),
            ),
          ]),
        ]),
      );

  // —— 面板二：BYOK 云端引擎（M4-T5） ——

  /// 装配语义：hybrid_assembly 取列表首个 profile 为生效云端引擎——首位即
  /// 「生效中」，置顶动作即切换生效配置（不改装配线，零回归面）。
  Widget _byokPanel(BuildContext context, ConsoleTokens t) {
    final store = _byokStore;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Text('BYOK 云端引擎',
                  style:
                      const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              const Spacer(),
              Text('配置 ${_byokProfiles.length} 项',
                  style: TextStyle(
                      fontFamily: t.monoFamily,
                      fontSize: 11.5,
                      color: t.terminalMuted)),
            ]),
            const SizedBox(height: 4),
            Text('自带 API Key 接入云端模型（OpenAI 兼容 / Anthropic）。'
                '列表首位为生效配置，可用「置顶」切换。',
                style: TextStyle(
                    fontSize: 11.5, color: Theme.of(context).hintColor)),
            const SizedBox(height: 8),
            if (store == null)
              const Padding(
                padding: EdgeInsets.all(8),
                child: Center(
                  child: Text('读取模型配置…', style: TextStyle(fontSize: 12)),
                ),
              )
            else ...[
              for (final (i, p) in _byokProfiles.indexed)
                _byokItem(context, t, i, p),
              if (_byokProfiles.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text('（暂无模型配置——云端引擎未装配，仅端侧路径）',
                      style: TextStyle(
                          fontSize: 12, color: Theme.of(context).hintColor)),
                ),
              if (_creatingByok) _byokEditor(context, t, null),
              if (!_creatingByok)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    key: const Key('byok-new'),
                    onPressed: () => setState(() => _creatingByok = true),
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

  Widget _byokItem(BuildContext context, ConsoleTokens t, int index, ByokProfile p) {
    final editing = _editingByokId == p.id;
    final hasKey = _hasByokKey.contains(p.id);
    return Container(
      key: Key('byok-item-${p.id}'),
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(t.cardRadius),
        border: Border.all(
            color: index == 0 ? t.l2Warn : t.hairline,
            width: index == 0 ? 1.2 : 1),
      ),
      child: editing
          ? _byokEditor(context, t, p)
          : Row(children: [
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Flexible(
                          child: Text(p.name,
                              style: TextStyle(
                                  fontFamily: t.monoFamily, fontSize: 12),
                              overflow: TextOverflow.ellipsis),
                        ),
                        if (index == 0) ...[
                          const SizedBox(width: 6),
                          Text('生效中',
                              style: TextStyle(
                                  fontSize: 10.5,
                                  color: t.l2Warn,
                                  fontWeight: FontWeight.w600)),
                        ],
                      ]),
                      Text(
                        '${_protoLabel(p.protocol)} · ${p.model}\n'
                        '${p.baseUrl}${hasKey ? ' · 已存密钥' : ' · ⚠ 未存密钥'}',
                        style: TextStyle(
                            fontFamily: t.monoFamily,
                            fontSize: 11,
                            color: t.terminalMuted),
                      ),
                    ]),
              ),
              if (index > 0)
                IconButton(
                  key: Key('byok-top-${p.id}'),
                  tooltip: '置顶启用',
                  iconSize: 18,
                  onPressed: () => _byokMoveTop(p),
                  icon: const Icon(Icons.vertical_align_top_outlined),
                ),
              IconButton(
                key: Key('byok-edit-${p.id}'),
                tooltip: '编辑',
                iconSize: 18,
                onPressed: () => setState(() {
                  _editingByokId = p.id;
                  _byokNameCtrl.text = p.name;
                  _byokProto = p.protocol;
                  _byokUrlCtrl.text = p.baseUrl;
                  _byokModelCtrl.text = p.model;
                  _byokTempCtrl.text = p.temperature?.toString() ?? '';
                  _byokKeyCtrl.clear();
                }),
                icon: const Icon(Icons.edit_outlined),
              ),
              IconButton(
                key: Key('byok-del-${p.id}'),
                tooltip: '删除',
                iconSize: 18,
                onPressed: () => _deleteByok(p),
                icon: const Icon(Icons.delete_outline),
              ),
            ]),
    );
  }

  /// 新增（profile == null）与编辑共用表单；编辑模式密钥留空 = 保持已存密钥。
  Widget _byokEditor(BuildContext context, ConsoleTokens t, ByokProfile? profile) {
    final isEdit = profile != null;
    return Container(
      key: Key(isEdit ? 'byok-edit-form' : 'byok-new-form'),
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(t.cardRadius),
        border: Border.all(color: t.hairline),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        TextField(
          key: const Key('byok-field-name'),
          controller: _byokNameCtrl,
          style: TextStyle(fontFamily: t.monoFamily, fontSize: 12),
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
                value: CloudProtocol.openaiCompatible, label: Text('OpenAI 兼容')),
            ButtonSegment(value: CloudProtocol.anthropic, label: Text('Anthropic')),
          ],
          selected: {_byokProto},
          onSelectionChanged: (s) => setState(() => _byokProto = s.first),
        ),
        const SizedBox(height: 6),
        TextField(
          key: const Key('byok-field-url'),
          controller: _byokUrlCtrl,
          style: TextStyle(fontFamily: t.monoFamily, fontSize: 12),
          decoration: const InputDecoration(
            labelText: 'Base URL',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          key: const Key('byok-field-model'),
          controller: _byokModelCtrl,
          style: TextStyle(fontFamily: t.monoFamily, fontSize: 12),
          decoration: const InputDecoration(
            labelText: '模型 ID（如 deepseek-chat / claude-sonnet-4-5）',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          key: const Key('byok-field-temp'),
          controller: _byokTempCtrl,
          style: TextStyle(fontFamily: t.monoFamily, fontSize: 12),
          keyboardType:
              const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            labelText: 'Temperature（可空）',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          key: const Key('byok-field-key'),
          controller: _byokKeyCtrl,
          obscureText: true,
          style: TextStyle(fontFamily: t.monoFamily, fontSize: 12),
          decoration: InputDecoration(
            labelText: isEdit ? 'API Key（留空 = 保持已存密钥）' : 'API Key',
            border: const OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 6),
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          TextButton(
            onPressed: () => setState(() {
              if (isEdit) {
                _editingByokId = null;
              } else {
                _creatingByok = false;
              }
            }),
            child: const Text('取消'),
          ),
          const SizedBox(width: 8),
          FilledButton(
            key: Key(isEdit ? 'byok-save' : 'byok-create'),
            onPressed: () => isEdit ? _saveByokEdit(profile) : _createByok(),
            child: Text(isEdit ? '保存' : '创建'),
          ),
        ]),
      ]),
    );
  }

  String _protoLabel(CloudProtocol p) => switch (p) {
        CloudProtocol.openaiCompatible => 'OpenAI 兼容',
        CloudProtocol.anthropic => 'Anthropic',
      };

  /// 表单 → profile 校验（name/baseUrl/model 必填；temperature 容错解析）。
  /// 返回 null = 校验失败（已 flash 提示）。
  ByokProfile? _collectForm(String id) {
    final name = _byokNameCtrl.text.trim();
    final url = _byokUrlCtrl.text.trim();
    final model = _byokModelCtrl.text.trim();
    final tempText = _byokTempCtrl.text.trim();
    if (name.isEmpty || url.isEmpty || model.isEmpty) {
      _flash('显示名 / Base URL / 模型 ID 均必填');
      return null;
    }
    double? temp;
    if (tempText.isNotEmpty) {
      temp = double.tryParse(tempText);
      if (temp == null) {
        _flash('Temperature 须为数字（如 0.2）');
        return null;
      }
    }
    return ByokProfile(
      id: id,
      name: name,
      protocol: _byokProto,
      baseUrl: url,
      model: model,
      temperature: temp,
    );
  }

  Future<void> _createByok() async {
    final store = _byokStore;
    if (store == null) return;
    final key = _byokKeyCtrl.text.trim();
    if (key.isEmpty) {
      _flash('API Key 必填（走安全存储，不落明文）');
      return;
    }
    var id = 'byok_${DateTime.now().millisecondsSinceEpoch}';
    while (_byokProfiles.any((p) => p.id == id)) {
      id = 'byok_${DateTime.now().microsecondsSinceEpoch}';
    }
    final profile = _collectForm(id);
    if (profile == null) return;
    await store.save([..._byokProfiles, profile]);
    await store.setApiKey(id, key);
    await _reloadByok(store);
    _flash('✓ 已添加 ${profile.name}');
  }

  Future<void> _saveByokEdit(ByokProfile old) async {
    final store = _byokStore;
    if (store == null) return;
    final profile = _collectForm(old.id);
    if (profile == null) return;
    final key = _byokKeyCtrl.text.trim();
    await store.save([
      for (final p in _byokProfiles) if (p.id == old.id) profile else p,
    ]);
    if (key.isNotEmpty) await store.setApiKey(old.id, key);
    await _reloadByok(store);
    _flash('✓ 已更新 ${profile.name}');
  }

  Future<void> _byokMoveTop(ByokProfile p) async {
    final store = _byokStore;
    if (store == null) return;
    await store.save([p, ..._byokProfiles.where((e) => e.id != p.id)]);
    await _reloadByok(store);
    _flash('✓ 已切换生效引擎：${p.name}');
  }

  Future<void> _deleteByok(ByokProfile p) async {
    final store = _byokStore;
    if (store == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除模型配置'),
        content: Text('删除「${p.name}」（${p.model}）？其已存密钥将一并清除。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
        ],
      ),
    );
    if (confirmed != true) return;
    // save 自带孤儿密钥连带清理（被移除 profile 的密钥删除）。
    await store.save(_byokProfiles.where((e) => e.id != p.id).toList());
    await _reloadByok(store);
    _flash('✓ 已删除 ${p.name}');
  }

  // —— 面板三：跨源授权语义（D5） ——

  Widget _crossSourcePanel(BuildContext context, ConsoleTokens t) => Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('跨源授权（\$ref 联合授权）',
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text('A 应用的工具输出经 \$ref 句柄传给 B 应用工具时，宿主弹卡确认后'
                '才注水放行——句柄是模型侧行话，真实数据永不出网关。',
                style: TextStyle(fontSize: 11.5, color: Theme.of(context).hintColor)),
            const SizedBox(height: 8),
            _policyRow(context, Icons.gavel_outlined, '恒 L2 弹卡确认',
                '每次跨源都需确认——会话豁免不适用（豁免按工具粒度防不住数据面风险）'),
            _policyRow(context, Icons.visibility_off_outlined, '禁盲签',
                '数据摘要不可读即拒；摘要封顶 300 字符（标题+前 5 行）'),
            _policyRow(context, Icons.lock_outline, '不记忆不豁免',
                '与隐私围栏同口径：显式确认不落盘、不旁路 N7 出站围栏'),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton.icon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                      builder: (_) => const GatewayLoopDebugPage()),
                ),
                icon: const Icon(Icons.science_outlined, size: 16),
                label: const Text('去联调页实测'),
              ),
            ),
          ]),
        ),
      );

  Widget _policyRow(BuildContext context, IconData icon, String title, String desc) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 15, color: consoleTokens(context).l2Warn),
          const SizedBox(width: 8),
          Expanded(
            child: Text.rich(
              TextSpan(children: [
                TextSpan(text: '$title：', style: const TextStyle(fontSize: 12)),
                TextSpan(
                    text: desc,
                    style: TextStyle(
                        fontSize: 12, color: Theme.of(context).hintColor)),
              ]),
            ),
          ),
        ]),
      );

  // —— 导航位（M3+ 范围外） ——

  Widget _placeholderPanel(ConsoleTokens t) => Card(
        margin: EdgeInsets.zero,
        child: Column(children: [
          ListTile(
            enabled: false,
            dense: true,
            leading: Icon(Icons.dns_outlined, size: 18, color: t.terminalMuted),
            title: Text('Server 节点管理',
                style: TextStyle(fontSize: 13, color: t.terminalMuted)),
            subtitle: Text('端口/延迟/在线状态/挂载开关（M3+）',
                style: TextStyle(fontSize: 11, color: t.terminalMuted)),
          ),
          ListTile(
            enabled: false,
            dense: true,
            leading: Icon(Icons.dns_outlined, size: 18, color: t.terminalMuted),
            title: Text('Server 节点管理',
                style: TextStyle(fontSize: 13, color: t.terminalMuted)),
            subtitle: Text('端口/延迟/在线状态/挂载开关（M3+）',
                style: TextStyle(fontSize: 11, color: t.terminalMuted)),
          ),
        ]),
      );
}
