#!/bin/bash
# check-contract-sync — 本地插件接入契约（AIDL）单副本与版本绑定门禁
#
# 背景：插件 SDK 拆独立仓后，AIDL 契约的**唯一物理副本**在 goodhub-mcp-sdk 仓的
#   :contract 模块；goodhub 宿主通过坐标 com.zzh.goodhub.mcp:goodhub-mcp-contract
#   消费（复合构建 includeBuild 优先，mavenLocal 兜底）。
# AIDL 生成的 DESCRIPTOR = 接口全限定名，随每次 Binder 事务作为 interface token 上线：
# 任一侧漂移 = 宿主与插件 interface token 不匹配 = 存量插件 bind 全失败，
# 且只在真机运行期暴露（编译期无感知）。本门禁把漂移提前到提交期拦截。
#
# 三条校验：
#   ① 宿主不得自带 AIDL 副本（契约必须物理单副本；副本复活 = 漂移源复活）
#   ② 宿主声明的契约坐标版本 == 登记的期望版本
#   ③ 契约仓可达时：期望版本 == 契约仓 VERSION 的 version，且 contract_version 一致
#
# toolbox-script
# format: v1
# name: check-contract-sync
# summary: 插件接入契约（AIDL）单副本与版本绑定门禁——禁宿主自拷 AIDL + 校验契约坐标版本与契约仓 VERSION 一致
# trigger: manual
# platform: unix
# alias: contract-check
#
# 规则口径见 docs/design/thirdconnect.md §1.2.2（AIDL 契约）/ §11.5（SDK 版本绑定契约版本）。

set -uo pipefail

ROOT=""
SDK_REPO=""
JSON_ONLY=0
SELF_TEST=0

LOCK_FILE="scripts/agent-tools/contract.lock"
HOST_AIDL_DIR="android/app/src/main/aidl"
HOST_BUILD_FILE="android/app/build.gradle.kts"
CONTRACT_MODULE="com.zzh.goodhub.mcp:goodhub-mcp-contract"
HOST_AIDL_SUBPATH="com/zzh/goodhub/mcp"

usage() {
  cat <<'EOF'
用法: check-contract-sync.sh [选项]   （toolbox run check-contract-sync [选项] 等价）
  校验本地插件接入契约（AIDL）保持物理单副本，且宿主声明的契约坐标版本与契约仓一致。
选项:
  --root <目录>      指定 goodhub 仓根（默认 git 顶层 / 当前目录）
  --sdk-repo <目录>  指定契约仓路径（默认 $GOODHUB_MCP_SDK_REPO 或 <仓根>/../goodhub-mcp-sdk）
  --json             只输出一行 JSON 结论（供 AI/钩子判定）
  --self-test        金丝雀自测：证明能抓到坏样本
  -h | --help        本帮助
退出码: 0=一致  1=不一致  2=自身故障
EOF
}

json_out() {
  if [ -n "${4:-}" ]; then
    printf '{"status":"%s","severity":"%s","message":"%s","remedy":"%s"}\n' "$1" "$2" "$3" "$4"
  else
    printf '{"status":"%s","severity":"%s","message":"%s"}\n' "$1" "$2" "$3"
  fi
}

die() { echo "ERROR: $*" >&2; exit 2; }

resolve_root() {
  if [ -n "$ROOT" ]; then printf '%s\n' "$ROOT"; return; fi
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  printf '%s\n' "$ROOT"
}

resolve_sdk_repo() {
  if [ -n "$SDK_REPO" ]; then printf '%s\n' "$SDK_REPO"; return; fi
  if [ -n "${GOODHUB_MCP_SDK_REPO:-}" ]; then printf '%s\n' "$GOODHUB_MCP_SDK_REPO"; return; fi
  printf '%s\n' "$(resolve_root)/../goodhub-mcp-sdk"
}

lock_get() { # $1=key
  [ -f "$LOCK" ] || return 1
  sed -n "s/^$1=//p" "$LOCK" | head -1
}

