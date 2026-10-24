#!/bin/bash
# release-r2 — goodhub 一键发布到 Cloudflare R2（应用内自更新源）
# 同款移植自 goodshare scripts/release-r2.sh（self-update epic，2026-10-14）
#
# 流程: 读 pubspec 版本 → flutter build apk --release（仅 arm64-v8a，注入 UPDATE_SOURCE_URL）
#       → 算 sha256 → 生成 updates/goodhub-update.json → 上传 apk+json 到 R2 公开域
#
# 前置:
#   1) Cloudflare 后台对该 bucket 开启「公开访问」并绑定自定义域（如 update.example.com），
#      确保 https://<域>/updates/... 可公开 GET（r2.dev 默认域有限速，不建议作生产更新源）
#   2) 在仓库根 .env（参考 .env.example）或环境变量中配置 R2_* 与域名
#
# 用法: bash scripts/release-r2.sh [-n|--dry-run] [--commit]
#   --commit   发布成功后把 updates/goodhub-update.json 提交进仓库（便于追溯）
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# 加载本地 .env：仓库根优先，回退 scripts/.env；均不存在则仅用环境变量
if [ -f .env ]; then
  source .env
elif [ -f scripts/.env ]; then
  source scripts/.env
fi

# ---- 可配置项（环境变量优先）----
R2_ACCOUNT_ID="${R2_ACCOUNT_ID:-}"
R2_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID:-}"
R2_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY:-}"
R2_BUCKET="${R2_BUCKET:-goodhub-updates}"
R2_PUBLIC_DOMAIN="${R2_PUBLIC_DOMAIN:-}"   # 自定义域，如 update.example.com（不含 https://）
REMOTE_PREFIX="${REMOTE_PREFIX:-updates}"   # R2 内对象前缀（对应 App 更新源子目录）
CHANGELOG="${CHANGELOG:-}"                  # 留空则取最近一条 git commit 信息

# 导出给 upload-r2.mjs 子进程读取
export R2_ACCOUNT_ID R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_BUCKET

DRY_RUN=0
DO_COMMIT=0
while [ $# -gt 0 ]; do
  case "$1" in
    -n|--dry-run) DRY_RUN=1 ;;
    --commit) DO_COMMIT=1 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "未知参数: $1"; exit 2 ;;
  esac
  shift
done

export ANDROID_HOME="${ANDROID_HOME:-$HOME/android-sdk}"
export PATH="$HOME/flutter/bin:$ANDROID_HOME/platform-tools:$PATH"

