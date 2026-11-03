import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/llm/on_device_asset_manager.dart';
import 'package:goodhub/llm/on_device_model_catalog.dart';

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

    test('组合探测：模板 + 架构前缀 context 键（qwen35.context_length 真实形态）',
        () async {
      final f = await writeGguf(ggufHeader({
        'general.architecture': 'qwen35',
        'qwen35.context_length': 262144,
        'tokenizer.chat_template': '{% if m %}\u003c|im_start|>{% endif %}',
      }));
      expect(await OnDeviceAssetManager.ggufChatTemplate(f),
          contains('\u003c|im_start|\u003e'));
      expect(await OnDeviceAssetManager.ggufContextLength(f), 262144);
    });

    test('架构键缺失时回落磁盘上唯一 context 键', () async {
      final f = await writeGguf(ggufHeader({
        'mystery.context_length': 4096,
        'tokenizer.chat_template': 'x',
      }));
      expect(await OnDeviceAssetManager.ggufContextLength(f), 4096);
    });

    test('无 context 键 → contextLength null（字段缺席）', () async {
      final f = await writeGguf(ggufHeader({'tokenizer.chat_template': 'x'}));
      expect(await OnDeviceAssetManager.ggufContextLength(f), isNull);
    });

    test('真实工件回归钉：Qwen3.5-2B GGUF（本机基准，缺席即跳过）', () async {
      const real = '/home/zzh/Downloads/ai/Qwen3.5-2B-Q4_0.gguf';
      final f = File(real);
      if (!f.existsSync()) return; // 无本机基准 → 跳过（CI 安全）
      final tpl = await OnDeviceAssetManager.ggufChatTemplate(f);
      expect(tpl, isNotNull);
      expect(
          OnDeviceAssetManager.chatTemplateFamilyOfTemplate(tpl!),
          'qwen_chatml');
      expect(await OnDeviceAssetManager.ggufContextLength(f), 262144);
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

  group('stopSequences 家族闭合 token 推导（规格 §2 声明区）', () {
    test('三已知家族按闭合 token 推导；unknown/null 缺席（禁猜测值）', () {
      expect(OnDeviceAssetManager.stopSequencesForFamily('qwen_chatml'),
          ['\u003c|im_end|\u003e']);
      expect(OnDeviceAssetManager.stopSequencesForFamily('llama3'),
          ['\u003c|eot_id|\u003e']);
      expect(OnDeviceAssetManager.stopSequencesForFamily('gemma'),
          ['\u003cend_of_turn\u003e']);
      expect(OnDeviceAssetManager.stopSequencesForFamily('unknown'), isNull);
      expect(OnDeviceAssetManager.stopSequencesForFamily(null), isNull);
    });
  });

  group('模板可应用性静态探针（规格 §6）', () {
    late Directory tmp;
    setUp(() async => tmp = await Directory.systemTemp.createTemp('gh_tpl'));
    tearDown(() async => tmp.delete(recursive: true));

    test('qairt：tokenizer.json 在场 = verified，缺席 = false', () async {
      final d = Directory('${tmp.path}/qa');
      await d.create(recursive: true);
      await File('${d.path}/genie_config.json').writeAsString('{}');
      expect(
          await OnDeviceAssetManager.templateApplicability(
              d, OnDeviceRuntime.qairt),
          isFalse);
      await File('${d.path}/tokenizer.json').writeAsString('{}');
      expect(
          await OnDeviceAssetManager.templateApplicability(
              d, OnDeviceRuntime.qairt),
          isTrue);
    });

    test('litertlm：bundle 布局在场 = verified（静态检查止于布局）', () async {
      final d = Directory('${tmp.path}/lt');
      await d.create(recursive: true);
      expect(
          await OnDeviceAssetManager.templateApplicability(
              d, OnDeviceRuntime.litertlm),
          isFalse);
      await File('${d.path}/gemma3-1b.litertlm').writeAsString('x');
      expect(
          await OnDeviceAssetManager.templateApplicability(
              d, OnDeviceRuntime.litertlm),
          isTrue);
    });

    test('auto → false（布局未判 = 未验证）', () async {
      final d = Directory('${tmp.path}/au');
      await d.create(recursive: true);
      expect(
          await OnDeviceAssetManager.templateApplicability(
              d, OnDeviceRuntime.auto),
          isFalse);
    });
  });

  group('存量模型幂等迁移（规格 §7）', () {
    late Directory tmp;
    late OnDeviceAssetManager mgr;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('gh_migrate');
      mgr = OnDeviceAssetManager.forTest(
        supportDirResolver: () async => tmp,
        freeBytesProvider: () async => 20 * 1024 * 1024 * 1024,
        fingerprintProvider: () async => 'fp-test',
      );
    });
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('缺块 qairt 旧 meta → 补块 + 结构区回填，version 不变（modelId 稳定）',
        () async {
      final dir = Directory('${tmp.path}/models/old-qairt');
      await dir.create(recursive: true);
      await File('${dir.path}/genie_config.json').writeAsString('{}');
      await File('${dir.path}/tokenizer.json').writeAsString('{}');
      final metaFile = File('${dir.path}/.asset-meta.json');
      await metaFile.writeAsString(jsonEncode({
        'version': 'v9-old',
        'installedAt': '2026-10-01T00:00:00.000',
        'driverFingerprint': 'fp-test',
        'sizes': {'genie_config.json': 2, 'tokenizer.json': 2},
        'sha256': {'genie_config.json': 'aa', 'tokenizer.json': 'bb'},
      }));

      final models = await mgr.listInstalled();
      final m = models.single;
      expect(m.dirName, 'old-qairt');
      expect(m.runtime, OnDeviceRuntime.qairt);
      expect(m.templateVerified, isTrue);

      final newMeta =
          jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
      expect(newMeta['version'], 'v9-old'); // 身份仅认 version 前缀 → 不变
      expect(newMeta['runtime'], OnDeviceRuntime.qairt);
      expect(newMeta['family'], OnDeviceAssetFamily.geniex);
      final profile = newMeta['modelProfile'] as Map<String, dynamic>;
      expect(profile['chatTemplateFamily'], 'qwen_chatml');
      expect(profile['stopSequences'], ['\u003c|im_end|\u003e']);
    });

    test('幂等：块在场后二次扫描不再重写', () async {
      final dir = Directory('${tmp.path}/models/old-qairt');
      await dir.create(recursive: true);
      await File('${dir.path}/genie_config.json').writeAsString('{}');
      await File('${dir.path}/tokenizer.json').writeAsString('{}');
      final metaFile = File('${dir.path}/.asset-meta.json');
      await metaFile.writeAsString(jsonEncode({
        'version': 'v9-old',
        'installedAt': 'x',
        'driverFingerprint': 'fp-test',
        'sizes': {'genie_config.json': 2, 'tokenizer.json': 2},
      }));
      await mgr.listInstalled();
      final after1 = await metaFile.readAsString();
      await mgr.listInstalled();
      expect(await metaFile.readAsString(), after1);
    });

    test('探测失败（auto 无工件）→ 不写迁移（保块缺席，禁半效迁移）', () async {
      final dir = Directory('${tmp.path}/models/plain');
      await dir.create(recursive: true);
      final metaFile = File('${dir.path}/.asset-meta.json');
      await metaFile.writeAsString(jsonEncode({
        'version': 'v1',
        'installedAt': 'x',
        'driverFingerprint': 'fp-test',
        'sizes': {'model.bin': 1},
      }));
      final before = await metaFile.readAsString();
      await mgr.listInstalled();
      expect(await metaFile.readAsString(), before);
    });
  });

  group('recommendedSampling S1 下发链（§3.5）', () {
    test('meta 解析：temperature/topP 透传，缺字段各自独立容忍', () {
      final p = OnDeviceModelProfile.fromMeta({
        'recommendedSampling': {'temperature': 1.0, 'topP': 0.95},
      });
      expect(p!.recommendedSampling!.temperature, 1.0);
      expect(p.recommendedSampling!.topP, 0.95);

      final partial = OnDeviceModelProfile.fromMeta({
        'recommendedSampling': {'temperature': 0.9},
      });
      expect(partial!.recommendedSampling!.temperature, 0.9);
      expect(partial.recommendedSampling!.topP, isNull);

      // 全空采样块 + 无其他字段 → 整块判 null（禁臆造默认，全空块=无块）。
      expect(
          OnDeviceModelProfile.fromMeta({
            'recommendedSampling': <String, dynamic>{},
          }),
          isNull);
    });

    test('无 recommendedSampling 键 → null（走引擎内建默认）', () {
      final p = OnDeviceModelProfile.fromMeta({'contextTokens': 1280});
      expect(p!.recommendedSampling, isNull);
    });

    test('toOption 透出：modelProfile 预设 → OnDeviceModelOption 同源', () {
      const profile = OnDeviceModelProfile(
        contextTokens: 1280,
        recommendedSampling: OnDeviceSamplingPreset(temperature: 1.0),
      );
      final opt = InstalledModel(
        dirName: 'm',
        displayName: 'm',
        runtime: 'litertlm',
        totalBytes: 1,
        imported: true,
        modelProfile: profile,
      ).toOption();
      expect(opt.recommendedSampling!.temperature, 1.0);
      expect(opt.recommendedSampling!.topP, isNull);
    });
  });
}
