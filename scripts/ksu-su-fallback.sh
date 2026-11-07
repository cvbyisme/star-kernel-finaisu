#!/bin/bash
# ksu-su-fallback.sh - 让 FinaSU 在 /data/adb/ksud 缺失时 fallback 到 /system/bin/sh
#
# 背景：Android 16 的 app seccomp 拦了 SYS_reboot，ksud 只能靠 /proc/self/fd
# 拿内核注入的 fd，而 sucompat 重定向的目标固定是 /data/adb/ksud。
# 文件缺失 = 两条路全断，管理器只会报「获取 Root 失败」。
#
# SukiSU Ultra 的做法是：ksud 不在时把 su 变成 /system/bin/sh（root shell），
# 首次刷入就能拿到 root，管理器随后自己把 ksud 释放到 /data/adb。
# FinaSU 里 SH_PATH 宏已定义但从未使用（死代码），本脚本把它接上。
#
# 参考：scripts/ak3-ksud.sh 是另一条路（AK3 预置 ksud），两者可共存。
#
# 用法：bash scripts/ksu-su-fallback.sh <kernel-dir>
# 幂等：可重复运行。
set -euo pipefail

KDIR="${1:?usage: ksu-su-fallback.sh <kernel-dir>}"
F="$KDIR/KernelSU/kernel/feature/sucompat.c"

[ -d "$KDIR" ] || { echo "ERROR: kernel dir $KDIR not found"; exit 1; }
[ -f "$F" ] || { echo "ERROR: $F not found (clone FinaSU into KernelSU/ first)"; exit 1; }

echo "=== [su-fallback] patching $F ==="

python3 - "$F" <<'PATCH_PY'
import sys

path = sys.argv[1]
src = open(path, encoding='utf-8').read()

if 'VENUS_SU_FALLBACK' in src:
    print('  already patched (skip)')
    sys.exit(0)

old = (
    '    if (IS_ERR(ksud_file)) {\n'
    '        pr_err("open ksud err: %ld\\n", PTR_ERR(ksud_file));\n'
    '        put_unused_fd(tmp_fd);\n'
    '        goto do_orig_execve;\n'
    '    }\n'
)

if old not in src:
    print('ERROR: anchor block not found. sucompat.c layout changed?')
    sys.exit(1)

new = (
    '    if (IS_ERR(ksud_file)) {\n'
    '        /* VENUS_SU_FALLBACK: /data/adb/ksud 缺失时改执行 /system/bin/sh，\n'
    '         * 让首次刷入就能拿到 root shell，管理器随后自行释放 ksud。 */\n'
    '        long ksud_err = PTR_ERR(ksud_file);\n'
    '\n'
    '        pr_info("sucompat: %s not found (err %ld), fallback to %s\\n",\n'
    '                KSUD_PATH, ksud_err, SH_PATH);\n'
    '        old_cred = override_creds(ksu_cred);\n'
    '        ksud_file = filp_open(SH_PATH, O_PATH, 0);\n'
    '        revert_creds(old_cred);\n'
    '        if (IS_ERR(ksud_file)) {\n'
    '            pr_err("open ksud err: %ld, fallback sh err: %ld\\n",\n'
    '                   ksud_err, PTR_ERR(ksud_file));\n'
    '            put_unused_fd(tmp_fd);\n'
    '            goto do_orig_execve;\n'
    '        }\n'
    '    }\n'
)

src = src.replace(old, new, 1)
open(path, 'w', encoding='utf-8').write(src)
print('  patched OK')
PATCH_PY

echo "--- verify ---"
grep -n 'VENUS_SU_FALLBACK' "$F"
grep -n 'fallback to %s' "$F"
echo "=== [su-fallback] done ==="
