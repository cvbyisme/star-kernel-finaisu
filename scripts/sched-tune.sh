#!/bin/bash
# sched-tune.sh - 内核调度源码补丁(构建时应用到内核树)
#
# 用法: bash scripts/sched-tune.sh <kernel_dir> [verify]
#
# 固定应用三个补丁(实机验证通过的正式形态,小米 11 Ultra / star):
#   s1-input-boost-off : cpu-boost 输入提升默认关(触摸不再拉高 min 频)
#   s2-io-is-busy-off  : WALT io_is_busy 默认 0(IO 等待不再推高频)
#   pelt-force         : schedutil 强制 PELT util 路径
#                        (WALT 信号路径在 star 上会卡小米 logo)
#
# 补丁针对 cvbyisme/android_kernel_xiaomi_sm8350_miyume@main 生成;
# 内核树漂移时 apply 显式失败,不静默跳过。

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_DIR="$SCRIPT_DIR/sched-patches"
KERNEL_DIR="${1:?usage: sched-tune.sh <kernel_dir> [verify]}"
MODE="${2:-apply}"
PATCHES="s1-input-boost-off.patch s2-io-is-busy-off.patch pelt-force.patch"

is_applied() {
    git -C "$KERNEL_DIR" apply --check --reverse "$PATCH_DIR/$1" >/dev/null 2>&1
}

FAIL=0
for p in $PATCHES; do
    if [ "$MODE" = "verify" ]; then
        if is_applied "$p"; then
            echo "sched-tune gate: $p applied - OK"
        else
            echo "::error::$p NOT applied"
            FAIL=1
        fi
        continue
    fi
    if is_applied "$p"; then
        echo "sched-tune: $p already applied, skip"
    elif git -C "$KERNEL_DIR" apply --check "$PATCH_DIR/$p" >/dev/null 2>&1; then
        git -C "$KERNEL_DIR" apply "$PATCH_DIR/$p" \
            && echo "sched-tune: applied $p" || FAIL=1
    else
        echo "::error::$p does not apply (kernel tree drift?)"
        FAIL=1
    fi
done

[ "$FAIL" -eq 0 ] && echo "sched-tune $MODE: PASS" || exit 1