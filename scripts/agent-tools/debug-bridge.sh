#!/usr/bin/env bash
# toolbox-script
# format: v1
# name: debug-bridge
# summary: AI 真机调试桥 CLI（adb forward + token 发现 + /debug/* 透传 + capture 会话日志采集）
# trigger: manual
# platform: unix
# alias: dbg
# cat: test
# self-test: --self-test

set -u

PORT=""
DEVICE=""
CMD=""
APP_NAME=""
NAME=""
PAGE=""
JSON_ARGS='{}'
SINCE=0
MODE=run

# capture：会话级日志采集（目录可由 DEBUG_BRIDGE_CAPTURE_DIR 覆盖）。
CAP_DIR=""
CAP_ROOT=""
CAP_SESSION=""
CAP_SUB=""
CAP_MAX_LINES=50000       # 单个 device 分片行数上限（端侧洪泛实证 290 万行/轮）
CAP_KEEP=3               # 保留最近几个分片
CAP_INTERVAL=2            # /debug/state revision 轮询间隔（秒）
CAP_LINES=40              # focus 每类最多输出条数
CAP_ALL=0

# 宿主 app 包名（前台守卫 / soft-hint 判定用）。默认 GoodHub；跨项目分发时
# 各仓副本用 DEBUG_BRIDGE_APP_PACKAGE 覆盖（goodshare / goodTemplate /
# shiguang 包名各异——硬编码会让守卫永远误判 is_goodhub=false）。
APP_PACKAGE="${DEBUG_BRIDGE_APP_PACKAGE:-com.zzh.goodhub}"

usage() {
  cat <<'EOF'
debug-bridge — AI 真机调试桥 CLI（薄管道：只做 adb forward + token 提取 + HTTP 透传）

统一入口: goodhub 仓主副本，--app 分层切换目标 App（按包名 pid 发现各自
桥端口+token，端口互异 token 隔离，防同机多 App 串台）。

用法:
  debug-bridge.sh --device <SERIAL> [--app <name>] <command> [args]
  debug-bridge.sh --json                      # 预检结论，不执行任务本体
  debug-bridge.sh --self-test                 # 参数校验金丝雀

命令:
  state                       GET  /debug/state
  logs [--since N]            GET  /debug/logs?since=N
  ui-tree                     GET  /debug/ui-tree
  action <name> [JSON_ARGS]   POST /debug/action  {"action":name,"args":JSON_ARGS}
  navigate <page>             action navigate {"page":page}
  ping                        action ping（检查 UI 执行面是否挂载）
  list-models                 action list_models（列已装端侧模型 + 各自当前策略 + 选中态）
  set-policy <id> [modelDir]  action set_history_policy {"policyId":id,"modelDir":...}
  get-policy [modelDir]       action get_history_policy {"modelDir":...}
  query-ondevice <prompt> [policyId]  直接驱动端侧引擎跑一轮（策略 A/B 用；history 用 action query_on_device --file）
  tap_bounds <x,y[,w,h]>      逻辑坐标点击（ui-tree bounds 直接粘贴；桥内换算
                              设备像素，含前台守卫——防误触其他 app）
  wait_log <ERE> [timeout_s]  阻塞等 logcat 出现匹配行（默认 60s，2s 步进；
                              语义等待替代 sleep 盲等）
  device-log [ERE] [N]        一次性拉 logcat 最近 N 行（默认 200）文本过滤
                              （-a 纯文本模式，规避二进制行 grep 失效）
  foreground                  报告当前前台包名 + 是否 GoodHub——消除「我在
                              哪个 app」盲区（SAF/系统弹窗时判断用桥面还是
                              系统级驱动）
  system-ui [text_substr]     系统 UI 可点节点结构化导出（uiautomator dump +
                              ElementTree 解析：text/desc/clickable/bounds
                              中心点；可选 text 子串过滤）——SAF 选择器/权限
                              弹窗等 Flutter 树外的系统 UI 驱动入口
  system-tap <x,y>            系统级 tap（设备像素直接 tap，豁免 GoodHub 前台
                              守卫——就是要点系统层；软提示当前前台防误触）
  capture <start|stop|tail|status> [--dir <path>] [--max-lines N] [--keep N]
                              [--interval S] [--lines N] [--all]
                              会话级日志采集：流式 logcat 按目标 App 全部 pid
                              （含 :engine）过滤落 device.*.log 分片；桥结构化
                              日志按 /debug/state logRevision 变化增量抓取并
                              本地去重落 app.jsonl；tail 生成 focus 重点摘要。
                              start 后台常驻、stop 幂等收尾、status 报体量。

示例:
  toolbox run debug-bridge --device <SERIAL> ui-tree
  toolbox run debug-bridge --device <SERIAL> action tap_node '{"key":"composer-attach"}'
  toolbox run debug-bridge --device <SERIAL> navigate logs
  toolbox run debug-bridge --device <SERIAL> capture start
  toolbox run debug-bridge --device <SERIAL> capture tail
  toolbox run debug-bridge --device <SERIAL> capture stop

前置: 真机装 debug 包并启动（toolbox run build-apk --install）；token 由 logcat 现取。
输出: 端点原始 JSON（不做业务解析，交给调用方）。--json 只回一行契约结论。

capture 产物默认 <DEBUG_BRIDGE_CAPTURE_DIR 或 /tmp/goodhub-capture>/session-*/：
  meta.json / pids / bridge.json(600) / app.jsonl / app.seen / device.NNN.log /
  focus.md / collector.log
device 通道不依赖桥；桥不可用时 app 通道留 [DEGRADE] 并周期重试发现。start
时若桥可发现，凭据缓存进 bridge.json，避免启动行被 logcat 冲掉后无法重连。
pid 集在 start 时固定：App 冷启动会换 pid 与 token，需重新 capture start。
多 App 或多次会话并行须各自指定 --dir；新 start 不自动停旧会话，切换前先
capture stop --dir <旧目录>。采集原文含桥 token 与用户输入——禁入 git 与
context/，focus 输出已脱敏，原文件用毕自行清理。--json 仅预检，不执行采集。
EOF
}

