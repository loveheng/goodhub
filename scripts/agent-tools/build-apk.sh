#!/bin/bash
# build-apk — goodhub Android 编译脚本（默认 arm64 release 分包，--abi 指定平台）
#
# toolbox-script
# format: v1
# name: build-apk
# summary: goodhub Android 编译：analyze+构建+产物校验，--abi 指定平台，支持 debug/整包/安装
# trigger: manual
# platform: unix
# alias: apk

set -euo pipefail

BUILD_DEBUG=0
BUILD_FAT=0
INSTALL_AFTER=0
RUN_ANALYZE=1
FRESH_DAEMON=0
DRY_RUN=0
ABI_SPEC="arm64"

usage() {
  cat <<'EOF'
用法: build-apk.sh [选项]        （toolbox run build-apk [选项] 等价）
  默认: flutter analyze + arm64 release 分包构建（产物 app-arm64-v8a-release.apk）
选项:
  --abi <平台>  指定目标平台，逗号分隔可组合：
                arm64（默认，= arm64-v8a）/ arm|armv7（= armeabi-v7a）/ x64（= x86_64）
                例: --abi arm  --abi arm64,x64
  --debug       构建 debug 包（快，冒烟验证用；--abi 对 debug 不生效）
  --fat         构建 release 整包（三架构全含，自更新兜底用）
  --install     构建成功后 adb 安装到已连接手机（多产物时装第一个匹配的）
  --skip-test   跳过 flutter analyze 门槛（0 issue 交付线）
  --fresh       先停掉 gradle 守护进程（构建锁被占/产物串台时用）
  -n, --dry-run 只打印将执行的步骤，不真正构建
  --json        环境快速预检（一行 JSON 结论，不执行构建）
  -h, --help    本帮助
说明: --json 只做环境预检；真正构建用裸跑（无参数或带选项）。
EOF
}

fail_remedy() {
  case "$1" in
    *"Timeout waiting to lock"*|*"waiting for a lock"*)
      echo "[remedy] gradle 项目锁被占：加 --fresh 重跑本脚本（或 pkill -f '[G]radleDaemon' 后重试）" ;;
    *"Connection timed out"*|*"Failed to establish a new connection"*|*"Connection reset"*)
      echo "[remedy] pub/maven 网络偶发停滞：直接重跑本脚本；pub 卡死清理 ~/.pub-cache/_temp 后再试" ;;
    *"does not support"*"compileSdk"*|*"AAR metadata"*)
      echo "[remedy] compileSdk 不满足插件要求：android/app/build.gradle.kts 需按插件要求抬高 compileSdk" ;;
  esac
}

# 平台别名 → flutter target-platform + 分包产物名 + abi 标签
resolve_abi() {
  case "$1" in
    arm64|arm64-v8a)      echo "android-arm64 app-arm64-v8a-release.apk arm64-v8a" ;;
    arm|armv7|armeabi-v7a) echo "android-arm app-armeabi-v7a-release.apk armeabi-v7a" ;;
    x64|x86_64)            echo "android-x64 app-x86_64-release.apk x86_64" ;;
    *) return 1 ;;
  esac
}

# 解析 ABI_SPEC（逗号分隔）→ TP 串 / 产物列表 / abi 标签列表；非法平台 exit 2
parse_abis() {
  local old_ifs="$IFS"
  IFS=','
  TP_JOINED=""
  ARTIFACTS=""
  ABI_LABELS=""
  for a in $ABI_SPEC; do
    a="$(echo "$a" | tr -d ' ')"
    [ -z "$a" ] && continue
    r="$(resolve_abi "$a")" || {
      IFS="$old_ifs"
      echo "FAIL: 未知平台 '$a'（支持: arm64 / arm|armv7 / x64）"
      exit 2
    }
    tp="${r%% *}"; rest="${r#* }"
    art="${rest%% *}"; label="${rest#* }"
    TP_JOINED="${TP_JOINED:+$TP_JOINED,}$tp"
    ARTIFACTS="$ARTIFACTS build/app/outputs/flutter-apk/$art"
    ABI_LABELS="${ABI_LABELS:+$ABI_LABELS,}$label"
  done
  # 必须还原 IFS：下游 $BUILD_CMD / $ARTIFACTS 无引号展开依赖默认空格分词，
  # 残留 IFS=',' 会让整串命令被当作单个命令名（command not found）
  IFS="$old_ifs"
}

precheck_json() {
  if ! command -v flutter >/dev/null 2>&1 && [ ! -x "$HOME/flutter/bin/flutter" ]; then
    printf '{"status":"FAIL","severity":"error","message":"flutter 不可用","remedy":"确认 ~/flutter 存在并 export PATH=$HOME/flutter/bin:$PATH"}\n'
    exit 1
  fi
  if [ ! -d "${ANDROID_HOME:-$HOME/android-sdk}" ]; then
    printf '{"status":"FAIL","severity":"error","message":"android-sdk 不存在","remedy":"设置 ANDROID_HOME 或安装 Android SDK"}\n'
    exit 1
  fi
  printf '{"status":"OK","severity":"info","message":"环境预检通过：flutter 与 android-sdk 就绪，可裸跑构建"}\n'
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --abi)
      [ $# -ge 2 ] || { echo "FAIL: --abi 需要平台参数"; usage; exit 2; }
      ABI_SPEC="$2"; shift
      ;;
    --debug) BUILD_DEBUG=1 ;;
    --fat) BUILD_FAT=1 ;;
    --install) INSTALL_AFTER=1 ;;
    --skip-test) RUN_ANALYZE=0 ;;
    --fresh) FRESH_DAEMON=1 ;;
    -n|--dry-run) DRY_RUN=1 ;;
    --json) precheck_json ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
  shift
