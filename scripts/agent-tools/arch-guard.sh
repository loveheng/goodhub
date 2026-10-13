#!/bin/bash
# arch-guard — goodhub 分层架构硬约束机械护栏
#
# toolbox-script
# format: v1
# name: arch-guard
# summary: goodhub 分层架构硬约束机械校验（UI 层禁 dart:io 平台污染 / UI 层禁平台分支），改动 lib/ 后与提交前门禁
# trigger: manual
# platform: unix
# cat: test
# alias: ag
#
# 规则口径见 docs/project/coding-standards.md §1/§2（禁平台污染 / 接口驱动）；
# 白名单内的条目是**历史例外**，只许减少不许增加（迁移一个删一行）。

set -uo pipefail

ROOT=""
JSON_ONLY=0
SELF_TEST=0
COUNT=0
HITS=""

usage() {
  cat <<'EOF'
用法: arch-guard.sh [选项]        （toolbox run arch-guard [选项] 等价）
  默认: 扫描仓库 lib/ 下硬约束，逐条打印命中，0=通过 1=有违规
选项:
  --root <目录>  指定仓库根（默认 git 顶层 / 当前目录）
  --json         只输出一行 JSON 结论（供 AI/钩子判定，不打印明细）
  --self-test    金丝雀自测：造已知坏样本，证明"能抓到坏"
  -h, --help     本帮助
说明: 裸跑=逐条明细（人看）；--json=单行结论（机器看）。两者扫描规则完全一致。
EOF
}

die() { echo "ERROR: $*" >&2; exit 2; }

resolve_root() {
  if [ -n "$ROOT" ]; then printf '%s\n' "$ROOT"; return; fi
  local here d
  here=$(cd "$(dirname "$0")" && pwd)
  d=$(git -C "$here" rev-parse --show-toplevel 2>/dev/null)
  printf '%s\n' "${d:-$PWD}"
}

# scan_pattern <id> <作用域(空格分隔)> <描述> <正则> <白名单相对路径(空格分隔)>
scan_pattern() {
  local id="$1" scopes="$2" desc="$3" pattern="$4" wl="$5"
  local dirs="" d
  for d in $scopes; do
    [ -d "$ROOT/$d" ] && dirs="$dirs $ROOT/$d"
  done
  [ -z "$dirs" ] && return 0
  local out line rel rest lineno code
  out=$(grep -rnE --include='*.dart' --exclude='*.g.dart' --exclude='*.freezed.dart' \
        "$pattern" $dirs 2>/dev/null || true)
  [ -z "$out" ] && return 0
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    rel=${line%%:*}; rest=${line#*:}; lineno=${rest%%:*}; code=${rest#*:}
    rel=${rel#"$ROOT/"}
    case " $wl " in *" $rel "*) continue ;; esac
    code=$(printf '%s' "$code" | cut -c1-72 | tr -d '"')
    HITS="${HITS}FAIL ${rel}:${lineno} [${id}] ${desc}\n        ${code}\n"
    COUNT=$((COUNT + 1))
  done <<EOF
$out
EOF
}

scan_all() {
  COUNT=0
  HITS=""
  # R1 UI 层禁 dart:io —— 平台污染（coding-standards §1/§2：文件系统统一走 core/storage 或抽象接口）
  # 白名单（均为历史例外，待收敛到抽象接口后逐个删除）：
  # - services_hall_page.dart / chat_page.dart / memory_board_page.dart：M4 期间 UI 内联文件操作（导出/日志读取），待收敛
  scan_pattern "R1-ui-dart-io" "lib/ui" \
    "UI 层 import dart:io（平台污染），文件系统能力须走 core/storage 或抽象接口注入" \
    "import 'dart:io'" "lib/ui/services_hall_page.dart lib/ui/chat_page.dart lib/ui/memory_board_page.dart"
  # R2 UI 层禁止平台分支（coding-standards §1：平台差异收敛到接口实现/工厂）
  scan_pattern "R2-ui-platform" "lib/ui" \
    "UI 层出现 Platform.isX 分支，平台差异须收敛到接口实现/工厂" \
    'Platform\.is[A-Z]' ""
  # R3 UI 层禁 MethodChannel 直连（平台通道统一在 lib/app 装配期注入）
  scan_pattern "R3-ui-methodchannel" "lib/ui" \
    "UI 层直连 MethodChannel，平台通道须收敛到抽象接口实现" \
    'MethodChannel\(' ""
  return 0
}

report_text() {
  if [ "$COUNT" -eq 0 ]; then
    echo "OK: 架构硬约束全部通过（$ROOT）"
    return 0
  fi
  printf '%b' "$HITS"
  echo "----"
  echo "FAIL: $COUNT 处违规"
  echo "[remedy] 逐条对照 docs/project/coding-standards.md §1/§2 修正；"
  echo "[remedy] 确认是历史遗留且暂不迁移的，加进脚本白名单并注明原因（只减不增）"
  return 1
}

report_json() {
  local msg remedy
  if [ "$COUNT" -eq 0 ]; then
    printf '{"status":"OK","severity":"info","message":"arch-guard: 架构硬约束全部通过"}\n'
    return 0
  fi
  msg="arch-guard: $COUNT 处架构硬约束违规（R1 UI dart:io / R2 UI 平台分支 / R3 UI MethodChannel）"
  remedy="裸跑 toolbox run arch-guard 看逐条明细；对照 docs/project/coding-standards.md §1/§2 修正，历史遗留加白名单并注明原因"
  printf '{"status":"FAIL","severity":"error","message":"%s","remedy":"%s"}\n' "$msg" "$remedy"
  return 1
}

self_test() {
  local bad clean rc
  bad=$(mktemp -d); clean=$(mktemp -d)
  trap 'rm -rf "$bad" "$clean"' RETURN

  mkdir -p "$bad/lib/ui" "$bad/lib/core"
  cat >"$bad/lib/ui/bad_page.dart" <<'EOF'
import 'dart:io';
if (Platform.isAndroid) {}
MethodChannel('ch').invokeMethod('x');
EOF

  mkdir -p "$clean/lib/ui"
  cat >"$clean/lib/ui/ok_widget.dart" <<'EOF'
import 'package:goodhub/core/storage/abstract_store.dart';
final s = await store.read();
EOF

  ROOT="$bad"; scan_all
  if [ "$COUNT" -lt 3 ]; then
    echo "SELF-TEST FAIL: 坏样本只抓到 $COUNT 处（期望 >=3）" >&2
    printf '%b' "$HITS" >&2
    return 2
  fi

  ROOT="$clean"; scan_all
  if [ "$COUNT" -ne 0 ]; then
    echo "SELF-TEST FAIL: 干净样本误报 $COUNT 处" >&2
    printf '%b' "$HITS" >&2
    return 2
  fi

  echo "SELF-TEST PASS: 坏样本抓到违规、干净样本零误报"
  return 0
}

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --root) ROOT="${2:-}"; [ -n "$ROOT" ] || die "--root 缺参数"; shift 2 ;;
      --json) JSON_ONLY=1; shift ;;
      --self-test) SELF_TEST=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) usage; exit 2 ;;
    esac
  done

  if [ "$SELF_TEST" -eq 1 ]; then
    self_test; exit $?
  fi

  ROOT=$(resolve_root)
  [ -d "$ROOT/lib" ] || die "未在仓库根找到 lib/：$ROOT（用 --root 指定）"

  scan_all
  if [ "$JSON_ONLY" -eq 1 ]; then report_json; else report_text; fi
}

main "$@"
