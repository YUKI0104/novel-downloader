#!/usr/bin/env bash
# dev-sign-setup.sh — 为「番茄猫」创建/复用**本仓库专用**的自签名代码签名身份。
#
# 为什么：ad-hoc 签名（CODE_SIGN_IDENTITY="-"）的 designated requirement 是 cdhash，
# 每次重编都会变，macOS「完全磁盘访问权限」等 TCC 授权随之失效。
# 换成固定 CN 的自签名证书后，requirement 变成
#   identifier "com.yuki.fanqiemao" and certificate leaf = H"<证书哈希>"
# 只绑证书与 bundle id，重编后仍然匹配。
#
# 红线：
#   · 只在 Tools/fqmdev.keychain-db 这个**独立钥匙串**里建证书；绝不写/删用户的 login 钥匙串；
#   · 证书**不加进系统信任**（add-trusted-cert 需要管理员权限，也非必需）；
#   · 证书/私钥/临时钥匙串都 gitignore，不提交。
#
# 幂等：身份已存在则复用。重跑安全。
set -euo pipefail
cd "$(dirname "$0")/.."

CN="FanQieMao Dev"
KEYCHAIN="$(pwd)/Tools/fqmdev.keychain-db"
KC_PASS=""
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
OPENSSL="/opt/homebrew/opt/openssl@3/bin/openssl"
[ -x "$OPENSSL" ] || OPENSSL="$(command -v openssl)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [ -f "$KEYCHAIN" ] && security find-certificate -c "$CN" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "已存在签名身份：${CN}（跳过创建；保持证书哈希稳定，TCC 授权不掉）"
else
  # 没有证书（或旧文件异常）：重建一个干净的独立钥匙串，保证只有一张同名证书，
  # 避免 --sign 在多个同名证书里选错导致 requirement 变化。
  if [ -f "$KEYCHAIN" ]; then security delete-keychain "$KEYCHAIN" 2>/dev/null || true; fi
  security create-keychain -p "$KC_PASS" "$KEYCHAIN"
  security set-keychain-settings -lut 21600 "$KEYCHAIN"
  security unlock-keychain -p "$KC_PASS" "$KEYCHAIN"

  # 自签名证书：CN=FanQieMao Dev，EKU 含 codeSigning（不加系统信任）
  "$OPENSSL" req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -subj "/CN=$CN" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "basicConstraints=critical,CA:FALSE"

  # 分开导 PEM（不用 p12，避免 MAC verification failed）
  security import "$WORK/cert.pem" -k "$KEYCHAIN" -T /usr/bin/codesign
  security import "$WORK/key.pem" -k "$KEYCHAIN" -T /usr/bin/codesign -P ""
  # 关键一步：预置分区列表 → codesign 用私钥不再弹钥匙串 UI
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PASS" "$KEYCHAIN" >/dev/null
  echo "已创建签名身份：$CN"
fi

# 搜索链：保留现有（含 login.keychain-db），只在末尾追加本钥匙串
existing="$(security list-keychains -d user | sed -e 's/^[[:space:]]*//' -e 's/"//g')"
if ! printf '%s\n' "$existing" | grep -qx "$KEYCHAIN"; then
  # shellcheck disable=SC2086
  security list-keychains -d user -s $existing "$KEYCHAIN"
  echo "已把 $KEYCHAIN 追加进用户搜索链（原有条目保留）"
fi

echo "=== 用户搜索链 ==="
security list-keychains -d user
echo "=== codesigning 身份 ==="
security find-identity -v -p codesigning
