import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';

import 'dart:isolate';
// 归档件（2026-10-15，SA-Q3）：路径已改为跨目录引用 lib/，复活时改回同级
// `import 'llm.dart';` / `import 'llm_model.dart';` 即可（其余两件为同级）。
import '../../lib/llm/llm.dart';
import 'llm_download_isolate.dart';
import '../../lib/llm/llm_model.dart';
import 'remote_config_store.dart';

/// 端侧 LLM 模型包下载管理（M2 自 goodshare 随迁，2026-10-10）：与原 ASR
/// `ModelManager` 同构——单文件 `.litertlm`（自带 tokenizer），支持断点续传
/// （`.part` 留痕 + `Range` 头续拉，落盘按 manifest `sizeBytes` 校验防翻倍/截断）。
///
/// 落盘约定与 Android `LlmBridge.selectedModelFile` 对齐：
/// `documents/llm_models/{modelId}/model.litertlm`；选中档持久化 pref
/// `llm_selected_model`（Flutter 与原生各自读 SharedPreferences，键一致即通）。
/// 本地模型文件的版本比对结论。
enum _DiskState {
  absent, // 无文件
  ready, // 与 manifest 同版本（或存量无 meta，兼容放行）
  stale, // 有文件但 size 与 manifest 不一致（同 id 换了文件/量化）
}

/// 内置默认 manifest 地址（随迁宿主仓，2026-10-10；GitHub raw 代理镜像，国内可达；
/// 直连 raw.githubusercontent.com 实测超时）。清单内容=仓库 `updates/llm-manifest.json`。
/// 更换地址无需发版：remote_config flags 的 `llmManifestUrl` 覆盖本默认值。
const String defaultLlmManifestUrl =
    'https://gh.927223.xyz/https://raw.githubusercontent.com/loveheng/goodhub/refs/heads/main/updates/llm-manifest.json';

class LlmModelManager extends ChangeNotifier {
  static const _prefSelected = 'llm_selected_model';

  /// 选择语义（goodshare 2026-09-29「名字坐标」拍板，随迁沿用）：
  /// - 显式选过：选中状态持久 **id+name**，目录更新后按 id→名字对位跟随同名模型
  ///   （id 换了也能跟住；同 id 换文件走 stale 提示，两条路径互不干扰）；
  /// - 从未显式选过：**自动跟随目录首条（发布者排序即最新记录）**，并同步原生 pref。
  /// 用户从不直接感知 id——名字才是用户与云端之间的坐标。
  static const _prefSelectedName = 'llm_selected_model_name';
  static const _prefExplicit = 'llm_selected_explicit';

  LlmModelManager({this._manifestUrl});

  /// manifest 地址取值器（null/空 = 不拉远端，恒用内置目录）。
  /// 接线：RemoteConfigStore.flags['llmManifestUrl']（检查更新后热更下发）。
  final String? Function()? _manifestUrl;

  final Dio _dio = Dio(BaseOptions(
    followRedirects: true,
    connectTimeout: const Duration(seconds: 30),
    receiveTimeout: const Duration(minutes: 30),
  ));

  String? _selectedId;
  bool _explicit = false; // 用户是否显式选过模型（false = 跟随目录首条 = 最新记录）
  final Set<String> _ready = {};
  final Set<String> _stale = {};
  final Map<String, double> _progress = {};
  SendPort? _isoSend; // 下载 worker isolate 的 SendPort（懒启动）
  Completer<SendPort>? _isoHandshake; // isolate 启动握手（首个 SendPort 消息）
  StreamSubscription<dynamic>? _isoSub; // 常驻唯一 listener（ReceivePort 不可重复 listen）
  StreamSubscription<dynamic>? _isoExitSub; // isolate 死亡监听（扇出+复位，防任务悬挂）
  final Map<String, _DlTask> _dlTasks = {}; // 进行中任务 id → 完成器+上下文
  static const MethodChannel _chan = MethodChannel('goodhub/llm'); // 与原生 LlmBridge 同通道，publish 模型绝对路径
  final Set<String> _paused = {}; // 用户主动暂停（.part 保留，可续传）

  /// 当前生效目录：远端 manifest（last-good 缓存）> 内置默认。
  /// 本地缓存文件不存在时为 null，`catalog` 落回 [llmModels]。
  List<LlmModel> _catalog = llmModels;

