// GGUF header 解析回归钉子（合成字节固定装置，不依赖真实模型文件）。
//
// 覆盖：magic/版本守卫、v3 全标量类型、string/array 递归、contextLength
// 派生键、缓冲不足/坏 magic 显式失败（禁静默空表）。
//
// 固定装置构造器按 GGUF v3 spec 手工拼字节（小端）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:goodhub/llm/on_device_gguf_header.dart';

class _B {
  final b = BytesBuilder();

  void u32(int v) => b.add((ByteData(4)..setUint32(0, v, Endian.little))
      .buffer
      .asUint8List());
  void u64(int v) => b.add((ByteData(8)..setUint64(0, v, Endian.little))
      .buffer
      .asUint8List());
  void f32(double v) => b.add((ByteData(4)..setFloat32(0, v, Endian.little))
      .buffer
      .asUint8List());
  void str(String s) {
    final bytes = utf8.encode(s);
    u64(bytes.length);
    b.add(bytes);
  }

  void kv(String key, int type, void Function(_B) write) {
    str(key);
    u32(type);
    write(this);
  }

  Uint8List take() => b.toBytes();
}

Uint8List _fixture() {
  final w = _B()
    ..u32(0x46554747) // magic "GGUF"
    ..u32(3) // version
    ..u64(2) // tensor_count
    ..u64(7); // kv_count
  w.kv('general.architecture', 8, (w) => w.str('qwen2'));
  w.kv('qwen2.context_length', 4, (w) => w.u32(32768));
  w.kv('general.file_type', 4, (w) => w.u32(2)); // Q4_0
  w.kv('general.quantization_version', 4, (w) => w.u32(2));
  w.kv('tokenizer.chat_template', 8, (w) => w.str('{% for m in msgs %}'));
  w.kv('general.name', 8, (w) => w.str('qwen3.5-2b'));
  w.kv('test.scores', 9, (w) {
    w.u32(6); // 元素类型 float32
    w.u64(3);
    w.f32(0.5);
    w.f32(1.5);
    w.f32(-2.0);
  });
  return w.take();
}

void main() {
  test('v3 合成头部：标量/string/array 全类型解析 + contextLength 派生', () {
    final h = parseGgufHeader(_fixture());
    expect(h.version, 3);
    expect(h.tensorCount, 2);
    expect(h[GgufKeys.architecture], 'qwen2');
    expect(h.contextLength, 32768);
    expect(h[GgufKeys.fileType], 2);
    expect(h[GgufKeys.quantizationVersion], 2);
    expect(h[GgufKeys.chatTemplate], '{% for m in msgs %}');
    expect(h['general.name'], 'qwen3.5-2b');
    final scores = h['test.scores'] as List<Object>;
    expect(scores, [0.5, 1.5, -2.0]);
  });

  test('缺 chat_template → null（unknown 判定归消费方，非空串兜底）', () {
    final w = _B()..u32(0x46554747)..u32(2)..u64(0)..u64(0);
    final h = parseGgufHeader(w.take());
    expect(h[GgufKeys.chatTemplate], isNull);
    expect(h.contextLength, isNull);
  });

  test('坏 magic / 未知版本 / 缓冲不足 → 显式失败', () {
    expect(() => parseGgufHeader(Uint8List(10)),
        throwsA(isA<GgufParseException>()));
    final w = _B()..u32(0x46554747)..u32(1)..u64(0)..u64(0);
    expect(() => parseGgufHeader(w.take()),
        throwsA(isA<GgufParseException>()));
    final full = _fixture();
    expect(() => parseGgufHeader(full.sublist(0, 30)),
        throwsA(isA<GgufParseException>()));
  });
}
