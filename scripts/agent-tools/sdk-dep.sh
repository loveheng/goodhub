#!/bin/bash
# sdk-dep — 把插件接入 SDK（goodhub-mcp-sdk）发布到本地 Maven 仓库
#
# 用途：goodhub 宿主解析契约坐标 com.zzh.goodhub.mcp:goodhub-mcp-contract 的**兜底通路**
#   ——复合构建（android/settings.gradle.kts 的 includeBuild）在没有 sibling 契约仓时不可用
#   （CI 环境、只拉了 goodhub 一个仓的机器），此时改由 mavenLocal() 解析。
#   先跑本脚本把 SDK 发布到 ~/.m2，宿主构建即可解析到契约 AAR。
#
# toolbox-script
# format: v1
# name: sdk-dep
# summary: 把插件接入 SDK（goodhub-mcp-sdk）发布到本地 Maven 仓库，供宿主在无 sibling 仓时解析契约坐标
# trigger: manual
# platform: unix
# alias: sdkdep
#
# 正常开发路径不需要本脚本：宿主默认用复合构建直接消费 sibling 契约仓源码（免发布、免版本滞后）。

set -uo pipefail

SDK_REPO=""
JSON_ONLY=0

usage() {
  cat <<'EOF'
用法: sdk-dep.sh [选项]   （toolbox run sdk-dep [选项] 等价）
  构建 goodhub-mcp-sdk 并发布到本地 Maven 仓库（~/.m2），产物坐标：
    com.zzh.goodhub.mcp:goodhub-mcp-contract
    com.zzh.goodhub.mcp:goodhub-mcp-plugin-core
选项:
  --sdk-repo <目录>  指定 SDK 仓路径（默认 $GOODHUB_MCP_SDK_REPO 或 <仓根>/../goodhub-mcp-sdk）
  --json             只输出一行 JSON 结论
  -h | --help        本帮助
退出码: 0=发布成功 1=发布失败 2=环境错误
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

VERSION="$(sed -n 's/^version=//p' "$SDK_REPO/VERSION" 2>/dev/null | head -1)"
[ -n "$VERSION" ] || { json_out "FAIL" "error" "SDK 仓缺 VERSION 文件或 version 字段" ""; exit 2; }

echo "==> 发布 SDK 到本地 Maven（版本 $VERSION，仓 $SDK_REPO）"
if ! (cd "$SDK_REPO" && ./gradlew --console=plain publishToMavenLocal); then
  json_out "FAIL" "error" "publishToMavenLocal 失败" "看上方 gradle 输出"; exit 1
fi

TARGET="$HOME/.m2/repository/com/zzh/goodhub/mcp/goodhub-mcp-contract/$VERSION"
if [ ! -f "$TARGET/goodhub-mcp-contract-$VERSION.aar" ]; then
  json_out "FAIL" "error" "本地 Maven 仓未见契约产物：$TARGET" ""; exit 1
fi

echo "OK: 已发布到 ~/.m2（goodhub-mcp-contract:$VERSION）"
json_out "OK" "info" "SDK $VERSION 已发布到本地 Maven 仓" ""
exit 0
