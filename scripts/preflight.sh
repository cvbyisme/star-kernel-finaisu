#!/bin/bash
# preflight.sh - 在 susfs-setup.sh 之后运行，修补「结构性」问题
#
# 作用：
#   1. 生成 5.4 缺失头文件的壳（minmax.h / hex.h / pgtable.h）
#      -> 让 FinaSU 源码里的 #include 原样命中，不用逐个文件 sed
#   2. 覆盖 ksu54_compat.h 为增强版（含 TWA_*、nofault 全系列）
#   3. 通过 KernelSU/Kbuild 的 -include 全局注入，一次覆盖所有翻译单元
#   4. 把 ksu_handle_devpts 的 stub 从 feature/sucompat.c 挪到 extension/
#   5. 校验所有前置条件
#
# 用法：
#   bash ci/scripts/susfs-setup.sh "$PWD/kernel"
#   bash ci/scripts/preflight.sh   "$PWD/kernel"
#
# 幂等：可重复运行。
set -euo pipefail

KDIR="${1:?usage: preflight.sh <kernel-dir>}"
SUDIR="$KDIR/KernelSU/kernel"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ -d "$KDIR" ]  || { echo "ERROR: kernel dir $KDIR not found"; exit 1; }
[ -d "$SUDIR" ] || { echo "ERROR: $SUDIR not found (clone FinaSU into KernelSU/ first)"; exit 1; }
[ -f "$KDIR/include/linux/kernel.h" ] || { echo "ERROR: $KDIR is not a kernel tree"; exit 1; }

echo "=== [preflight] 1/5: shim headers for 5.8+/5.10+/6.2+ includes ==="

# 5.4 没有 include/linux/pgtable.h：壳指向 asm/pgtable.h
if [ ! -f "$KDIR/include/linux/pgtable.h" ]; then
  cat > "$KDIR/include/linux/pgtable.h" <<'EOF'
/* ksu54 shim: <linux/pgtable.h> was split out of <asm/pgtable.h> in 5.8 */
#ifndef _LINUX_PGTABLE_H
#define _LINUX_PGTABLE_H
#include <asm/pgtable.h>
#endif
EOF
  echo "  created include/linux/pgtable.h"
else
  echo "  include/linux/pgtable.h already present (skip)"
fi

# 5.10 没有 include/linux/minmax.h：壳指向 kernel.h（5.4 的 min/max 在那里）
if [ ! -f "$KDIR/include/linux/minmax.h" ]; then
  cat > "$KDIR/include/linux/minmax.h" <<'EOF'
/* ksu54 shim: <linux/minmax.h> was split out of <linux/kernel.h> in 5.10 */
#ifndef _LINUX_MINMAX_H
#define _LINUX_MINMAX_H
#include <linux/kernel.h>
#endif
EOF
  echo "  created include/linux/minmax.h"
else
  echo "  include/linux/minmax.h already present (skip)"
fi

# 6.2 没有 include/linux/hex.h：壳指向 kernel.h（bin2hex 声明在 kernel.h:638）
if [ ! -f "$KDIR/include/linux/hex.h" ]; then
  cat > "$KDIR/include/linux/hex.h" <<'EOF'
/* ksu54 shim: <linux/hex.h> was split out of <linux/kernel.h> in 6.2 */
#ifndef _LINUX_HEX_H
#define _LINUX_HEX_H
#include <linux/kernel.h>
#endif
EOF
  echo "  created include/linux/hex.h"
else
  echo "  include/linux/hex.h already present (skip)"
fi

echo "=== [preflight] 2/5: install enhanced ksu54_compat.h ==="
# 覆盖 susfs-setup.sh 生成的那一版（多了 TWA_* 和 nofault 全系列）
cp "$SELF/ksu54-compat.h" "$KDIR/include/linux/ksu54_compat.h"
echo "  installed $(wc -c < "$KDIR/include/linux/ksu54_compat.h") bytes"

echo "=== [preflight] 3/5: inject -include into KernelSU/Kbuild ==="
KB="$SUDIR/Kbuild"
if grep -q 'ksu54_compat.h' "$KB" 2>/dev/null; then
  echo "  already injected (skip)"
else
  # FinaSU 的 Kbuild 末尾有官方锚点：
  #   # Keep a new line here!! Because someone may append config
  # 直接追加即可，ccflags-y 是累积的。
  cat >> "$KB" <<'EOF'

# --- ksu54 preflight: global 5.4 API shims (see include/linux/ksu54_compat.h) ---
ccflags-y += -include $(srctree)/include/linux/ksu54_compat.h
EOF
  echo "  appended -include to KernelSU/Kbuild"