json_ok() { printf '{"status":"OK","severity":"info","message":"%s"}\n' "$1"; exit 0; }
json_fail() {
  printf '{"status":"FAIL","severity":"error","message":"%s","remedy":"%s"}\n' "$1" "$2"
  exit 1
}
fail() {
  echo "[remedy] $2" >&2
  echo "FAIL: $1" >&2
  exit 1
}

valid_name() { printf '%s' "$1" | grep -Eq '^[a-z_][a-z0-9_-]*$'; }
valid_page() { printf '%s' "$1" | grep -Eq '^[a-z][a-z0-9-]*$'; }

self_test() {
  valid_name tap_node || { echo "self-test: 好动作名被拒"; return 2; }
  ! valid_name 'tap;rm -rf /' || { echo "self-test: 坏动作名未拦住"; return 2; }
  valid_page logs || { echo "self-test: 好页面名被拒"; return 2; }
  ! valid_page 'logs/../x' || { echo "self-test: 坏页面名未拦住"; return 2; }
  valid_cap_dir /tmp/gh-cap || { echo "self-test: 好采集目录被拒"; return 2; }
  ! valid_cap_dir '/tmp/a b;rm' || { echo "self-test: 坏采集目录未拦住"; return 2; }
  valid_uint 50000 || { echo "self-test: 好行数被拒"; return 2; }
  ! valid_uint '50;rm' || { echo "self-test: 坏行数未拦住"; return 2; }
  APP_NAME=shiguang; map_app
  [ "$APP_PACKAGE" = "app.shiguang.shiguang" ] || { echo "self-test: shiguang 别名映射错误"; return 2; }
  APP_NAME=goodTemplate; map_app
  [ "$APP_PACKAGE" = "com.goodhub.good_template" ] || { echo "self-test: goodTemplate 别名映射错误"; return 2; }
  echo "self-test: OK（好/坏样本各 4 例 + 别名 2 例）"
  return 0
}

precheck() {
  command -v adb >/dev/null 2>&1 || return 1
  command -v curl >/dev/null 2>&1 || return 1
  adb -s "$DEVICE" get-state >/dev/null 2>&1 || return 1
  return 0
}

# 统一入口核心：按目标包名发现该 App 的调试桥端口与 token（多 App 共存）。
# pidof 给出目标包全部 pid，用 logcat 第 3/4 列过滤——同机多 App 各持桥
# （端口互异、token 各自隔离），按 pid 匹配天然防串台。只认含 token= 的
# 启动行，[DEGRADE] 启动失败行不带 token，天然排除。
resolve_bridge() {
  local pids line
  pids="$(adb -s "$DEVICE" shell pidof "$APP_PACKAGE" 2>/dev/null \
    | tr -d '\r' | tr '\n' ' ')"
  [ -n "${pids// /}" ] || return 1
  line="$(adb -s "$DEVICE" logcat -d 2>/dev/null \
    | grep -aF 'token=' \
    | grep -aF '[debug-bridge]' \
    | awk -v p="$pids" '
        BEGIN { n=split(p, a, /[ \t]+/); for (i=1;i<=n;i++) if (a[i] != "") ok[a[i]]=1 }
        ($3 in ok) || ($4 in ok) { last=$0 }
        END { print last }')"
  [ -n "$line" ] || return 1
  TOKEN="$(printf '%s' "$line" | grep -oE 'token=[^ ]+' | tail -1 \
    | cut -d= -f2 | tr -d '\r[:space:]')"
  PORT="$(printf '%s' "$line" | grep -oE '127\.0\.0\.1:[0-9]+' | head -1 \
    | cut -d: -f2 | tr -d '\r[:space:]')"
  [ -n "$TOKEN" ] && [ -n "$PORT" ]
}

# --app 别名 → 包名映射（统一入口分层切换；新 App 接入 = 加一行映射）。
# 兜底：DEBUG_BRIDGE_APP_PACKAGE 环境变量可直接传原始包名。
map_app() {
  case "$APP_NAME" in
    ""|goodhub) : ;;
    goodshare)  APP_PACKAGE="com.zzh.goodshare" ;;
    shiguang)   APP_PACKAGE="app.shiguang.shiguang" ;;
    goodTemplate) APP_PACKAGE="com.goodhub.good_template" ;;
    *) fail "未知 --app: $APP_NAME" "可用: goodhub / goodshare / shiguang / goodTemplate；其他 App 用 DEBUG_BRIDGE_APP_PACKAGE=<包名> 直传" ;;
  esac
}

# 提取当前前台 app 包名（dumpsys topResumedActivity 的 `u0 <pkg>/` 段）。
# 通用提取（不限定宿主包名），配合 [APP_PACKAGE] 做精确匹配——跨项目分发后
# 守卫/soft-hint 仍按各自包名判定，不再依赖 goodhub 硬编码。
foreground_pkg() {
  adb -s "$DEVICE" shell dumpsys activity activities 2>/dev/null \
    | grep -E 'topResumedActivity|ResumedActivity' | tail -1 \
    | grep -oE 'u0 [a-zA-Z0-9_.]+/' | head -1 \
    | awk '{print $2}' | sed 's|/$||'
}

