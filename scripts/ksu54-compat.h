/*
 * ksu54_compat.h - Linux 5.4 compatibility layer for FinaSU on sm8350 (star)
 *
 * 设计原则：只做「API 存在性」补齐，不改语义。
 * 由 preflight.sh 复制到 <kernel>/include/linux/ksu54_compat.h，
 * 再通过 KernelSU/Kbuild 的
 *     ccflags-y += -include $(srctree)/include/linux/ksu54_compat.h
 * 全局注入到所有 kernelsu 翻译单元 —— 这样就不用逐个文件 sed include。
 *
 * 注意：能被本头文件解决的，只有「头文件/内联函数缺失」这一类。
 * 结构体字段差异（struct seccomp_filter.filter_count、struct selinux_policy）
 * 必须改代码，见 preflight.sh 的 step 5。
 */
#ifndef _KSU54_COMPAT_H
#define _KSU54_COMPAT_H

#include <linux/version.h>
#include <linux/types.h>
#include <linux/kernel.h>
#include <linux/string.h>
#include <linux/errno.h>

/* ------------------------------------------------------------------ *
 * 5.8: <linux/pgtable.h> 从 <asm/pgtable.h> 里拆出来
 * ------------------------------------------------------------------ */
#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 8, 0)
#include <asm/pgtable.h>

/* __p4d_to_phys() 在 5.8 之前 p4d 被折叠掉，等价于 pgd */
#ifndef __p4d_to_phys
#define __p4d_to_phys(p4d) __pgd_to_phys(p4d)
#endif
#endif /* < 5.8 */

/* ------------------------------------------------------------------ *
 * 5.7: untagged_addr()。arm64 5.4 默认不做 tag 扩展，恒等即可。
 * 注意 vendor 树可能在 <linux/mm.h> 已定义，用 ifndef 保护。
 * ------------------------------------------------------------------ */
#ifndef untagged_addr
#define untagged_addr(addr) ((unsigned long)(addr))
#endif

/* ------------------------------------------------------------------ *
 * 5.8: *_from_user_nofault / *_to_user_nofault 系列
 * 5.4 只有 probe_kernel_read/write，这里用 pagefault_disable + 原子拷贝实现。
 * ------------------------------------------------------------------ */
#include <linux/uaccess.h>
#include <linux/mm.h>
#include <linux/highmem.h>

#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 8, 0)

static inline long ksu54_strncpy_from_user_nofault(char *dst,
						   const void __user *src,
						   long count)
{
	long ret;

	if (count < 0)
		return -EINVAL;
	if (!access_ok(src, count))
		return -EFAULT;

	pagefault_disable();
	ret = strncpy_from_user(dst, src, count);
	pagefault_enable();

	if (ret < 0)
		return ret;
	if (ret >= count) {
		dst[count - 1] = 0;
		return -ERANGE;
	}
	return ret;
}
#define strncpy_from_user_nofault(dst, src, n) \
	ksu54_strncpy_from_user_nofault((char *)(dst), \
					(const void __user *)(src), (long)(n))

static inline long ksu54_copy_from_user_nofault(void *dst,
						const void __user *src,
						size_t size)
{
	long ret;

	if (!access_ok(src, size))
		return -EFAULT;
	pagefault_disable();
	ret = __copy_from_user_inatomic(dst, src, size);
	pagefault_enable();
	return ret ? -EFAULT : 0;
}
#define copy_from_user_nofault(dst, src, n) \
	ksu54_copy_from_user_nofault((void *)(dst), \
				     (const void __user *)(src), (size_t)(n))

static inline long ksu54_copy_to_user_nofault(void __user *dst,
					      const void *src,
					      size_t size)
{
	long ret;

	if (!access_ok(dst, size))
		return -EFAULT;
	pagefault_disable();
	ret = __copy_to_user_inatomic(dst, src, size);
	pagefault_enable();
	return ret ? -EFAULT : 0;
}
#define copy_to_user_nofault(dst, src, n) \
	ksu54_copy_to_user_nofault((void __user *)(dst), \
				   (const void *)(src), (size_t)(n))

#endif /* < 5.8 */

/* ------------------------------------------------------------------ *
 * 5.8: copy_to_kernel_nofault()
 * ------------------------------------------------------------------ */
#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 8, 0)
static inline int ksu54_copy_to_kernel_nofault(void *dst, const void *src,
					       size_t size)
{
	return copy_from_kernel_nofault(dst, src, size);
}
#define copy_to_kernel_nofault(dst, src, n) \
	ksu54_copy_to_kernel_nofault((void *)(dst), (const void *)(src), (size_t)(n))
#endif

/* ------------------------------------------------------------------ *
 * 5.8: task_work 的 TWA_* 枚举（5.4 的 task_work_add 第 3 参是 bool）
 * ------------------------------------------------------------------ */
#include <linux/task_work.h>

#ifndef TWA_RESUME
#define TWA_RESUME	true
#endif
#ifndef TWA_NONE
#define TWA_NONE	false
#endif
#ifndef TWA_SIGNAL
#define TWA_SIGNAL	true
#endif

/* ------------------------------------------------------------------ *
 * 5.10: <linux/minmax.h> 从 <linux/kernel.h> 拆出（5.4 已在 kernel.h）
 * 说明：preflight.sh 还会生成 include/linux/minmax.h 的壳，
 * 覆盖 `#include <linux/minmax.h>` 这种写法。这里再兜一层。
 * ------------------------------------------------------------------ */
#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 10, 0)
#ifndef min_t
#define min_t(type, x, y) \
	({ type __min1 = (x); type __min2 = (y); __min1 < __min2 ? __min1 : __min2; })
#endif
#ifndef max_t
#define max_t(type, x, y) \
	({ type __max1 = (x); type __max2 = (y); __max1 > __max2 ? __max1 : __max2; })
#endif
#endif /* < 5.10 */

/* ------------------------------------------------------------------ *
 * 6.2: <linux/hex.h> 拆出（5.4 的 bin2hex 声明在 <linux/kernel.h>）
 * preflight.sh 生成 include/linux/hex.h 壳，这里只做说明性兜底。
 * ------------------------------------------------------------------ */

#endif /* _KSU54_COMPAT_H */

