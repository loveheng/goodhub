import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';
import 'package:goodhub/llm/on_device_asset_manager.dart';
import 'package:goodhub/llm/on_device_model_catalog.dart';

/// S2-2 OTA 资产分发单测：本地 HttpServer 扮演分发源，覆盖 manifest 分发、
/// sha256/尺寸校验、≥5GB 磁盘门禁、staging 原子替换、驱动指纹漂移脏删重拉
/// （NPU 稿 §4.5/§4.6/§4.8）。
void main() {
  late Directory supportDir;
  late HttpServer server;
  late String base;

  // 分发源内容：两个「文件」，小体积即可覆盖全链路。
  final fileA = Uint8List.fromList(List.generate(1024, (i) => i % 256));
  final fileB = Uint8List.fromList(utf8.encode('tokenizer-fixture'));
  final shaA = sha256.convert(fileA).toString();
  final shaB = sha256.convert(fileB).toString();

  /// 分发源行为开关（各用例自行改写）。
  var serveTruncatedA = false;
  var corruptShaA = false;
  var fingerprint = 'rom-fp-v1';

  setUp(() async {
    supportDir = await Directory.systemTemp.createTemp('asset-mgr-test');
    serveTruncatedA = false;
    corruptShaA = false;
    fingerprint = 'rom-fp-v1';
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((req) async {
      final name = req.uri.pathSegments.last;
      Uint8List body;
      if (name == 'manifest.json') {
        body = Uint8List.fromList(utf8.encode(jsonEncode({
          'version': 'v1',
          'files': [
            {'name': 'model.bin', 'size': fileA.length, 'sha256': shaA},
            {'name': 'tokenizer.json', 'size': fileB.length, 'sha256': shaB},
          ],
        })));
      } else if (name == 'model.bin') {
        body = corruptShaA
            ? Uint8List.fromList([0xAB, ...fileA.skip(1)])
            : fileA;
        if (serveTruncatedA) body = Uint8List.fromList(fileA.sublist(0, 100));
      } else if (name == 'tokenizer.json') {
        body = fileB;
      } else {
        req.response.statusCode = 404;
        await req.response.close();
        return;
      }
      // serveTruncatedA 时谎报 Content-Length 之外的实际长度由 body 决定；
      // 校验链应双路拦截（Content-Length 与 manifest 尺寸）。
      req.response.contentLength = body.length;
      req.response.add(body);
      await req.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    await supportDir.delete(recursive: true);
  });

  OnDeviceAssetManager mgr({int? freeBytes}) => OnDeviceAssetManager.forTest(
        baseUrlOverride: base,
        freeBytesProvider: () async => freeBytes,
        fingerprintProvider: () async => fingerprint,
        supportDirResolver: () async => supportDir,
      );

  /// 显式装载目标（2026-10-31 纯导入制无默认模型：ensureAssets 不再接受
  /// 无参调用偷偷拉 1.7B，测试必须给目标）。base 用 setUp 里的 mock 源。
  /// （main 函数体内不能声明 getter → 局部函数，每次取最新 [base]。）
  OnDeviceModelOption testModel() => OnDeviceModelOption(
        id: 'test-1b',
        displayName: 'Test（测试）',
        base: base,
        dirName: 'qwen3_1_7b-geniex_qairt-w4a16',
      );

  Directory modelDir() =>
      Directory('${supportDir.path}/models/qwen3_1_7b-geniex_qairt-w4a16');

  test('全量下载：落盘 + meta 版本/尺寸/sha256/指纹齐备 + 幂等跳过', () async {
    final dir = await mgr(freeBytes: 10 << 30).ensureAssets(model: testModel());
    if (dir == null) fail('ensureAssets should succeed');
    expect(await File('${dir.path}/model.bin').readAsBytes(), fileA);
    expect(await File('${dir.path}/tokenizer.json').readAsBytes(), fileB);

    final meta =
        jsonDecode(await File('${dir.path}/.asset-meta.json').readAsString())
            as Map<String, dynamic>;
    expect(meta['version'], 'v1');
    expect(meta['driverFingerprint'], 'rom-fp-v1');
    expect((meta['sizes'] as Map)['model.bin'], fileA.length);
    expect((meta['sha256'] as Map)['model.bin'], shaA);

    // 幂等：二轮不再下载（关掉源，仍能返回已装目录）。
    await server.close(force: true);
    final again = await mgr(freeBytes: 10 << 30).ensureAssets(model: testModel());
    expect(again, isNotNull);
    expect(await File('${again!.path}/model.bin').exists(), isTrue);
  });

  test('Content-Length 截断拒收：不落盘不转正（staging 残留被清）', () async {
    serveTruncatedA = true;
    final dir = await mgr(freeBytes: 10 << 30).ensureAssets(model: testModel());
    expect(dir, isNull);
    expect(await modelDir().exists(), isFalse);
  });

  test('sha256 不符拒收（Content-Length 合法但内容损坏）', () async {
    corruptShaA = true;
    final dir = await mgr(freeBytes: 10 << 30).ensureAssets(model: testModel());
    expect(dir, isNull);
    expect(await modelDir().exists(), isFalse);
  });

  test('磁盘门禁：余量 < 5GB 直接中止，不建目录不发请求', () async {
    final dir = await mgr(freeBytes: 4 << 30).ensureAssets(model: testModel());
    expect(dir, isNull);
    expect(await Directory('${supportDir.path}/models').exists(), isFalse);
  });

  test('热更新原子替换：旧版本在位时新版本整包换装，无残留 staging/trash', () async {
    final dir = await mgr(freeBytes: 10 << 30).ensureAssets(model: testModel());
    expect(dir, isNotNull);

    // 模拟 :engine 持旧句柄：打开旧文件不放（rename 后旧 inode 仍可读）。
    final oldHandle =
        File('${modelDir().path}/model.bin').openSync(mode: FileMode.read);

    // 源翻版 v2（tokenizer 变更 + 同版本绑定校验）。
    final fileB2 = Uint8List.fromList(utf8.encode('tokenizer-fixture-v2'));
    final shaB2 = sha256.convert(fileB2).toString();
    await server.close(force: true);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((req) async {
      final name = req.uri.pathSegments.last;
      final body = name == 'tokenizer.json'
          ? fileB2
          : name == 'model.bin'
              ? fileA
              : Uint8List.fromList(utf8.encode(jsonEncode({
                  'version': 'v2',
                  'files': [
                    {'name': 'model.bin', 'size': fileA.length, 'sha256': shaA},
                    {'name': 'tokenizer.json', 'size': fileB2.length, 'sha256': shaB2},
                  ],
                })));
      req.response.contentLength = body.length;
      req.response.add(body);
      await req.response.close();
    });

    final dir2 = await mgr(freeBytes: 10 << 30).ensureAssets(model: testModel());
    expect(dir2, isNotNull);
    expect(await File('${dir2!.path}/tokenizer.json').readAsBytes(), fileB2);
    // 旧句柄（旧 inode）不受替换影响——SIGBUS 防护的语义面。
    expect(oldHandle.lengthSync(), fileA.length);
    oldHandle.closeSync();

    final modelsRoot = Directory('${supportDir.path}/models');
    final leftovers = await modelsRoot
        .list()
        .where((e) =>
            e.path.contains('.staging-') || e.path.contains('.trash-'))
        .toList();
    expect(leftovers, isEmpty);
  });

  test('驱动指纹漂移：recoverIfDriverChanged 脏删，下轮 ensureAssets 整包重拉', () async {
    final dir = await mgr(freeBytes: 10 << 30).ensureAssets(model: testModel());
    expect(dir, isNotNull);

    // 系统 OTA：ROM 指纹变化。
    fingerprint = 'rom-fp-v2-after-ota';
    final changed = await mgr(freeBytes: 10 << 30).recoverIfDriverChanged(model: testModel());
    expect(changed, isTrue);
    expect(await modelDir().exists(), isFalse);

    // 重拉成功（源仍是 v1，指纹记录为新值）。
    final refetched = await mgr(freeBytes: 10 << 30).ensureAssets(model: testModel());
    expect(refetched, isNotNull);
    final meta =
        jsonDecode(await File('${refetched!.path}/.asset-meta.json').readAsString())
            as Map<String, dynamic>;
    expect(meta['driverFingerprint'], 'rom-fp-v2-after-ota');
  });

  test('markDirty：静默删除已装资产（§4.8 自愈入口，不计熔断——本件不触熔断器）', () async {
    final dir = await mgr(freeBytes: 10 << 30).ensureAssets(model: testModel());
    expect(dir, isNotNull);
    await mgr(freeBytes: 10 << 30).markDirty(model: testModel());
    expect(await modelDir().exists(), isFalse);
  });

  test('manifest 不可达：已装资产兜底放行（不误判重下 1.8GB）', () async {
    final dir = await mgr(freeBytes: 10 << 30).ensureAssets(model: testModel());
    expect(dir, isNotNull);
    await server.close(force: true);
    final fallback = await mgr(freeBytes: 10 << 30).ensureAssets(model: testModel());
    expect(fallback, isNotNull);
    expect(await File('${fallback!.path}/model.bin').exists(), isTrue);
  });
}
