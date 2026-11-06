/// 端侧 LLM 模型目录类型与 manifest 解析面（M2 自 goodshare 随迁，2026-10-10；
/// 原设计见 goodshare 仓 docs/design/on-device-llm.md，随迁后 SSOT 移至本仓 docs/design/）。
///
/// 目录事实源（2026-11-06 修订）：**远端 manifest**（`llm_manifest.json`，经
/// RemoteConfigStore.flags 里的 URL 热更下发）+ 纯导入制模型资产（规格声明 =
/// assets/model-specs.json per-bundle 规格表）。原「内置默认目录」随旧下载
/// 通道退役（见文件尾注记），下载 UI 通道已不存在。
///
/// 文件名均为 hf-mirror API/HEAD 实测（2026-09-29）：
/// - Qwen 官方文件名带 `multi-prefill-seq_` 中缀（官网表格省略，凭表格转写会 404）；
/// - Gemma NPU 专包 SoC 后缀为小写，且仓库 gated（HEAD 403）——需 R2 中转，经 manifest
///   下发绝对 `url` 即可，无需改代码发版。
class LlmModel {
  const LlmModel({
    required this.id,
    required this.name,
    required this.desc,
    required this.file,
    required this.sizeBytes,
    this.repo,
    this.url,
    this.socModel,
    this.localOnly = false,
  });

  /// 持久化标识（设置/缓存目录用）。
  final String id;

  /// 展示名（分类语义内嵌：通用 / NPU · 机型）。
  final String name;

  /// 档位描述（设置页 subtitle）。
  final String desc;

  /// 模型文件名（`.litertlm` 单文件，自带 tokenizer 与 chat template）；
  /// 也是本地缓存目录内的落盘文件名。
  final String file;

  /// 远端文件字节数（下载前提示用）。
  final int sizeBytes;

  /// HuggingFace 仓库路径（{base}/resolve/main/{file}）；与 [url] 二选一。
  final String? repo;

  /// 绝对下载地址（R2 自托管 / gated 中转用）；非空时**优先于** repo 拼接。
  final String? url;

  /// NPU 专包限定的 SoC 型号（`ro.soc.model` 精确匹配，如 'SM8750'）；
  /// null = 通用包（GPU/CPU，全设备可下载）。
  final String? socModel;

  /// 本机残留条目（manifest 已移除该 id，但设备上仍有已下载文件）。
  /// 非目录来源，由 LlmModelManager 扫盘合成；用户照常可用，仅提示不再云端分发。
  final bool localOnly;

  /// 实际下载 URL：manifest 显式 [url] 优先（R2 自托管/gated 中转），否则 HF 仓库拼接。
  String urlFor(String base) =>
      (url != null && url!.isNotEmpty) ? url! : '$base/$repo/resolve/main/$file';

  /// manifest JSON → 模型条目。防御式解析：字段缺失/类型不符抛 FormatException，
  /// 由目录级解析器吞掉该条并跳过（一条坏数据不拖垮整个目录）。
  factory LlmModel.fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final name = json['name'];
    final file = json['file'];
    final size = json['size'];
    if (id is! String || id.isEmpty) throw const FormatException('id 缺失');
    if (name is! String || name.isEmpty) throw const FormatException('name 缺失');
    if (file is! String || file.isEmpty) throw const FormatException('file 缺失');
    if (size is! int || size <= 0) throw const FormatException('size 非法');
    final repo = json['repo'];
    final absUrl = json['url'];
    if ((repo is! String || repo.isEmpty) &&
        (absUrl is! String || absUrl.isEmpty)) {
      throw const FormatException('repo 与 url 至少一个');
    }
    final soc = json['socModel'];
    return LlmModel(
      id: id,
      name: name,
      desc: json['desc'] is String ? json['desc'] as String : '',
      file: file,
      sizeBytes: size,
      repo: repo is String && repo.isNotEmpty ? repo : null,
      url: absUrl is String && absUrl.isNotEmpty ? absUrl : null,
      socModel: soc is String && soc.isNotEmpty ? soc : null,
    );
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'desc': desc,
        'file': file,
        'size': sizeBytes,
        if (repo != null) 'repo': repo,
        if (url != null) 'url': url,
        if (socModel != null) 'socModel': socModel,
      };
}

/// manifest JSON（`{"models":[...]}`）→ 目录。坏条目跳过不拖垮整表；全坏/结构错返回空
/// （调用方落回内置目录）。
List<LlmModel> llmModelsFromJson(Object? raw) {
  if (raw is! Map) return const [];
  final list = raw['models'];
  if (list is! List) return const [];
  final out = <LlmModel>[];
  for (final e in list) {
    if (e is! Map) continue;
    try {
      out.add(LlmModel.fromJson(e.cast<String, Object?>()));
    } on FormatException catch (_) {
      // 单条损坏跳过：远端配置是外部输入，不能让它毁掉整个目录
    }
  }
  return out;
}

/// 2026-11-06 旧下载通道退役（m4 ②⑤ 清理）：原内置默认目录 `llmModels`
///（三模型条目）/ `llmModelBase` / `llmModelById` 全仓零消费，随旧下载
/// 通道一并退役——纯导入制后目录事实源 = 导入的模型资产 + model-specs.json
/// 规格表（通用实现纪律，2026-11-03），本文件只保留 [LlmModel] 类型与
/// [llmModelsFromJson] manifest 解析面。