fi

echo "=== [preflight] optional: disable preinit (DISABLE_PREINIT=true) ==="
# 二分定位用：preinit 是 5.4 上最可疑的运行时路径。
# 教训：只用 -DKSU_NO_PREINIT 不可靠——某些调用方（syscall_event_bridge.c、
# ksud_integration.c、dispatch.c）自己 extern 声明或经 LTO 全程序分析后
# 仍然产生外部引用，最终 vmlinux 链接报 undefined symbol。
# 稳妥做法：提供一份真实的空实现 stub 文件，从 Kbuild 摘掉 preinit 对象。
if [ "${DISABLE_PREINIT:-false}" = "true" ]; then
  sed -i 's|^kernelsu-objs += preinit/preinit\.o$||' "$KB"
  sed -i 's|^kernelsu-objs += preinit/blob\.o$||' "$KB"

  POF="$SUDIR/extension/ksu54_preinit_off.c"
  if [ ! -f "$POF" ]; then
    cat > "$POF" <<'EOF'
/*
 * ksu54_preinit_off.c - diagnostic build: preinit disabled.
 * Real definitions (not macros): every caller of the preinit interface
 * resolves against these no-ops, regardless of how it declares them.
 */
#include <linux/types.h>
#include <asm/ptrace.h>

void ksu_preinit_init(void)
{
}

void ksu_preinit_exit(void)
{
}

bool ksu_preinit_handle_execve(const char __user **filename_user,
                               const char __user *const __user *argv_user,
                               int orig_nr, struct pt_regs *regs, long *ret)
{
    return false;
}

void ksu_preinit_release(void)
{
}

bool ksu_preinit_enabled_param(void)
{
    return false;
}
EOF
    echo "  created extension/ksu54_preinit_off.c"
  else
    echo "  extension/ksu54_preinit_off.c exists (skip)"
  fi

  if ! grep -q 'ksu54_preinit_off.o' "$KB"; then
    printf '\nkernelsu-objs += extension/ksu54_preinit_off.o\n' >> "$KB"
  fi
  echo "  preinit objects removed + ksu54_preinit_off.o registered"
else
  echo "  preinit left enabled (default)"
fi

echo "=== [preflight] optional: disable SUSFS (DISABLE_SUSFS=true) ==="
# SUSFS 关闭时 extension/susfs.c 不参与编译，但 vendor 树在纯 CONFIG_KSU
# 下仍引用 ksu_handle_* 系列符号（faccessat/stat/execveat/sys_read/
# vfs_fstat/sys_reboot），必须补一份签名与调用点精确匹配的空实现，
# 其中 sys_reboot 必须保持「-EINVAL 让真 reboot 流程继续」的语义。
if [ "${DISABLE_SUSFS:-false}" = "true" ]; then
  STUB="$SUDIR/extension/ksu54_stub.c"
  if [ ! -f "$STUB" ]; then
    cat > "$STUB" <<'STUBEOF'
/*
 * ksu54_stub.c - SUSFS-free stand-ins for the hooks FinaSU keeps inside
 * extension/susfs.c. Signatures follow the vendor tree externs exactly.
 */
#include <linux/cred.h>
#include <linux/fs.h>
#include <linux/types.h>
#include <linux/uaccess.h>

#include "uapi/supercall.h"

struct user_arg_ptr;

/* fs/exec.c */
int __maybe_unused ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv, void *envp,
                                       int *flags)
{
    return -EINVAL;
}

/* fs/open.c */
int __maybe_unused ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode, int *flags)
{
    return 0;
}

/* fs/stat.c */
int __maybe_unused ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags)
{
    return 0;
}

void __maybe_unused ksu_handle_vfs_fstat(int fd, loff_t *kstat_size_ptr)
{
    (void)fd;
    (void)kstat_size_ptr;
}

void __maybe_unused ksu_handle_sys_read(unsigned int fd)
{
    (void)fd;
}

/*
 * kernel/reboot.c only falls through to the real reboot path on non-zero
 * return. Return 0 for the KernelSU install magic pair, -EINVAL otherwise.
 */
