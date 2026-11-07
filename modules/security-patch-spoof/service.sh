#!/system/bin/sh
# 启动完成后补一次，防止 PIF 自动刷新/ROM 覆盖
MODDIR=${0%/*}
i=0
while [ $i -lt 15 ]; do
  [ "$(getprop sys.boot_completed)" = "1" ] && break
  sleep 2
  i=$((i+1))
done
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
