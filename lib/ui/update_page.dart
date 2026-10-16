import 'dart:io';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../update/installer.dart';
import '../update/update_manifest.dart';
import '../update/update_service.dart';
import 'tokens/console_tokens.dart';

/// 更新页（self-update epic）：应用内自更新入口——检查清单 → 下载（sha256 校验）→ 拉起安装器。
class UpdatePage extends StatefulWidget {
  const UpdatePage({super.key});

  @override
  State<UpdatePage> createState() => _UpdatePageState();
}

enum _Phase { idle, checking, downloading, readyToInstall }

/// 页面消息语气（ux-hardening P0-3 视觉分权）：成功/失败/提示不再共用灰字。
enum _MsgTone { info, success, warn, error }

class _UpdatePageState extends State<UpdatePage> {
  late UpdateService _service;
  final _urlCtrl = TextEditingController();
  _Phase _phase = _Phase.idle;
  String? _message;
  _MsgTone _messageTone = _MsgTone.info;
  UpdateManifest? _manifest;
  File? _apk;
  int _received = 0;
  int? _total;
  PackageInfo? _info;
  bool _ready = false;
  // 初始化失败可见 + 可重试（替代 _bootstrap 无 try/catch 时按钮永久灰死
  // 无报错；_service 非 final——重试可重新装配）。
  String? _bootstrapError;
  // 下载取消标志（downloadApk 每 chunk 轮询；取消≠失败，中性呈现）。
  bool _downloadCancelled = false;

  void _say(String msg, _MsgTone tone) {
    if (!mounted) return;
    setState(() {
      _message = msg;
      _messageTone = tone;
    });
  }

  Color _msgColor(ConsoleTokens t) => switch (_messageTone) {
    _MsgTone.info => t.terminalMuted,
    _MsgTone.success => t.l1Ok,
    _MsgTone.warn => t.l2Warn,
    _MsgTone.error => t.danger,
  };

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    setState(() => _bootstrapError = null);
    try {
      final info = await PackageInfo.fromPlatform();
      final prefs = await SharedPreferences.getInstance();
      _service = UpdateService(prefs);
      final url = await _service.sourceUrl();
      _urlCtrl.text = url ?? '';
      if (!mounted) return;
      setState(() {
        _info = info;
        _ready = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _bootstrapError = '更新页初始化失败：$e');
    }
  }

  Future<void> _saveSource() async {
    try {
      await _service.setSourceUrl(_urlCtrl.text);
      _say('更新源已保存', _MsgTone.success);
    } on UpdateException catch (e) {
      _say('更新源保存失败：${e.message}', _MsgTone.error);
    }
  }

  Future<void> _check() async {
    setState(() {
      _phase = _Phase.checking;
      _message = null;
      _apk = null;
    });
    try {
      final manifest = await _service.check();
      final current = int.tryParse(_info?.buildNumber ?? '') ?? 0;
      final newer = manifest.isNewerThan(current);
      if (!mounted) return;
      setState(() {
        _manifest = manifest;
        _phase = _Phase.idle;
      });
      _say(
        newer
            ? '发现新版本 v${manifest.versionName}（${manifest.changelog ?? '无更新说明'}）'
            : '已是最新版本（远程 v${manifest.versionName}）',
        newer ? _MsgTone.success : _MsgTone.info,
      );
    } on UpdateException catch (e) {
      if (!mounted) return;
      setState(() => _phase = _Phase.idle);
      _say('检查更新失败：${e.message}', _MsgTone.error);
    }
  }

  Future<void> _download() async {
    final manifest = _manifest;
    if (manifest == null) return;
    setState(() {
      _phase = _Phase.downloading;
      _received = 0;
      _total = null;
      _message = null;
      _downloadCancelled = false;
    });
    try {
      final apk = await _service.downloadApk(
        manifest.apkUrl,
        expectedSha256: manifest.sha256,
        onProgress: (received, total) => mounted
            ? setState(() {
                _received = received;
                _total = total;
              })
            : null,
        isCancelled: () => _downloadCancelled,
      );
      if (!mounted) return;
      setState(() {
        _apk = apk;
        _phase = _Phase.readyToInstall;
      });
      _say('下载完成并已通过完整性校验，点击安装', _MsgTone.success);
    } on UpdateCancelled {
      if (!mounted) return;
      setState(() => _phase = _Phase.idle);
      _say('下载已取消', _MsgTone.info);
    } on UpdateException catch (e) {
      if (!mounted) return;
      setState(() => _phase = _Phase.idle);
      _say('下载失败：${e.message}', _MsgTone.error);
    }
  }