# ---- capture：会话级日志采集 ----
# 采集目录由本工具生成或 --dir 显式给出；限安全字符集，防 awk system() 与
# shell 拼接注入（toolbox spec：禁交互输入、结果可重复）。
valid_cap_dir() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9_/.-]+$'; }
valid_uint() { printf '%s' "$1" | grep -Eq '^[0-9]+$' && [ "$1" -gt 0 ]; }

cap_root() {
  if [ -n "$CAP_DIR" ]; then CAP_ROOT="$CAP_DIR"
  else CAP_ROOT="${DEBUG_BRIDGE_CAPTURE_DIR:-/tmp/goodhub-capture}"; fi
  valid_cap_dir "$CAP_ROOT" || fail "非法采集目录: $CAP_ROOT" "仅允许字母数字 / _ . -；或设 DEBUG_BRIDGE_CAPTURE_DIR"
}

cap_current() {
  [ -f "$CAP_ROOT/current" ] || fail "当前无采集会话" "先 capture start [--dir <path>]；或用 --dir 指定已有会话根目录"
  CAP_SESSION="$(cat "$CAP_ROOT/current")"
  valid_cap_dir "$CAP_SESSION" || fail "会话路径异常: $CAP_SESSION" "检查 $CAP_ROOT/current 内容"
  [ -d "$CAP_SESSION" ] || fail "会话目录不存在: $CAP_SESSION" "重新 capture start"
}

cap_pid_alive() {
  [ -f "$CAP_SESSION/collector.pid" ] || return 1
  local p; p="$(cat "$CAP_SESSION/collector.pid")"
  case "$p" in *[!0-9]*) return 1 ;; esac
  kill -0 "$p" 2>/dev/null
}

# 目标 App 全部 pid：ps -A 最后一列是进程名，主进程与 :engine 等子进程一并纳入
# （只按主 pid 过滤会丢端侧引擎日志）。
cap_pids() {
  adb -s "$DEVICE" shell ps -A 2>/dev/null \
    | awk -v p="$APP_PACKAGE" '$NF ~ ("^" p "(:|$)") { print $2 }' \
    | tr -d '\r' | sort -u
}

cap_start() {
  cap_root
  mkdir -p "$CAP_ROOT" || fail "建采集根目录失败: $CAP_ROOT" "检查路径权限"
  CAP_SESSION="$CAP_ROOT/session-$(date +%Y%m%d-%H%M%S)-$$"
  mkdir -p "$CAP_SESSION" || fail "建会话目录失败: $CAP_SESSION" "检查路径权限"
  local pids pids_json bridge_port self
  pids="$(cap_pids)"
  [ -n "$pids" ] || fail "未发现 $APP_PACKAGE 进程" "确认 App 已启动：am start -n $APP_PACKAGE/.MainActivity"
  printf '%s\n' "$pids" > "$CAP_SESSION/pids"
  pids_json="$(printf '%s\n' "$pids" | awk 'NF { printf "%s\"%s\"", (n++ ? "," : ""), $1 }')"
  # DEGRADE: 桥未发现不阻断启动——device 流式通道独立可用，采集器会周期重试。
  bridge_port=""
  if resolve_bridge 2>/dev/null; then
    bridge_port="$PORT"
    # 桥启动行会被 logcat 环形缓冲冲掉（实测 256 KiB / 洪泛 290 万行），
    # 凭据随会话缓存，采集期间不再依赖从 logcat 重新捞 token。
    python3 -c 'import json,sys; json.dump({"port":int(sys.argv[2]),"token":sys.argv[3]}, open(sys.argv[1],"w",encoding="utf-8"))' \
      "$CAP_SESSION/bridge.json" "$PORT" "$TOKEN" \
      && chmod 600 "$CAP_SESSION/bridge.json" \
      || echo "[DEGRADE] capture: bridge.json 凭据缓存失败，采集器将依赖 logcat 启动行" >> "$CAP_SESSION/collector.log"
  else
    echo "[DEGRADE] capture: 启动桥发现失败，仅采 device 通道；采集器将周期重试" >> "$CAP_SESSION/collector.log"
  fi
  python3 -c '
import json, sys, datetime
out, device, pkg, app, pids, port, maxl, keep, interval = sys.argv[1:10]
json.dump({
  "startedAt": datetime.datetime.now().isoformat(timespec="seconds"),
  "device": device, "package": pkg, "app": app,
  "pids": [int(x) for x in pids.split() if x.isdigit()],
  "bridgePort": int(port) if port.isdigit() else None,
  "maxLines": int(maxl), "keep": int(keep), "interval": int(interval),
  "note": "device.*.log 为流式 logcat 原文（含桥 token）；app.jsonl 为 /debug/logs 结构化条目"
}, open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
' "$CAP_SESSION/meta.json" "$DEVICE" "$APP_PACKAGE" "${APP_NAME:-goodhub}" "$pids" "$bridge_port" \
    "$CAP_MAX_LINES" "$CAP_KEEP" "$CAP_INTERVAL" \
    || fail "写 meta.json 失败" "检查 python3 可用性"
  : > "$CAP_SESSION/app.jsonl"
  : > "$CAP_SESSION/app.seen"
  command -v setsid >/dev/null 2>&1 \
    || fail "缺 setsid（util-linux），无法后台常驻采集器" "安装 util-linux 或改用前台会话"
  self="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
  # 采集器与 logcat 管线同进程组，stop 一次收干净；无散落持久脚本。
  # 显式经 bash 执行：工具池脚本无 +x 位（toolbox shim 用 bash 调），setsid
  # 直接 exec 会 Permission denied。
  setsid bash "$self" --device "$DEVICE" --app "${APP_NAME:-goodhub}" _collector \
      "$CAP_SESSION" "$CAP_MAX_LINES" "$CAP_KEEP" "$CAP_INTERVAL" \
      >> "$CAP_SESSION/collector.log" 2>&1 < /dev/null &
  local cpid=$!
  printf '%s\n' "$cpid" > "$CAP_SESSION/collector.pid"
  printf '%s\n' "$CAP_SESSION" > "$CAP_ROOT/current"
  sleep 1
  cap_pid_alive || fail "采集器启动后立即退出" "查看 $CAP_SESSION/collector.log"
  printf '{"ok":true,"session":"%s","pids":[%s],"collectorPid":%s,"bridgePort":%s,"deviceChannel":"streaming","appChannel":"revision-polling"}\n' \
    "$CAP_SESSION" "$pids_json" "$cpid" "${bridge_port:-null}"
}

