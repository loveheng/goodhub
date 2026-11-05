package com.zzh.goodhub

import android.content.Context
import android.content.pm.PackageManager
import android.util.Log
import java.security.MessageDigest

/**
 * 调用方进程身份解析（task-capability W1-S07/S07b）：
 * 宿主作服务端接受同机 App 反向调用时，经 Binder 内核传来的**调用方 UID**
 * 解析包名 + 签名指纹，回填 Dart 侧 [com.zzh.goodhub] Actor.app 身份档。
 *
 * 红线（S07b）：身份**只从内核进程身份（UID）推导**，严禁从请求载荷字段读取
 * ——载荷自声明即允许冒充任意包名，使信任白名单与授权矩阵同时失效；
 * 解析失败（无包名 / PM 异常）返回 null，调用方按**拒绝**处置，不按匿名放行。
 *
 * 消费时点：反向 Binder 通道落地时（W4 形态 A 多来源 / W5 跨 App 转发）在
 * onTransact / Service 回调内以 `Binder.getCallingUid()` 调用本件；宿主进程
 * 内调用（own uid）同样走本链，不设捷径（防自声明旁路）。
 */
object CallerIdentityResolver {

    private const val TAG = "CallerIdentity"

    /** 已解析的调用方身份（字段判据与信任白名单 PluginTrustGate 同源：包名 + sha256）。 */
    data class CallerIdentity(
        val packageName: String,
        val signatureSha256: String,
    )

    /**
     * UID → 调用方身份。解析失败返回 null（调用方按拒绝处置，禁匿名放行）。
     *
     * - 包名：`getPackagesForUid`（共享 uid 多包场景取首个——Android 共享 uid
     *   须 sharedUserId 且签名一致，同 uid 即同信任域，取首包无越权面）；
     * - 指纹：`GET_SIGNING_CERTIFICATES` 取签名证书首枚 → SHA-256 十六进制串
     *   （与 BinderTransport.ownSignatureSha256 同口径，同签名判定可比对）。
     */
    fun resolve(context: Context, callingUid: Int): CallerIdentity? {
        return try {
            val pm = context.packageManager
            val packages = pm.getPackagesForUid(callingUid)
            if (packages.isNullOrEmpty()) {
                Log.w(TAG, "resolve: no package for uid=$callingUid → deny")
                return null
            }
            val pi = runCatching {
                pm.getPackageInfo(packages[0], PackageManager.GET_SIGNING_CERTIFICATES)
            }.getOrNull()
            val sha = pi?.signingInfo?.apkContentsSigners
                ?.firstOrNull()?.toByteArray()
                ?.let { sha256Hex(it) } ?: ""
            Log.i(TAG, "resolve: uid=$callingUid → ${packages[0]} (sigSha256=${if (sha.isEmpty()) "<empty>" else "${sha.take(12)}…"})")
            CallerIdentity(packageName = packages[0], signatureSha256 = sha)
        } catch (e: Throwable) {
            Log.w(TAG, "resolve uid=$callingUid failed: $e → deny")
            null
        }
    }

    /** SHA-256 十六进制串（与 BinderTransport.sha256Hex 同算法口径）。 */
    fun sha256Hex(bytes: ByteArray): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
        return digest.joinToString("") { "%02x".format(it) }
    }
}
