#!/usr/bin/env bash
# 启动「番茄猫」（本仓库约定的启动入口）。
# 用法：bash Tools/跑.sh [--debug|--release] [--selftest <close|quit|chain|update>] [--delay <秒>]
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="Release"
SELFTEST=""
DELAY="${FQM_SELFTEST_DELAY:-8}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug) CONFIG="Debug" ;;
    --release) CONFIG="Release" ;;
    --selftest) SELFTEST="${2:-}"; shift ;;
    --delay) DELAY="${2:-8}"; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

echo "== build ${CONFIG} =="
# Release 要出通用二进制（arm64 + x86_64）：必须显式给 generic/platform=macOS。
# 不给 destination 时，xcodebuild 会自己挑「本机 arch」的 destination
# （arch=arm64, name=My Mac），结果只编出本机那一片，ARCHS 白写。
# Debug 仍走本机 destination：只编当前架构，迭代快。
DEST_ARG=""
[[ "${CONFIG}" == "Release" ]] && DEST_ARG="-destination generic/platform=macOS"
xcodebuild -scheme FanQieMao -configuration "${CONFIG}" ${DEST_ARG} \
  -derivedDataPath "$HOME/Library/Caches/fqm-derived" \
  build >/tmp/fqm-build.log 2>&1 || {
  tail -40 /tmp/fqm-build.log
  exit 1
}

APP="$(xcodebuild -scheme FanQieMao -configuration "${CONFIG}" \
  -derivedDataPath "$HOME/Library/Caches/fqm-derived" -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')/FanQieMao.app"
echo "app: ${APP}"
[[ -d "${APP}" ]] || { echo "app not found" >&2; exit 1; }

# 稳定签名：ad-hoc 签名的 designated requirement 是 cdhash，重编即失效 →
# 每次构建后用自签名证书（CN=FanQieMao Dev，独立钥匙串 Tools/fqmdev.keychain-db）重签，
# requirement 变成 identifier + certificate leaf，重编仍匹配（TCC/完全磁盘访问权限不掉）。
# 证书不存在时跳过（先跑 bash Tools/dev-sign-setup.sh）。
KEYCHAIN="$(pwd)/Tools/fqmdev.keychain-db"
if [ -f "${KEYCHAIN}" ]; then
  security unlock-keychain -p "" "${KEYCHAIN}" 2>/dev/null || true
  if codesign --force --deep --identifier com.yuki.fanqiemao --keychain "${KEYCHAIN}" \
       --sign "FanQieMao Dev" "${APP}" 2>/tmp/fqm-codesign.log; then
    echo "signed: $(codesign -dvvv "${APP}" 2>&1 | grep -m1 '^Authority=')"
  else
    echo "!! 稳定签名失败（沿用 xcodebuild 的 ad-hoc 签名）:" >&2
    tail -3 /tmp/fqm-codesign.log >&2
  fi
else
  echo "!! 未找到 ${KEYCHAIN}，跳过稳定签名（先跑 bash Tools/dev-sign-setup.sh）"
fi

echo "== launch =="
# 用 LaunchServices（open）启动：直接当 shell 子进程跑时，TCC 会把文件访问算到「终端」头上；
# 经 open 启动的番茄猫才用自己的签名身份（完全磁盘访问权限才生效，M3-d 读 Safari 需要）。
if [[ -n "${SELFTEST}" ]]; then
  open -n "${APP}" --env FQM_SELFTEST="${SELFTEST}" --env FQM_SELFTEST_DELAY="${DELAY}" \
    --stdout /tmp/fqm-selftest.log --stderr /tmp/fqm-selftest.err
  echo "launched (selftest=${SELFTEST}, open/LaunchServices)"
else
  open -n "${APP}" --stdout /tmp/fqm-app.log --stderr /tmp/fqm-app.err
  echo "launched (open/LaunchServices)"
fi
