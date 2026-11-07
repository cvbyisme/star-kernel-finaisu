#!/system/bin/sh
# =====================================================================
# star-selftest.sh  —  小米11 (star/SM8350) Neko-CL 内核刷入自检
# 用法（推荐 root）：
#   su -c 'sh /sdcard/Download/star-selftest.sh'
# 普通权限也能跑，但 dmesg / pstore / 模块项会 SKIP。
# 建议在刚刷完机第一次开机后立刻跑，dmesg 里开机日志才不会被覆盖。
# =====================================================================
TS=$(date +%Y%m%d-%H%M%S)
OUT="/sdcard/Download/star-selftest-$TS.txt"
PASS=0; FAIL=0; WARN=0; SKIP=0
R=0; [ "$(id -u 2>/dev/null)" = "0" ] && R=1
DML=/data/local/tmp/star-dmesg.log
[ "$R" = "1" ] && dmesg > "$DML" 2>/dev/null

log()  { echo "$@" >> "$OUT"; }
say()  { echo "$@"; echo "$@" >> "$OUT"; }
ok()   { PASS=$((PASS+1)); say "  [PASS] $1"; }
bad()  { FAIL=$((FAIL+1)); say "  [FAIL] $1"; }
wrn()  { WARN=$((WARN+1)); say "  [WARN] $1"; }
skp()  { SKIP=$((SKIP+1)); say "  [SKIP] $1"; }
sec()  { say ""; say "== $1 =="; }

: > "$OUT" 2>/dev/null
say "star-selftest  $TS   device=$(getprop ro.product.device)  rom=$(getprop ro.build.display.id)"
[ "$R" = "1" ] || say "!! 非 root 运行，部分项目会跳过"

# ---------- 1. 内核身份 ----------
sec "1. 内核身份"
PV=$(cat /proc/version 2>/dev/null)
UR=$(uname -r 2>/dev/null)
KREL=$(echo "$PV" | sed -n 's/^Linux version \([^ ]*\).*/\1/p')
say "  /proc/version : $PV"
say "  uname -r      : $UR   (kernel uts spoof 可能改写，不可信)"
case "$KREL" in
  *Neko-CL*) ok "真内核标识含 Neko-CL ($KREL)" ;;
  "")        bad "读不到 /proc/version" ;;
  *)         bad "内核不是 Neko-CL：$KREL" ;;
esac
case "$PV" in
  *"5.4.302"*) ok "源版本 5.4.302" ;;
  *"5.4."*)    wrn "源版本不是 5.4.302" ;;
esac

# ---------- 2. KernelSU / FinaSU ----------
sec "2. KernelSU / FinaSU"
KS=/data/adb/ksu/bin/ksud
if [ -x "$KS" ]; then
  KV=$($KS -V 2>/dev/null | head -1)
  say "  ksud: $KV"
  [ -n "$KV" ] && ok "ksud 可执行" || bad "ksud 无输出"
else
  bad "缺少 $KS（KSU 侧未安装或路径变了）"
fi
if [ "$R" = "1" ] && [ -x "$KS" ]; then
  FL=$($KS feature list 2>/dev/null)
  for f in selinux_hide avc_spoof su_compat kernel_umount; do
    echo "$FL" | grep -q "\[ENABLED (1)\] $f" && ok "feature $f = ENABLED" \
      || wrn "feature $f 未启用"
  done
else
  skp "ksud feature list（需要 root）"
fi

# ---------- 3. SELinux ----------
sec "3. SELinux"
EN=$(getenforce 2>/dev/null)
say "  getenforce : $EN"
[ "$EN" = "Enforcing" ] && ok "SELinux Enforcing" || wrn "SELinux 非 Enforcing：$EN"
if [ "$R" = "1" ]; then
  DOM=$(cat /proc/self/attr/current 2>/dev/null | tr -d '\0')
  say "  当前域     : $DOM"
  case "$DOM" in u:r:ksu:s0*) ok "root 域为 ksu" ;; *) wrn "root 域异常：$DOM" ;; esac
  CNT=$(grep -c "ksu54" "$DML" 2>/dev/null)
  say "  dmesg ksu54 命中: $CNT"
  if [ "$CNT" -gt 0 ]; then
    ok "access 规则层掩码有日志（本次开机已生效）"
  else
    DMT0=$(head -1 "$DML" 2>/dev/null | sed -n 's/^\[ *\([0-9][0-9]*\)\..*/\1/p')
    if [ -n "$DMT0" ] && [ "$DMT0" -gt 600 ] 2>/dev/null; then
      say "  （dmesg 最早一条已是开机 ${DMT0}s，开机日志被覆盖，本次无法判断，建议刚重启后立刻再跑）"
    else
      wrn "无 ksu54 日志（开机不久仍无，掩码可能未加载）"
    fi
  fi