# 内部子命令：由 capture start 经 setsid 后台拉起，勿手调。
collector_run() {
  local session="$1" max="$2" keep="$3" interval="$4"
  local base="" auth="" last_rev="" st="" rev="" out="" creds="" bp="" bt=""
  # 优先用 start 缓存的桥凭据：启动行常被 logcat 洪泛冲掉，不能指望重捞。
  if [ -f "$session/bridge.json" ]; then
    creds="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1],encoding="utf-8")); print(d["port"]); print(d["token"])' \
      "$session/bridge.json" 2>/dev/null)" || creds=""
    if [ -n "$creds" ]; then
      bp="$(printf '%s\n' "$creds" | sed -n 1p)"; bt="$(printf '%s\n' "$creds" | sed -n 2p)"
      if adb -s "$DEVICE" forward "tcp:$bp" "tcp:$bp" >/dev/null 2>&1; then
        base="http://127.0.0.1:$bp"; auth="Authorization: Bearer $bt"
      fi
    fi
  fi
  # 流式 logcat：pid 集过滤 + 分片轮转（旧片超额删除，防洪泛打爆磁盘）。
  (
    adb -s "$DEVICE" logcat -v threadtime 2>/dev/null \
      | awk -v dir="$session" -v max="$max" -v keep="$keep" '
          BEGIN { part=1; n=0; f=sprintf("%s/device.%03d.log", dir, part) }
          NR==FNR { ok[$1]=1; next }
          $3 in ok {
            if (n >= max) {
              fflush(f); close(f); part++; n=0
              f=sprintf("%s/device.%03d.log", dir, part)
              if (part > keep) system("rm -f " sprintf("%s/device.%03d.log", dir, part-keep))
            }
            print >> f; n++; fflush(f)
          }
        ' "$session/pids" -
  ) &
  local lpid=$!
  trap 'kill "$lpid" 2>/dev/null; exit 0' TERM INT
  while true; do
    if [ -z "$base" ]; then
      if resolve_bridge 2>/dev/null; then
        adb -s "$DEVICE" forward "tcp:$PORT" "tcp:$PORT" >/dev/null 2>&1 \
          || { echo "[DEGRADE] capture: adb forward tcp:$PORT 失败，下轮重试" >> "$session/collector.log"; sleep "$interval"; continue; }
        base="http://127.0.0.1:$PORT"; auth="Authorization: Bearer $TOKEN"
        last_rev=""
      else
        # DEGRADE: 桥未就绪仅影响 app 通道；device 流式通道持续采集，不静默跳过。
        echo "[DEGRADE] capture: 桥未发现，本轮跳过 app.jsonl（device 通道不受影响）" >> "$session/collector.log"
        sleep "$interval"; continue
      fi
    fi
    st="$(curl -sS --max-time 5 -H "$auth" "$base/debug/state" 2>/dev/null)" || st=""
    if [ -z "$st" ]; then
      echo "[DEGRADE] capture: /debug/state 无响应，重置桥发现下轮重试" >> "$session/collector.log"
      base=""; auth=""; last_rev=""
      sleep "$interval"; continue
    fi
    rev="$(printf '%s' "$st" | grep -o '"logRevision":[0-9]*' | cut -d: -f2)"
    if [ -z "$rev" ]; then
      echo "[DEGRADE] capture: /debug/state 无 logRevision（桥未注入 logSink）" >> "$session/collector.log"
      sleep "$interval"; continue
    fi
    if [ "$rev" != "$last_rev" ]; then
      out="$(curl -sS --max-time 5 -H "$auth" "$base/debug/logs?since=0" 2>/dev/null)" || out=""
      if [ -n "$out" ]; then
        printf '%s' "$out" > "$session/.logs.tmp"
        # DEGRADE: /debug/logs 非 JSON 或去重写入失败均明确留痕，不静默当空集合。
        python3 -c '
import json, sys, hashlib, os
src, seenp, outp = sys.argv[1:4]
try:
    d = json.load(open(src, encoding="utf-8"))
except Exception as e:
    print("[DEGRADE] capture: /debug/logs 非 JSON: " + str(e)); sys.exit(1)
seen = set()
if os.path.exists(seenp):
    seen = set(open(seenp, encoding="utf-8").read().splitlines())
n = 0
with open(outp, "a", encoding="utf-8") as o, open(seenp, "a", encoding="utf-8") as s:
    for e in d.get("entries", []):
        k = hashlib.sha1((str(e.get("at","")) + "|" + str(e.get("level","")) + "|" + str(e.get("message",""))).encode("utf-8")).hexdigest()
        if k in seen: continue
        seen.add(k); s.write(k + "\n"); o.write(json.dumps(e, ensure_ascii=False) + "\n"); n += 1
print(n)
' "$session/.logs.tmp" "$session/app.seen" "$session/app.jsonl" \
          || echo "[DEGRADE] capture: app.jsonl 去重写入失败，下轮重试" >> "$session/collector.log"
        rm -f "$session/.logs.tmp"
      fi
      last_rev="$rev"
    fi
    sleep "$interval"
  done
}

