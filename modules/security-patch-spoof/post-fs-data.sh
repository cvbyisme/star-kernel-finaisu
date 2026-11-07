#!/system/bin/sh
# 开机早期：写 attestation 补丁级别 + resetprop
MODDIR=${0%/*}
TARGET=2026-09-01
TS=/data/adb/tricky_store

# 1) attestation 补丁级别（AlwaysStrong / TEESimulator-RS 读这个）
if [ -d "$TS" ]; then
  echo "all=$TARGET" > "$TS/security_patch.txt"
  for f in "$TS/pif.prop" "$TS/custom.pif.prop"; do
    [ -f "$f" ] || continue
    if grep -q '^SECURITY_PATCH=' "$f"; then
      sed -i "s|^SECURITY_PATCH=.*|SECURITY_PATCH=$TARGET|" "$f"
    fi
  done
fi

# 2) 系统属性
for RP in /data/adb/ksu/bin/resetprop /data/adb/magisk/resetprop resetprop; do
  if [ -x "$RP" ] || command -v "$RP" >/dev/null 2>&1; then
    "$RP" -n ro.build.version.security_patch "$TARGET"
    "$RP" -n ro.vendor.build.security_patch "$TARGET"
    "$RP" -n ro.boot.security_patch "$TARGET"
    "$RP" -n ro.system.build.version.security_patch "$TARGET"
    break
  fi
done
