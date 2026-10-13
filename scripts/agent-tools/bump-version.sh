#!/bin/bash
# bump-version — goodhub pubspec.yaml 版本号更新脚本
#
# toolbox-script
# format: v1
# name: bump-version
# summary: 更新 pubspec.yaml 版本：bump 版本段/仅加 build 号/--set 显式；自动探测已连接设备的已装版本，降级风险时自动追平 build 号
# trigger: manual
# platform: unix
# cat: build
# alias: bump

set -euo pipefail

MODE=""        # major|minor|patch|build(仅加 build 号)
SET_SPEC=""    # 显式 x.y.z+w
DRY_RUN=0
PUBSPEC="pubspec.yaml"
PKG="com.zzh.goodhub"    # applicationId（android/app/build.gradle.kts）
ABI_OFFSET=2000          # arm64-v8a 拆分包 versionCode = pub build 号 + 2000（本仓库约定）
SKIP_DEVICE=0
GUARD=0

usage() {
  cat <<'EOF'
用法: bump-version.sh [选项]        （toolbox run bump-version [选项] 等价）
作用: 修改 <repo>/pubspec.yaml 的 version: 行（版本段 x.y.z 与 build 号 w）
选项:
  --patch       版本段 +0.0.1（默认）
  --minor       版本段 +0.1.0
  --major       版本段 +1.0.0
  --build       版本段不动，仅 build 号 +1（补发/拆分包场景）
  --set x.y.z+w 显式指定完整版本（w 可省，省略则保留原 build 号）
  --no-device   跳过设备已装版本探测（CI/无 adb 环境）
  --guard       只读+按需守卫：仅当设备已装版本会导致降级时才抬高 build 号，否则不动文件
                （供 build-apk 等脚本构建前调用，平时 bump 用 --patch/--build/--set）
  -f <file>     指定 pubspec 路径（默认 repo 根 pubspec.yaml）
  -n, --dry-run 只打印将写入的新版本行，不落盘
  --json        快速预检（一行 JSON 结论，读当前版本，不修改）
  -h, --help    本帮助
说明: 裸跑（带 --patch/--minor/--major/--build/--set 之一）才修改文件；
      --json 与 --dry-run 均只读。幂等可重跑。
EOF
}

json_out() { # status severity message remedy
  if [ -n "${4:-}" ]; then
    printf '{"status":"%s","severity":"%s","message":"%s","remedy":"%s"}\n' "$1" "$2" "$3" "$4"
  else
    printf '{"status":"%s","severity":"%s","message":"%s"}\n' "$1" "$2" "$3"
  fi
}

# 从 pubspec 提取当前 version 值（取首个 ^version: 行；剥离行尾 # 注释）
read_version() {
  grep -m1 -E '^[[:space:]]*version:[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+' "$PUBSPEC" \
    | sed -E 's/^[[:space:]]*version:[[:space:]]*//' \
    | sed -E 's/[[:space:]]*#.*$//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --patch) MODE="patch" ;;
    --minor) MODE="minor" ;;
    --major) MODE="major" ;;
    --build) MODE="build" ;;
    --set)
      [ $# -ge 2 ] || { echo "FAIL: --set 需要 x.y.z+w 参数"; usage; exit 2; }
      SET_SPEC="$2"; shift
      ;;
    -f) [ $# -ge 2 ] || { echo "FAIL: -f 需要文件路径"; exit 2; }; PUBSPEC="$2"; shift ;;
    --no-device) SKIP_DEVICE=1 ;;
    --guard) GUARD=1 ;;
    -n|--dry-run) DRY_RUN=1 ;;
    --json)
      if [ ! -f "$PUBSPEC" ]; then
        json_out FAIL error "pubspec 不存在: $PUBSPEC" "确认在 repo 根运行或用 -f 指定路径"
        exit 1
      fi
      CUR="$(read_version || true)"
      if [ -z "$CUR" ]; then
        json_out FAIL error "pubspec 中未找到 version 行" "检查 $PUBSPEC 顶层 version: 字段格式 x.y.z+w"
        exit 1
      fi
      json_out OK info "当前版本 $CUR，可裸跑 --patch/--minor/--major/--build/--set 更新"
      exit 0
      ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
  shift
done

# ---- 校验入参与现状 ----
[ -n "$MODE" ] || [ -n "$SET_SPEC" ] || [ "$GUARD" = 1 ] || {
  # 无模式：等效只读预检——报当前版本并给用法提示（退出码 2）
  echo "FAIL: 未指定更新模式（--patch/--minor/--major/--build/--set 之一）"
  echo "[remedy] 先 toolbox run bump-version --json 读当前版本，再带模式裸跑"
  usage
  exit 2
}
[ -f "$PUBSPEC" ] || { echo "FAIL: pubspec 不存在: $PUBSPEC"; echo "[remedy] 在 repo 根运行，或 -f 指定 pubspec 路径"; exit 2; }

CUR="$(read_version || true)"
[ -n "$CUR" ] || { echo "FAIL: 未在 $PUBSPEC 找到 version 行"; exit 2; }

CUR_VER="${CUR%%+*}"
CUR_BUILD=""
case "$CUR" in *+*) CUR_BUILD="${CUR#*+}" ;; esac
IFS='.' read -r MA MI PA <<< "$CUR_VER"