cap_stop() {
  cap_root; cap_current
  if cap_pid_alive; then
    local p i=0; p="$(cat "$CAP_SESSION/collector.pid")"
    kill -TERM "-$p" 2>/dev/null || kill -TERM "$p" 2>/dev/null || true
    while [ "$i" -lt 5 ] && cap_pid_alive; do sleep 1; i=$((i+1)); done
    # DEGRADE: TERM 后仍存活不假装已停，留痕并给出人工处置路径。
    if cap_pid_alive; then
      echo "[DEGRADE] capture: 采集器未响应 TERM（pid $p），需手工 kill -KILL -$p" >> "$CAP_SESSION/collector.log"
      echo "[DEGRADE] capture: 采集器未响应 TERM（pid $p）" >&2
    fi
  else
    echo "capture: 采集器未在运行（幂等 stop）"
  fi
  python3 -c '
import json, sys, datetime
p=sys.argv[1]
try: m=json.load(open(p, encoding="utf-8"))
except Exception: m={}
m["stoppedAt"]=datetime.datetime.now().isoformat(timespec="seconds")
json.dump(m, open(p,"w",encoding="utf-8"), ensure_ascii=False, indent=1)
' "$CAP_SESSION/meta.json" \
    || echo "[DEGRADE] capture: meta.json stoppedAt 写入失败" >> "$CAP_SESSION/collector.log"
  printf '{"ok":true,"session":"%s","stopped":true}\n' "$CAP_SESSION"
}

cap_status() {
  cap_root; cap_current
  local app_lines parts device_lines bytes running
  app_lines="$(wc -l < "$CAP_SESSION/app.jsonl" 2>/dev/null | tr -d ' ')"
  parts="$(find "$CAP_SESSION" -maxdepth 1 -name 'device.*.log' | wc -l | tr -d ' ')"
  device_lines="$(cat "$CAP_SESSION"/device.*.log 2>/dev/null | wc -l | tr -d ' ')"
  bytes="$(du -sk "$CAP_SESSION" 2>/dev/null | cut -f1)"
  if cap_pid_alive; then running=true; else running=false; fi
  printf '{"ok":true,"session":"%s","running":%s,"appLines":%s,"deviceLines":%s,"parts":%s,"kbytes":%s}\n' \
    "$CAP_SESSION" "$running" "${app_lines:-0}" "${device_lines:-0}" "${parts:-0}" "${bytes:-0}"
}