  /// 本机残留条目（manifest 已移除、设备上仍有已下载文件）——叠加展示拍板
  /// （goodshare 2026-09-29）：新模型与本机已下载模型同列表呈现，孤儿照常可用不隐藏。
  List<LlmModel> _orphans = const [];

  /// 当前生效的模型目录（设置页渲染与可见性过滤的数据源）＝ manifest 目录 + 本机残留。
  List<LlmModel> get catalog => [..._catalog, ..._orphans];

  /// 当前选中 id：显式选过用 [_selectedId]；未显式选过时**优先已下载模型**
  /// （照着真实可用走），其次目录首条（最新记录）。与 LlmBridge 回退扫描语义对齐，
  /// 避免「自动跟首条却没下载 → 原生找不到文件 → 引擎不可用」的静默失败。
  String get selectedId {
    if (_selectedId != null) return _selectedId!;
    final downloaded = _catalog.where((m) => _ready.contains(m.id)).toList();
    return (downloaded.isNotEmpty ? downloaded.first : _catalog.first).id;
  }

  LlmModel? get selected => modelById(selectedId);

  bool isReady(LlmModel m) => _ready.contains(m.id);

  /// 已下载但与当前 manifest 不同版本（同 id 换文件/换量化）——**仅信息性提示**
  /// （goodshare 2026-09-29 用户拍板：旧模型用得好好的不能不让用）：就绪判定不受影响，
  /// 设置页显示「云端有新版本可更新」，更新与否由用户自选。
  bool isStale(LlmModel m) => _stale.contains(m.id);

  double? progressOf(LlmModel m) => _progress[m.id];

  /// 用户是否已暂停该模型下载（`.part` 仍在，可继续）。
  bool isPaused(LlmModel m) => _paused.contains(m.id);

  /// 本机可见模型（SoC 感知：NPU 专包仅对应机型可见，通用包恒可见；残留条目恒可见）。
  Future<List<LlmModel>> visibleModels() async {
    final soc = await deviceSocModel();
    return [
      for (final m in catalog)
        if (m.localOnly || llmModelVisibleOnDevice(m, soc)) m
    ];
  }

