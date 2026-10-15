import 'dart:async';
import 'dart:developer';
import 'dart:io';
import 'dart:isolate';
import 'package:dio/dio.dart';

/// 下载 worker isolate 入口：承载 LLM 模型包的字节拉取（网络 + 磁盘 I/O），
/// 让 main isolate 不被 1.5GB 写入与进度回调拖累（轻量版「后台下载」）。
/// （M2 自 goodshare 随迁，2026-10-10）
///
/// 协议：main → isolate 发 `cmd`；isolate → main 回 `type`，均用可序列化的 Map。
/// 注意：spawn 出的 isolate **不可用 platform channel**（path_provider 等），
/// 故路径 / URL 由 main 预先算好以字符串传入；Dio 与 dart:io 在 isolate 内可用。
///
/// 断点续传逻辑（`.part` 留痕 + `Range` 续拉 + 落盘大小校验防翻倍/截断）完整保留，
/// 与原 main 侧实现等价，仅执行线程不同。

// 活跃任务的取消令牌（isolate 内维护，供 cancel 指令命中）
final Map<String, CancelToken> _activeCancels = {};

/// 下载 worker isolate 入口：接收 main 侧发来的指令并回传进度/完成/错误。
/// 公开（非 `_` 前缀）以便 [LlmModelManager] 经 import 跨库引用。
void downloaderEntry(SendPort mainSend) {
  final recv = ReceivePort();
  mainSend.send(recv.sendPort); // 回传 isolate 的 SendPort 给 main
  recv.listen((msg) async {
    if (msg is! Map) return;
    final cmd = msg['cmd'];
    if (cmd == 'download') {
      await _runDownload(
        sendPort: mainSend,
        id: msg['id'] as String,
        url: msg['url'] as String,
        partPath: msg['partPath'] as String,
        sizeBytes: msg['sizeBytes'] as int,
        existingBytes: msg['existingBytes'] as int? ?? 0,
        resume: msg['resume'] as bool? ?? false,
      );
    } else if (cmd == 'cancel') {
      _activeCancels[msg['id'] as String]?.cancel('user cancelled');
    }
  });
}

Future<void> _runDownload({
  required SendPort sendPort,
  required String id,
  required String url,
  required String partPath,
  required int sizeBytes,
  required int existingBytes,
  required bool resume,
}) async {
  final dio = Dio(BaseOptions(
    followRedirects: true,
    connectTimeout: const Duration(seconds: 30),
    receiveTimeout: const Duration(minutes: 30),
  ));
  final cancel = CancelToken();
  _activeCancels[id] = cancel;

  // 单次拉取：resume=true 时从已有片段续拉（append + Range），否则整文件重写。
  Future<void> fetch(bool r) async {
    final existing =
        r && await File(partPath).exists() ? await File(partPath).length() : 0;
    await dio.download(
      url,
      partPath,
      cancelToken: cancel,
      deleteOnError: false, // 保留 .part 以便续传
      fileAccessMode: r ? FileAccessMode.append : FileAccessMode.write,
      options: Options(
        headers: r && existing > 0 ? {'Range': 'bytes=$existing-'} : null,
      ),
      onReceiveProgress: (recv, _) {
        if (sizeBytes > 0) {
          sendPort.send({
            'type': 'progress',
            'id': id,
            'value': (existing + recv) / sizeBytes,
          });
        }
      },
    );
  }

  try {
    final hasPart =
        await File(partPath).exists() && await File(partPath).length() > 0;
    await fetch(hasPart);
    // 校验：Range 未生效（翻倍/截断）则清片段从头重下
    if (await File(partPath).length() != sizeBytes) {
      await File(partPath).delete();
      await fetch(false);
    }
    if (await File(partPath).length() != sizeBytes) {
      throw Exception('下载文件大小校验失败（期望 $sizeBytes，'
          '实际 ${await File(partPath).length()} 字节）');
    }
    sendPort.send({'type': 'done', 'id': id});
  } on DioException catch (e) {
    if (CancelToken.isCancel(e)) {
      // 用户取消：.part 片段保留，下次 download 自动续传；不视为错误
      sendPort.send({'type': 'cancelled', 'id': id});
      return;
    }
    // gated 仓库（Gemma 系）经镜像会 403/401——给出可行动原因（R1：错误要被感知且明说）。
    final code = e.response?.statusCode;
    if (code == 403 || code == 401) {
      sendPort.send({
        'type': 'error',
        'id': id,
        'message': '该模型在 gated 仓库（需先在 huggingface.co 模型页登录并接受 Gemma 条款），'
            '直连与镜像都无法下载；将经自托管 R2 中转'
      });
      return;
    }
    sendPort.send({'type': 'error', 'id': id, 'message': e.toString()});
  } catch (e) {
    // DEGRADE: 下载失败属用户可重试动作，状态复位即可；不静默吞——main 侧展示错误。
    // .part 片段已保留（deleteOnError:false），下次 download 自动续传。
    log('[LlmDownloadIsolate] download failed ($id): $e');
    sendPort.send({'type': 'error', 'id': id, 'message': e.toString()});
  } finally {
    _activeCancels.remove(id);
  }
}
