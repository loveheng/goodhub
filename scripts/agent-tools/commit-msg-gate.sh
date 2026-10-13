#!/bin/bash
# commit-msg-gate — Conventional Commits 提交信息校验（commit-msg 钩子）
# 校验格式 type(scope)?: subject（中英均可）；body/trailer 不限。
# 允许 type: feat fix docs style refactor perf test build ci chore revert
#
# toolbox-script
# format: v1
# name: commit-msg-gate
# summary: 提交信息 Conventional Commits 校验：type(scope)?: subject 格式、type 白名单、subject 非空非纯空白
# trigger: manual
# cat: test
# alias: cmg
# platform: unix
# self-test: --self-test

set -u
MSG_FILE=''; JSON_ONLY=0

usage() {
  cat <<'EOF'
用法: commit-msg-gate.sh <commit-msg文件> [选项]   （toolbox run commit-msg-gate <文件> [选项] 等价）
  校验提交信息首行是否符合 Conventional Commits：
    <type>(<scope>)?: <subject>
  type 白名单: feat fix docs style refactor perf test build ci chore revert
  scope 可选；subject 非空且不以空白开头。merge/revert 自动生成的标题放行。
选项:
  --json         只输出一行 JSON 结论（供 AI/钩子判定，不打印明细）
  --self-test    金丝雀自测：内嵌好/坏样本证明判定正确
  -h | --help    显示本帮助
退出码: 0=通过 1=检查未通过 2=自身故障
EOF
  exit 0
}

check_msg() { # $1=消息文件；0=通过 1=违规
  local first types rx
  [ -f "$1" ] || { echo "FAIL 自身故障: 消息文件不存在 $1"; return 2; }
  first=$(head -n 1 "$1")
  # merge / revert 自动标题放行
  case "$first" in
    "Merge "*|"Revert \""*) return 0 ;;
  esac
  types='feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert'
  rx="^($types)(\([a-zA-Z0-9_/.-]+\))?!?: [^[:space:]].+$"
  if printf '%s' "$first" | grep -Eq "$rx"; then
    return 0
  fi
  echo "FAIL 提交信息首行不符合 Conventional Commits: $first"
  echo "[remedy] 格式 <type>(scope)?: <subject>，type 取 feat/fix/docs/style/refactor/perf/test/build/ci/chore/revert，如: git commit --amend -m 'fix(share): 修正附件路径'"
  return 1
}

report_json() { # $1=rc $2=首行
  if [ "$1" -eq 0 ]; then
    printf '{"status":"OK","severity":"info","message":"commit-msg: 格式合规"}\n'
  else
    printf '{"status":"FAIL","severity":"error","message":"commit-msg 首行不符合 Conventional Commits: %s","remedy":"格式 type(scope)?: subject；type 取 feat/fix/docs/style/refactor/perf/test/build/ci/chore/revert"}\n' "$2"
  fi
  return "$1"
}

self_test() {
  local tmp good bad merge
  tmp=$(mktemp) || return 2
  printf 'fix(share): 修正附件路径\n\n正文。\n' > "$tmp"
  check_msg "$tmp" >/dev/null 2>&1; good=$?
  printf '更新了一些东西\n' > "$tmp"
  check_msg "$tmp" >/dev/null 2>&1; bad=$?
  printf 'Merge branch "feature/x"\n' > "$tmp"
  check_msg "$tmp" >/dev/null 2>&1; merge=$?
  rm -f "$tmp"
  if [ "$good" -eq 0 ] && [ "$bad" -eq 1 ] && [ "$merge" -eq 0 ]; then
    echo "self-test PASS: 合规格式放行、不合规拦截、merge 标题放行"
    return 0
  fi
  echo "FAIL self-test: good=$good bad=$bad merge=$merge（预期 0/1/0）"
  return 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON_ONLY=1; shift ;;
    --self-test) self_test; exit $? ;;
    -h|--help) usage ;;
    -*) echo "未知参数: $1"; usage ;;
    *) MSG_FILE="$1"; shift ;;
  esac
done

[ -n "$MSG_FILE" ] || {
  if [ "$JSON_ONLY" -eq 1 ]; then
    printf '{"status":"FAIL","severity":"error","message":"commit-msg-gate: 缺 commit-msg 文件参数","remedy":"用法 toolbox run commit-msg-gate <commit-msg文件>"}\n'
    exit 1
  fi
  echo "FAIL 自身故障: 缺 commit-msg 文件参数"
  exit 2
}
first=$(head -n 1 "$MSG_FILE")
if [ "$JSON_ONLY" -eq 1 ]; then
  check_msg "$MSG_FILE" >/dev/null 2>&1
  report_json "$?" "$first"
  exit $?
fi
check_msg "$MSG_FILE"
exit $?