# focus 摘要：只看结构化 warning/error + device 异常关键词 + 时间线首尾；
# 输出脱敏 token=...，原文仍留在会话目录（禁入 git / context/）。
cap_tail() {
  cap_root; cap_current
  python3 -c '
import json, sys, os, glob, re
sess, lines, show_all = sys.argv[1], int(sys.argv[2]), sys.argv[3] == "1"
def redact(t): return re.sub(r"token=[^ \t\r\n]+", "token=<redacted>", t)
meta = {}
try: meta = json.load(open(os.path.join(sess, "meta.json"), encoding="utf-8"))
except Exception as e: print("[DEGRADE] focus: meta.json 解析失败: " + str(e))
app, bad = [], 0
p = os.path.join(sess, "app.jsonl")
if os.path.exists(p):
    for l in open(p, encoding="utf-8"):
        try: app.append(json.loads(l))
        except Exception: bad += 1
dev, parts = [], sorted(glob.glob(os.path.join(sess, "device.*.log")))
for f in parts:
    for l in open(f, encoding="utf-8", errors="replace"): dev.append(l.rstrip())
kw = re.compile(r"DEGRADE|Exception|FATAL|ANR|failed|error|tombstone|SIGSEGV", re.I)
out = ["# capture focus ｜ " + os.path.basename(sess), "",
  "- App: %s ｜ pids %s ｜ 起 %s ｜ 止 %s" % (meta.get("package","?"), meta.get("pids",[]), meta.get("startedAt","?"), meta.get("stoppedAt","进行中")),
  "- 结构化日志 %d 条 ｜ device 日志 %d 行（%d 分片）" % (len(app), len(dev), len(parts)), ""]
if bad: out.append("- [DEGRADE] focus: app.jsonl 有 %d 行无法解析（已跳过）" % bad)
out.append("## 重点：结构化 warning/error")
n = 0
for e in app:
    if str(e.get("level","")).lower() in ("warning","error") or "[DEGRADE]" in str(e.get("message","")):
        out.append("- [%s] %s %s" % (e.get("at","?"), e.get("level","?"), redact(str(e.get("message",""))[:300])))
        n += 1
        if not show_all and n >= lines: break
if n == 0: out.append("- （无）")
out += ["", "## 重点：device 异常关键词命中"]
n = 0
for l in dev:
    if kw.search(l):
        out.append("- " + redact(l[:300])); n += 1
        if not show_all and n >= lines: break
if n == 0: out.append("- （无）")
out += ["", "## 时间线"]
if dev:
    out += ["- 首行: " + redact(dev[0][:200]), "- 末行: " + redact(dev[-1][:200])]
else: out.append("- device 通道暂无日志")
out += ["", "## 产物"]
out += ["- " + f for f in ("meta.json","pids","app.jsonl","focus.md","collector.log")]
out += ["- " + os.path.basename(x) for x in parts]
text = "\n".join(out) + "\n"
open(os.path.join(sess, "focus.md"), "w", encoding="utf-8").write(text)
sys.stdout.write(text)
' "$CAP_SESSION" "$CAP_LINES" "$CAP_ALL" \
    || fail "生成 focus 失败" "检查 python3 与会话目录完整性"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --self-test) self_test; exit $? ;;
    --json) MODE=json; shift ;;
    --device) DEVICE="${2:-}"; shift 2 ;;
    --app) APP_NAME="${2:-}"; shift 2 ;;
    state|ui-tree|ping) CMD="$1"; shift ;;
    logs)
      CMD=logs
      shift
      if [ "${1:-}" = "--since" ]; then SINCE="${2:-0}"; shift 2; fi
      case "$SINCE" in
        *[!0-9]*) fail "since 必须是非负整数: $SINCE" "logs --since 0" ;;
      esac
      ;;
    --file)
      ARGS_FILE="${2:-}"; shift 2
      [ -n "$ARGS_FILE" ] && [ -f "$ARGS_FILE" ] || fail "--file 缺文件: $ARGS_FILE" "先写 JSON 到文件再 --file 传入"
      JSON_ARGS="$(cat "$ARGS_FILE")"
      ;;
    tap_bounds)
      CMD=tap_bounds; BOUNDS="${2:-}"; shift 2
      printf '%s' "$BOUNDS" | grep -Eq '^[0-9.]+,[0-9.]+(,[0-9.]+,[0-9.]+)?$'         || fail "非法 bounds: $BOUNDS" "格式 x,y 或 x,y,w,h（ui-tree bounds 逻辑像素，直接粘贴）"
      ;;
    wait_log)
      CMD=wait_log; WAIT_PAT="${2:-}"; shift 2
      WAIT_TMO="${1:-60}"; [ $# -gt 0 ] && shift
      case "$WAIT_TMO" in *[!0-9]*) fail "timeout 必须是秒数: $WAIT_TMO" "wait_log <ERE> [timeout_s]" ;; esac
      ;;
    device-log)
      CMD=device_log; shift
      DL_PAT="${1:-}"; [ $# -gt 0 ] && shift
      DL_TAIL="${1:-200}"; [ $# -gt 0 ] && shift
      case "$DL_TAIL" in *[!0-9]*) fail "tail 必须是行数: $DL_TAIL" "device-log [ERE] [N]" ;; esac
      ;;
    foreground)
      CMD=foreground; shift ;;
    system-ui)
      CMD=system_ui; shift; SU_SUB="${1:-}"; [ $# -gt 0 ] && shift ;;
    system-tap)
      CMD=system_tap; ST_X="${2:-}"; ST_Y="${3:-}"
      [ $# -ge 3 ] && shift 3   # 消耗 command + x + y（残留会被 while 循环再迭代误判 unknown）
      case "$ST_X,$ST_Y" in
        *[!0-9,]*) fail "非法坐标: $ST_X,$ST_Y" "格式 x,y（设备像素，system-ui 中心点直接粘贴）" ;;
      esac
      ;;
    navigate)
      CMD=navigate
      PAGE="${2:-}"
      shift 2
      valid_page "$PAGE" || fail "非法 page: $PAGE" "仅小写字母/数字/连字符，如 logs gateway settings"
      JSON_ARGS="{\"page\":\"$PAGE\"}"
      ;;
    list-models)
      CMD=action; NAME=list_models; JSON_ARGS='{}'; shift ;;
    set-policy)
      CMD=action; NAME=set_history_policy
      PID="${2:-}"; shift 2
      valid_name "$PID" || fail "非法 policyId: $PID" "须为 bare/drop_oldest/anchor_recent/rolling_summary"
      JSON_ARGS="{\"policyId\":\"$PID\"}"
      if [ $# -gt 0 ] && [ -n "${1:-}" ]; then
        MD="$1"; shift
        JSON_ARGS="{\"policyId\":\"$PID\",\"modelDir\":\"$MD\"}"
      fi
      ;;
    get-policy)
      CMD=action; NAME=get_history_policy; shift
      if [ $# -gt 0 ] && [ -n "${1:-}" ]; then
        MD="$1"; shift
        JSON_ARGS="{\"modelDir\":\"$MD\"}"
      else
        JSON_ARGS='{}'
      fi
      ;;
    query-ondevice)
      # 直接驱动端侧引擎跑一轮（P3 历史策略 A/B 用）：prompt 必填，可选 policyId；
      # 多轮 history 走通用入口：action query_on_device --file <hist.json>
      # （hist.json = {"prompt":...,"history":[{"role":"user","content":...}],"policyId":...}）。
      CMD=action; NAME=query_on_device; shift
      PROMPT="${1:-}"; shift
      [ -n "$PROMPT" ] || fail "query-ondevice 缺 prompt" "用法: query-ondevice <prompt> [policyId]（带 history 用 action query_on_device --file）"
      PID="${1:-}"
      if [ -n "$PID" ]; then shift; fi
      JSON_ARGS="$(python3 -c "import json,sys; print(json.dumps({'prompt':sys.argv[1],'policyId':(sys.argv[2] if len(sys.argv)>2 and sys.argv[2] else None)}))" "$PROMPT" "$PID")"
      ;;
    action)
      CMD=action
      NAME="${2:-}"
      shift 2
      valid_name "$NAME" || fail "非法 action: $NAME" "动作名须匹配 ^[a-z_][a-z0-9_-]*"
      if [ $# -gt 0 ]; then JSON_ARGS="$1"; shift
      elif [ ! -t 0 ]; then STDIN_ARGS="$(cat)";
        [ -n "$STDIN_ARGS" ] && JSON_ARGS="$STDIN_ARGS"; fi
      ;;
    capture)
      CMD=capture
      CAP_SUB="${2:-}"; shift 2
      case "$CAP_SUB" in
        start|stop|tail|status) ;;
        *) fail "非法 capture 子命令: $CAP_SUB" "可用: start / stop / tail / status" ;;
      esac
      while [ $# -gt 0 ]; do
        case "$1" in
          --dir) CAP_DIR="${2:-}"; shift 2 ;;
          --max-lines) CAP_MAX_LINES="${2:-}"; shift 2
            valid_uint "$CAP_MAX_LINES" || fail "非法 --max-lines: $CAP_MAX_LINES" "正整数，如 50000" ;;
          --keep) CAP_KEEP="${2:-}"; shift 2
            valid_uint "$CAP_KEEP" || fail "非法 --keep: $CAP_KEEP" "正整数，如 3" ;;
          --interval) CAP_INTERVAL="${2:-}"; shift 2
            valid_uint "$CAP_INTERVAL" || fail "非法 --interval: $CAP_INTERVAL" "正整数秒，如 2" ;;
          --lines) CAP_LINES="${2:-}"; shift 2
            valid_uint "$CAP_LINES" || fail "非法 --lines: $CAP_LINES" "正整数，如 40" ;;
          --all) CAP_ALL=1; shift ;;
          *) fail "capture 未知参数: $1" "参数须放在 capture 子命令之后；可用 --dir / --max-lines / --keep / --interval / --lines / --all" ;;
        esac
      done
      ;;
    _collector)
      CMD=_collector
      CAP_SESSION="${2:-}"; shift 2
      CAP_MAX_LINES="${1:-}"; [ $# -gt 0 ] && shift
      CAP_KEEP="${1:-}"; [ $# -gt 0 ] && shift
      CAP_INTERVAL="${1:-}"; [ $# -gt 0 ] && shift
      [ -d "$CAP_SESSION" ] || fail "采集器会话目录不存在: $CAP_SESSION" "由 capture start 内部拉起，勿手调"
      ;;
    *) echo "unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

if [ "$MODE" = "json" ]; then
  if [ -n "$DEVICE" ]; then
    precheck && json_ok "debug-bridge 预检通过（adb/curl/设备就绪）"
    json_fail "adb 或 curl 不可用，或设备不在线" "adb devices 查串号；export PATH=\$HOME/android-sdk/platform-tools:\$PATH"
  fi
  if command -v adb >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
    json_ok "debug-bridge 可用（裸跑需 --device <SERIAL>）"
  fi
  json_fail "adb 或 curl 不在 PATH" "export PATH=\$HOME/android-sdk/platform-tools:\$PATH"
fi

[ -n "$CMD" ] || { usage; exit 2; }
[ -n "$DEVICE" ] || fail "缺 --device" "adb devices 查串号后传 --device <SERIAL>"
map_app
precheck || fail "adb/curl 不可用或设备不在线" "adb devices；export PATH=\$HOME/android-sdk/platform-tools:\$PATH"

# —— capture 早分派：不依赖桥可用性（collector 自行发现/重连）——
case "$CMD" in
  capture)
    case "$CAP_SUB" in
      start) cap_start ;;
      stop) cap_stop ;;
      tail) cap_tail ;;
      status) cap_status ;;
    esac
    exit $?
    ;;
  _collector)
    collector_run "$CAP_SESSION" "$CAP_MAX_LINES" "$CAP_KEEP" "$CAP_INTERVAL"
    exit $?
    ;;