# ---- 设备已装版本探测（防 INSTALL_FAILED_VERSION_DOWNGRADE）----
# 约定：arm64 拆分包装到手机的 versionCode = pub build 号 + ABI_OFFSET
# 目标：pub build 号使得「pub 号 + OFFSET」> 设备已装 code，否则自动抬高 build 号追平
DEVICE_CODE=""
if [ "$SKIP_DEVICE" = 0 ] && command -v adb >/dev/null 2>&1 && adb devices 2>/dev/null | grep -q 'device$'; then
  DEVICE_CODE="$(adb shell dumpsys package "$PKG" 2>/dev/null | grep -m1 -oE 'versionCode=[0-9]+' | cut -d= -f2 || true)"
  if [ -n "$DEVICE_CODE" ]; then
    echo "设备 $PKG 已装 versionCode: $DEVICE_CODE（拆分包约定 pub 号+${ABI_OFFSET}）"
  else
    echo "设备已连接但未安装 $PKG，跳过追平"
  fi
fi

# 设备要求的最低 pub build 号（拆分包场景）；整包/未装/无设备时为空
MIN_BUILD=""
if [ -n "$DEVICE_CODE" ]; then
  MIN_BUILD=$(( DEVICE_CODE - ABI_OFFSET + 1 ))
fi

# ---- 计算新版本 ----
if [ "$GUARD" = 1 ]; then
  # 守卫模式：版本段不动，build 号取 max(原号+1, 设备底线)——无降级风险时结果=原号+1 仍会写入；
  # 若原号已 >= 底线则只在原号+1 与底线间取大，行为与 --build 一致
  NEW_VER="$CUR_VER"
  NEW_BUILD=$(( ${CUR_BUILD:-0} + 1 ))
elif [ -n "$SET_SPEC" ]; then
  NEW_VER="${SET_SPEC%%+*}"
  case "$SET_SPEC" in
    *+*) NEW_BUILD="${SET_SPEC#*+}" ;;
    *)   NEW_BUILD="$CUR_BUILD" ;;
  esac
else
  case "$MODE" in
    major) NEW_VER="$((MA+1)).0.0" ;;
    minor) NEW_VER="$MA.$((MI+1)).0" ;;
    patch) NEW_VER="$MA.$MI.$((PA+1))" ;;
    build) NEW_VER="$CUR_VER" ;;
  esac
  NEW_BUILD=$(( ${CUR_BUILD:-0} + 1 ))
fi

# ---- 降级防护：目标 build 号追不上设备已装版本时自动抬高 ----
if [ -n "$MIN_BUILD" ] && [ "$NEW_BUILD" -lt "$MIN_BUILD" ]; then
  OLD_NEW_BUILD="$NEW_BUILD"
  NEW_BUILD="$MIN_BUILD"
  echo "⚠ 目标 build 号 $OLD_NEW_BUILD 在设备上会装配降级（设备已装 code $DEVICE_CODE > $((NEW_BUILD + ABI_OFFSET - 1))），自动抬高 build 号至 $NEW_BUILD"
fi

# guard 且无降级风险且 build 号未变 → 不动文件，快速返回
if [ "$GUARD" = 1 ] && [ -z "$MIN_BUILD" ]; then
  echo "OK: 设备未连接/未安装，无降级风险，版本保持 $CUR"
  exit 0
fi

# guard 有设备但 build 号已 >= 底线 → 不动文件
if [ "$GUARD" = 1 ] && [ -n "$MIN_BUILD" ] && [ "${CUR_BUILD:-0}" -ge "$MIN_BUILD" ]; then
  echo "OK: 当前 build 号 $CUR_BUILD 装到设备为 $((CUR_BUILD + ABI_OFFSET)) ≥ 已装 $DEVICE_CODE，无降级风险，版本保持 $CUR"
  exit 0
fi

if ! printf '%s' "$NEW_VER" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "FAIL: 新版本段非法: '$NEW_VER'"
  exit 2
fi

NEW="$NEW_VER"
[ -n "$NEW_BUILD" ] && NEW="$NEW+$NEW_BUILD"

echo "当前: $CUR"
echo "目标: $NEW"

if [ "$DRY_RUN" = 1 ]; then
  echo "[dry-run] 将把 $PUBSPEC 的 version 行替换为: version: $NEW（未动真目标）"
  exit 0
fi

# ---- 写入（仅替换首个 version 行，其余原样）----
TMP="$PUBSPEC.bump-tmp"
REPLACED=0
while IFS= read -r line; do
  if [ "$REPLACED" = 0 ] && printf '%s' "$line" | grep -qE '^[[:space:]]*version:[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+'; then
    INDENT="${line%%version:*}"
    # 保留原行行尾注释：去掉行首到版本号为止的前缀，余下即注释
    COMMENT="$(printf '%s' "$line" | sed -E 's/^[^#]*version:[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+(\+[0-9]+)?[[:space:]]*//' || true)"
    case "$COMMENT" in \#*) printf '%sversion: %s %s\n' "$INDENT" "$NEW" "$COMMENT" ;;
    *) printf '%sversion: %s\n' "$INDENT" "$NEW" ;; esac
    REPLACED=1
  else
    printf '%s\n' "$line"
  fi
done < "$PUBSPEC" > "$TMP"

if [ "$REPLACED" = 0 ]; then
  rm -f "$TMP"
  echo "FAIL: 写入时未匹配到 version 行，文件未改动"
  exit 2
fi
mv "$TMP" "$PUBSPEC"

# ---- 复核 ----
AFTER="$(read_version)"
if [ "$AFTER" != "$NEW" ]; then
  echo "FAIL: 写入后复核不一致（期望 $NEW，实际 $AFTER）"
  exit 2
fi
echo "OK: $PUBSPEC version 已更新为 $AFTER"
