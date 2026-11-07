#!/bin/bash
# susfs-version.sh - 让内核 SUSFS 如实汇报 v2.3.0 wire 协议（匹配 FinaSU v1.4.2）
#
# 背景：FinaSU v1.4.2 的 ksud（userspace/ksud/src/susfs/mod.rs classify()）
# 硬性要求内核 SUSFS 版本字符串**精确等于 "v2.3.0"**，否则判定
# unknown_protocol，管理器所有 SUSFS 功能只读不可用（「未知协议」）。
# 而 miyume 5.4 树自带的是 SUSFS v2.1.0。
#
# 经逐项对比，v2.1.0 与 v2.3.0 的 userspace<->kernel 协议完全兼容：
#   - 23 个 CMD_SUSFS_* 命令编号逐一相同
#   - st_susfs_* wire 结构布局一致（sus_path / sus_kstat / uname /
#     open_redirect / sus_map / version）
#   - 差异只在内核内部实现（TIF 位、mount ID 范围、内部链表），对用户态透明
# 因此内核汇报 "v2.3.0" 是安全的（它实现的正是这套 wire 协议）。
#
# 同时修掉 v2.1.0 的笔误：KSTAT_SPOOF_CTIME_TV_SEC 写成 (1 < 8)（比较），
# 应为 (1 << 8)（位移），否则 ctime 秒级伪装永远不生效。
#
# 用法：susfs-version.sh <kernel-dir>   幂等，可重复运行。
set -euo pipefail

KDIR="${1:?usage: susfs-version.sh <kernel-dir>}"
H="$KDIR/include/linux/susfs.h"
[ -f "$H" ] || { echo "ERROR: $H not found" >&2; exit 1; }

echo "=== [susfs-version] report v2.3.0 wire protocol (FinaSU v1.4.2 requirement) ==="

# 1) 版本字符串 v2.1.0 -> v2.3.0
if grep -q '#define SUSFS_VERSION "v2.3.0"' "$H"; then
  echo "  SUSFS_VERSION already v2.3.0 (skip)"
else
  sed -i 's|^#define SUSFS_VERSION "v2.1.0"$|#define SUSFS_VERSION "v2.3.0"|' "$H"
  if ! grep -q '#define SUSFS_VERSION "v2.3.0"' "$H"; then
    echo "ERROR: SUSFS_VERSION rewrite failed" >&2
    exit 1
  fi
  echo "  SUSFS_VERSION v2.1.0 -> v2.3.0"
fi

# 2) ctime 伪装标志笔误：(1 < 8) 是比较，应为 (1 << 8)
if grep -q '#define KSTAT_SPOOF_CTIME_TV_SEC (1 < 8)' "$H"; then
  sed -i 's|^#define KSTAT_SPOOF_CTIME_TV_SEC (1 < 8)$|#define KSTAT_SPOOF_CTIME_TV_SEC (1 << 8)|' "$H"
  if ! grep -q '#define KSTAT_SPOOF_CTIME_TV_SEC (1 << 8)' "$H"; then
    echo "ERROR: KSTAT_SPOOF_CTIME_TV_SEC rewrite failed" >&2
    exit 1
  fi
  echo "  KSTAT_SPOOF_CTIME_TV_SEC (1 < 8) -> (1 << 8)"
else
  echo "  KSTAT_SPOOF_CTIME_TV_SEC already correct (skip)"
fi

echo "=== [susfs-version] verification ==="
grep -n 'define SUSFS_VERSION' "$H"
grep -n 'define KSTAT_SPOOF_CTIME_TV_SEC' "$H"
echo "=== [susfs-version] DONE ==="