  Future<void> _install() async {
    final apk = _apk;
    final manifest = _manifest;
    if (apk == null || manifest == null) return;
    // 纵深防御：安装前再比对一次清单包名与本机包名，不一致直接拒装。
    // 正常流程在 check() 已拦截，此处防将来新增入口绕过检查直接安装。
    final currentId = _info?.packageName;
    if (manifest.applicationId != null &&
        currentId != null &&
        manifest.applicationId != currentId) {
      _say(
        '更新包身份不符（疑似串包，已拒绝安装）：清单=${manifest.applicationId} 本机=$currentId',
        _MsgTone.error,
      );
      return;
    }
    // ux-hardening P0-3：安装是准破坏性操作（替换当前版本）——先确认，
    // 明示版本跃迁与重启后果。
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('安装更新'),
        content: Text(
          '将安装 v${manifest.versionName}（build ${manifest.versionCode}）替换当前版本，'
          '安装后应用会重启。安装包已通过 SHA-256 完整性校验。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('安装'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await installApk(apk.path);
    } catch (e) {
      _say('$e（首次安装需在系统弹窗中允许「安装未知应用」）', _MsgTone.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    final manifest = _manifest;
    final t = Theme.of(context).extension<ConsoleTokens>() ?? ConsoleTokens.fallback;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: '关闭',
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('更新'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('当前版本', style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 4),
                  Text(
                    info == null ? '读取中…' : 'v${info.version}（build ${info.buildNumber}）',
                    style: TextStyle(fontFamily: t.monoFamily, fontSize: Fsz.telemetry),
                  ),
                  const SizedBox(height: 12),
                  Text('远程更新', style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 4),
                  if (manifest != null)
                    Text(
                      '远程版本 v${manifest.versionName}（build ${manifest.versionCode}）',
                      style: TextStyle(fontFamily: t.monoFamily, fontSize: Fsz.telemetry),
                    ),
                  // 初始化失败态（ux-hardening P0-3）：Rose 文案 + 重试——
                  // 历史病：_bootstrap 无 try/catch，失败后 _ready 永假、
                  // 按钮全灰且无任何报错。
                  if (_bootstrapError != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '⚠ $_bootstrapError',
                            style: TextStyle(
                              fontSize: Fsz.note,
                              color: t.danger,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton.icon(
                              onPressed: _bootstrap,
                              icon: const Icon(Icons.refresh, size: 16),
                              label: const Text('重试'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (_message != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        _message!,
                        style: TextStyle(
                          fontSize: Fsz.note,
                          color: _msgColor(t),
                        ),
                      ),
                    ),
                  if (_phase == _Phase.downloading)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: LinearProgressIndicator(
                        value: _total != null && _total! > 0 ? _received / _total! : null,
                      ),
                    ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: _ready && _phase == _Phase.idle ? _check : null,
                        icon: const Icon(Icons.cloud_download_outlined),
                        label: const Text('检查更新'),
                      ),
                      if (_manifest != null &&
                          _manifest!.isNewerThan(int.tryParse(_info?.buildNumber ?? '') ?? 0))
                        FilledButton.tonalIcon(
                          onPressed:
                              _phase == _Phase.idle || _phase == _Phase.checking ? _download : null,
                          icon: const Icon(Icons.download_outlined),
                          label: Text(_phase == _Phase.downloading ? '下载中…' : '下载安装包'),
                        ),
                      // 下载中可取消（ux-hardening P0-3）：标志位由 downloadApk
                      // 每 chunk 轮询生效；连接 stall 时等下一个 chunk。
                      if (_phase == _Phase.downloading)
                        OutlinedButton.icon(
                          onPressed: () =>
                              setState(() => _downloadCancelled = true),
                          icon: const Icon(Icons.close),
                          label: const Text('取消下载'),
                        ),
                      if (_phase == _Phase.readyToInstall)
                        FilledButton.icon(
                          onPressed: _install,
                          icon: const Icon(Icons.system_update_alt),
                          label: const Text('安装'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('更新源', style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 4),
                  Text(
                    '默认更新源已内置（构建时注入），装上即可「检查更新」；'
                    '如需更换为其他静态托管，可在此修改后点「保存更新源」。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _urlCtrl,
                    style: TextStyle(fontFamily: t.monoFamily, fontSize: Fsz.telemetry),
                    decoration: const InputDecoration(
                      hintText: 'https://<host>/updates',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _ready ? _saveSource : null,
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('保存更新源'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