int __maybe_unused ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg)
{
    (void)cmd;
    (void)arg;

    if (magic1 != (int)KSU_INSTALL_MAGIC1)
        return -EINVAL;
    if (magic2 == (int)KSU_INSTALL_MAGIC2)
        return 0;
    return -EINVAL;
}
STUBEOF
    echo "  created extension/ksu54_stub.c"
  else
    echo "  extension/ksu54_stub.c exists (skip)"
  fi

  if ! grep -q 'ksu54_stub.o' "$KB"; then
    printf '\n# ksu54 stub: SUSFS off, provide vendor tree hook symbols\nkernelsu-y += extension/ksu54_stub.o\n' >> "$KB"
    echo "  registered ksu54_stub.o in Kbuild"
  fi
else
  echo "  SUSFS left enabled (default)"
fi

echo "=== [preflight] 4/5: relocate ksu_handle_devpts stub to extension/ ==="
# 内核树 fs/devpts/inode.c:608-610 调用它，FinaSU 无实现。
# susfs-setup.sh step 8 会在 feature/sucompat.c 尾部塞一个同符号 stub；
# 先摘掉它，再在 extension/ 里放正式版 —— 否则两个同名定义链接报
# "multiple definition of ksu_handle_devpts"。
SCT="$SUDIR/feature/sucompat.c"
if [ -f "$SCT" ] && grep -q 'ksu_handle_devpts' "$SCT"; then
  python3 - "$SCT" <<'PYSTRIP'
import sys
p = sys.argv[1]
lines = open(p, encoding='utf-8').read().splitlines()
i = next((n for n, l in enumerate(lines) if 'ksu_handle_devpts(struct inode' in l), None)
if i is not None:
    j = i
    while j > 0 and (lines[j-1].strip().startswith('*') or lines[j-1].strip().startswith('/*')):
        j -= 1
    k = i
    while k < len(lines) and lines[k].strip() != '}':
        k += 1
    del lines[j:k+1]
    open(p, 'w', encoding='utf-8').write('\n'.join(lines) + '\n')
    print('  stripped old stub from sucompat.c (lines %d-%d)' % (j+1, k+1))
else:
    print('  no stub in sucompat.c')
PYSTRIP
else
  echo "  no ksu_handle_devpts in sucompat.c (nothing to strip)"
fi

DEVSTUB="$SUDIR/extension/ksu54_devpts.c"
if [ ! -f "$DEVSTUB" ]; then
  cat > "$DEVSTUB" <<'EOF'
/*
 * ksu54_devpts.c - no-op ksu_handle_devpts() for the star 5.4 vendor tree.
 *
 * fs/devpts/inode.c:608-610 carries a ReSukiSU-era hook:
 *     #ifdef CONFIG_KSU
 *     extern int ksu_handle_devpts(struct inode *);
 *     ksu_handle_devpts(dentry->d_inode);
 *     #endif
 * FinaSU 1.x has no implementation, so the vmlinux link dies with
 * "undefined symbol: ksu_handle_devpts" whenever CONFIG_KSU=y.
 *
 * This is a genuine no-op: devpts-based su hiding is unavailable on 5.4,
 * which is a known limitation, not something we can fake.
 */
#include <linux/fs.h>
#include <linux/types.h>

int __maybe_unused ksu_handle_devpts(struct inode *inode)
{
	(void)inode;
	return 0;
}
EOF
  echo "  created extension/ksu54_devpts.c"
else
  echo "  extension/ksu54_devpts.c exists (skip)"
fi

if ! grep -q 'ksu54_devpts.o' "$KB"; then
  # 无条件编译：fs/devpts/inode.c 的调用点只受 CONFIG_KSU 控制
  sed -i 's|^kernelsu-objs := core/init.o$|kernelsu-objs := core/init.o\nkernelsu-objs += extension/ksu54_devpts.o|' "$KB"
  if ! grep -q 'ksu54_devpts.o' "$KB"; then
    printf '\nkernelsu-objs += extension/ksu54_devpts.o\n' >> "$KB"
  fi
  echo "  registered in Kbuild"
fi

echo "=== [preflight] 5/6: retarget kernel_umount.c path_umount -> ksys_umount ==="
# susfs-setup.sh 的 step 7 只认旧版 3 参数 ksu_umount_mnt()，master 早已
# 改成 2 参数，锚点必然 miss 并 SystemExit —— 这里补上 master 版本。
KUM="$SUDIR/feature/kernel_umount.c"
if [ -f "$KUM" ]; then
python3 - "$KUM" <<'PYUM'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
if 'ksu54_umount' in s:
    print('  skipped (already retargeted)')
