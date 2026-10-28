/// 调用主体一级值对象（施工稿 `docs/design/arch-consolidation.md` §S6）。
///
/// **推导纪律（coding-standards §6.2）**：主体**只在鉴权层推导**——
/// Bearer 配对 Token / Binder 同签名 / 信任白名单；**严禁从请求载荷字段读取**
/// （否则外部 AI 在 JSON 里自称 `"actor":"local"` 即越权）。
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

  /// 展示标签（排查卡 / 错误文案用）。
  String get label => switch (this) {
        _OwnerActor() => 'owner',
        _ExternalActor(:final id) => 'external:$id',
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