esac

resolve_bridge \
  || fail "按包名 $APP_PACKAGE 发现不到调试桥（端口/token）" \
       "确认装 debug 包且目标 App 已启动；logcat 被清则重启该 App 重新产出 [debug-bridge] 行"
adb -s "$DEVICE" forward "tcp:$PORT" "tcp:$PORT" >/dev/null 2>&1 \
  || fail "adb forward tcp:$PORT 失败" "检查端口占用与设备连接"

BASE="http://127.0.0.1:$PORT"
AUTH="Authorization: Bearer $TOKEN"
CONTENT="Content-Type: application/json"

case "$CMD" in
  state) URL="$BASE/debug/state"; BODY="" ;;
  logs) URL="$BASE/debug/logs?since=$SINCE"; BODY="" ;;
  ui-tree) URL="$BASE/debug/ui-tree"; BODY="" ;;
  ping) URL="$BASE/debug/action"; BODY='{"action":"ping","args":{}}' ;;
  navigate) URL="$BASE/debug/action"; BODY="{\"action\":\"navigate\",\"args\":$JSON_ARGS}" ;;
  action) URL="$BASE/debug/action"; BODY="{\"action\":\"$NAME\",\"args\":$JSON_ARGS}" ;;
esac

# —— 桥面独立命令（不透传 HTTP）——
assert_foreground() {
  local fg
  fg="$(foreground_pkg)"
  case "$fg" in
    "$APP_PACKAGE"*) return 0 ;;
    *)
      fail "前台不是宿主 app（当前: ${fg:-unknown}，期望: $APP_PACKAGE）" \
        "am start -n $APP_PACKAGE/.MainActivity 拉起后重试——前台守卫防误触其他 app（2026-11-05 微信误点事故）"
      ;;
  esac
}