else:
    old_decl = 'extern int path_umount(struct path *path, int flags);'
    if old_decl not in s:
        print('  WARN: path_umount decl anchor not found')
        raise SystemExit(1)
    s = s.replace(old_decl,
        '/* ksu54_umount: 5.4 has no path_umount(); route through ksys_umount + d_path */\n'
        'extern int ksys_umount(char __user *name, int flags);', 1)
    old_fn = '''static void ksu_umount_mnt(struct path *path, int flags)
{
    int err = path_umount(path, flags);
    if (err) {
        pr_info_ratelimited("umount list entry failed: %d\\n", err);
    }
}'''
    if old_fn not in s:
        print('  WARN: ksu_umount_mnt 2-arg body anchor not found')
        raise SystemExit(1)
    new_fn = '''static void ksu_umount_mnt(struct path *path, int flags)
{
    int err;
    char *dir = kmalloc(PATH_MAX, GFP_KERNEL);

    if (!dir)
        return;
    {
        char *p2 = d_path(path, dir, PATH_MAX);
        if (!IS_ERR(p2)) {
            mm_segment_t oldfs = get_fs();
            set_fs(KERNEL_DS);
            err = ksys_umount((char __user *)p2, flags);
            set_fs(oldfs);
            if (err)
                pr_info_ratelimited("umount list entry failed: %d\\n", err);
        }
    }
    kfree(dir);
}'''
    s = s.replace(old_fn, new_fn, 1)
    open(p, 'w', encoding='utf-8').write(s)
    print('  kernel_umount.c: path_umount -> ksys_umount (2-arg master API)')
PYUM
else
  echo "  kernel_umount.c missing (skip)"
fi

echo "=== [preflight] 5.5/6: fix rules.c 5.4 policy shim (audit: kfree-static + self-deadlock) ==="
# 审计确认的两处确定性缺陷（susfs-setup step 4d 引入的 5.4 shim）：
#  a) KSU_POLICY_GET() 返回静态 shadow，apply_kernelsu_rules() 末尾却
#     ksu_destroy_sepolicy(old_pol) -> kfree(静态内存) -> BUG -> panic，
#     恰在 init 二阶段 execve 触发 -> MI logo 无限重启。
#  b) 5.4 shim 的 KSU_POLICY_LOCK 锁 status_lock，随后 reset_avc_cache ->
#     selinux_status_update_policyload 再锁同一 mutex -> 自死锁
#     （5.7+ 用 policy_mutex 所以上游没这问题）。
#     注意：本树 policy_rwlock 是 rwlock_t（自旋锁）不是 rw_semaphore，
#     且 susfs_cache_sid 会内部 read_lock 它——所以锁不能用它，正确修法是
#     在 <5.7 时跳过 status 通知（只是给用户空间看的 seqno bump）。
RUL="$SUDIR/selinux/rules.c"
if [ -f "$RUL" ]; then
python3 - "$RUL" <<'PYRULE'
import sys
import re
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
if 'ksu54_rules_fix' in s:
    print('  skipped (already fixed)')
    raise SystemExit(0)

ok = 0

old_destroy = '    ksu_destroy_sepolicy(old_pol);'
new_destroy = ('#if (LINUX_VERSION_CODE >= KERNEL_VERSION(5, 7, 0)) /* ksu54_rules_fix */\n'
               '    ksu_destroy_sepolicy(old_pol);\n'
               '#endif')
n = s.count(old_destroy)
if n >= 1:
    s = s.replace(old_destroy, new_destroy)
    ok += 1
    print('  guarded %d destroy-old call site(s)' % n)
else:
    print('  WARN: destroy-old anchor not found')

# 5.4 死锁修复：reset_avc_cache 里两处 status 通知（6.4+/else 分支各一）都
# 在 <5.7 时跳过。selinux_status_update_policyload 内部拿 status_lock。
# FinaSU v1.5.0 把第 2 参从硬编码 0 改成真实 seqno，所以这里用正则匹配整行。
old_status_pat = re.compile(
    r'    selinux_status_update_policyload\(&selinux_state, [^;\n]*\);')
n2 = len(old_status_pat.findall(s))
if n2 >= 1:
    s = old_status_pat.sub(
        lambda mo: ('#if (LINUX_VERSION_CODE >= KERNEL_VERSION(5, 7, 0)) /* ksu54_status_guard */\n'
                    + mo.group(0) + '\n#endif'),
        s)
    ok += 1
    print('  guarded %d status_update call site(s)' % n2)
else:
    print('  WARN: status_update anchor not found')

open(p, 'w', encoding='utf-8').write(s)
print('  rules.c fixed (%d/2 anchors)' % ok)
if ok < 2:
    raise SystemExit(1)
PYRULE
else
  echo "  rules.c missing (skip)"
fi

