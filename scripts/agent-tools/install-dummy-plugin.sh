#!/bin/bash
# install-dummy-plugin — 构建并安装本地插件靶子 APK（GoodHub 真机 e2e 前置）
#
# 背景：插件 SDK 拆仓到 goodhub-mcp-sdk 后，sample-dummy-plugin 不再随 goodhub 仓构建。
# integration_test/thirdconnect_e2e_test.dart 断言宿主能扫到 serverId=dummy 的本地插件
# （发现 → Binder 同步 → _async 流式 → sampling 反向闭环），必须先在设备上装好靶子 APK。
# 本脚本负责「构建契约仓 sample APK → adb 安装 → 校验」。
#
# toolbox-script
# format: v1
# name: install-dummy-plugin
# summary: 构建并安装本地插件靶子 APK（goodhub-mcp-sdk 的 sample-dummy-plugin），供真机 e2e 联调
# trigger: manual
# platform: unix
# alias: dummy-install

set -uo pipefail

SDK_REPO=""
DEVICE=""
JSON_ONLY=0

usage() {
  cat <<'EOF'
用法: install-dummy-plugin.sh [选项]   （toolbox run install-dummy-plugin [选项] 等价）
  构建 goodhub-mcp-sdk 仓的 sample-dummy-plugin 调试 APK 并安装到设备。
选项:
  --sdk-repo <目录>  指定 SDK 仓路径（默认 $GOODHUB_MCP_SDK_REPO 或 <仓根>/../goodhub-mcp-sdk）
  --device <ID>      指定 adb 设备（默认唯一在线设备；多设备时报错）
  --json             只输出一行 JSON 结论
  -h | --help        本帮助
退出码: 0=装好 1=失败 2=环境错误
EOF
}

json_out() {
  if [ -n "${4:-}" ]; then
    printf '{"status":"%s","severity":"%s","message":"%s","remedy":"%s"}\n' "$1" "$2" "$3" "$4"
  else
    printf '{"status":"%s","severity":"%s","message":"%s"}\n' "$1" "$2" "$3"
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --sdk-repo) SDK_REPO="${2:-}"; shift 2 ;;
    --device) DEVICE="${2:-}"; shift 2 ;;
    --json) JSON_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1"; usage; exit 2 ;;
  esac
done

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
SDK_REPO="${SDK_REPO:-${GOODHUB_MCP_SDK_REPO:-$ROOT/../goodhub-mcp-sdk}}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/android-sdk}"

[ -d "$SDK_REPO" ] || { json_out "FAIL" "error" "找不到 SDK 仓：$SDK_REPO" "指定 --sdk-repo 或设 GOODHUB_MCP_SDK_REPO"; exit 2; }
[ -x "$SDK_REPO/gradlew" ] || { json_out "FAIL" "error" "SDK 仓缺 gradlew：$SDK_REPO" ""; exit 2; }
command -v adb >/dev/null 2>&1 || { json_out "FAIL" "error" "adb 不可用" "确认 ANDROID_HOME 指向 Android SDK（platform-tools）"; exit 2; }

if [ -z "$DEVICE" ]; then
  mapfile -t devs < <(adb devices | awk 'NR>1 && $2=="device" {print $1}')
  [ "${#devs[@]}" -eq 1 ] || { json_out "FAIL" "error" "在线设备数=${#devs[@]}（需恰好 1 台）" "用 --device <ID> 指定"; exit 2; }
  DEVICE="${devs[0]}"
fi

echo "==> 构建 sample-dummy-plugin（SDK 仓：$SDK_REPO）"
if ! (cd "$SDK_REPO" && ./gradlew --console=plain :sample-dummy-plugin:assembleDebug); then
  json_out "FAIL" "error" "sample-dummy-plugin 构建失败" "看上方 gradle 输出"; exit 1
fi

APK="$SDK_REPO/sample-dummy-plugin/build/outputs/apk/debug/sample-dummy-plugin-debug.apk"
[ -f "$APK" ] || { json_out "FAIL" "error" "未产出 APK：$APK" ""; exit 1; }

echo "==> 安装到设备 $DEVICE"
if ! adb -s "$DEVICE" install -r "$APK"; then
  json_out "FAIL" "error" "adb install 失败" "设备可能存在版本降级（先卸载旧包）或签名不一致"; exit 1
fi

echo "OK: 靶子插件已装到 $DEVICE（$APK）"
json_out "OK" "info" "靶子插件已安装到 $DEVICE" ""
exit 0
