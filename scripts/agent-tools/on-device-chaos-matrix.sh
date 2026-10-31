#!/usr/bin/env bash
# toolbox-script
# format: v1
# name: on-device-chaos-matrix
# summary: 端侧混沌矩阵（kill×rebind×evict×reload×资产替换 + F2 modelId 失配 / F4 装载停滞新用例）真机回归驱动
# trigger: manual
# platform: unix
# 备注: 需真机侧载 debug 包 + adb 在线；断言取 logcat 关键对账行（投影零漂移）。

set -u

PKG="com.zzh.goodhub"
ENGINE_PID_FMT='%d'

usage() {
cat <<EOF
on-device-chaos-matrix — 端侧混沌矩阵真机回归驱动（骨架，2026-10-31 F6）

用法:
  on-device-chaos-matrix.sh --device <SERIAL> [--case <NAME>] [--json]

用例集（每例后断言 logcat 对账行，任一失败即 FAIL）:
  kill            :engine 强杀 → 进程死亡 → 后台重试重装 → ready（零漂移）
  rebind          : 断连后 bind() 幂等重发（Fix2 活引擎判据）→ 重连回调齐
  evict           : 空闲 TTL 驱逐 → onEngineEvicted 上行 → 投影作废（非猜测）
  reload          : 空闲回收后重载 → reloading 序数 8 → 冷启动新进程装载（禁报「未导入」）
  asset-swap      : 删除→重导入→立刻提问 → SESSION_MODEL_MISMATCH 分码（F2 新用例）→ 重装
  load-stall      : 模拟装载停滞 → :engine LOAD_STALLED 自裁 → reloading 链路接管（F4 新用例）

前置: flutter build apk --debug && adb install -r（装机纪律查 lessons.md android-ops 节）
EOF
exit 0
}

JSON=0
DEVICE=""
CASE="all"
while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h) usage ;;
    --json) JSON=1; shift ;;
    --device) DEVICE="${2:-}"; shift 2 ;;
    --case) CASE="${2:-all}"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; usage ;;
  esac
done

if [ -z "$DEVICE" ]; then
  if [ "$JSON" = "1" ]; then
    echo '{"status":"FAIL","severity":"error","message":"missing --device","remedy":"pass adb serial (flutter devices)"}'
  else
    echo "✕ 缺 --device（真机序列号，flutter devices 查询）" >&2
  fi
  exit 1
fi

fail() {
  if [ "$JSON" = "1" ]; then
    echo "{\"status\":\"FAIL\",\"severity\":\"error\",\"message\":\"$1\",\"remedy\":\"check logcat -s flutter:* + [DIAG] 对账行\"}"
  else
    echo "✕ $1"
  fi
  exit 1
}

command -v adb >/dev/null 2>&1 || fail "adb 不在 PATH（export PATH=\$HOME/android-sdk/platform-tools:\$PATH）"
adb -s "$DEVICE" get-state >/dev/null 2>&1 || fail "设备 $DEVICE 不在线"

# 骨架：逐用例驱动位（真机回归轮按断言行补齐，登记制=本文件唯一存放点）
# run_case <NAME>：驱动动作 + logcat 断言（对账行口径见设计稿 §6）
run_case() {
  echo "▷ case: $1（断言位待真机轮补齐——骨架不伪造通过）"
  fail "case $1: 骨架未实现断言（严禁假绿，真机回归轮补齐后逐例点亮）"
}

case "$CASE" in
  kill|rebind|evict|reload|asset-swap|load-stall) run_case "$CASE" ;;
  all) for c in kill rebind evict reload asset-swap load-stall; do run_case "$c"; done ;;
  *) fail "未知用例: $CASE" ;;
esac