else
  skp "SELinux 域 / ksu54 日志（需要 root）"
fi

# ---------- 4. 调度与功耗 ----------
sec "4. 调度 / 功耗调优"
for c in 0 4 7; do
  f="/sys/devices/system/cpu/cpu$c/cpufreq/scaling_governor"
  if [ -r "$f" ]; then
    g=$(cat "$f" 2>/dev/null)
    [ "$g" = "schedutil" ] && ok "cpu$c governor = schedutil" || wrn "cpu$c governor = $g（预期 schedutil）"
  else
    skp "cpu$c governor 不可读"
  fi
done
IB=$(find /sys/devices/system/cpu -name input_boost -maxdepth 3 2>/dev/null | head -1)
if [ -n "$IB" ]; then
  ibv=$(cat "$IB" 2>/dev/null)
  [ "$ibv" = "0" ] && ok "input_boost = 0" || wrn "input_boost = $ibv（预期 0）"
else
  ok "input_boost 节点不存在（默认关闭）"
fi
IOB=$(find /sys/devices/system/cpu -name io_is_busy -maxdepth 3 2>/dev/null | head -1)
if [ -n "$IOB" ]; then
  iov=$(cat "$IOB" 2>/dev/null)
  [ "$iov" = "0" ] && ok "io_is_busy = 0" || wrn "io_is_busy = $iov"
else
  ok "io_is_busy 节点不存在（默认关闭）"
fi

# ---------- 5. 内存 / zram ----------
sec "5. 内存 / ZRAM"
if [ -r /proc/meminfo ]; then
  say "  $(grep -E '^(MemTotal|MemAvailable|SwapTotal|SwapFree):' /proc/meminfo | tr '\n' ' ')"
  ok "meminfo 可读"
fi
if [ -r /sys/block/zram0/disksize ]; then
  DS=$(cat /sys/block/zram0/disksize 2>/dev/null)
  say "  zram0 disksize : $DS"
  case "$DS" in
    ""|0) wrn "zram0 disksize 未配置（$DS）" ;;
    *)    ok "zram0 已配置 ($DS B)" ;;
  esac
  CA=$(cat /sys/block/zram0/comp_algorithm 2>/dev/null)
  [ -n "$CA" ] && say "  comp_algorithm : $CA"
else
  skp "zram0 不可读"
fi

# ---------- 6. 电池 / 充电 ----------
sec "6. 电池"
for f in capacity status charge_counter voltage_now; do
  p="/sys/class/power_supply/battery/$f"
  [ -r "$p" ] && say "  battery/$f = $(cat "$p" 2>/dev/null)" || skp "battery/$f 不存在"
done
[ -r /sys/class/power_supply/battery/capacity ] && ok "电池节点正常" || bad "电池节点缺失"

# ---------- 7. 安全补丁日期一致性 ----------
sec "7. 安全补丁日期"
for p in ro.build.version.security_patch ro.vendor.build.security_patch ro.boot.security_patch; do
  say "  $p = $(getprop $p)"
done
SYSP=$(grep -m1 '^ro.build.version.security_patch=' /system/build.prop 2>/dev/null | cut -d= -f2)
VNDP=$(grep -m1 '^ro.vendor.build.security_patch=' /vendor/build.prop 2>/dev/null | cut -d= -f2)
say "  /system/build.prop = ${SYSP:-?}    /vendor/build.prop = ${VNDP:-?}"
A=$(getprop ro.build.version.security_patch)
[ -n "$A" ] && ok "运行时属性已设置" || bad "运行时补丁日期为空"
if [ -n "$SYSP" ] && [ "$SYSP" != "$A" ]; then
  wrn "属性($A) 与 /system/build.prop($SYSP) 不一致（属伪装正常，设置页需 zygote 重启后才更新）"
