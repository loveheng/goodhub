/// 自更新服务单测：更新源解析 / 清单 URI 归一 / 未配置源拒绝 / 清单拉取与
/// 解析 / APK 流式下载的 sha256 校验（成功与篡改两条）+ 进度回调。
///
/// 不触网：清单与 APK 均由本地回环 HttpServer 供给（端口 0 自动分配）。
/// 串包防御（清单带 applicationId）的比对分支依赖 PackageInfo 平台通道，
/// 单测只覆盖「旧清单无 applicationId → 宽容跳过」路径，真机侧载验证。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:goodhub/update/update_manifest.dart';
import 'package:goodhub/update/update_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<HttpServer> _serve({
  String body = '',
  List<int>? bytes,
  int status = 200,
}) async {
  final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  s.listen((req) async {
    final res = req.response;
    res.statusCode = status;
    if (bytes != null) {
      res.add(bytes);
    } else {
      res.write(body);
    }
    await res.close();
  });
  return s;
}

String _sha256(List<int> bytes) => crypto.sha256.convert(bytes).toString();

void main() {
  late Directory tmp;
  final servers = <HttpServer>[];

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tmp = await Directory.systemTemp.createTemp('goodhub-upd');
  });

  tearDown(() async {
    for (final s in servers) {
      await s.close(force: true);
    }
    servers.clear();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<HttpServer> serve({
    String body = '',
    List<int>? bytes,
    int status = 200,
  }) async {
    final s = await _serve(body: body, bytes: bytes, status: status);
    servers.add(s);
    return s;
  }

  group('更新源', () {
    test('未配置且无内置源 → sourceUrl 为 null', () async {
      final prefs = await SharedPreferences.getInstance();
      final svc = UpdateService(prefs);
      expect(await svc.sourceUrl(), isNull);
    });

    test('无用户配置时回退编译期内置源', () async {
      final prefs = await SharedPreferences.getInstance();
      final svc = UpdateService(prefs, defaultSourceUrl: 'https://example.com/u');
      expect(await svc.sourceUrl(), 'https://example.com/u');
    });

    test('用户配置优先于内置源', () async {
      final prefs = await SharedPreferences.getInstance();
      final svc = UpdateService(prefs, defaultSourceUrl: 'https://example.com/u');
      await svc.setSourceUrl('https://user.example.com/u');
      expect(await svc.sourceUrl(), 'https://user.example.com/u');
    });

    test('非法 URL 拒绝（非 http(s) scheme）', () async {
      final prefs = await SharedPreferences.getInstance();
      final svc = UpdateService(prefs);
      expect(
        () => svc.setSourceUrl('ftp://example.com/u'),
        throwsA(isA<UpdateException>()),
      );
    });

    test('置空即清除用户配置', () async {
      final prefs = await SharedPreferences.getInstance();
      final svc = UpdateService(prefs, defaultSourceUrl: 'https://example.com/u');
      await svc.setSourceUrl('https://user.example.com/u');
      await svc.setSourceUrl('  ');
      expect(await svc.sourceUrl(), 'https://example.com/u');
    });
  });

  group('清单', () {
    test('manifestUri 归一尾斜杠', () async {
      final prefs = await SharedPreferences.getInstance();
      final svc = UpdateService(prefs);
      expect(
        svc.manifestUri('https://example.com/u').toString(),
        'https://example.com/u/goodhub-update.json',
      );
      expect(
        svc.manifestUri('https://example.com/u/').toString(),
        'https://example.com/u/goodhub-update.json',
      );
    });

    test('未配置更新源 → 拒绝（不触网）', () async {
      final prefs = await SharedPreferences.getInstance();
      final svc = UpdateService(prefs);
      expect(
        svc.check(),
        throwsA(isA<UpdateException>()),
      );
    });

    test('拉取并解析清单（旧清单无 applicationId → 宽容跳过身份比对）', () async {
      final s = await serve(body: jsonEncode({
        'versionCode': 2004,
        'versionName': 'v1.0.2',
        'apkUrl': 'https://example.com/app.apk',
        'sha256': 'deadbeef',
        'changelog': '修复若干问题',
      }));
      final prefs = await SharedPreferences.getInstance();
      final svc = UpdateService(prefs);
      await svc.setSourceUrl('http://127.0.0.1:${s.port}');
      final m = await svc.check();
      expect(m.versionCode, 2004);
      expect(m.versionName, 'v1.0.2');
      expect(m.sha256, 'deadbeef');
      expect(m.applicationId, isNull); // 旧清单宽容路径
    });

    test('非 200 → UpdateException', () async {
      final s = await serve(body: 'nope', status: 404);
      final prefs = await SharedPreferences.getInstance();
      final svc = UpdateService(prefs);
      await svc.setSourceUrl('http://127.0.0.1:${s.port}');
      expect(svc.check(), throwsA(isA<UpdateException>()));
    });
  });

  group('APK 下载与校验', () {
    test('sha256 一致 → 落盘并上报进度', () async {
      final payload = utf8.encode('fake-apk-bytes');
      final s = await serve(bytes: payload);
      final prefs = await SharedPreferences.getInstance();
      final svc = UpdateService(prefs);
      final progress = <int>[];
      final file = await svc.downloadApk(
        'http://127.0.0.1:${s.port}/app.apk',
        expectedSha256: _sha256(payload),
        to: tmp,
        onProgress: (received, _) => progress.add(received),
      );
      expect(await file.readAsBytes(), payload);
      expect(progress.last, payload.length); // 终帧进度 = 总长
      expect(file.path, endsWith('.apk')); // part 已 rename
      expect(File('${tmp.path}/update.apk.part').existsSync(), isFalse);
    });

    test('sha256 不一致 → 拒绝并删除半成品（防篡改/不完整）', () async {
      final payload = utf8.encode('fake-apk-bytes');
      final s = await serve(bytes: payload);
      final prefs = await SharedPreferences.getInstance();
      final svc = UpdateService(prefs);
      expect(
        () => svc.downloadApk(
          'http://127.0.0.1:${s.port}/app.apk',
          expectedSha256: '0' * 64,
          to: tmp,
        ),
        throwsA(isA<UpdateException>()),
      );
      expect(File('${tmp.path}/update.apk.part').existsSync(), isFalse);
    });

    test('未给期望 sha256 → 不校验但照常落盘（旧清单路径）', () async {
      final payload = utf8.encode('another-apk');
      final s = await serve(bytes: payload);
      final prefs = await SharedPreferences.getInstance();
      final svc = UpdateService(prefs);
      final file = await svc.downloadApk(
        'http://127.0.0.1:${s.port}/app.apk',
        to: tmp,
      );
      expect(await file.readAsBytes(), payload);
    });

    test('下载取消（ux-hardening P0-3）：isCancelled 命中即中止——半成品删除、'
        '抛 UpdateCancelled（取消≠失败）', () async {
      // 慢速分块响应：让 isCancelled 在第一个 chunk 之后有机会命中。
      final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      servers.add(s);
      s.listen((req) async {
        final res = req.response;
        res.statusCode = 200;
        for (var i = 0; i < 20; i++) {
          res.add(List<int>.filled(64, i));
          await res.flush();
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        await res.close();
      });
      final prefs = await SharedPreferences.getInstance();
      final svc = UpdateService(prefs);
      var cancelled = false;
      expect(
        () => svc.downloadApk(
          'http://127.0.0.1:${s.port}/app.apk',
          to: tmp,
          onProgress: (received, _) {
            if (received >= 64) cancelled = true; // 首 chunk 后置取消
          },
          isCancelled: () => cancelled,
        ),
        throwsA(isA<UpdateCancelled>()),
      );
      expect(File('${tmp.path}/update.apk.part').existsSync(), isFalse,
          reason: '取消即删半成品，不留残留');
    });

    test('HTTP 404 → 立即 UpdateException（状态码前置检查钉）', () async {
      final s = await serve(status: 404, body: 'not found');
      final prefs = await SharedPreferences.getInstance();
      final svc = UpdateService(prefs);
      await expectLater(
        svc.downloadApk('http://127.0.0.1:${s.port}/app.apk', to: tmp),
        throwsA(isA<UpdateException>()
            .having((e) => e.message, 'message', contains('HTTP 404'))),
      );
    });

    test('响应头挂起（服务器收请求不回应）→ httpTimeout 内抛超时，不再永挂', () async {
      final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      servers.add(s);
      s.listen((req) async {
        // 永不写响应头/体——复现 2026-11-07 真机 R2 404 流挂起形态。
        await Completer<void>().future.timeout(const Duration(minutes: 5));
      });
      final prefs = await SharedPreferences.getInstance();
      final svc = UpdateService(prefs, httpTimeout: const Duration(milliseconds: 300));
      final sw = Stopwatch()..start();
      await expectLater(
        svc.downloadApk('http://127.0.0.1:${s.port}/app.apk', to: tmp),
        throwsA(isA<UpdateException>()
            .having((e) => e.message, 'message', contains('下载超时'))),
      );
      expect(sw.elapsed.inSeconds, lessThan(5), reason: '超时须短平快，不等服务器');
    });

    test('响应体半途 stall（发了部分字节后挂起）→ 无推进看门狗超时', () async {
      final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      servers.add(s);
      s.listen((req) async {
        final res = req.response;
        res.statusCode = 200;
        res.add(List<int>.filled(64, 1)); // 先给一个 chunk
        await res.flush();
        await Completer<void>().future.timeout(const Duration(minutes: 5));
      });
      final prefs = await SharedPreferences.getInstance();
      final svc = UpdateService(prefs, httpTimeout: const Duration(milliseconds: 300));
      await expectLater(
        svc.downloadApk('http://127.0.0.1:${s.port}/app.apk', to: tmp),
        throwsA(isA<UpdateException>()
            .having((e) => e.message, 'message', contains('无数据推进'))),
      );
    });

    test('清单拉取：响应头挂起 → check() 超时抛 UpdateException（同族挂起点）', () async {
      final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      servers.add(s);
      s.listen((req) async {
        await Completer<void>().future.timeout(const Duration(minutes: 5));
      });
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('update_source_url',
          'http://127.0.0.1:${s.port}'); // 回环 http 豁免合法
      final svc = UpdateService(prefs, httpTimeout: const Duration(milliseconds: 300));
      await expectLater(
        svc.check(),
        throwsA(isA<UpdateException>()
            .having((e) => e.message, 'message', contains('清单拉取超时'))),
      );
    });
  });
}