done

export ANDROID_HOME="${ANDROID_HOME:-$HOME/android-sdk}"
export PATH="$HOME/flutter/bin:$ANDROID_HOME/platform-tools:$PATH"

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"
LOG="build/apk-build.log"
AAPT="$(ls -1 "$ANDROID_HOME"/build-tools/*/aapt 2>/dev/null | sort | tail -1)"

if [ "$BUILD_DEBUG" = 1 ]; then
  BUILD_CMD="flutter build apk --debug"
  ARTIFACTS="build/app/outputs/flutter-apk/app-debug.apk"
  STEP_NAME="debug 包（全架构）"
elif [ "$BUILD_FAT" = 1 ]; then
  BUILD_CMD="flutter build apk --release"
  ARTIFACTS="build/app/outputs/flutter-apk/app-release.apk"
  STEP_NAME="release 整包（三架构）"
else
  parse_abis
  BUILD_CMD="flutter build apk --release --split-per-abi --target-platform=$TP_JOINED"
  STEP_NAME="release 分包（$ABI_LABELS）"
fi

STEPS=(
  "版本防降级守卫（bump-version --guard，设备已装版本更高时自动抬 build 号）"
  "flutter pub get"
  "flutter analyze（0 issue 门槛）"
  "$BUILD_CMD"
  "产物校验（aapt 版本/ABI + sha256）"
)
[ "$FRESH_DAEMON" = 1 ] && STEPS=("停掉 gradle 守护进程（--fresh）" "${STEPS[@]}")
[ "$INSTALL_AFTER" = 1 ] && STEPS+=("adb install -r 到已连接手机")

if [ "$DRY_RUN" = 1 ]; then
  echo "[dry-run] 将执行以下步骤（未动真目标）："
  i=1
  for s in "${STEPS[@]}"; do echo "  [$i/${#STEPS[@]}] $s"; i=$((i+1)); done
  echo "  预期产物:$ARTIFACTS"
  echo "  构建日志: $LOG"
  exit 0
fi

i=1; total=${#STEPS[@]}

echo "[$i/$total] 版本防降级守卫"
TOOLBOX_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -x "$TOOLBOX_DIR/bump-version.sh" ]; then
  "$TOOLBOX_DIR/bump-version.sh" --guard || { echo "FAIL: 版本守卫异常，中止构建（防装包降级）"; exit 1; }
else
  echo "  跳过：未找到 bump-version.sh"
fi
i=$((i+1))
[ "$FRESH_DAEMON" = 1 ] && {
  echo "[$i/$total] 停掉 gradle 守护进程"
  (cd android && ./gradlew --stop >/dev/null 2>&1 || true)
  i=$((i+1))
}

echo "[$i/$total] flutter pub get"
flutter pub get || { echo "FAIL: pub get 失败"; fail_remedy "$(tail -5 "$LOG" 2>/dev/null || true)"; exit 1; }
i=$((i+1))

if [ "$RUN_ANALYZE" = 1 ]; then
  echo "[$i/$total] flutter analyze（0 issue 门槛）"
  ANALYZE_OUT="$(flutter analyze 2>&1)" || {
    echo "$ANALYZE_OUT" | tail -15
    echo "FAIL: analyze 存在 issue（0 issue 为交付线），先修复再编译"
    exit 1
  }
  echo "$ANALYZE_OUT" | tail -1
  i=$((i+1))
fi

echo "[$i/$total] $BUILD_CMD（日志: $LOG）"
mkdir -p build
if ! $BUILD_CMD > "$LOG" 2>&1; then
  tail -25 "$LOG"
  echo "FAIL: 构建失败，完整日志在 $LOG"
  fail_remedy "$(tail -25 "$LOG")"
  exit 1
fi
echo "构建完成"
i=$((i+1))

echo "[$i/$total] 产物校验"
VERIFY_FAILED=0
for ART in $ARTIFACTS; do
  if [ ! -f "$ART" ]; then
    echo "  FAIL: 预期产物不存在: $ART"
    VERIFY_FAILED=1
    continue
  fi
  SHA="$(sha256sum "$ART" | cut -d' ' -f1)"
  BADGE="$("$AAPT" dump badging "$ART" 2>/dev/null | grep -E '^package:|native-code' | tr '\n' ' ')"
  ls -lh "$ART" | awk -v a="$ART" '{print "  " a "  大小: "$5}'
  echo "  sha256: $SHA"
  echo "  $BADGE"
done
[ "$VERIFY_FAILED" = 1 ] && exit 1

if [ "$INSTALL_AFTER" = 1 ]; then
  if adb devices | grep -q "device$"; then
    FIRST_ART="$(echo $ARTIFACTS | awk '{print $1}')"
    adb install -r "$FIRST_ART" && echo "已安装到手机: $FIRST_ART"
  else
    echo "未检测到已连接手机，跳过安装；手动安装: adb install -r${ARTIFACTS%% *}"
  fi
fi

echo "OK: $STEP_NAME 编译完成 →$ARTIFACTS"
