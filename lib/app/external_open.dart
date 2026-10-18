/// 资源中心外部唤起（resource-center M1-T2，RC6 纯外部唤起）。
///
/// 平台调用收敛装配域（coding-standards §1.3：平台通道统一 lib/app 注入，
/// UI 层只持注入位回调）；open_filex 先例 = `lib/update/installer.dart`。
/// 传入路径由 `ResourceStore.prepareExternalOpen` 产出（cacheDir/external
/// 唯一临时副本，绝不暴露库内实体原身）。
library;

import 'package:open_filex/open_filex.dart';

/// 用系统默认应用打开 [path]（外部唤起唯一入口）。
///
/// 打开失败抛 [ExternalOpenException]（带系统结果 message），调用方按
/// flash/错误行口径呈现——禁静默吞。
Future<void> openExternalPath(String path) async {
  final result = await OpenFilex.open(path);
  if (result.type != ResultType.done) {
    throw ExternalOpenException(result.message);
  }
}

/// 外部唤起失败（系统无默认应用 / 权限拒绝 / 平台错误）。
class ExternalOpenException implements Exception {
  const ExternalOpenException(this.message);

  final String message;

  @override
  String toString() => '外部打开失败: $message';
}
