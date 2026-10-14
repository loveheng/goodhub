#!/bin/bash
# check-same-signature — §5 签名一致性门禁（#9 D.1）：比对两个 APK 的签名证书 SHA-256
#   指纹是否一致。同签名 = 本地插件 signature 权限 bind 的前提（goodshare↔goodhub 同机
#   同一 debug keystore 构建，或共享受控 release keystore）。不一致 → bind 必
#   SecurityException，#10 联调阻塞。
#
# 工具选型：用 apksigner（Android SDK build-tools）而非 keytool。#9 §5 D.1 原文写的
#   `keytool -printcert -jarfile` 只认 v1(JAR) 签名块；Flutter APK 走 v2/v3 签名方案时
#   该命令报「不是已签名的 jar 文件」→ 提取失败（真机联调实测踩中）。apksigner 才是 APK
#   证书的权威工具（v1/v2/v3 全覆盖）。
#
# toolbox-script
# format: v1
# name: check-same-signature
# summary: §5 门禁 D.1——apksigner 比对两 APK 证书 SHA-256 指纹，给同/异签名结论与非零退出码
# trigger: manual
# platform: unix
# alias: sig-check

set -euo pipefail
export ANDROID_HOME="${ANDROID_HOME:-$HOME/android-sdk}"

usage() {
  cat <<'EOF'
用法: check-same-signature.sh <apkA> <apkB>
  apksigner verify --print-certs 分别提取两 APK 的全部签名证书 SHA-256 指纹，
  去重排序后比对。一致 → 打印 SAME 并以 0 退出；不一致/提取失败 → 非零。
典型用途（#9 §5 D.1，联调前双方各跑一次）:
  check-same-signature.sh build/app/outputs/flutter-apk/app-debug.apk /path/to/goodshare.apk
选项:
  --self-test   用样例 apksigner 输出自校验指纹提取逻辑（无需真实 APK）
  --json        环境预检（apksigner/JDK 是否可用），一行 JSON 结论
  -h, --help    本帮助
退出码: 0=同签名  1=异签名/提取失败  2=用法/环境错误
EOF
}

precheck_json() {
  if ! locate_apksigner >/dev/null 2>&1; then
    printf '{"status":"FAIL","severity":"error","message":"apksigner 不可用","remedy":"确认 ANDROID_HOME 指向 Android SDK（build-tools/*/apksigner）且已装 JDK"}\n'
    exit 1
  fi
  printf '{"status":"OK","severity":"info","message":"apksigner 可用：%s"}\n' "$(locate_apksigner)"
  exit 0
}

# 定位 apksigner：先 PATH，再 build-tools 取最新版。
locate_apksigner() {
  if command -v apksigner >/dev/null 2>&1; then command -v apksigner; return 0; fi
  local a
  a="$(ls -1 "$ANDROID_HOME"/build-tools/*/apksigner 2>/dev/null | sort | tail -1)"
  [ -n "$a" ] && { echo "$a"; return 0; }
  return 1
}

# 从 stdin 的 `apksigner verify --print-certs` 输出提取全部 SHA-256 指纹：
# 仅取 "SHA-256 digest" 行（SHA-1 行为 40 hex、DN 行无 64 hex，均不匹配 {64}），
# 抽 64 位十六进制 → 转小写 → 去重排序。
extract_sha256() {
  grep -iE 'SHA-?256 digest' \
    | grep -oiE '[0-9a-f]{64}' \
    | tr 'A-Z' 'a-z' | sort -u
}

# 提取单个 APK 的全部签名证书 SHA-256 指纹集合（空 = 未签到/非 APK/解析失败）。
# `|| true` 吸收 apksigner/grep 的非零退出，避免 set -e/pipefail 提前终止。
apk_sha256() {
  local signer; signer="$(locate_apksigner)" || return 0
  { "$signer" verify --print-certs "$1" 2>/dev/null | extract_sha256; } || true
}

self_test() {
  # 样例含 DN + SHA-256 + SHA-1 行、两个 signer（模拟 apksigner 多证书输出）：
  # 应只抽出两条 SHA-256 且去重排序，SHA-1/DN 行被忽略。
  local sample expected actual rc=0
  sample="$(printf '%s\n' \
    'Signer #1 certificate DN: C=US, O=Android, CN=Android Debug' \
    'Signer #1 certificate SHA-256 digest: 112233445566778899aabbccddeeff00112233445566778899aabbccddeeff00' \
    'Signer #1 certificate SHA-1 digest: 0a1b2c3d4e5f60718293a4b5c6d7e8f900112233' \
    'Signer #2 certificate DN: C=US, O=Android, CN=Android Debug' \
    'Signer #2 certificate SHA-256 digest: aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899' \
    'Signer #2 certificate SHA-1 digest: 0a1b2c3d4e5f60718293a4b5c6d7e8f900112233')"
  expected="$(printf '%s\n' \
    '112233445566778899aabbccddeeff00112233445566778899aabbccddeeff00' \
    'aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899')"
  actual="$(printf '%s' "$sample" | extract_sha256 || true)"
  if [ "$actual" = "$expected" ]; then
    echo "self-test PASS: SHA-256 提取/去重排序正确（SHA-1/DN 行已忽略）"
  else
    echo "self-test FAIL"
    echo "--- expected ---"; echo "$expected"
    echo "--- actual ---"; echo "$actual"
    rc=1
  fi
  return $rc
}

case "${1:-}" in
  --self-test) self_test; exit $? ;;
  --json) precheck_json ;;
  -h|--help) usage; exit 0 ;;
esac

[ $# -eq 2 ] || { echo "FAIL: 需两个 APK 路径"; usage; exit 2; }
for f in "$1" "$2"; do
  [ -f "$f" ] || { echo "FAIL: APK 不存在: $f"; exit 2; }
done
locate_apksigner >/dev/null 2>&1 || { echo "FAIL: apksigner 不可用（需 Android SDK build-tools + JDK）"; exit 2; }

FA="$(apk_sha256 "$1")"
FB="$(apk_sha256 "$2")"

echo "A: $1"
[ -n "$FA" ] && echo "$FA" | sed 's/^/    /' || echo "    (未提取到 SHA-256)"
echo "B: $2"
[ -n "$FB" ] && echo "$FB" | sed 's/^/    /' || echo "    (未提取到 SHA-256)"

if [ -z "$FA" ] || [ -z "$FB" ]; then
  echo "MISMATCH: 无法提取 SHA-256 指纹（APK 未签名 / 非 APK / apksigner 输出异常）"
  exit 1
fi
if [ "$FA" = "$FB" ]; then
  echo "SAME: 两 APK 签名证书 SHA-256 一致 → 同签名（#9 §5 D.1 通过，bind 可过 signature 权限）"
  exit 0
else
  echo "MISMATCH: 两 APK 签名证书 SHA-256 不一致 → 异签名（bind 必 SecurityException）"
  exit 1
fi
