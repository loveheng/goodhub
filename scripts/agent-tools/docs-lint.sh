#!/bin/bash
# docs-lint — docs/ 工程文档机械校验（docs-spec §6 落地）
# ① frontmatter 四项校验 ② 根目录平铺检查 ③ README 双向覆盖（链接存在 + 非孤儿）
# 严重级：E=错误(阻断) / W=警告(阻断) / I=提示(不阻断)
#   deprecated 墓碑属 I：docs-spec §4 明令「不删」、废弃态长期存在，且检索入口本就靠
#   `status: deprecated`——若判阻断则等于禁止规范动作，故只提示。
#
# toolbox-script
# format: v1
# name: docs-lint
# summary: docs/ 机械校验：frontmatter status/updated 四项、根目录平铺、README 双向覆盖（链接存在性+孤儿检测）；deprecated 墓碑为提示级不阻断（docs-spec §4）
# trigger: pre-commit
# cat: docs
# alias: dl
# platform: unix
# self-test: --self-test

set -u
ROOT=''; FINDINGS=''; ERR=0; WARN=0; INFO=0; JSON_ONLY=0

usage() {
  cat <<'EOF'
用法: docs-lint.sh [选项]          （toolbox run docs-lint [选项] 等价）
  校验 docs/ 全部 .md：frontmatter（status/updated/字段量）、根目录平铺、
  README.md 双向覆盖（README 链接的文件必须存在；非 README 文档必须在 README 有条目）。
选项:
  --root <目录>  指定仓库根（默认 git 顶层 / 当前目录）
  --json         只输出一行 JSON 结论（供 AI/钩子判定，不打印明细）
  --self-test    金丝雀自测：内嵌已知坏样本证明能抓到坏
  -h | --help    显示本帮助
退出码: 0=通过 1=检查未通过 2=自身故障
EOF
  exit 0
}

add() { # $1=级别（E=错误阻断 / W=警告阻断 / I=提示不阻断）$2=消息（消息内禁双引号，json 契约要求）
  case "$1" in
    E) ERR=$((ERR+1)) ;;
    W) WARN=$((WARN+1)) ;;
    *) INFO=$((INFO+1)) ;;
  esac
  FINDINGS="${FINDINGS}$1 $2\n"
}

lint_docs() {
  local docs="$ROOT/docs"
  [ -d "$docs" ] || { add E "docs/ 目录不存在于 $ROOT"; return 0; }

  # ① frontmatter 四项校验（docs-spec §6①：行1=--- 行2=status 行3=updated 行4=---）
  local f l1 l2 l3 l4
  while IFS= read -r f; do
    l1=$(sed -n '1p' "$f"); l2=$(sed -n '2p' "$f"); l3=$(sed -n '3p' "$f"); l4=$(sed -n '4p' "$f")
    case "$l1" in "---") : ;; *) add E "${f#$ROOT/} 缺frontmatter开头" ;; esac
    case "$l2" in "status: draft"|"status: active"|"status: deprecated") : ;; *) add E "${f#$ROOT/} status异常($l2)" ;; esac
    case "$l2" in "status: deprecated") add I "${f#$ROOT/} 已废弃（Tombstone, docs-spec §4）——严禁当现行事实引用, 引用前须按其首行墓碑转向继任文档" ;; esac
    case "$l3" in "updated: "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]|updated:[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) : ;; *) add E "${f#$ROOT/} updated异常($l3)" ;; esac
    case "$l4" in "---") : ;; *) add E "${f#$ROOT/} 字段超量(应仅status/updated)" ;; esac
  done < <(find "$docs" -name '*.md' ! -name README.md)

  # ② 根目录平铺检查（docs-spec §6②，README.md 豁免）
  local flat
  flat=$(find "$docs" -maxdepth 1 -name '*.md' ! -name README.md)
  [ -n "$flat" ] && add E "docs/ 根目录平铺: $(echo "$flat" | tr '\n' ' ')"

  # ③ README 双向覆盖（docs-spec §5：双向覆盖原则）
  local readme="$docs/README.md" link doc
  if [ ! -f "$readme" ]; then
    add W "docs/README.md 缺失（纯结构索引）"
  else
    # ③a README 链接的文档必须存在
    while IFS= read -r link; do
      [ -z "$link" ] && continue
      case "$link" in http*|\#*) continue ;; esac
      link="${link%%\?*}"
      [ -f "$docs/$link" ] || [ -f "$ROOT/$link" ] || add E "README 链接不存在: $link"
    done < <(grep -o '](\([^)]\+\.md\))' "$readme" | sed 's/^](\(.*\))$/\1/')
    # ③b 每个 docs 下非 README 文档必须在 README 有条目（README 链接相对 docs/）
    while IFS= read -r doc; do
      local rel="${doc#"$docs"/}"
      grep -qF "($rel)" "$readme" || add E "孤儿文档（README 无条目）: docs/$rel"
    done < <(find "$docs" -name '*.md' ! -name README.md)
  fi
  return 0
}

