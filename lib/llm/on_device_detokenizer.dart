/// 轻量 Detokenizer（on-device epic S1-4；立法源 on-device-npu-deployment.md §6.4 /
/// §4.5）。
///
/// 职责边界（§6.4）：**只做** `token id → raw bytes` 查表 + 流式 UTF-8 重组；
/// 禁全功能 BPE 分词框架（30~60MB，客户端无需 encode）；停用词/终止判定不在此做
/// （§6.7 下沉 `:engine`）。
///
/// 表格式（紧凑只读 ID-to-Byte 表，由 §4.5 OTA 包随 model.bin 同源下发、版本对齐）：
/// ```
/// magic "GHDT" | version u32=1 | count u32
/// count 个条目（id 隐含为序号 0..count-1）：len u32 | bytes[len]
/// ```
///
/// 偏差标注（S1-4）：§6.4 要求 mmap 只读防 RSS 尖峰——mmap 需 native 侧，
/// 纯 Dart 不可达；本件先以单次读入 `Uint8List` 承载（3B 词表 ID→字节表为
/// MB 级，可接受），mmap 化随 S3-6 native eventfd worker 一并下沉。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 只读紧凑 ID→字节表。
class TokenByteTable {
  TokenByteTable._(this._rows);

  final List<Uint8List?> _rows;

  /// `id → raw bytes`；越界/空洞返回 null（由调用方决定未知 token 处置，
  /// 禁静默吞——默认回调路径上报）。
  Uint8List? bytesFor(int id) {
    if (id < 0 || id >= _rows.length) return null;
    return _rows[id];
  }

  int get length => _rows.length;

  /// 从紧凑表二进制解析（格式见库注释；损坏/魔数不符抛 [FormatException]）。
  factory TokenByteTable.parse(Uint8List data) {
    if (data.length < 12) throw const FormatException('token table truncated');
    final bd = ByteData.sublistView(data);
    if (data[0] != 0x47 || data[1] != 0x48 || data[2] != 0x44 || data[3] != 0x54) {
      throw const FormatException('token table bad magic (expect GHDT)');
    }
    final version = bd.getUint32(4, Endian.little);
    if (version != 1) throw FormatException('token table unsupported version $version');
    final count = bd.getUint32(8, Endian.little);
    final rows = List<Uint8List?>.filled(count, null);
    var offset = 12;
    for (var id = 0; id < count; id++) {
      if (offset + 4 > data.length) throw const FormatException('token table truncated');
      final len = bd.getUint32(offset, Endian.little);
      offset += 4;
      if (offset + len > data.length) throw const FormatException('token table truncated');
      // len=0 = 空洞（token 至少编码 1 字节，0 长条目仅为 builder 对齐占位）。
      rows[id] = len == 0 ? null : Uint8List.sublistView(data, offset, offset + len);
      offset += len;
    }
    return TokenByteTable._(rows);
  }

  /// 从文件装载（§4.5 OTA 包内 `tokenizer.id2byte.bin`，与 model.bin 版本对齐）。
  static Future<TokenByteTable> loadFile(String path) async =>
      TokenByteTable.parse(await File(path).readAsBytes());
}

/// 表构造器（资产管线侧：tokenizer.json → 紧凑表 的中间形态；S2-2 OTA 打包时
/// 由构建脚本产出正式 .bin，此处提供运行时等价构造以支撑单测与 Mock）。
class TokenByteTableBuilder {
  final List<Uint8List?> _rows = [];

  void add(int id, List<int> bytes) {
    while (_rows.length <= id) {
      _rows.add(null);
    }
    _rows[id] = Uint8List.fromList(bytes);
  }

  /// 序列化为紧凑表二进制（parse 的逆运算，供资产管线/测试截断用例）。
  Uint8List toBytes() {
    final out = BytesBuilder();
    out.add(utf8.encode('GHDT'));
    final bd = ByteData(8)..setUint32(0, 1, Endian.little)..setUint32(4, _rows.length, Endian.little);
    out.add(bd.buffer.asUint8List());
    for (final row in _rows) {
      final lenBd = ByteData(4)..setUint32(0, row?.length ?? 0, Endian.little);
      out.add(lenBd.buffer.asUint8List());
      if (row != null) out.add(row);
    }
    return out.toBytes();
  }

  TokenByteTable build() => TokenByteTable.parse(toBytes());
}

/// 流式 Detokenizer：token id 流 → raw bytes → `utf8.decoder` 流式重组。
///
/// 跨微批无损的关键：多字节汉字/emoji 的不完整前缀序列由 utf8 解码器内部
/// 携带（chunked conversion），绝不出现 `U+FFFD` 强转乱码（§6.4）。
class StreamingDetokenizer {
  StreamingDetokenizer({
    required this.table,
    required void Function(String delta) onText,
    this.onUnknownToken,
  }) {
    _decoder = utf8.decoder.startChunkedConversion(_ChunkedTextSink(onText));
  }

  final TokenByteTable table;
  final void Function(int id)? onUnknownToken;
  late final ByteConversionSink _decoder;

  /// 喂入单个 token id（载荷 = 原始 uint32 id，§6.1）。
  void addToken(int id) {
    final bytes = table.bytesFor(id);
    if (bytes == null) {
      // 未知 token：禁静默吞（表与模型版本漂移即触此路径），交调用方决策。
      onUnknownToken?.call(id);
      return;
    }
    _decoder.add(bytes);
  }

  /// 批量喂入（40ms 微批排空场景，§6.1）。
  void addTokens(Iterable<int> ids) => ids.forEach(addToken);

  /// 收口：冲刷解码器内部残留序列（正常流以 EOS 收尾后应无残留）。
  void finish() => _decoder.close();
}

class _ChunkedTextSink implements ChunkedConversionSink<String> {
  _ChunkedTextSink(this._onText);

  final void Function(String delta) _onText;

  @override
  void add(String chunk) {
    if (chunk.isNotEmpty) _onText(chunk);
  }

  @override
  void close() {}
}