  /// 设备 SoC 型号（Android 原生回传；非 Android / 失败为 null）。
  Future<String?> deviceSocModel() => ChannelLlmEngine().socModel();

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _explicit = prefs.getBool(_prefExplicit) ?? false;
    await _loadCachedCatalog();
    await _syncOrphans();
    await _realignSelection(prefs);
    // 必须 await（goodshare 2026-10-10 真机排障）：_diskState 是真异步，不等待则
    // _ready 尚为空，下面的 publish 会以 ready=false 提前退出——原生收不到
    // 模型路径，重启 app 后摘要全部误报「未下载模型包」。
    await _syncReadyFlags();
    notifyListeners();
    unawaited(_publishReadyIfAny()); // 把已就绪模型路径告知原生（路径对齐）
    // 远端刷新异步跑：失败静默留 last-good，不打断首帧
    unawaited(refreshCatalog());
  }

  /// 名字坐标对位：id 精确命中 → 名字命中（manifest 改 id 时的迁移路径）。
  LlmModel? _byName(String? name) {
    if (name == null || name.isEmpty) return null;
    for (final m in catalog) {
      if (m.name == name) return m;
    }
    return null;
  }

  /// 选择重对齐（load / refreshCatalog 后调用）——「名字坐标」语义：
  /// - 显式选过：id 精确 → 名字对位 → 兜底目录首条；
  /// - 未显式选过：**自动跟随目录首条（最新记录）**，与旧目录同名档自然解绑。
  /// 两条路径都持久化 id+name，保证原生桥（读 flutter.llm_selected_model）与 Dart 同步。
  Future<void> _realignSelection(SharedPreferences prefs) async {
    LlmModel? m;
    if (_explicit) {
      m = modelById(prefs.getString(_prefSelected)) ??
          _byName(prefs.getString(_prefSelectedName));
    }
    m ??= _catalog.first;
    await _persistSelection(prefs, m);
  }

  Future<void> _persistSelection(SharedPreferences prefs, LlmModel m) async {
    _selectedId = m.id;
    await prefs.setString(_prefSelected, m.id);
    await prefs.setString(_prefSelectedName, m.name);
  }

  /// 扫盘合成残留条目（叠加展示拍板）：documents/llm_models/ 下有 model.litertlm
  /// 但不在当前目录的 id → 合成 [LlmModel.localOnly] 条目，与目录条目同列表呈现，
  /// 照常可用（旧文件引擎照跑），仅提示「云端已移除」；用户可手动删除腾空间。
  Future<void> _syncOrphans() async {
    try {
      final base = await getApplicationDocumentsDirectory();
      final root = Directory(p.join(base.path, 'llm_models'));
      if (!await root.exists()) {
        _orphans = const [];
        return;
      }
      final known = _catalog.map((m) => m.id).toSet();
      final found = <LlmModel>[];
      await for (final d in root.list()) {
        if (d is! Directory) continue;
        final id = p.basename(d.path);
        if (known.contains(id)) continue;
        final f = File(p.join(d.path, 'model.litertlm'));
        if (!await f.exists() || await f.length() <= 0) continue;
        found.add(LlmModel(
          id: id,
          name: id,
          desc: '云端目录已移除，本机保留可继续使用',
          file: 'model.litertlm',
          sizeBytes: await f.length(),
          localOnly: true,
        ));
      }
      _orphans = found;
    } catch (e) {
      // DEGRADE: 扫盘失败只影响叠加展示，不影响目录与下载；留日志不中断。
      debugPrint('[LlmModelManager] syncOrphans failed: $e');
    }
  }

  /// last-good 目录缓存：`documents/llm_manifest.json`。
  /// 损坏/缺失时保持内置目录（远端配置是外部输入，不能让它毁掉本地状态）。
  Future<void> _loadCachedCatalog() async {
    try {
      final f = await _cacheManifestFile();
      if (!await f.exists()) return;
      final parsed = llmModelsFromJson(jsonDecode(await f.readAsString()));
      if (parsed.isNotEmpty) _catalog = parsed;
    } catch (_) {
      // 缓存损坏 → 落回内置目录，等下次 refreshCatalog 覆盖
    }
  }

  Future<File> _cacheManifestFile() async {
    final base = await getApplicationDocumentsDirectory();
    return File(p.join(base.path, 'llm_manifest.json'));
  }

  /// 拉取远端 manifest 并替换目录（成功才写 last-good，全失败保持现状）。
  ///
  /// URL 优先级：构造参数 > RemoteConfigStore.flags['llmManifestUrl'] > 内置默认
  /// [defaultLlmManifestUrl]（随迁时嵌入，开箱即热更，无需先配 remote_config）。
  /// 供「检查更新成功后」与设置页下拉刷新调用；返回是否替换成功。
  Future<bool> refreshCatalog() async {
    final viaFlags =
        RemoteConfigStore.instance.current.flags['llmManifestUrl'] as String?;
    final url = _manifestUrl?.call() ??
        (viaFlags != null && viaFlags.isNotEmpty ? viaFlags : defaultLlmManifestUrl);
    try {
      final res = await _dio.get<String>(url);
      final parsed = llmModelsFromJson(
        jsonDecode(res.data ?? '') as Object?,
      );
      // 空目录视为无效 manifest：可能是 CDN 半程/被劫持，绝不覆盖可用目录
      if (parsed.isEmpty) return false;
      _catalog = parsed;
      // 目录替换后重扫：被移除的条目转为「本机保留」，新条目不再算孤儿
      await _syncOrphans();
      final f = await _cacheManifestFile();
      await f.writeAsString(res.data ?? '', flush: true);
      // 目录可能已变：就绪标记与选中项都要对新目录重对齐（名字坐标语义：
      // 显式选过按 id→名对位跟随，未选过自动跟随新目录首条=最新记录）
      _syncReadyFlags();
      final prefs = await SharedPreferences.getInstance();
      await _realignSelection(prefs);
      notifyListeners();
      return true;
    } catch (e) {
      // DEGRADE: 拉取失败静默留 last-good（内置兜底），不打断用户；至少留日志。
      debugPrint('[LlmModelManager] refreshCatalog failed: $e');
      return false;
    }
  }

  /// 按 id 在**合并目录**（manifest + 本机残留）里找模型——叠加展示拍板：
  /// 残留条目照常可用，选中/下载/删除与目录条目同一套逻辑。
  LlmModel? modelById(String? id) {
    if (id == null) return null;
    for (final m in catalog) {
      if (m.id == id) return m;
    }
    return null;
  }

  /// 就绪探测按当前目录重跑（manifest 替换后旧标记可能失效）。
  /// **文件存在即可用**（goodshare 2026-09-29 用户拍板：旧模型照常跑，云端更新不强禁）；
  /// stale 只作「云端有新版本」的提示标记，绝不阻塞就绪。
  Future<void> _syncReadyFlags() async {
    final ready = <String>{};
    final stale = <String>{};
    for (final m in _catalog) {
      final state = await _diskState(m);
      if (state == _DiskState.absent) continue;
      ready.add(m.id);
      if (state == _DiskState.stale) stale.add(m.id);
    }
    _ready
      ..clear()
      ..addAll(ready);
    _stale
      ..clear()
      ..addAll(stale);
    // 残留条目（扫盘时已确认文件存在）直接就绪：叠加展示拍板——照常可用
    _ready.addAll(_orphans.map((m) => m.id));
  }

  /// 本地文件与 manifest 条目的版本比对。
  ///
  /// 下载完成时落 `meta.json`（file/size/url 快照）；比对规则：
  /// - meta 存在 → 严格比对 size（manifest 换文件/换量化必改 size，改了即 stale）；
  /// - meta 缺失 → 旧版本 app 下载的存量，按 ready 处理；
  /// - stale **仅提示不阻塞**——旧文件对推理引擎完全可用，更新与否用户自选。
  Future<_DiskState> _diskState(LlmModel m) async {
    final f = await _fileFor(m);
    if (!await f.exists() || await f.length() <= 0) return _DiskState.absent;
    final meta = File(p.join(f.parent.path, 'meta.json'));
    if (!await meta.exists()) return _DiskState.ready; // 存量兼容
    try {
      final j = jsonDecode(await meta.readAsString()) as Map;
      return j['size'] == m.sizeBytes ? _DiskState.ready : _DiskState.stale;
    } catch (_) {
      // meta 损坏不阻塞（文件本身可用），按就绪处理
      return _DiskState.ready;
    }
  }

  Future<File> _fileFor(LlmModel m) async {
    final base = await getApplicationDocumentsDirectory();
    return File(p.join(base.path, 'llm_models', m.id, 'model.litertlm'));
  }

  Future<void> select(String id) async {
    final m = modelById(id);
    if (m == null) return;
    _explicit = true; // 显式选择后即脱离「自动跟随最新」，改按名字坐标跟随
    final prefs = await SharedPreferences.getInstance();
    await _persistSelection(prefs, m);
    await prefs.setBool(_prefExplicit, true);
    notifyListeners();
    if (isReady(m)) await _publish(m); // 选中且已就绪则立即告知原生路径
  }

  /// 进行中的下载任务上下文见文件末尾顶层类 [_DlTask]。

  /// 启动常驻下载 worker isolate（懒加载）；main 侧只收发消息，不碰字节 I/O。
  ///
  /// **单 listener 原则**：ReceivePort 是单订阅流，`.first` 消费握手消息会取消订阅
  /// 并使端口死亡，随后 `listen` 丢失所有回传（progress/done 永不到达 → 永不 finalize
  /// → 文件停在 `.part` → 原生扫不到模型 →「引擎不可用」）。这里用一个常驻
  /// subscription 分流：首个 SendPort 消息完成握手，其余交给 [_onIsoMessage]。
  Future<void> _ensureIsolate() async {
    if (_isoSend != null) return;
    if (_isoSub != null) {
      // 上一次启动仍在握手期（并发下载首调）：等握手完成即可
      await _isoHandshake?.future;
      return;
    }
    final recv = ReceivePort();
    final exitPort = ReceivePort();
    _isoHandshake = Completer<SendPort>();
    _isoSub = recv.listen((msg) {
      if (msg is SendPort) {
        _isoSend = msg;
        _isoHandshake?.complete(msg);
        return;
      }
      _onIsoMessage(msg);
    }, onError: (Object e) {
      // isolate 崩溃不能静默：把错误扇出给所有在等任务，否则 UI 永远转圈
      _fanOutIsoFailure(Exception('下载线程异常：$e'));
    }, cancelOnError: true);
    // isolate 死亡（未捕获异常/被杀）只触发 onExit、不走 onError——没有这路扇出，
    // 在等任务的 completer 永远挂起，进度条冻死、下载按钮消失
    _isoExitSub = exitPort.listen((_) {
      _fanOutIsoFailure(Exception('下载线程已退出'));
      exitPort.close();
    });
    try {
      await Isolate.spawn(downloaderEntry, recv.sendPort, onExit: exitPort.sendPort);
      await _isoHandshake!.future;
    } on Object {
      // spawn 失败 / 握手失败都必须全量复位：否则 _isoSub 残留，下一次 download
      // 走「等握手」分支但握手永远完不成 → 永挂（冻死变体）
      _fanOutIsoFailure(Exception('下载线程启动失败'));
      rethrow;
    }
  }

  /// isolate 失败统一处置：错误扇出给所有在等任务 + 全量复位（下次 download 自动重启线程）。
  void _fanOutIsoFailure(Exception e) {
    for (final t in _dlTasks.values) {
      if (!t.completer.isCompleted) t.completer.completeError(e);
    }
    _dlTasks.clear();
    // 握手可能仍有等待者（isolate 早死、SendPort 未送达）：必须 completeError 解除，
    // 否则 await _ensureIsolate 永挂。先挂兜底 listener 防无等待时的未处理异常。
    final h = _isoHandshake;
    if (h != null && !h.isCompleted) {
      unawaited(h.future.then<void>(
        (_) {},
        onError: (Object err, StackTrace st) {}, // 兜底吞错：真实等待者走原始 future
      ));
      h.completeError(e);
    }
    _isoHandshake = null;
    _isoSend = null;
    _isoSub = null;
    _isoExitSub?.cancel();
    _isoExitSub = null;
  }

  /// 处理 isolate 回传：进度刷新、完成（main 侧 finalize）、取消、错误。
  ///
  /// **迟到消息守卫**：取消/失败后 isolate 可能仍在途发送 progress/done——
  /// 任务已从 [_dlTasks] 移除时一律忽略，否则迟到 progress 会复活占位
  /// （幽灵进度再次吃掉下载按钮，冻死变体）。终态回执均带 isCompleted 防重。
  void _onIsoMessage(dynamic msg) {
    if (msg is! Map) return;
    final id = msg['id'] as String?;
    if (id == null) return;
    final task = _dlTasks[id];
    switch (msg['type']) {
      case 'progress':
        if (task == null) return; // 迟到进度：任务已结束，不得复活占位
        _progress[id] = (msg['value'] as num).toDouble();
        notifyListeners();
      case 'done':
        if (task == null) return;
        // finalize 在 main isolate 执行（写 meta、更新就绪态），完成后再解 await
        _finalize(task.m, task.part, task.file).then((_) {
          if (!task.completer.isCompleted) task.completer.complete();
        }).catchError((Object e) {
          if (!task.completer.isCompleted) {
            task.completer.completeError(Exception('落盘失败：$e'));
          }
        });
      case 'cancelled':
        if (task != null && !task.completer.isCompleted) task.completer.complete();
      case 'error':
        // 可观测性：isolate 侧只有 log()（developer log，logcat 不可见），错误必须
        // 在 main 侧留痕，否则「下载失败」只剩 SnackBar 一瞬，事后无从取证
        debugPrint('[LlmModelManager] download error ($id): ${msg['message']}');
        if (task != null && !task.completer.isCompleted) {
          task.completer.completeError(Exception(msg['message'] as String? ?? '下载失败'));
        }
    }
  }

  /// 下载模型（已就绪幂等返回；stale 允许更新到新文件）。
  /// 轻量后台：字节拉取委托给 downloader isolate，main isolate 仅收进度、做 finalize 与 UI 通知，UI 不卡。
  ///
  /// **进度占位全程受 finally 保护**（goodshare 冻死根因修复）：占位在入口先置（进度条立即出现），
  /// 无论成功/失败/取消/线程崩溃，finally 必清占位——此前 `_ensureIsolate` 抛错发生在
  /// try 之前，占位永久残留，下载按钮被幽灵进度吃掉（「点了没反应」的真凶）。
  Future<void> download(LlmModel m) async {
    if ((isReady(m) && !isStale(m)) || _progress.containsKey(m.id)) return;
    _progress[m.id] = 0;
    notifyListeners();
    try {
      final file = await _fileFor(m);
      await file.parent.create(recursive: true);
      final part = File('${file.path}.part');

      // 断点完成态：上次已下完整但未落盘（片段恰好齐 size）
      if (await part.exists()) {
        final len = await part.length();
        if (len == m.sizeBytes) {
          await _finalize(m, part, file);
          return;
        }
        if (len > m.sizeBytes) await part.delete(); // 旧版本更大/损坏片段，丢弃重来
      }

      _paused.remove(m.id); // 进入下载即脱离暂停态

      await _ensureIsolate();
      final completer = Completer<void>();
      _dlTasks[m.id] = _DlTask(completer, m, part, file);

      final existing = await part.exists() ? await part.length() : 0;
      _isoSend!.send({
        'cmd': 'download',
        'id': m.id,
        'url': m.urlFor(llmModelBase),
        'partPath': part.path,
        'sizeBytes': m.sizeBytes,
        'existingBytes': existing,
        'resume': existing > 0,
      });

      await completer.future;
    } finally {
      _progress.remove(m.id);
      _dlTasks.remove(m.id);
      // 注意：_paused 不在此清除——cancelDownload 依赖它存续以显示「继续」
      notifyListeners();
    }
  }

  /// 落盘：`.part` → `model.litertlm` 并写版本快照 `meta.json`，标记就绪/清 stale。
  Future<void> _finalize(LlmModel m, File part, File file) async {
    await part.rename(file.path);
    // 版本快照：此后 manifest 同 id 换文件（size 变化）即可被 _diskState 识别为 stale
    await File(p.join(file.parent.path, 'meta.json')).writeAsString(
      jsonEncode({'id': m.id, 'file': m.file, 'size': m.sizeBytes, 'ts': DateTime.now().millisecondsSinceEpoch}),
      flush: true,
    );
    _ready.add(m.id);
    _stale.remove(m.id);
    _paused.remove(m.id);
    notifyListeners();
    await _publish(m); // 落盘即告知原生真实路径，下次摘要无需重启
  }

  /// 把已就绪模型的真实绝对路径 publish 给原生，消除 path_provider 与原生 getDir 的路径差异。
  Future<void> _publish(LlmModel m) async {
    if (!isReady(m)) return;
    try {
      final file = await _fileFor(m);
      if (await file.exists()) {
        await _chan.invokeMethod('setModelPath', file.absolute.path);
      }
    } catch (e) {
      debugPrint('[LlmModelManager] publish model path failed: $e');
    }
  }

  /// 启动时把任一就绪模型路径告知原生（无需重新下载即可用）。
  Future<void> _publishReadyIfAny() async {
    final ordered = [modelById(selectedId), ...catalog.where((m) => _ready.contains(m.id))];
    for (final m in ordered) {
      if (m != null) {
        await _publish(m);
        break;
      }
    }
  }

  /// 取消下载：向 worker isolate 发取消指令，`.part` 片段保留，可再次 [download] 断点续传；
  /// 标记暂停态供 UI 显示「继续」。仅在确有进行中任务时生效，避免对已就绪模型误标暂停。
  ///
  /// **本地立即解除等待**（冻死修复）：不等 isolate 的 'cancelled' 回执——若回执丢失
  /// （线程恰死/消息丢失），download() 将永远 await 挂起。迟到回执按无任务忽略；
  /// 若 cancel 指令本身丢失，isolate 下完发 'done' 同样被忽略，.part 完整留存，
  /// 下次 [download] 走「断点完成态」自动转正（自愈）。
  Future<void> cancelDownload(String id) async {
    final task = _dlTasks[id];
    if (task == null) return;
    _isoSend?.send({'cmd': 'cancel', 'id': id});
    if (!task.completer.isCompleted) task.completer.complete();
    _paused.add(id);
    notifyListeners();
  }

  /// 清除已下载模型（腾空间；不撤历史产物）。删除孤儿条目后重扫，列表即时收敛。
  Future<void> remove(LlmModel m) async {
    final file = await _fileFor(m);
    if (await file.exists()) await file.delete();
    // 连带清理未完成的 .part 片段与暂停标记，避免残留占用空间 / 误显「继续」
    final part = File('${file.path}.part');
    if (await part.exists()) await part.delete();
    _ready.remove(m.id);
    _stale.remove(m.id);
    _paused.remove(m.id);
    if (m.localOnly) await _syncOrphans();
    notifyListeners();
  }
}

/// 进行中的下载任务上下文（id → 完成器 + 模型/路径），供 isolate 回传后 main 侧 finalize。
class _DlTask {
  final Completer<void> completer;
  final LlmModel m;
  final File part;
  final File file;
  _DlTask(this.completer, this.m, this.part, this.file);
}
