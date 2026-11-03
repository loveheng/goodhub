/// GGUF 头部元数据解析（元数据管线 S0 来源，2026-11-03 spike 立法件）。
///
/// **只读头部，零权重加载**：GGUF 的 metadata KV 区紧跟 24 字节文件头、
/// 先于张量数据区——解析器只消费 KV 区字节（典型 <1MB），1GB+ 权重永不
/// 进内存。产出 context_length / chat_template / 量化参数等模型自带
/// 真相源，供 modelProfile 单源消费（asset-meta 扩展；GGUF 探测不出的
/// 字段标 unknown，禁静默兜底——D-3 禁中心化 token 级解析口径不变，
/// 本件只读 KV 标量，不碰 tokenizer 词表数据面）。
///
/// 规格口径（GGUF v2/v3 spec）：magic "GGUF" + u32 version + u64 张量数
/// + u64 KV 数 + KV 对（key = u64 长度前缀 UTF-8 串；value = u32 类型 +
/// 载荷）。类型 0~12 全覆盖，array 递归。纯逻辑件（无平台依赖）：单测
/// 见 `test/llm/on_device_gguf_header_test.dart`（合成字节固定装置），
/// 真样本诊断入口 `tool/gguf_header_probe.dart`。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// "GGUF" 小端 u32。
const int _kGgufMagic = 0x46554747;

/// KV 区读取上限（防畸形文件读穿张量区）。2026-11-03 真样本实证：Qwen3.5-2B
/// KV 区 10.9MB（tokenizer tokens/merges/token_type 三数组占 ~10.5MB）——
/// 8MB 档会误拒正常模型；32MB 覆盖现有量级并留大词表余量（与导入探测
/// 通道历史预算同值，单源纪律：两通道共用本件后只此一档）。
const int kGgufHeaderMaxBytes = 32 * 1024 * 1024;

/// 元数据键（架构信息 / 窗口 / 模板 / 量化），消费方按这些键取 S0 值。
abstract final class GgufKeys {
  /// 模型架构（如 `qwen2`、`gemma3`）。
  static const architecture = 'general.architecture';

  /// 模型自带 chat 模板（Jinja；GenieX 系 bundle 可能缺失 → unknown）。
  static const chatTemplate = 'tokenizer.chat_template';

  /// 量化格式名（`general.file_type`，如 Q4_0 对应枚举值）。
  static const fileType = 'general.file_type';

  /// 量化版本。
  static const quantizationVersion = 'general.quantization_version';
}

class GgufHeader {
  const GgufHeader({
    required this.version,
    required this.tensorCount,
    required this.metadata,
  });

  /// GGUF 规格版本（2 / 3）。
  final int version;

  /// 张量数（仅记录，本件不进张量区）。
  final int tensorCount;

  /// KV 元数据（string→String / 标量→num|bool / array→List<Object>）。
  final Map<String, Object> metadata;

  /// 便捷取值：键不存在返回 null（unknown 判定归消费方，禁静默兜底值）。
  Object? operator [](String key) => metadata[key];

  /// 窗口 token 数：`{arch}.context_length` 架构前缀键优先（架构名从
  /// `general.architecture` 派生）；未命中回落**唯一** context 键或裸
  /// `context_length`（防御非规范工件——旧导入探测通道同语义，单源化
  /// 保留）。多键冲突不猜（返回 null，禁取首值冒充）。
  int? get contextLength {
    final arch = metadata[GgufKeys.architecture];
    if (arch is String) {
      final v = metadata['$arch.context_length'];
      if (v is num) return v.toInt();
    }
    final candidates = <int>[];
    for (final e in metadata.entries) {
      if (!e.key.endsWith('.context_length')) continue;
      final v = e.value;
      if (v is num) candidates.add(v.toInt());
    }
    return candidates.length == 1 ? candidates.single : null;
  }
}

/// 头部结构不合法（magic/版本/缓冲不足/越界）——显式失败，禁静默空表。
class GgufParseException implements Exception {
  const GgufParseException(this.reason);

  final String reason;

  @override
  String toString() => 'GgufParseException: $reason';
}