fi

# ---------- 8. 模块 ----------
sec "8. 模块"
if [ "$R" = "1" ] && [ -x "$KS" ]; then
  MN=$($KS module list 2>/dev/null | grep -c '"id"')
  say "  已安装模块数: $MN"
  [ "$MN" -gt 0 ] && ok "模块系统正常" || wrn "没有已安装模块"
  for m in star_spoof_security_patch tricky_store zygisksu; do
    if [ -d "/data/adb/modules/$m" ]; then say "  [OK] /data/adb/modules/$m 存在"; fi
    if [ -d "/data/adb/modules_update/$m" ]; then wrn "/data/adb/modules_update/$m 待重启合并"; fi
  done
else
  skp "模块列表（需要 root）"
fi

# ---------- 9. 异常扫描 ----------
sec "9. 内核日志异常扫描"
if [ "$R" = "1" ]; then
  if [ ! -s "$DML" ]; then
    skp "dmesg 为空"
  else
    for pat in "Kernel panic" "Oops" "Unable to handle kernel" "BUG: soft lockup" "BUG: sleeping function" "Watchdog bark" "Call trace"; do
      n=$(grep -c -i "$pat" "$DML" 2>/dev/null)
      [ "$n" -gt 0 ] && bad "dmesg 命中 '$pat' x$n" || ok "无 '$pat'"
    done
    say "  --- 最后 8 行 dmesg ---"
    tail -n 8 "$DML" 2>/dev/null | sed 's/^/    /' | tee -a "$OUT"
    AVCN=$(grep -c 'avc: *denied' "$DML" 2>/dev/null)
    say "  avc denied : ${AVCN:-0} 条（仅 dmesg 可见部分）"
    AVCT=$(grep -o 'scontext=u:r:[a-z0-9_]*' "$DML" 2>/dev/null | sort | uniq -c | sort -rn | head -3)
    [ -n "$AVCT" ] && echo "$AVCT" | sed 's/^/    来源 /' | tee -a "$OUT"
    AL0=$(grep -o 'audit_lost=[0-9]*' "$DML" 2>/dev/null | tail -1 | cut -d= -f2)
    if [ -n "$AL0" ]; then
      sleep 3
      dmesg > "$DML.2" 2>/dev/null
      AL1=$(grep -o 'audit_lost=[0-9]*' "$DML.2" 2>/dev/null | tail -1 | cut -d= -f2)
      rm -f "$DML.2"
      if [ -n "$AL1" ] && [ "$AL1" != "$AL0" ]; then
        wrn "audit 正在丢日志：3 秒内 $AL0 → $AL1（rate_limit 过紧或 AVC 洪泛）"
      else
        say "  audit_lost : $AL0（开机阶段累计，当前已静止，不算异常）"
      fi
    else
      say "  audit_lost : 本次 dmesg 无该记录（开机日志已被覆盖，属正常）"
    fi
  fi
  if [ -d /sys/fs/pstore ] && [ -n "$(ls /sys/fs/pstore 2>/dev/null)" ]; then
    wrn "pstore 有残留崩溃记录: $(ls /sys/fs/pstore | tr '\n' ' ')"
  else
    ok "pstore 无崩溃记录"
  fi
else
  skp "dmesg / pstore（需要 root）"
fi

# ---------- 10. 备份 ----------
sec "10. boot 备份"
for f in /sdcard/cvby/boot_a.img /sdcard/cvby/vendor_boot_a.img /sdcard/cvby/dtbo_a.img; do
  if [ -f "$f" ]; then
    sz=$(ls -l "$f" 2>/dev/null | awk '{print $5}')
    say "  $f  ($sz B)"
    [ "$sz" -gt 1000000 ] 2>/dev/null && ok "$(basename $f) 备份可用" || wrn "$(basename $f) 体积异常"
  else
    wrn "缺 $f（刷机前应备份）"
  fi
done

# ---------- 汇总 ----------
say ""
say "=================================================================="
say "  结果：PASS=$PASS  WARN=$WARN  FAIL=$FAIL  SKIP=$SKIP"
say "  详细报告：$OUT"
say "=================================================================="
[ "$FAIL" -gt 0 ] && exit 1
exit 0