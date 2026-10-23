#!/bin/sh
# pre-commit 聚合门禁：提交前机械拦截——arch-guard 架构硬约束 + docs-lint 文档规范 + drift-guard 契约面漂移。
# 复用既有单工具而非重写规则；无 lib/ 改动则跳过 arch-guard，无 docs/ 改动则跳过 docs-lint。
#
# toolbox-script
# format: v1
# name: pre-commit-gate
# summary: 提交前门禁：按改动范围分派 arch-guard（lib/ 改动）、docs-lint（docs/ 改动）、drift-guard（lib/ 或 docs/ 改动），任一 FAIL 拒绝提交
# trigger: pre-commit
# after: arch-guard,docs-lint,check-contract-sync,drift-guard
# cat: test
# alias: pcg
# platform: unix
# self-test: --self-test

set -u
ROOT=''; LIB_TOUCHED=0; DOC_TOUCHED=0; ANDROID_TOUCHED=0; SELF_TEST=0; JSON_ONLY=0

usage() {
  cat <<'EOF'
用法: pre-commit-gate.sh [选项]      （toolbox run pre-commit-gate [选项] 等价）
  提交前门禁：git 取暂存区改动，涉及 lib/ 跑 arch-guard，涉及 docs/ 跑 docs-lint，
  涉及 android/ 跑 check-contract-sync（本地插件 AIDL 契约跨仓双副本防漂移）；
  涉及 lib/ 或 docs/ 跑 drift-guard（契约面漂移：退役词表 / 单源常量 / 超标登记，
  数据 = scripts/agent-tools/drift-registry.txt，引擎在全局 toolbox 池）；
  任一 FAIL → exit 1 拒绝提交（规则本身在各自工具内，本脚本只做分派与聚合）。
选项:
  --root <目录>  指定仓库根（默认 git 顶层 / 当前目录）
  --json         只输出一行 JSON 结论（供 AI/钩子判定，不打印明细）
  --self-test    金丝雀自测：证明能抓到坏样本
  -h | --help    显示本帮助
环境变量:
  ARCH_GATE_FULL=1  追加跑 arch-deps（flutter test 全套依赖护栏，~12s）；
                    默认只跑秒级 arch-guard（R1~R8，含依赖方向五条），
                    因 pre-commit 钩子有 10s 预算而 flutter test 单次 ~12s
退出码: 0=通过 1=检查未通过 2=自身故障
EOF
  exit 0
}

json_out() { # $1=status $2=severity $3=message $4=remedy(可空)；只打印，退出码由调用方 return
  if [ -n "${4:-}" ]; then
    printf '{"status":"%s","severity":"%s","message":"%s","remedy":"%s"}\n' "$1" "$2" "$3" "$4"
  else
    printf '{"status":"%s","severity":"%s","message":"%s"}\n' "$1" "$2" "$3"
  fi
}

detect_touched() {
  # 暂存区有内容按暂存区，否则按工作区相对 HEAD（覆盖 git add -A 前的 pre-commit 直跑）
  if git -C "$ROOT" diff --cached --quiet 2>/dev/null; then
    LIB_TOUCHED=$(git -C "$ROOT" diff --name-only HEAD -- lib | wc -l)
    DOC_TOUCHED=$(git -C "$ROOT" diff --name-only HEAD -- docs | wc -l)
    ANDROID_TOUCHED=$(git -C "$ROOT" diff --name-only HEAD -- android | wc -l)
  else
    LIB_TOUCHED=$(git -C "$ROOT" diff --cached --name-only -- lib | wc -l)
    DOC_TOUCHED=$(git -C "$ROOT" diff --cached --name-only -- docs | wc -l)
    ANDROID_TOUCHED=$(git -C "$ROOT" diff --cached --name-only -- android | wc -l)
  fi
  return 0
}

