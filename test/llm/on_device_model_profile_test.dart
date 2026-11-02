import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/llm/on_device_asset_manager.dart';

/// modelProfile 探测回归钉（声明式解析元数据，2026-11-02）。
///
/// 覆盖两层纯逻辑面（写入侧 `_probeModelProfile` 走导入集成路径，由
/// on_device_asset_import_test 兜底；本文件钉 GGUF 头解析与家族映射）：
/// - GGUF v2/v3 头 KV 扫描取 `tokenizer.chat_template`（含跳过非字符串
///   KV / ARRAY / 损坏头降级）；
/// - 模板文本 → 家族映射单源。
void main() {
  group('GGUF chat_template 探测', () {
    late Directory tmp;
    setUp(() async => tmp = await Directory.systemTemp.createTemp('gguf-probe-'));
    tearDown(() async => tmp.delete(recursive: true));

    /// 合成 GGUF v3 头：magic + version + tensorCount + kv 串。
    Uint8List ggufHeader(Map<String, Object> kvs) {
      final b = BytesBuilder();
      void u32(int v) =>
          b.add(Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little));
      void u64(int v) =>
          b.add(Uint8List(8)..buffer.asByteData().setUint64(0, v, Endian.little));
      void str(String s) {
        final bytes = s.codeUnits;
        u64(bytes.length);
        b.add(bytes);
      }

      b.add('GGUF'.codeUnits); // magic（LE 读回 0x47554647）
      u32(3); // version
      u64(0); // tensor_count
      u64(kvs.length);
      kvs.forEach((key, value) {
        str(key);
        if (value is String) {
          u32(8); // STRING
          str(value);
        } else if (value is int) {
          u32(4); // UINT32
          u32(value);
        } else if (value is List) {
          u32(9); // ARRAY
          u32(8); // elem = STRING
          u64(value.length);
          for (final s in value) {
            str(s as String);
          }
        }
      });
      return b.toBytes();
    }

    Future<File> writeGguf(Uint8List bytes) async {
      final f = File('${tmp.path}/m.gguf');
      await f.writeAsBytes(bytes);
      return f;
    }

    test('qwen 模板命中 → qwen_chatml', () async {
      final f = await writeGguf(ggufHeader({
        'general.architecture': 'qwen2',
        'tokenizer.chat_template':
            '{% for m %}<|im_start|>{{m.role}}...',
      }));
      expect(await OnDeviceAssetManager.ggufChatTemplate(f),
          contains('<|im_start|>'));
    });

    test('非字符串与 ARRAY KV 混排可跳过，仍命中其后字符串 KV', () async {
      final f = await writeGguf(ggufHeader({
        'general.size_label': 2,
        'tokenizer.ggml.tokens': ['<unk>', 'hello'],
        'tokenizer.chat_template': '<|start_header_id|>',
      }));
      expect(await OnDeviceAssetManager.ggufChatTemplate(f),
          '<|start_header_id|>');
    });

    test('无 chat_template KV → null（调用方落 unknown）', () async {
      final f = await writeGguf(ggufHeader({'general.architecture': 'qwen2'}));
      expect(await OnDeviceAssetManager.ggufChatTemplate(f), isNull);
    });

    test('坏魔数 / 截断头 → null 不抛', () async {
      final bad = File('${tmp.path}/bad.gguf');
      await bad.writeAsBytes([1, 2, 3, 4, 5, 6]);
      expect(await OnDeviceAssetManager.ggufChatTemplate(bad), isNull);

      final trunc = File('${tmp.path}/trunc.gguf');
      await trunc.writeAsBytes(ggufHeader({'a': 'b'}).sublist(0, 20));
      expect(await OnDeviceAssetManager.ggufChatTemplate(trunc), isNull);
    });
  });

  group('模板家族映射', () {
    test('四族单源映射', () {
      expect(OnDeviceAssetManager.chatTemplateFamilyOfTemplate(
          '<|im_start|>user'), 'qwen_chatml');
      expect(OnDeviceAssetManager.chatTemplateFamilyOfTemplate(
          '<|start_header_id|>user<|end_header_id|>'), 'llama3');
      expect(OnDeviceAssetManager.chatTemplateFamilyOfTemplate(
          '<start_of_turn>user'), 'gemma');
      expect(OnDeviceAssetManager.chatTemplateFamilyOfTemplate('no markers'),
          'unknown');
    });
  });
}
