/// 调用主体一级值对象（施工稿 `docs/design/arch-consolidation.md` §S6）。
///
/// **推导纪律（coding-standards §6.2）**：主体**只在鉴权层推导**——
/// Bearer 配对 Token / Binder 同签名 / 信任白名单；**严禁从请求载荷字段读取**
/// （否则外部 AI 在 JSON 里自称 `"actor":"local"` 即越权）。
///
/// **主体粒度（task-capability W1-S06 修订）**：owner（宿主用户）/
/// external（通道级外部调用方）/ app（同机调用方 App 身份档：包名 + 签名
/// 指纹，字段判据与信任白名单 `PluginTrustGate.isTrusted` 同源）。app 档
/// 由平台侧鉴权层解析调用方进程身份后构造（W1-S07b），载荷自声明不采信。
///
/// **与投影正交**：主体是**每请求动态**的运行时裁决维度；`policy` 投影与
/// `assemble(profile)` 的能力上限（§S2）是场景级——三层各管各的，不得合并。
library;

/// 调用主体。
sealed class Actor {
  const Actor();

  /// 宿主本机用户（聊天 UI 发起的调用）。
  static const Actor owner = _OwnerActor();

  /// 经接入通道进来的外部调用方：[id] = 通道标识（如 `gateway` / Binder 包名）。
  /// **身份粒度随鉴权层演进**（当前配对 Token = 单一共享凭证，粒度即通道级；
  /// UID 白名单落地后细化到 app 级）。
  const factory Actor.external(String id) = _ExternalActor;

  /// 同机调用方 App 身份档（W1-S06）：[packageName] + [signatureSha256]，
  /// 与信任白名单判据同源（`trusted_plugins.dart` 的包名 + sha256 字段形状）。
  /// **只在鉴权层推导**（Android 侧经调用方 Binder 进程身份解析，S07b），
  /// 严禁从请求载荷构造。
  const factory Actor.app({
    required String packageName,
    String signatureSha256,
  }) = _AppActor;

  /// 展示标签（排查卡 / 错误文案用）。
  String get label => switch (this) {
        _OwnerActor() => 'owner',
        _ExternalActor(:final id) => 'external:$id',
        _AppActor(:final packageName) => 'app:$packageName',
      };

  @override
  String toString() => 'Actor($label)';
}

class _OwnerActor extends Actor {
  const _OwnerActor();

  @override
  bool operator ==(Object other) => other is _OwnerActor;

  @override
  int get hashCode => 'owner'.hashCode;
}

class _ExternalActor extends Actor {
  const _ExternalActor(this.id);

  final String id;

  @override
  bool operator ==(Object other) => other is _ExternalActor && other.id == id;

  @override
  int get hashCode => Object.hash('external', id);
}

class _AppActor extends Actor {
  const _AppActor({required this.packageName, this.signatureSha256 = ''});

  /// 调用方包名（鉴权层解析；判据与信任白名单同源）。
  final String packageName;

  /// 调用方签名指纹（sha256；空 = 鉴权层无指纹数据，信任判定按包名口径）。
  final String signatureSha256;

  @override
  bool operator ==(Object other) =>
      other is _AppActor &&
      other.packageName == packageName &&
      other.signatureSha256 == signatureSha256;

  @override
  int get hashCode => Object.hash('app', packageName, signatureSha256);
}