run() {
  command -v git >/dev/null 2>&1 || { echo "FAIL 自身故障: git 不可用"; return 2; }
  [ -d "$ROOT/.git" ] || { echo "FAIL 自身故障: $ROOT 不是 git 仓库"; return 2; }
  detect_touched
  local rc=0 agg=0
  if [ "$LIB_TOUCHED" -gt 0 ]; then
    echo "==> pre-commit-gate: lib/ 有改动，跑 arch-guard"
    if [ -f "$SCRIPT_DIR/arch-guard.sh" ]; then
      bash "$SCRIPT_DIR/arch-guard.sh" --root "$ROOT" || { rc=1; agg=$((agg+1)); }
    else
      echo "⚠ arch-guard.sh 缺失，跳过（fail-open）"
    fi
  fi
  # 2026-10-17 P0-C：默认门禁跑秒级 shell 护栏（arch-guard R4~R8 已含依赖方向五条）；
  # flutter test 版（arch-deps，~12s 超 pre-commit 10s 预算）走显式开关：
  #   ARCH_GATE_FULL=1 git commit ...  或  toolbox run pre-commit-gate 前 export 之
  if [ "${ARCH_GATE_FULL:-0}" = "1" ] && [ "$LIB_TOUCHED" -gt 0 ]; then
    echo "==> pre-commit-gate: ARCH_GATE_FULL=1，追加跑 arch-deps（flutter test 全套依赖护栏）"
    if [ -f "$SCRIPT_DIR/arch-deps.sh" ]; then
      bash "$SCRIPT_DIR/arch-deps.sh" --root "$ROOT" || { rc=1; agg=$((agg+1)); }
    else
      echo "⚠ arch-deps.sh 缺失，跳过（fail-open）"
    fi
  fi
  if [ "$DOC_TOUCHED" -gt 0 ]; then
    echo "==> pre-commit-gate: docs/ 有改动，跑 docs-lint"
    if [ -f "$SCRIPT_DIR/docs-lint.sh" ]; then
      bash "$SCRIPT_DIR/docs-lint.sh" --root "$ROOT" || { rc=1; agg=$((agg+1)); }
    else
      echo "⚠ docs-lint.sh 缺失，跳过（fail-open）"
    fi
  fi
  if [ "$ANDROID_TOUCHED" -gt 0 ]; then
    echo "==> pre-commit-gate: android/ 有改动，跑 check-contract-sync（AIDL 契约防跨仓漂移）"
    if [ -f "$SCRIPT_DIR/check-contract-sync.sh" ]; then
      bash "$SCRIPT_DIR/check-contract-sync.sh" --root "$ROOT" || { rc=1; agg=$((agg+1)); }
    else
      echo "⚠ check-contract-sync.sh 缺失，跳过（fail-open）"
    fi
  fi
  # drift-guard：契约面漂移（退役词表 / 单源常量 / 超标登记）。引擎在**全局**
  # toolbox 池（跨项目共用一份），数据在本仓 scripts/agent-tools/drift-registry.txt。
  # toolbox 缺失 → fail-open + 明示兜底路径（CI 侧 Dart 镜像仍把关）。
  if [ "$LIB_TOUCHED" -gt 0 ] || [ "$DOC_TOUCHED" -gt 0 ]; then
    echo "==> pre-commit-gate: 有 lib/docs 改动，跑 drift-guard（契约面漂移）"
    if command -v toolbox >/dev/null 2>&1; then
      toolbox run drift-guard --root "$ROOT" || { rc=1; agg=$((agg+1)); }
    else
      echo "⚠ toolbox 不可用，drift-guard 跳过（fail-open：CI 侧 test/architecture/drift_rules_test.dart 仍把关）"
    fi
  fi
  if [ "$rc" -eq 0 ]; then
    if [ "$JSON_ONLY" -eq 1 ]; then
      json_out "OK" "info" "pre-commit门禁通过" ""
      return 0
    fi
    echo "OK: pre-commit 门禁通过（lib 改动=$LIB_TOUCHED docs 改动=$DOC_TOUCHED）"
    return 0
  fi
  if [ "$JSON_ONLY" -eq 1 ]; then
    json_out "FAIL" "error" "pre-commit门禁: $agg 项未过（lib=$LIB_TOUCHED docs=$DOC_TOUCHED）" "裸跑对应工具看明细；历史遗留加各工具白名单只减不增"
    return 1
  fi
  echo "FAIL: $agg 项门禁未过，禁止提交"
  echo "[remedy] 裸跑对应工具看逐条明细；历史遗留豁免加各工具白名单（只减不增）"
  return 1
}

self_test() {
  local tmp rc=0
  tmp=$(mktemp -d) || return 2
  (
    cd "$tmp" && git init -q . && mkdir -p lib/ui docs
    echo 'void x() {}' > lib/ui/bad.dart
    printf -- '---\nstatus: active\nupdated: 2026-10-13\n---\n# doc\n' > docs/ok.md
    printf '# index\n- [ok.md](ok.md)\n' > docs/README.md
    git add -A
    git -c user.email=t@t -c user.name=t commit -qm init --allow-empty
    # 坏样本：UI 层直连 dart:io（arch-guard R1 应抓到）
    printf "import 'dart:io';\nvoid f() { File('x'); }\n" > lib/ui/bad.dart
    git add -A
  )
  sh "$0" --root "$tmp" >/dev/null 2>&1
  local bad_rc=$?
  ( cd "$tmp" && printf 'void ok() {}\n' > lib/ui/bad.dart && git add -A )
  sh "$0" --root "$tmp" >/dev/null 2>&1
  local good_rc=$?
  rm -rf "$tmp"
  if [ "$bad_rc" -eq 1 ] && [ "$good_rc" -eq 0 ]; then
    echo "self-test PASS: 坏样本被拦(exit 1)、净样本放行(exit 0)"
    return 0
  fi
  echo "FAIL self-test: bad_rc=$bad_rc good_rc=$good_rc（预期 1/0）"
  return 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift 2 ;;
    --json) JSON_ONLY=1; shift ;;
    --self-test) SELF_TEST=1; break ;;
    -h|--help) usage ;;
    *) echo "未知参数: $1"; usage ;;
  esac
done

ROOT="${ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ "$SELF_TEST" -eq 1 ]; then self_test; exit $?; fi
run
exit $?