echo "=== [preflight] 5.8/6: rate-limit SELinux avc notif warn (5.4 seqno mismatch) ==="
# FinaSU v1.5.0 用 selinux_status_update_policyload() 传真实 policy seqno，
# 5.4 的 avc_cache.latest_notif 与之不同步，每次 notify 都 pr_warn 一行；
# 实测 0.04 秒内刷出 7000+ 行，把 ring buffer 打满并拖慢整机。
AVC="$KDIR/security/selinux/avc.c"
if [ -f "$AVC" ]; then
python3 - "$AVC" <<'PYAVC'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
if 'avc54_notif_ratelimit' in s:
    print('  already rate-limited')
    raise SystemExit(0)
anchor = 'pr_warn("SELinux: avc: seqno %d < latest_notif %d\\n",'
if anchor not in s:
    print('  WARN: avc notif warn anchor not found (skip)')
    raise SystemExit(0)
s = s.replace(
    anchor,
    '/* avc54_notif_ratelimit */\n\t\t\t'
    'pr_warn_ratelimited("SELinux: avc: seqno %d < latest_notif %d\\n",',
    1)
open(p, 'w', encoding='utf-8').write(s)
print('  rate-limited avc notif warning')
PYAVC
else
  echo "  avc.c missing (skip)"
fi

echo "=== [preflight] 6/6: verification ==="
fail=0
chk() {
  if eval "$2"; then echo "  OK   $1"; else echo "  FAIL $1"; fail=1; fi
}
chk "include/linux/pgtable.h shim"      "[ -f '$KDIR/include/linux/pgtable.h' ]"
chk "include/linux/minmax.h shim"       "[ -f '$KDIR/include/linux/minmax.h' ]"
chk "include/linux/hex.h shim"          "[ -f '$KDIR/include/linux/hex.h' ]"
chk "ksu54_compat.h installed"          "grep -q 'TWA_RESUME' '$KDIR/include/linux/ksu54_compat.h'"
chk "Kbuild -include injected"          "grep -q 'ksu54_compat.h' '$SUDIR/Kbuild'"
chk "devpts stub compiled in"           "grep -q 'ksu54_devpts.o' '$SUDIR/Kbuild'"
chk "devpts call site present"          "grep -q 'ksu_handle_devpts' '$KDIR/fs/devpts/inode.c'"
chk "extension/susfs.c present"         "[ -f '$SUDIR/extension/susfs.c' ]"
chk "kernel has built-in SUSFS v2.x"    "grep -q 'obj-\$(CONFIG_KSU_SUSFS) += susfs.o' '$KDIR/fs/Makefile'"
chk "kernel_umount.c retargeted"         "grep -q 'ksu54_umount' '$SUDIR/feature/kernel_umount.c'"
chk "susfs_def.h FinaSU aliases"         "grep -q 'susfs_set_current_proc_no_su' '$KDIR/include/linux/susfs_def.h'"
chk "namespace.c exports do_mount"       "grep -q 'EXPORT_SYMBOL(do_mount)' '$KDIR/fs/namespace.c'"
chk "su_mount_ns.c uses do_mount"        "grep -q 'do_mount' '$SUDIR/infra/su_mount_ns.c'"
chk "rules.c destroy-old guarded"         "grep -q 'ksu54_rules_fix' '$SUDIR/selinux/rules.c'"
chk "rules.c status_update guarded"       "grep -q 'ksu54_status_guard' '$SUDIR/selinux/rules.c'"

if [ "${DISABLE_PREINIT:-false}" = "true" ]; then
  chk "preinit disabled (stub + objs removed)" "grep -q 'ksu54_preinit_off.o' '$SUDIR/Kbuild' && ! grep -q 'preinit/preinit\.o' '$SUDIR/Kbuild'"
fi

if [ "${DISABLE_SUSFS:-false}" = "true" ]; then
  chk "ksu54_stub registered (SUSFS off)"  "grep -q 'ksu54_stub.o' '$SUDIR/Kbuild'"
fi

if [ "$fail" -ne 0 ]; then
  echo "=== [preflight] FAILED ==="
  exit 1
fi

echo "=== [preflight] DONE ==="
echo "  提醒：make 命令行务必带上"
echo "        KSU_SECOND_SIGNATURE_RELEASE=1 \\"
echo "        KSU_EXPECTED_SIZE2=716 \\"
echo "        KSU_EXPECTED_HASH2=<对应管理器的签名 hash>"
echo "  否则 FINASU_TRUSTED_* 会回落到 slot1（KSU 官方签名），注入的 slot2 无效。"

