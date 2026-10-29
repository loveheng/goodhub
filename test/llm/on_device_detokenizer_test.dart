import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/llm/on_device_detokenizer.dart';

/// 轻量 Detokenizer 单测（on-device S1-4）：跨微批 UTF-8 重组无损是核心契约
///（on-device-npu-deployment.md §6.4——撤流式重组退回逐批 utf8.decode 即红）。
void main() {
  /// 构造「按字节切 token」的退化表：id i → 第 i 个字节（字节级 BPE 退化形态），
  /// 便于精确控制微批切点。
  TokenByteTable byteTable(List<int> bytes) {
    final b = TokenByteTableBuilder();
    for (var i = 0; i < bytes.length; i++) {
      b.add(i, [bytes[i]]);
    }
    return b.build();
  }

  group('TokenByteTable', () {
    test('parse/build round-trip preserves rows', () {
      final b = TokenByteTableBuilder();
      b.add(0, utf8.encode('你'));
      b.add(1, [0x61]);
      b.add(3, utf8.encode('😀'));
      final table = b.build();
      expect(table.bytesFor(0), utf8.encode('你'));
      expect(table.bytesFor(1), [0x61]);
      expect(table.bytesFor(3), utf8.encode('😀'));
      expect(table.bytesFor(2), isNull, reason: '空洞 id 显式返回 null');
      expect(table.length, 4);
    });

    test('parse rejects bad magic and truncation', () {
      expect(() => TokenByteTable.parse(Uint8List.fromList([1, 2, 3])),
          throwsFormatException);
      final b = TokenByteTableBuilder();
      b.add(0, [1, 2, 3]);
      final data = b.toBytes();
      // 丢尾部字节：截断。
      expect(
        () => TokenByteTable.parse(data.sublist(0, data.length - 1)),
        throwsFormatException,
      );
    });

    test('loadFile reads compact table from disk', () async {
      final b = TokenByteTableBuilder();
      b.add(0, utf8.encode('好'));
      final tmp = await File(
        '${Directory.systemTemp.path}/ghdt_test_${DateTime.now().microsecondsSinceEpoch}.bin',
      ).writeAsBytes(b.build().rowsForTest());
      addTearDown(() => tmp.delete());
      final table = await TokenByteTable.loadFile(tmp.path);
      expect(table.bytesFor(0), utf8.encode('好'));
    });
  });

  group('StreamingDetokenizer', () {
    test('multi-byte han split per byte across microbatches is lossless', () {
      final text = '你好，端侧引擎';
      final table = byteTable(utf8.encode(text));
      final out = StringBuffer();
      final d = StreamingDetokenizer(table: table, onText: out.write);
      // 逐字节喂入（最恶劣切点：每 token 一次）。
      final bytes = utf8.encode(text);
      for (var i = 0; i < bytes.length; i++) {
        d.addToken(i);
      }
      d.finish();
      expect(out.toString(), text);
    });

    test('4-byte emoji split across batches is lossless', () {
      final text = 'ok😀done';
      final bytes = utf8.encode(text);
      final table = byteTable(bytes);
      final out = StringBuffer();
      final d = StreamingDetokenizer(table: table, onText: out.write);
      d.addTokens(List.generate(bytes.length, (i) => i));
      d.finish();
      expect(out.toString(), text);
    });

    test('mixed table tokens (word-piece granularity) assemble in order', () {
      final b = TokenByteTableBuilder();
      b.add(10, utf8.encode('生成'));
      b.add(11, [0x20]);
      b.add(12, utf8.encode('流水线'));
      final d = <String>[];
      final detok = StreamingDetokenizer(table: b.build(), onText: d.add);
      detok.addTokens([10, 11, 12]);
      detok.finish();
      expect(d.join(), '生成 流水线');
    });

    test('unknown token surfaces via onUnknownToken, never silently dropped', () {
      final b = TokenByteTableBuilder();
      b.add(0, [0x61]);
      final unknown = <int>[];
      final out = StringBuffer();
      final detok = StreamingDetokenizer(
        table: b.build(),
        onText: out.write,
        onUnknownToken: unknown.add,
      );
      detok.addToken(0);
      detok.addToken(999); // 越界
      detok.addToken(-1); // 非法
      detok.finish();
      expect(out.toString(), 'a');
      expect(unknown, [999, -1]);
    });

    test('empty batches produce no empty delta calls', () {
      final b = TokenByteTableBuilder();
      b.add(0, [0x61]);
      final deltas = <String>[];
      final detok = StreamingDetokenizer(table: b.build(), onText: deltas.add);
      detok.addToken(0);
      detok.addTokens(const []); // 空微批不产生空 delta
      detok.finish();
      expect(deltas, ['a'], reason: 'utf8 解码器不产生空 delta');
    });
  });
}

extension on TokenByteTable {
  /// 测试辅助：取底层字节（loadFile 用）。
  Uint8List rowsForTest() {
    // 直接重打包：走 builder 的 parse 路径拿原始数据。
    final out = BytesBuilder();
    out.add(utf8.encode('GHDT'));
    final bd = ByteData(8)
      ..setUint32(0, 1, Endian.little)
      ..setUint32(4, length, Endian.little);
    out.add(bd.buffer.asUint8List());
    for (var i = 0; i < length; i++) {
      final row = bytesFor(i);
      final lenBd = ByteData(4)..setUint32(0, row?.length ?? 0, Endian.little);
      out.add(lenBd.buffer.asUint8List());
      if (row != null) out.add(row);
    }
    return out.toBytes();
  }
}