report() {
  if [ "$JSON_ONLY" -eq 1 ]; then
    if [ "$ERR" -eq 0 ]; then
      printf '{"status":"OK","severity":"info","message":"docs-lint: %d项通过（warn=%d, info=%d）"}\n' "$((ERR+WARN+INFO))" "$WARN" "$INFO"
    else
      printf '{"status":"FAIL","severity":"error","message":"docs-lint: %d项错误 %d项警告","remedy":"裸跑 toolbox run docs-lint 看逐条明细；frontmatter 格式见 docs-spec §1"}\n' "$ERR" "$WARN"
    fi
    return $([ "$ERR" -eq 0 ] && echo 0 || echo 1)
  fi
  if [ "$ERR" -eq 0 ] && [ "$WARN" -eq 0 ]; then
    if [ "$INFO" -gt 0 ]; then printf '%b' "$FINDINGS"; echo "----"; fi
    echo "OK: docs/ 全部校验通过（提示 $INFO 项，提示级不阻断）"
    return 0
  fi
  printf '%b' "$FINDINGS"
  echo "----"
  echo "FAIL: $ERR 项错误，$WARN 项警告"
  echo "[remedy] frontmatter 格式见 docs-spec §1；README 索引条目格式见现有条目"
  return 1
}

self_test() {
  local tmp bad_rc good_rc
  tmp=$(mktemp -d) || return 2
  mkdir -p "$tmp/docs/guide"
  # 坏样本：缺 frontmatter + 根目录平铺 + 孤儿文档
  printf '# no fm\n' > "$tmp/docs/guide/bad.md"
  printf '# flat\n' > "$tmp/docs/flat.md"
  printf '# index\n' > "$tmp/docs/README.md"
  bash "$0" --root "$tmp" >/dev/null 2>&1; bad_rc=$?
  # 好样本：齐 frontmatter + README 条目
  printf -- '---\nstatus: active\nupdated: 2026-09-28\n---\n# ok\n' > "$tmp/docs/guide/bad.md"
  rm "$tmp/docs/flat.md"
  # 废弃态样本：deprecated 是 docs-spec §4 标准手段，属提示级不阻断——净样本仍须放行 exit 0
  printf -- '---\nstatus: deprecated\nupdated: 2026-09-28\n---\n# dep\n' > "$tmp/docs/guide/dep.md"
  printf -- '---\nstatus: active\nupdated: 2026-09-28\n---\n# idx\n- [bad.md](guide/bad.md)\n- [dep.md](guide/dep.md)\n' > "$tmp/docs/README.md"
  bash "$0" --root "$tmp" >/dev/null 2>&1; good_rc=$?
  rm -rf "$tmp"
  if [ "$bad_rc" -eq 1 ] && [ "$good_rc" -eq 0 ]; then
    echo "self-test PASS: 坏样本被抓(exit 1)、净样本放行(exit 0)"
    return 0
  fi
  echo "FAIL self-test: bad_rc=$bad_rc good_rc=$good_rc（预期 1/0）"
  return 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift 2 ;;
    --json) JSON_ONLY=1; shift ;;
    --self-test) self_test; exit $? ;;
    -h|--help) usage ;;
    *) echo "未知参数: $1"; usage ;;
  esac
done

ROOT="${ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[ -d "$ROOT" ] || { echo "FAIL 自身故障: 根目录不存在 $ROOT"; exit 2; }
lint_docs
report
exit $?