check() {
  local root sdk_repo hits=0
  root="$(resolve_root)"
  sdk_repo="$(resolve_sdk_repo)"
  LOCK="$root/$LOCK_FILE"
  [ -f "$LOCK" ] || die "找不到契约绑定登记文件：$LOCK"

  local want_ver want_cver
  want_ver="$(lock_get contract_version)" || die "登记文件缺 contract_version"
  want_cver="$(lock_get aidl_contract_version)" || die "登记文件缺 aidl_contract_version"
  [ -n "$want_ver" ] || die "登记文件 contract_version 为空"

  # ① 宿主不得自带 AIDL 副本（契约必须物理单副本）
  if [ -d "$root/$HOST_AIDL_DIR/$HOST_AIDL_SUBPATH" ]; then
    local n
    n=$(find "$root/$HOST_AIDL_DIR/$HOST_AIDL_SUBPATH" -name '*.aidl' 2>/dev/null | wc -l)
    if [ "$n" -gt 0 ]; then
      echo "FAIL 宿主自带 AIDL 契约副本（$n 个文件）——契约必须物理单副本（在契约仓 :contract 模块）"
      echo "     位置：$HOST_AIDL_DIR/$HOST_AIDL_SUBPATH/"
      echo "     副本即漂移源：AIDL DESCRIPTOR 随每次 Binder 事务上线，两份必然走向不一致"
      hits=$((hits+1))
    fi
  fi

  # ② 宿主声明的契约坐标版本 == 登记期望版本
  [ -f "$root/$HOST_BUILD_FILE" ] || die "找不到宿主构建脚本：$HOST_BUILD_FILE"
  local declared
  declared="$(grep -oE "$CONTRACT_MODULE:[0-9A-Za-z._-]+" "$root/$HOST_BUILD_FILE" | head -1 | sed "s|^$CONTRACT_MODULE:||")"
  if [ -z "$declared" ]; then
    echo "FAIL 宿主构建脚本未声明契约坐标 $CONTRACT_MODULE"
    hits=$((hits+1))
  elif [ "$declared" != "$want_ver" ]; then
    echo "FAIL 宿主契约坐标版本与登记不符：宿主=$declared 期望=$want_ver"
    echo "     改契约版本须同轮改两处：$LOCK_FILE 与 $HOST_BUILD_FILE"
    hits=$((hits+1))
  else
    echo "OK   宿主契约坐标版本 = $declared"
  fi

  # ③ 契约仓可达时核对 VERSION（版本事实源）
  if [ -f "$sdk_repo/VERSION" ]; then
    local sdk_ver sdk_cver
    sdk_ver="$(sed -n 's/^version=//p' "$sdk_repo/VERSION" | head -1)"
    sdk_cver="$(sed -n 's/^contract_version=//p' "$sdk_repo/VERSION" | head -1)"
    if [ "$sdk_ver" != "$want_ver" ]; then
      echo "FAIL 契约仓版本与登记不符：契约仓=$sdk_ver 期望=$want_ver"
      hits=$((hits+1))
    else
      echo "OK   契约仓版本 = $sdk_ver"
    fi
    if [ "$sdk_cver" != "$want_cver" ]; then
      echo "FAIL AIDL 契约版本不符：契约仓=$sdk_cver 期望=$want_cver"
      echo "     契约版本变更属线级破坏性变更，须宿主与插件同步升版"
      hits=$((hits+1))
    else
      echo "OK   AIDL 契约版本 = $sdk_cver"
    fi
  else
    echo "WARN 契约仓不可达（$sdk_repo），跳过与契约仓 VERSION 的比对"
  fi

  if [ "$hits" -gt 0 ]; then
    [ "$JSON_ONLY" -eq 1 ] && json_out "FAIL" "error" "契约绑定不一致（$hits 项）" "契约只允许一份物理副本；版本变更须同轮改 contract.lock 与宿主 build.gradle.kts"
    echo "FAIL: 契约绑定不一致（$hits 项）"
    return 1
  fi
  if [ "$JSON_ONLY" -eq 1 ]; then
    json_out "OK" "info" "契约保持物理单副本，版本绑定一致"
  else
    echo "OK: 契约保持物理单副本，版本绑定一致"
  fi
  return 0
}

self_test() {
  local tmp rc_bad rc_good
  tmp=$(mktemp -d) || return 2
  mkdir -p "$tmp/scripts/agent-tools" "$tmp/android/app/src/main" "$tmp/sdk"
  printf 'contract_version=0.1.0\naidl_contract_version=v1\n' > "$tmp/scripts/agent-tools/contract.lock"
  printf 'dependencies { implementation("com.zzh.goodhub.mcp:goodhub-mcp-contract:0.1.0") }\n' > "$tmp/android/app/build.gradle.kts"
  printf 'version=0.1.0\ncontract_version=v1\n' > "$tmp/sdk/VERSION"
  bash "$0" --root "$tmp" --sdk-repo "$tmp/sdk" >/dev/null 2>&1
  rc_good=$?
  mkdir -p "$tmp/android/app/src/main/aidl/com/zzh/goodhub/mcp"
  printf 'package com.zzh.goodhub.mcp;\ninterface X {}\n' > "$tmp/android/app/src/main/aidl/com/zzh/goodhub/mcp/IMcpChannel.aidl"
  bash "$0" --root "$tmp" --sdk-repo "$tmp/sdk" >/dev/null 2>&1
  rc_bad=$?
  rm -rf "$tmp"
  if [ "$rc_good" -eq 0 ] && [ "$rc_bad" -eq 1 ]; then
    echo "self-test PASS: 自拷 AIDL 被拦(exit 1)、单副本放行(exit 0)"
    return 0
  fi
  echo "FAIL self-test: rc_good=$rc_good rc_bad=$rc_bad（预期 0/1）"
  return 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift 2 ;;
    --sdk-repo) SDK_REPO="${2:-}"; shift 2 ;;
    --json) JSON_ONLY=1; shift ;;
    --self-test) SELF_TEST=1; break ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1"; usage; exit 2 ;;
  esac
done

ROOT="${ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
if [ "$SELF_TEST" -eq 1 ]; then self_test; exit $?; fi
check
exit $?
