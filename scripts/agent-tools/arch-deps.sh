#!/bin/bash
# arch-deps — 依赖方向护栏（flutter test 版）
#
# toolbox-script
# format: v1
# name: arch-deps
# summary: 跑 test/architecture/ 全套依赖护栏（含扫描器金丝雀自测）；秒级 shell 镜像见 arch-guard R4~R8，本工具用于 CI 与提交前全量校验（ARCH_GATE_FULL=1）
# trigger: manual
# platform: unix
# cat: test
# alias: ad
# self-test: --self-test
#
# 为什么有两个实现：
#   arch-guard（shell，秒级）  —— pre-commit 钩子 10s 预算内跑得完，进默认门禁；
#   arch-deps（本工具，~12s）  —— 跑 flutter test，覆盖扫描器金丝雀与规则表全量，
#                                适合 CI 与「提交前全量」开关，不进默认钩子路径。
# 规则口径同源：goodhub-workflow skill「架构依赖纪律」红灯表；改规则须两处同步。

set -uo pipefail

ROOT=""
JSON_ONLY=0
SELF_TEST=0

usage() {
  cat <<'EOF'
用法: arch-deps.sh [选项]        （toolbox run arch-deps [选项] 等价）
  默认: 在仓库根跑 flutter test test/architecture/，依赖护栏全绿则 0
选项:
  --root <目录>  指定仓库根（默认 git 顶层 / 当前目录）
  --json         只输出一行 JSON 结论（供 AI/钩子判定，不打印明细）
  --self-test    金丝雀自测：向 lib/sandbox/ 注入一条违例 import，证明护栏会红
                 （注入件经 trap 保证还原；需 flutter 可用）
  -h, --help     本帮助
说明: 裸跑=执行测试；--json=单行结论。两者判定完全一致。
      flutter 取用顺序：$FLUTTER 环境变量 → PATH 中的 flutter → $HOME/flutter/bin/flutter
EOF
}

json_out() {
  if [ -n "${4:-}" ]; then
    printf '{"status":"%s","severity":"%s","message":"%s","remedy":"%s"}\n' "$1" "$2" "$3" "$4"
  else
    printf '{"status":"%s","severity":"%s","message":"%s"}\n' "$1" "$2" "$3"
  fi
}

resolve_flutter() {
  if [ -n "${FLUTTER:-}" ] && [ -x "$FLUTTER" ]; then printf '%s\n' "$FLUTTER"; return 0; fi
  if command -v flutter >/dev/null 2>&1; then printf '%s\n' "$(command -v flutter)"; return 0; fi
  if [ -x "$HOME/flutter/bin/flutter" ]; then printf '%s\n' "$HOME/flutter/bin/flutter"; return 0; fi
  return 1
}

resolve_root() {
  if [ -n "$ROOT" ]; then printf '%s\n' "$ROOT"; return; fi
  local here d
  here=$(cd "$(dirname "$0")" && pwd)
  d=$(git -C "$here" rev-parse --show-toplevel 2>/dev/null)
  printf '%s\n' "${d:-$PWD}"
}

run_tests() {
  local flutter_bin
  flutter_bin=$(resolve_flutter) || return 2
  if [ "$JSON_ONLY" -eq 1 ]; then
    ( cd "$ROOT" && "$flutter_bin" test test/architecture/ --timeout 120s ) >/dev/null 2>&1
    return $?
  fi
  ( cd "$ROOT" && "$flutter_bin" test test/architecture/ --timeout 120s )
}

run() {
  local rc=0
  [ -d "$ROOT/test/architecture" ] || {
    echo "FAIL 自身故障: $ROOT/test/architecture 不存在（用 --root 指定仓库根）"
    [ "$JSON_ONLY" -eq 1 ] && json_out "FAIL" "error" "arch-deps: 自身故障（目录缺失）" "用 --root 指向仓库根"
    return 2; }

  run_tests || rc=$?

  if [ "$rc" -eq 0 ]; then
    [ "$JSON_ONLY" -eq 1 ] && json_out "OK" "info" "arch-deps: 依赖护栏全绿"
    return 0
  fi
  if [ "$rc" -eq 2 ]; then
    [ "$JSON_ONLY" -eq 1 ] && json_out "FAIL" "error" "arch-deps: 自身故障（flutter 不可用）" "export PATH 指向 flutter，或设 FLUTTER=/path/to/flutter"
    echo "[remedy] flutter 不可用：export PATH=\"\$HOME/flutter/bin:\$PATH\" 或设 FLUTTER 环境变量"
    return 2
  fi
  [ "$JSON_ONLY" -eq 1 ] && json_out "FAIL" "error" "arch-deps: 依赖护栏未通过（test/architecture/）" "裸跑 toolbox run arch-deps 看失败用例；各规则的修复指向见 dependency_rules_test.dart 的 hint 字段"
  echo "[remedy] 裸跑 toolbox run arch-deps 看失败用例；逐条对照 goodhub-workflow skill 红灯表修正反向边"
  return 1
}

self_test() {
  local flutter_bin leak
  flutter_bin=$(resolve_flutter) || { echo "SELF-TEST FAIL: flutter 不可用" >&2; return 2; }
  leak="$ROOT/lib/sandbox/_arch_deps_selftest_leak.dart"
  trap 'rm -f "$leak"' RETURN

  # 金丝雀：注入一条 mcp/sandbox → coordinator 违例，护栏必须变红
  printf "library;\nimport '../coordinator/agent_loop.dart';\n" >"$leak"
  if run_tests >/dev/null 2>&1; then
    echo "SELF-TEST FAIL: 注入违例后护栏仍放行（护栏失效）" >&2
    return 2
  fi

  rm -f "$leak"
  if run_tests >/dev/null 2>&1; then
    echo "SELF-TEST PASS: 注入违例被拦(exit 1)、还原后放行(exit 0)"
    return 0
  fi
  echo "SELF-TEST FAIL: 还原后护栏仍红（误报）" >&2
  return 2
}

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --root) ROOT="${2:-}"; [ -n "$ROOT" ] || { echo "ERROR: --root 缺参数" >&2; exit 2; }; shift 2 ;;
      --json) JSON_ONLY=1; shift ;;
      --self-test) SELF_TEST=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) usage; exit 2 ;;
    esac
  done

  ROOT=$(resolve_root)
  [ -d "$ROOT/lib" ] || { echo "ERROR: 未在仓库根找到 lib/：$ROOT（用 --root 指定）" >&2; exit 2; }

  if [ "$SELF_TEST" -eq 1 ]; then
    self_test; exit $?
  fi
  run
}

main "$@"