case "$CMD" in
  tap_bounds)
    assert_foreground
    SCREEN="$(curl -sS --max-time 10 -H "$AUTH" "$BASE/debug/action" \
      -X POST -H "$CONTENT" -d '{"action":"screen","args":{}}' 2>&1)" \
      || fail "screen 端点请求失败" "$SCREEN"
    DPR="$(printf '%s' "$SCREEN" | grep -o '"dpr":[0-9.]*' | cut -d: -f2)"
    [ -n "$DPR" ] || fail "screen 端点未返回 dpr" "$SCREEN"
    X="$(printf '%s' "$BOUNDS" | cut -d, -f1)"
    Y="$(printf '%s' "$BOUNDS" | cut -d, -f2)"
    W="$(printf '%s' "$BOUNDS" | cut -d, -f3)"
    H="$(printf '%s' "$BOUNDS" | cut -d, -f4)"
    if [ -n "$W" ] && [ -n "$H" ]; then
      X="$(awk "BEGIN{print $X + $W/2}")"; Y="$(awk "BEGIN{print $Y + $H/2}")"
    fi
    PX="$(awk "BEGIN{printf \"%d\", $X * $DPR}")"
    PY="$(awk "BEGIN{printf \"%d\", $Y * $DPR}")"
    echo "[tap_bounds] logical($X,$Y) ×dpr($DPR) → device($PX,$PY)"
    adb -s "$DEVICE" shell input tap "$PX" "$PY"
    exit $?
    ;;
  wait_log)
    DEADLINE=$(( $(date +%s) + WAIT_TMO ))
    while [ "$(date +%s)" -lt "$DEADLINE" ]; do
      HIT="$(adb -s "$DEVICE" logcat -d 2>/dev/null | grep -aE "$WAIT_PAT" | tail -1)"
      if [ -n "$HIT" ]; then printf '%s\n' "$HIT"; exit 0; fi
      sleep 2
    done
    fail "wait_log 超时（${WAIT_TMO}s）未匹配: $WAIT_PAT" \
      "确认设备时间线/触发动作是否已执行；先 device-log 看最新日志"
    ;;
  device_log)
    if [ -n "$DL_PAT" ]; then
      adb -s "$DEVICE" logcat -d 2>/dev/null | grep -aE "$DL_PAT" | tail -"$DL_TAIL"
    else
      adb -s "$DEVICE" logcat -d 2>/dev/null | tail -"$DL_TAIL"
    fi
    exit 0
    ;;
  foreground)
    FG="$(foreground_pkg)"
    case "$FG" in
      "$APP_PACKAGE"*) ISG=true ;;
      *) ISG=false ;;
    esac
    if [ "$ISG" = true ]; then HINT="宿主 app 前台（$APP_PACKAGE）——用桥面命令（tap_bounds/ui-tree/action）"; \
    else HINT="非宿主 app 前台（${FG:-unknown}）——桥面 UI 命令会命中错误界面，改用 system-ui + system-tap 驱动系统层"; fi
    printf '{"foreground":"%s","is_goodhub":%s,"hint":"%s"}\n' "${FG:-unknown}" "$ISG" "$HINT"
    exit 0
    ;;
  system_ui)
    # dump→cat 留 flush 窗口（FUSE 存储竞态：紧贴偶发读到空文件，2026-11-05
    # 真机实证）；exec-out 比 shell 二进制安全。
    adb -s "$DEVICE" shell uiautomator dump /sdcard/gh_wd.xml >/dev/null 2>&1
    sleep 1
    XML="$(adb -s "$DEVICE" exec-out cat /sdcard/gh_wd.xml 2>/dev/null)"
    adb -s "$DEVICE" shell rm -f /sdcard/gh_wd.xml >/dev/null 2>&1
    [ -n "$XML" ] || fail "取不到 UI dump XML" "uiautomator dump 空——可能正在动画，稍候重试"
    # XML 走临时文件参数，stdin 专供 heredoc 脚本——`python3 - <<PY` 会从
    # stdin 读脚本，若同时管道喂 XML 则争抢 stdin，sys.stdin.read() 读到空
    # （2026-11-05 真机实证「no element found」根因）。
    XMLF="$(mktemp -t gh_wd_XXXXXX.xml)"
    printf '%s' "$XML" > "$XMLF"
    python3 - "$SU_SUB" "$XMLF" <<'PY'
import sys, json, xml.etree.ElementTree as ET
sub, xmlfile = sys.argv[1], sys.argv[2]
try:
    root = ET.fromstring(open(xmlfile, encoding='utf-8').read())
except ET.ParseError as e:
    print(json.dumps({"ok": False, "error": "xml_parse", "detail": str(e)})); sys.exit(1)
def center(b):
    try:
        xs, ys = b.strip("[]").split("][")
        x1, y1 = map(int, xs.split(",")); x2, y2 = map(int, ys.split(","))
        return {"x": (x1+x2)//2, "y": (y1+y2)//2, "w": x2-x1, "h": y2-y1}
    except Exception:
        return None
out = []
for n in root.iter("node"):
    text = n.get("text",""); desc = n.get("content-desc","")
    lab = text or desc
    if not lab: continue
    if sub and sub not in lab: continue
    b = center(n.get("bounds",""))
    if b is None: continue
    out.append({"label": lab[:120], "clickable": n.get("clickable")=="true",
                "class": n.get("class","").split(".")[-1], **b})
print(json.dumps({"ok": True, "count": len(out), "nodes": out}, ensure_ascii=False, indent=1))
PY
    rm -f "$XMLF"
    exit 0
    ;;
  system_tap)
    FG="$(foreground_pkg)"
    case "$FG" in
      "$APP_PACKAGE"*) echo "[system-tap] 注意：当前前台是宿主 app（$APP_PACKAGE）——若目标是系统 UI 可能已关闭；如需点宿主用 tap_bounds" ;;
      *) echo "[system-tap] 前台: ${FG:-unknown}（系统/第三方 UI，符合预期）" ;;
    esac
    adb -s "$DEVICE" shell input tap "$ST_X" "$ST_Y"
    exit $?
    ;;
esac

if [ -n "$BODY" ]; then
  OUT="$(curl -sS --max-time 10 -X POST -H "$AUTH" -H "$CONTENT" -d "$BODY" "$URL" 2>&1)" \
    || fail "端点请求失败" "$OUT"
else
  OUT="$(curl -sS --max-time 10 -H "$AUTH" "$URL" 2>&1)" \
    || fail "端点请求失败" "$OUT"
fi
printf '%s\n' "$OUT"