# ---- 校验 ----
missing=()
[ -z "$R2_ACCOUNT_ID" ] && missing+=(R2_ACCOUNT_ID)
[ -z "$R2_ACCESS_KEY_ID" ] && missing+=(R2_ACCESS_KEY_ID)
[ -z "$R2_SECRET_ACCESS_KEY" ] && missing+=(R2_SECRET_ACCESS_KEY)
[ -z "$R2_PUBLIC_DOMAIN" ] && missing+=(R2_PUBLIC_DOMAIN)
if [ ${#missing[@]} -gt 0 ]; then
  echo "FAIL: 缺少 R2 配置: ${missing[*]}"
  echo "      在仓库根 .env 或环境变量中设置（参考 .env.example）"
  exit 1
fi
command -v node >/dev/null 2>&1 || { echo "FAIL: 需要 node（本机应已具备）"; exit 1; }
command -v flutter >/dev/null 2>&1 || command -v "$HOME/flutter/bin/flutter" >/dev/null 2>&1 || { echo "FAIL: flutter 不可用"; exit 1; }

# ---- 版本 ----
VERSION_LINE="$(grep -m1 '^version:' pubspec.yaml)"
VERSION_NAME="$(echo "$VERSION_LINE" | sed -E 's/.*:\s*([0-9.]+)\+.*/\1/')"
VERSION_CODE="$(echo "$VERSION_LINE" | sed -E 's/.*\+([0-9]+).*/\1/')"
# 应用包名：从 gradle 取，作为串包防御写入清单（缺失时留空，客户端宽容跳过）
APP_ID="$(grep -m1 'applicationId' android/app/build.gradle.kts | sed -E 's/.*applicationId[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/')"
[ -z "$CHANGELOG" ] && CHANGELOG="$(git log -1 --pretty=%s 2>/dev/null || echo '')"
# 转义 json 字符串中的反斜杠与双引号
CHANGELOG_ESC="${CHANGELOG//\\/\\\\}"
CHANGELOG_ESC="${CHANGELOG_ESC//\"/\\\"}"

# 读取旧清单中的上一个 APK 键，发布成功后删除，避免版本化文件越攒越多
# 键语义：完整对象键（公开域 URL 去掉域前缀，含 REMOTE_PREFIX）——upload-r2.mjs 对
# put/delete 均按传入键原样签名，不做前缀拼接（旧实现传相对键名，DELETE 打到桶根
# 不存在的键上，S3 幂等返回成功 → 清理静默失效，孤儿 APK 越攒越多）
OLD_APK_KEY=""
if [ -f updates/goodhub-update.json ]; then
  _OLD_APK_URL="$(grep -oE '"apkUrl"[[:space:]]*:[[:space:]]*"[^"]+"' updates/goodhub-update.json | sed -E 's/.*"([^"]+)".*/\1/')"
  if [ -n "$_OLD_APK_URL" ]; then
    OLD_APK_KEY="${_OLD_APK_URL#"https://${R2_PUBLIC_DOMAIN}/"}"
    case "$OLD_APK_KEY" in
      http://*|https://*) OLD_APK_KEY="" ;;   # apkUrl 非本公开域（外部源/异常清单）→ 放弃清理
    esac
  fi
fi

APK="build/app/outputs/flutter-apk/app-arm64-v8a-release.apk"
ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
PUBLIC_BASE="https://${R2_PUBLIC_DOMAIN}"
APK_URL="${PUBLIC_BASE}/${REMOTE_PREFIX}/app-release-${VERSION_CODE}.apk"
SRC_URL="${PUBLIC_BASE}/${REMOTE_PREFIX}"

echo "版本: v${VERSION_NAME} (build ${VERSION_CODE})"
echo "更新源 URL（填 App 更新页）: ${SRC_URL}"

if [ "$DRY_RUN" = 1 ]; then
  echo "[dry-run] 将执行:"
  echo "  flutter pub get"
  echo "  flutter analyze"
  echo "  （Flutter 3.47.5 坑）剔除 GeneratedPluginRegistrant.java 中 integration_test 注册块"
  echo "  flutter build apk --release --split-per-abi --target-platform android-arm64 --dart-define=UPDATE_SOURCE_URL=\"$SRC_URL\" --no-pub"
  echo "  sha256sum $APK"
  echo "  生成 updates/goodhub-update.json (apkUrl=$APK_URL)"
  echo "  node scripts/upload-r2.mjs $APK $REMOTE_PREFIX/app-release-${VERSION_CODE}.apk application/vnd.android.package-archive"
  echo "  node scripts/upload-r2.mjs updates/goodhub-update.json $REMOTE_PREFIX/goodhub-update.json application/json"
  if [ -n "$OLD_APK_KEY" ] && [ "$OLD_APK_KEY" != "${REMOTE_PREFIX}/app-release-${VERSION_CODE}.apk" ]; then
    echo "  node scripts/upload-r2.mjs delete $OLD_APK_KEY   # 清理上一个版本 APK"
  fi
  exit 0
fi

# ---- 构建 ----
flutter pub get
# analyze 非 0（如存量 info/deprecated 提示）只告警不阻断；交付门槛由日常 analyze/test 把守
# ⚠️ analyze 自身也会以非 release 语义重生成 registrant（pub get 同款），故 patch 必须在其后
flutter analyze || echo "WARN: flutter analyze 报 ${?}（可能为存量 issue），继续构建"
# 工具链坑（Flutter 3.47.5 实测，2026-10-17）：dev_dependency 的 integration_test 会被
# pub get / analyze / build(非--no-pub) 反复写入 android GeneratedPluginRegistrant.java，
# 但其原生类按设计不进 release classpath → javac 报「程序包 dev.flutter.plugins.integration_test
# 不存在」构建失败。在最后一次 tooling 生成之后剔除该注册块；构建加 --no-pub 防止
# build 阶段再次 pub get 时被覆盖。上游修复后可删此段。
REGISTRANT="android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java"
if [ -f "$REGISTRANT" ] && grep -q 'dev\.flutter\.plugins\.integration_test' "$REGISTRANT"; then
  python3 - "$REGISTRANT" <<'PYEOF'
import re, sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
s2 = re.sub(
    r'\n[ \t]*try \{\n'
    r'[ \t]*flutterEngine\.getPlugins\(\)\.add\(new dev\.flutter\.plugins\.integration_test\.IntegrationTestPlugin\(\)\);\n'
    r'[ \t]*\} catch \(Exception e\) \{\n'
    r'[ \t]*Log\.e\([^\n]*\);\n'
    r'[ \t]*\}',
    '', s)
assert s2 != s, 'registrant patch failed: integration_test block not found'
open(p, 'w', encoding='utf-8').write(s2)
PYEOF
  echo "已剔除 registrant 中 integration_test 注册块（dev_dependency 不进 release）"
fi
flutter build apk --release --split-per-abi --target-platform android-arm64 --dart-define=UPDATE_SOURCE_URL="$SRC_URL" --no-pub

[ -f "$APK" ] || { echo "FAIL: 构建产物不存在: $APK"; exit 1; }
SHA="$(sha256sum "$APK" | cut -d' ' -f1)"

# ---- 清单 versionCode 校验（机械护栏，2026-10-24）----
# 历史坑：清单写 pub 号（2013）而拆分包真实 versionCode = pub 号 + 2000（4013），
# 客户端 isNewerThan(已装 4012) 恒 false → 检测到新版本但下载按钮永不出现。
# 此处用 aapt2 从 APK 真身读 versionCode，与清单将写入的推算值比对，不一致即中止。
APK_VERSION_CODE_EXPECTED=$((VERSION_CODE + 2000))
AAPT2="$(ls "$ANDROID_HOME"/build-tools/*/aapt2 2>/dev/null | sort -V | tail -1)"
if [ -z "$AAPT2" ]; then
  echo "FAIL: 找不到 aapt2（$ANDROID_HOME/build-tools/*/aapt2），无法校验清单 versionCode"
  exit 1
fi
APK_VERSION_CODE_ACTUAL="$("$AAPT2" dump badging "$APK" | sed -nE 's/^package:.*versionCode='"'"'([0-9]+)'"'"'.*/\1/p' | head -1)"
if [ "$APK_VERSION_CODE_ACTUAL" != "$APK_VERSION_CODE_EXPECTED" ]; then
  echo "FAIL: 清单 versionCode 校验不过：APK 真身=${APK_VERSION_CODE_ACTUAL:-<未读到>} 推算（pub 号+2000）=${APK_VERSION_CODE_EXPECTED}"
  echo "      拆分包偏移约定若变更，需同步改本脚本的清单口径，否则客户端恒判无新版"
  exit 1
fi
echo "✓ 清单 versionCode 校验通过：${APK_VERSION_CODE_EXPECTED}（= APK 真身 versionCode）"

# ---- 生成清单 ----
# versionCode 口径 = 拆分包 APK 真实 versionCode（Flutter split-per-abi 自动加
# 1000×ABI_VERSION，arm64-v8a = +2000），与本机 PackageInfo.buildNumber 同口径，
# 客户端 isNewerThan 才能判出「有新版」——写 pub 号会恒小于已装值（下载按钮消失）。
APK_VERSION_CODE=$((VERSION_CODE + 2000))
mkdir -p updates
cat > updates/goodhub-update.json <<EOF
{
  "versionCode": ${APK_VERSION_CODE},
  "versionName": "${VERSION_NAME}",
  "applicationId": "${APP_ID}",
  "apkUrl": "${APK_URL}",
  "sha256": "${SHA}",
  "changelog": "${CHANGELOG_ESC}"
}
EOF
echo "清单已生成: updates/goodhub-update.json"

# ---- 上传（零依赖 Node 脚本，AWS SigV4 直传 R2）----
echo "上传 APK → s3://$R2_BUCKET/$REMOTE_PREFIX/app-release-${VERSION_CODE}.apk"
node scripts/upload-r2.mjs "$APK" "$REMOTE_PREFIX/app-release-${VERSION_CODE}.apk" "application/vnd.android.package-archive"
echo "上传清单 → s3://$R2_BUCKET/$REMOTE_PREFIX/goodhub-update.json"
node scripts/upload-r2.mjs updates/goodhub-update.json "$REMOTE_PREFIX/goodhub-update.json" "application/json"

# 清理上一个版本的 APK（版本化文件名会随时间堆积，删旧留新）
if [ -n "$OLD_APK_KEY" ] && [ "$OLD_APK_KEY" != "${REMOTE_PREFIX}/app-release-${VERSION_CODE}.apk" ]; then
  echo "清理旧版本 APK → s3://$R2_BUCKET/$OLD_APK_KEY"
  node scripts/upload-r2.mjs delete "$OLD_APK_KEY" || echo "WARN: 删除旧 APK 失败（可忽略，稍后手动清理）"
fi

echo "OK: 发布完成"
echo "  更新源 URL（App 更新页填写）: ${SRC_URL}"
echo "  APK 公开地址: ${APK_URL}"
if [ "$DO_COMMIT" = 1 ]; then
  # updates/ 被 .gitignore 忽略（防 APK 入库），清单单独强加追溯
  git add -f updates/goodhub-update.json
  git commit -m "chore: release v${VERSION_NAME} (${VERSION_CODE})" && echo "已提交清单"
fi
