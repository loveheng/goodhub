#!/usr/bin/env bash
# release-r2 — goodhub 一键发布到 Cloudflare R2（应用内自更新源）
#
# toolbox-script
# format: v1
# name: release-r2
# summary: goodhub 发布到 R2：analyze+release 构建+清单生成+上传（薄包装，真身 scripts/release-r2.sh，参数原样透传）
# trigger: manual
# platform: unix
# cat: deploy
# alias: r2

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TARGET="$REPO_ROOT/scripts/release-r2.sh"

usage() {
  cat <<'EOF'
用法: release-r2.sh [选项]        （toolbox run release-r2 [选项] 等价）
作用: goodhub 一键发布到 Cloudflare R2（应用内自更新源）。
      本脚本为薄包装，参数原样透传给真身 scripts/release-r2.sh（路径不动，文档指针不受影响）。
选项（透传）:
  -n, --dry-run 只预览发布步骤，不构建不上传
  --commit      发布成功后把 updates/goodhub-update.json 提交进仓库
  -h, --help    真身用法
本包装独有:
  --json        环境预检（一行 JSON 结论：真身存在/.env R2 凭证/node/flutter 就绪性），不执行发布
说明: --json 只做预检；真正发布用裸跑（无参数或带透传选项）。
前置: 仓库根 .env（或 scripts/.env）配置 R2_ACCOUNT_ID / R2_ACCESS_KEY_ID /
      R2_SECRET_ACCESS_KEY / R2_PUBLIC_DOMAIN，参考 .env.example。
EOF
}

json_out() { # status severity message [remedy]
  if [ -n "${4:-}" ]; then
    printf '{"status":"%s","severity":"%s","message":"%s","remedy":"%s"}\n' "$1" "$2" "$3" "$4"
  else
    printf '{"status":"%s","severity":"%s","message":"%s"}\n' "$1" "$2" "$3"
  fi
}

precheck_json() {
  [ -f "$TARGET" ] || { json_out FAIL error "发布真身不存在: scripts/release-r2.sh" "确认在 goodhub 仓库内运行"; exit 1; }
  local env_file="" missing=()
  [ -f "$REPO_ROOT/.env" ] && env_file="$REPO_ROOT/.env"
  [ -f "$REPO_ROOT/scripts/.env" ] && env_file="$REPO_ROOT/scripts/.env"
  if [ -z "$env_file" ]; then
    json_out FAIL error "未找到 .env（仓库根或 scripts/）" "复制 .env.example 为 .env 并填入 R2 凭证"
    exit 1
  fi
  local key
  for key in R2_ACCOUNT_ID R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_PUBLIC_DOMAIN; do
    grep -qE "^[[:space:]]*${key}=" "$env_file" || missing+=("$key")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    json_out FAIL error ".env 缺少 R2 配置: ${missing[*]}" "参考 .env.example 补齐四项后重试"
    exit 1
  fi
  command -v node >/dev/null 2>&1 || { json_out FAIL error "node 不可用（上传依赖）" "安装 node 后重试"; exit 1; }
  if ! command -v flutter >/dev/null 2>&1 && [ ! -x "$HOME/flutter/bin/flutter" ]; then
    json_out FAIL error "flutter 不可用" "确认 ~/flutter/bin/flutter 存在并纳入 PATH"; exit 1
  fi
  json_out OK info "发布环境就绪：真身/.env R2 凭证/node/flutter 齐备，可裸跑发布"
  exit 0
}

case "${1:-}" in
  --json) precheck_json ;;
  -h|--help) usage; exit 0 ;;
esac

[ -f "$TARGET" ] || { echo "FAIL: 发布真身不存在: $TARGET"; echo "[remedy] 确认在 goodhub 仓库内运行"; exit 2; }
exec bash "$TARGET" "$@"