/// 解析 [bytes]（须覆盖完整 KV 区；不足抛 [GgufParseException]）。
GgufHeader parseGgufHeader(Uint8List bytes) {
  if (bytes.length < 24) {
    throw const GgufParseException('buffer < 24B（文件头不完整）');
  }
  final d = ByteData.sublistView(bytes);
  final magic = d.getUint32(0, Endian.little);
  if (magic != _kGgufMagic) {
    throw const GgufParseException('magic 非 GGUF');
  }
  final version = d.getUint32(4, Endian.little);
  if (version < 2 || version > 3) {
    throw GgufParseException('不支持 GGUF v$version（仅 v2/v3）');
  }
  final tensorCount = d.getUint64(8, Endian.little);
  final kvCount = d.getUint64(16, Endian.little);
  final c = _Cursor(bytes, d)..p = 24;
  final metadata = <String, Object>{};
  for (var i = 0; i < kvCount; i++) {
    final key = c.str();
    metadata[key] = c.value();
  }
  return GgufHeader(
      version: version, tensorCount: tensorCount, metadata: metadata);
}

/// 从文件读头部并解析：按 [kGgufHeaderMaxBytes] 封顶读取（权重不进内存），
/// 缓冲不足以覆盖 KV 区时按实际文件长度裁剪判定。
GgufHeader readGgufHeader(File file) {
  final RandomAccessFile raf;
  try {
    raf = file.openSync();
  } on FileSystemException catch (e) {
    throw GgufParseException('open failed: ${e.message}');
  }
  try {
    final fileLen = raf.lengthSync();
    final want = fileLen < kGgufHeaderMaxBytes ? fileLen : kGgufHeaderMaxBytes;
    final bytes = raf.readSync(want);
    return parseGgufHeader(bytes);
  } finally {
    raf.closeSync();
  }
}

final class _Cursor {
  _Cursor(this.b, this.d);

  final Uint8List b;
  final ByteData d;
  int p = 0;

  void _need(int n) {
    if (p + n > b.length) {
      throw const GgufParseException('缓冲不足（KV 区超出读取上限，文件畸形）');
    }
  }

  int _u8() {
    _need(1);
    return b[p++];
  }

  int _u32() {
    _need(4);
    final v = d.getUint32(p, Endian.little);
    p += 4;
    return v;
  }

  int _u64() {
    _need(8);
    final v = d.getUint64(p, Endian.little);
    p += 8;
    return v;
  }

  String str() {
    final n = _u64();
    _need(n);
    final s = utf8.decode(b.sublist(p, p + n), allowMalformed: true);
    p += n;
    return s;
  }

  Object value() {
    final type = _u32();
    switch (type) {
      case 0:
        return _u8();
      case 1:
        return _u8().toSigned(8);
      case 2:
        return _u16();
      case 3:
        return _u16().toSigned(16);
      case 4:
        return _u32();
      case 5:
        return _u32().toSigned(32);
      case 6:
        _need(4);
        final v = d.getFloat32(p, Endian.little);
        p += 4;
        return v;
      case 7:
        return _u8() != 0;
      case 8:
        return str();
      case 9:
        return _array();
      case 10:
        return _u64();
      case 11:
        return _u64().toSigned(64);
      case 12:
        _need(8);
        final v = d.getFloat64(p, Endian.little);
        p += 8;
        return v;
      default:
        throw GgufParseException('未知 KV value type=$type');
    }
  }

  int _u16() {
    _need(2);
    final v = d.getUint16(p, Endian.little);
    p += 2;
    return v;
  }

  List<Object> _array() {
    final elemType = _u32();
    final count = _u64();
    if (count > 1 << 20) {
      throw const GgufParseException('array count 异常（>1M）');
    }
    return List<Object>.generate(count, (_) => _typedValue(elemType));
  }

  /// array 元素按元素类型读取（不复用 [value]——元素不带类型前缀）。
  Object _typedValue(int type) {
    switch (type) {
      case 0:
        return _u8();
      case 1:
        return _u8().toSigned(8);
      case 2:
        return _u16();
      case 3:
        return _u16().toSigned(16);
      case 4:
        return _u32();
      case 5:
        return _u32().toSigned(32);
      case 6:
        _need(4);
        final v = d.getFloat32(p, Endian.little);
        p += 4;
        return v;
      case 7:
        return _u8() != 0;
      case 8:
        return str();
      case 10:
        return _u64();
      case 11:
        return _u64().toSigned(64);
      case 12:
        _need(8);
        final v = d.getFloat64(p, Endian.little);
        p += 8;
        return v;
      default:
        throw GgufParseException('array 不支持嵌套元素类型=$type');
    }
  }
}
