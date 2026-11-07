#!/system/bin/sh
# ============================================================
# star-kernel-finaisu 日志采集脚本
# 用法（需要 root）：
#     su -c 'sh /data/local/tmp/collect-logs.sh'
# 产物：/sdcard/Download/star-logs-<时间戳>.zip
# 可把 zip 直接发给作者排错，里面不含任何账号/隐私数据
# ============================================================
set -u

TS=$(date +%Y%m%d-%H%M%S)
NAME=star-logs-$TS
OUT=/sdcard/Download/$NAME
LOG=$OUT/log.txt

[ "$(id -u)" = "0" ] || { echo "!! 需要 root：su -c 'sh $0'"; exit 1; }

mkdir -p "$OUT" || { echo "!! 无法创建 $OUT"; exit 1; }
: > "$LOG"

sec() { echo "" >>"$LOG"; echo "===== $* =====" >>"$LOG"; }
run() { echo "\$ $*" >>"$LOG"; eval "$*" >>"$LOG" 2>&1; }

sec 基本信息
run "date"
run "uname -a"
run "cat /proc/version"
run "getprop ro.product.model"
run "getprop ro.build.display.id"
run "getprop ro.build.version.release"
run "getprop ro.boot.slot_suffix"
run "cat /proc/uptime"
run "cat /proc/loadavg"

sec 内核启动参数
run "cat /proc/cmdline"

sec FinaSU / KernelSU
run "ls -l /data/adb/ksud /data/adb/ksu/bin/ksud"
run "/data/adb/ksu/bin/ksud --version"
run "/data/adb/ksu/bin/ksud feature list"
run "ls /data/adb/ksu"
run "ls /data/adb/modules"

sec SELinux
run "cat /sys/fs/selinux/status"
run "cat /sys/fs/selinux/enforce"
run "cat /sys/fs/selinux/policyvers"
run "getenforce"
run "dmesg | grep -i ksu54"

sec SUSFS
run "dmesg | grep -i susfs | tail -60"
run "ls /sys/kernel | grep -i susfs"

sec 电源与频率
run "cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"
run "cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq"
run "head -6 /sys/devices/system/cpu/cpu0/cpufreq/stats/time_in_state"
run "cat /sys/devices/system/cpu/cpu_boost/input_boost"
run "cat /sys/class/power_supply/battery/capacity"
run "cat /sys/class/power_supply/battery/temp"
run "cat /sys/class/thermal/thermal_zone0/temp"

sec 内存
run "head -6 /proc/meminfo"

sec dmesg 全文
dmesg >"$OUT/dmesg.txt" 2>&1 || echo "dmesg 读取失败（可能需要先 su）" >"$OUT/dmesg.txt"

sec logcat 全文
logcat -b all -d -v threadtime >"$OUT/logcat.txt" 2>&1 || echo "logcat 读取失败" >"$OUT/logcat.txt"

sec pstore
mkdir -p "$OUT/pstore"
cp /sys/fs/pstore/* "$OUT/pstore/" 2>/dev/null || true

sec 模块与日志文件
cp /data/adb/ksud.log "$OUT/" 2>/dev/null || true
cp /data/adb/ksu/log/* "$OUT/" 2>/dev/null || true

# ---- 打包 ----
cd /sdcard/Download || exit 1
if command -v zip >/dev/null 2>&1; then
    zip -r -q "$NAME.zip" "$NAME" && rm -rf "$NAME"
    FINAL=/sdcard/Download/$NAME.zip
else
    tar czf "$NAME.tar.gz" "$NAME" && rm -rf "$NAME"
    FINAL=/sdcard/Download/$NAME.tar.gz
fi

echo ""
echo "✅ 采集完成：$FINAL"
echo "大小：$(ls -l "$FINAL" | awk '{print $5}') 字节"
command -v sha256sum >/dev/null 2>&1 && echo "sha256：$(sha256sum "$FINAL" | awk '{print $1}')"
command -v md5sum >/dev/null 2>&1 && echo "md5：$(md5sum "$FINAL" | awk '{print $1}')"
echo "把它发作者即可（不含隐私数据）"
