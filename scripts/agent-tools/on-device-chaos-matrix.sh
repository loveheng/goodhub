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
LONG=0
while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h) usage ;;
    --json) JSON=1; shift ;;
    --long) LONG=1; shift ;;
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

# 驱动位（断言逐例点亮 2026-11-06 真机轮：kill/rebind 纯 adb 可自动化；
# evict/reload 走 --long 真 TTL 等待；asset-swap/load-stall 依赖 UI/注入面
# 保持占位——前置见各例注记，严禁假绿）。
ADB_LOG() { adb -s "$DEVICE" logcat -d -t "$1" 2>/dev/null; }

ENGINE_PID() {
    adb -s "$DEVICE" shell pidof "$PKG:engine" 2>/dev/null | tr -d '\r'
}

# 断言等 N 秒内 logcat 出现锚点行（打点起点 = 注入前，防竞态漏读）。
await_log() { # $1=等待秒 $2=锚点 grep -E 模式 $3=起点标记行数前缀（logcat -T）
    local tries=0
    while [ "$tries" -lt "$1" ]; do
        if adb -s "$DEVICE" logcat -d -T "$3" 2>/dev/null | grep -qE "$2"; then
            return 0
        fi
        tries=$((tries + 1))
        sleep 1
    done
    return 1
}

run_case() {
  case "$1" in
    kill)
      # 注入：kill :engine。**2026-11-06 真机结论（Ace 6，非 root）**：
      # kill -9（SELinux 拒）/ run-as（seapp_context 拒）/ am kill（FGS 豁免）
      # 三路全部无法单独杀 :engine——注入位 = debug action kill_engine
      # （复用 cold-reload-restart 自杀契约，待扩面后点亮断言）。
      # 断言逻辑在位：await_log "death cause=|onProcessDied"。
      fail "kill: 无注入位（非 root 三路拒绝，见上方结论）——待 debug action kill_engine 扩面后点亮"
      ;;
    rebind)
      # 注入同 kill（断连前提 = 能杀 :engine）。断言逻辑在位：
      # 等 45s 内 pidof 新 pid ≠ 旧 pid（Fix2 活引擎判据重绑的物理证据）。
      fail "rebind: 无注入位（同 kill）——待 debug action kill_engine 扩面后点亮"
      ;;
    evict|reload)
      [ "$LONG" = "1" ] || fail "case $1: 需 --long（TTL 5min WARM_STANDBY 真等待；暂无驱逐注入位）"
      fail "case $1: --long TTL 等待断言待下一真机窗口补齐（onEngineEvicted/reloading 序数 8 对账行口径已在案）"
      ;;
    asset-swap|load-stall)
      fail "case $1: 依赖 UI 驱动（删除→重导入）/ 装载停滞注入面（LOAD_STALLED 需真实 90s 停滞），暂无可自动化注入位——待 debug action 扩面后点亮"
      ;;
    *) fail "未知用例: $1" ;;
  esac
}

case "$CASE" in
  kill|rebind|evict|reload|asset-swap|load-stall) run_case "$CASE" ;;
  all) for c in kill rebind evict reload asset-swap load-stall; do run_case "$c"; done ;;
  *) fail "未知用例: $CASE" ;;
esac
