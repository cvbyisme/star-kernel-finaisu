# star-kernel-finaisu

> 小米 11 Ultra（star / SM8350）5.4 非 GKI 内核，内置 [FinaSU](https://github.com/LyraVoid/FinaSU)。
>
>
> 一切改动都来自公开上游，大肥鱼参与了搭建、排错与文档撰写。
>
> ⚠️只在自己机器上验证过，刷机风险自负。

---

## 目标设备

| 项 | 值 |
|---|---|
| 机型 | Xiaomi 11 Ultra（star / M2102K1C） |
| SoC | Snapdragon 888 / SM8350 |
| 内核基线 | Linux 5.4.302（`cvbyisme/android_kernel_xiaomi_sm8350_miyume`） |
| 原厂内核 | `5.4.274-qgki-gcc3ec22f5061` |
| Android | 16 / HyperOS 3.0（WPBCNXM） |
| 工具链 | ZyCromerZ Clang 14.0.6 |
| 内核类型 | **非 GKI**，vendor 树 |

---

## 快速开始

1. 到 **[Releases](../../releases)** 下载最新的 `star-test-*` 测试包（本仓刚起步，尚无正式版）
2. 进 **TWRP** 刷入或者APP刷入
3. 重启，打开 FinaSU —— 首屏显示 **「工作中」** 即完成

**管理器版本要对上**：内核编入的是 FinaSU 的管理器签名与协议版本，管理器 APK 与内核不匹配时会表现为「不识别 / 只读」。

| 内核内嵌 | 用哪个管理器 |
|---|---|
| FinaSU `v1.4.2`（现行主线） | FinaSU v1.4.2 及其后的同签 APK |
| FinaSU `v1.2.1`（历史构建线 `fix-v121.yml`） | 必须配 v1.2.1 时期的旧 APK，混用会识别失败 |

**确认刷的是自编内核**：`uname -r` 形如 `5.4.302-Neko-CL-g<hash>`；若仍是 `5.4.274-qgki-gcc3ec22f5061`，说明 boot 没刷进去。


---

## 核心

### 一、头文件法：用 `-include` 造 5.4 兼容层

**问题**：FinaSU 基线是 5.10+，vendor 5.4 树缺三个头文件、缺 `*_from_user_nofault` 系列、`TWA_*` 枚举也不存在。

**做法**：`scripts/preflight.sh` 生成兼容头 + `scripts/ksu54-compat.h` 补齐定义：

| 缺失项 | 来自版本 | 处理方式 |
|---|---|---|
| `<linux/pgtable.h>` | 5.8 拆出 | 生成壳 → `<asm/pgtable.h>`，补 `__p4d_to_phys` |
| `<linux/minmax.h>` | 5.10 拆出 | 生成壳 → `<linux/kernel.h>`，补 `min_t` / `max_t` |
| `<linux/hex.h>` | 6.2 拆出 | 生成壳 → `<linux/kernel.h>` |
| `{strncpy,copy_from,copy_to}_user_nofault` | 5.8 | `pagefault_disable` + 原子拷贝，手写实现 |
| `untagged_addr()` | 5.7 | 恒等宏（arm64 5.4 不做 tag 扩展） |
| `TWA_RESUME` / `TWA_NONE` / `TWA_SIGNAL` | 5.8 | `#define` 成 `true` / `false` |

**关键一步**：不逐个文件 `sed` 改 include，而是往 FinaSU 的 `KernelSU/Kbuild` 末尾追加一行 ——

```make
ccflags-y += -include $(srctree)/include/linux/ksu54_compat.h
```

所有翻译单元一次性命中，**内核源文件一行都不用改**，也不插入任何 `ksu_handle_*` 调用点。

`preflight.sh`（现行 v2）另外处理三件事：

- **devpts / vfs_fstat 等桩函数**从 `feature/sucompat.c` 挪到 `extension/` 独立对象，避免与 SUSFS 关闭时的链接缺符号互斥
- **preinit 关闭不能只靠 `-DKSU_NO_PREINIT`**（调用方自己 extern 声明会继续产生外部引用）→ 改从 Kbuild 摘掉 `preinit/*.o` 并注册真实空实现 `.c`
- **SUSFS 关闭时**补一份签名与 vendor 树 extern 完全匹配的 `ksu_handle_*` stub（`sys_reboot` 必须返回 `-EINVAL` 让真 reboot 流程继续）

> `scripts/ksu54-compat.sh` / `ksu54-v121.sh` 是早期「逐文件打补丁」版本，现在只作排查与备用；主线已切到 `preflight.sh`。

### 二、ksud 法：AK3 里预置 ksud（+ 内核侧 fallback 兜底）（已废弃）

**为什么必须做**：Android 16 的 app seccomp 拦掉了 `syscall(SYS_reboot, ...)` 这条路，ksud 只能先扫 `/proc/self/fd` 拿内核注入的 fd；而内核 sucompat 注入 fd 时重定向的目标固定是 `/data/adb/ksud`。**文件缺失 = 两条路全断**，FinaSU 只会显示「获取 Root 失败」。

**两层保险**：

1. **内核侧 fallback**（`scripts/ksu-su-fallback.sh`）：ksud 缺失时改用 `SH_PATH=/system/bin/sh` 直通，保证首次刷完也能拿到 root。该宏在 FinaSU 源码里早已定义但从未被使用（死代码），这里接上。
2. **AK3 预置**（`scripts/ak3-ksud.sh`，CI 打包时 append 到 `anykernel.sh` 末尾）：
   - 从 FinaSU APK 里抽出 `lib/arm64-v8a/libksud.so` 当 `ksud` 放进 AK3 根目录
   - 判定 `/data` 是否挂载，再做一次**真实写测试**（`/data/adb` 属 DE 区，不需要 FBE 解密）
   - 成功 → `/data/adb/ksud`（755 root:root）+ `/data/adb/ksu/bin/ksud` 软链
   - 失败 → 落到 `/sdcard/Download/ksud`，并生成 `ksud-install.sh`，开机后 `su -c sh ...` 一次即可

**已验证**（2026-11-02，TWRP 实机）：

```
- /data/adb/ksud installed
- reboot, then open FinaSU (root ready)
```

落地校验：`/data/adb/ksud` 7717840 B，md5 `2c5fc89e…`，SELinux 上下文 `u:object_r:ksu_file:s0`（由 ksud 运行时自动重设）。

**几个关键认知**

| 认知 | 说明 |
|---|---|
| `/data/adb` 在 TWRP **可写** | 它是 DE 区，只要 `/data` 挂载成功就写得了；拿 `/data/system`（CE 区）判断会误判成「加密未解」 |
| TWRP 的 busybox 很精简 | 常见缺 `chcon`、不支持 `ls -Z`；脚本已做守卫，上下文由 ksud 运行时自设 |
| App 内刷写**不执行** `update-binary` | FinaSU / KernelFlasher 直接用 magiskboot patch boot 分区，AK3 脚本只在 TWRP 下生效 |
| 刷 boot 不会清 `/data/adb` | 所以 ksud 只需装一次，之后换内核包也不会丢 |

### 三、SUSFS 集成与协议对齐（v2.3.0）

本树**自带** SUSFS v2.1.0（源码在 `fs/susfs.c` 等，不从上游下载），`scripts/susfs-setup.sh` 负责把它接进 FinaSU 与 5.4 内核。

FinaSU v1.4.2 的 ksud 要求内核 SUSFS 版本字符串**精确等于 `v2.3.0`**，否则判定 `unknown_protocol`，管理器 SUSFS 页只读、全功能不可用。v2.1.0 与 v2.3.0 的用户态协议完全兼容（23 个 `CMD_SUSFS_*` 编号逐一相同、`st_susfs_*` wire 结构布局一致，差异只在内核内部实现）。因此 `scripts/susfs-version.sh` 让内核如实汇报 `v2.3.0`，并顺手修掉 v2.1.0 的 `KSTAT_SPOOF_CTIME_TV_SEC (1 < 8)` 笔误（应为 `(1 << 8)`）。

钩子后端采用 **Tracepoint**：FinaSU 的 `SUSFS Inline` 后端在 5.4 上会导致内核 panic（init exec 路径，连 recovery 也无法进入），已实机复现，故不采用。

> 历史现象：早期版本 SUSFS 一直报「未知协议」，dmesg 里 `show_version` / `show_variant` / `get_enabled_features` 均 `ret:0`（内核能响应 ioctl），最终定位为版本字符串不一致 —— 已由 `susfs-version.sh` 彻底解决，不是集成方式问题。

### 四、SELinux 隐藏（5.7+ API 的 5.4 backport，双层拦截）

5.4 没有 `struct selinux_policy`（5.7 才引入），早期的兼容层直接把 `selinux_hide` 整块 stub 成空实现，等于该功能不存在。现在改为**真正的 backport**，并且行为语义按探测器文档对齐：

探测器不是单点检查，而是**分层的**：`type 名存在性` → `access 规则位` → `status/sequence 自洽` → `重复性 / syscall-libc 交叉比对`。所以这里按层拦截。

#### 第一层：原生 type 白名单（context oracle）
启动时对 policydb 做一次快照，记下全部原生 type 名（本机 3903 个）。写入 `/sys/fs/selinux/context` 的 context 若满足下列任一条件，返回 `-EINVAL`（探测器把 `EINVAL` 判为「不存在」）：
- type 段不在原生白名单里
- 名字命中 `ksu` / `susfs` / `lsposed` / `magisk` / `xposed` / `riru` / `zygisk` / `tricky` / `sukisu` / `apatch` / `kernelsu` 关键词

原生 type 全部放行。写 `/proc/self/attr/current` 时同样返回 `-EINVAL` —— **绝不能返回 `EPERM`**，探测器把 `EPERM` 判为「存在」（这是参考实现 `DirtySepolicy` 的判定口径）。

#### 第二层：access 规则位掩码（AVD）
命中敏感组合时，在应答返回前把对应允许位剥掉，并保持 `avd.seqno = 1`：

| 源域 | 目标 | 权限 |
|---|---|---|
| `system_server` | 自身 | `process:execmem` |
| `zygote` | `adb_data_file` | `dir:search` |
| `shell` | `su` | `process:transition` |
| `kernel` | `adb_data_file` | `file:read` |
| `system_server` | `apk_data_file` | `file:execute` |
| `dex2oat` | `dex2oat_exec` | `file:execute_no_trans` |
| `rootfs` | `tmpfs` | `filesystem:associate` |
| `kernel` | `tmpfs` | `file:open` |

实现细节（5.4 树）：
- `type` 取 context **第 3 段**，关键词优先匹配；比较时忽略 MLS 段（探测器会带 `:c512,c768`）
- 白名单快照**只尝试一次**（重试会抓到已被 KSU 注入的 policy）
- 权限位查找：先查 class 自己的 `permissions`，找不到再回退 `comdatum->permissions`（`file` 类的 `read` / `execute` 定义在 common class 里）
- 5.4 的 `struct symtab` 内是**指针**：正确写法 `p_types.table->htable[i]`，写 `p_types.htable` 编译不过

#### 反例（都会被打回）

| 做法 | 命中的判定 |
|---|---|
| 关键词黑名单 / 随机化 type 名 | type 依然在 policydb 里，第一层就命中 |
| 只做 type 白名单 | type 层过了，`system_server execmem` / `zygote -> adb_data_file search` 仍是 allow |
| 对特权域一律拒绝 | direct syscall and libc views disagree（正控被拒） |

#### 诊断

`dmesg | grep ksu54` 可见：`oracle "…" cnt=3903 foreign=0`、`ctx-write uid=… size=…`、`mask avd <scon> -> <tcon> perm=<perm>`。

> ⚠️ **构建链路坑**：`scripts/susfs-setup.sh` 是多段 heredoc 脚本。早期 step7 的 anchor 匹配失败会 `raise SystemExit`，`set -e` 让整个脚本非 0 退出，又被 workflow 的 `|| echo "##[warning]partially applied"` 吞掉 —— 于是 step8 / step4g / verification **全部不执行**，SELinux 侧改动一个都没进内核，而 job 仍显示 success。现改为打印并正常退出，step4g 也提前到 step4e 之后；排查时务必在 CI 日志里 grep `=== [SUSFS] step4g`。

### 五、功耗调优（已启用，实机验证）

**背景**：`star_defconfig` 未设置默认 governor，Kconfig 会兜底成 `performance` —— 8 核恒满频，日常功耗/发热偏高。

**排查记录**（小米 11 Ultra 实机）：直接设默认 `schedutil` 会卡第一屏（小米 logo，recovery 可进，非 panic）。逐项二分：

| 组合 | 结果 |
|---|---|
| `performance` 默认 | 正常（满频） |
| `conservative` 默认 | 正常 |
| `schedutil` 默认（纯 / 禁 fast_switch） | **卡 logo** |
| `schedutil` 默认 + 强制 PELT 信号 | **正常** |

→ 根因：schedutil 的 **WALT util 信号路径**在早期启动时序下挂死；改用内核原生 **PELT** 信号即可。WALT 调度器本身保留（任务放置 / boost 不变）。

**正式方案**（构建时自动应用）：

| 组件 | 文件 | 作用 |
|---|---|---|
| 默认 governor | `scripts/power-tune.sh` | 构建时把默认 governor 从 `performance` 改为 `schedutil` |
| PELT 修复 | `scripts/sched-patches/pelt-force.patch` | schedutil 强制 PELT util 路径（**必需**，否则卡 logo） |
| 输入提升 | `scripts/sched-patches/s1-input-boost-off.patch` | `cpu-boost` 输入提升主开关默认关：触摸不再拉高 min 频；运行时 `echo 1 > /sys/devices/system/cpu/cpu_boost/input_boost` 可恢复 |
| IO 推频 | `scripts/sched-patches/s2-io-is-busy-off.patch` | WALT `io_is_busy` 默认 0：IO 等待不再推高频 |

补丁由 `scripts/sched-tune.sh` 在 CI 克隆内核后应用，带幂等与 `git apply --check` 门禁；内核树漂移时显式失败，不静默跳过。三条构建线（`build-susfs.yml` / `build.yml` / `pure.yml`）均已接入，**workflow 默认即省电形态**，无需额外勾选。

> 早期在 `power-wip` 分支上试验的 `WQ_POWER_EFFICIENT_DEFAULT` / `SCHED_DEBUG` / `PROFILING` 未纳入正式版：`SCHED_DEBUG` 在最终配置里本就由依赖关系决定（无收益），另两项收益小、且与卡屏问题无关，故不启用。

---

## 构建

全部 workflow 都是 **`workflow_dispatch` 手动触发**，单次全量约 **28 分钟**，产物在 Actions artifact 与 Releases 里。

### Workflows

| 文件 | 作用 |
|---|---|
| `build-susfs.yml` | **现行主线**：FinaSU + SUSFS + preflight v2 + 功耗调优（PELT）+ 内置 ksud；带 `disable_preinit` / `disable_susfs` 诊断开关，发布 `star-test-<n>` |
| `build.yml` | 上一代主线：FinaSU + SUSFS（走 `susfs-setup.sh`，无 preflight v2 / 无版本对齐）+ 功耗调优，发布 `test-run-<n>` |
| `pure.yml` | 不带 root 的纯净内核（同样接功耗调优），用于排查与回退 |
| `pack.yml` / `pack-pure.yml` | 不重编，直接对已有 run 的 artifact 重新打 AK3 包 |
| `fix.yml` / `fix-v121.yml` | 历史构建线（preinit 二分、FinaSU v1.2.1 适配），保留作参考 |

### Scripts

| 文件 | 作用 |
|---|---|
| `scripts/preflight.sh` | **现行** 5.4 兼容层施工（头文件壳、`-include` 注入、桩函数对象迁移、前置校验） |
| `scripts/ksu54-compat.h` | 兼容头本体（被 `-include` 全局注入） |
| `scripts/susfs-setup.sh` | SUSFS 5.4 移植（接进 FinaSU 与内核树） |
| `scripts/susfs-version.sh` | SUSFS 版本对齐（v2.1.0 内核如实汇报 v2.3.0 协议，修 ctime 笔误） |
| `scripts/power-tune.sh` | 默认 governor 改 `schedutil`（含 verify 模式） |
| `scripts/sched-tune.sh` | 应用 `scripts/sched-patches/*.patch`（幂等 + `git apply --check`） |
| `scripts/sched-patches/` | `pelt-force` / `s1-input-boost-off` / `s2-io-is-busy-off` 三个补丁 |
| `scripts/star-selftest.sh` | **刷完自检**：内核身份 / KSU feature / SELinux 域 / governor / zram / 电池 / 补丁日期 / 模块 / dmesg 异常扫描 / boot 备份，输出 PASS-WARN-FAIL 表 |
| `scripts/collect-logs.sh` | 一键收集日志打包 zip，给别人排错用（dmesg、logcat、pstore、ksud.log 全带） |
| `scripts/ak3-ksud.sh` | AK3 内置 ksud 安装器（第二层保险） |
| `scripts/ksu-su-fallback.sh` | 内核侧 sucompat fallback（第一层保险） |
| `scripts/ksu54-compat.sh`、`scripts/ksu54-v121.sh` | 早期逐文件补丁版，历史·备用 |

> CI 里 `actions/checkout` 用 `path: ci`，所以脚本的真实路径是 `ci/scripts/*`（= 仓库 `scripts/*`）。

### 构建门禁

`ksu_handle_*`、`CONFIG_KSU`、`CONFIG_KSU_SUSFS_*`、`CONFIG_KPROBES` 这些符号**静默缺失**（`scripts/config` 不校验依赖，`olddefconfig` 阶段被丢弃且不报错）是踩过最深的坑之一。现在 workflow 在编译后会做一次硬门禁：逐项 grep `.config`，缺任一项就 `::error::` + 打印依赖诊断并 `exit 1`，绝不放出「能刷但没有 root」的产物。

---

## 刷完自检

刷完重启后建议先跑一遍自检，确认内核真的活了，而不是只看能不能开机：

```sh
curl -sL -o /sdcard/Download/star-selftest.sh \
  https://raw.githubusercontent.com/cvbyisme/star-kernel-finaisu/main/scripts/star-selftest.sh
su -c 'sh /sdcard/Download/star-selftest.sh'
```

输出一张 `PASS / WARN / FAIL / SKIP` 汇总表，详细报告落在 `/sdcard/Download/star-selftest-<时间>.txt`。检查项：

| 段 | 检查内容 |
|---|---|
| 1 | `/proc/version` 是否含 `Neko-CL`（`uname -r` 会被 uts spoof 改写成 `5.4.274-qgki`，**不可信**） |
| 2 | `ksud -V` 与 `selinux_hide` / `avc_spoof` / `su_compat` / `kernel_umount` 是否 ENABLED |
| 3 | `getenforce`、root 域是否 `u:r:ksu:s0`、`dmesg` 里 `ksu54` 掩码日志 |
| 4 | 三个簇的 governor 是否 `schedutil`、`input_boost` / `io_is_busy` 是否关闭 |
| 5 | meminfo、`zram0` disksize 与压缩算法 |
| 6 | 电池 `capacity` / `status` / `charge_counter` / `voltage_now` |
| 7 | 三个安全补丁属性，以及与 `/system/build.prop` 的差异（差异属伪装正常） |
| 8 | 已装模块数、`star_spoof_security_patch` / `tricky_store` / `zygisksu` 是否在 `modules` 而非 `modules_update` |
| 9 | dmesg 扫 `Kernel panic` / `Oops` / `soft lockup` / `sleeping function` / `Call trace` / `Watchdog bark`；另统计 `avc denied` 条数与 top3 来源域；`audit_lost` 只在仍在增长时告警（开机阶段累计属正常） |
| 10 | `boot_a` / `vendor_boot_a` / `dtbo_a` 备份是否存在且体积正常 |

> 想给别人看日志用 `scripts/collect-logs.sh`；想确认自己刷成功用 `scripts/star-selftest.sh`。

---

## Releases

**推荐**

| Tag | 内容 |
|---|---|
| **[`ak3-susfs-2`](https://github.com/cvbyisme/star-kernel-finaisu/releases/tag/ak3-susfs-2)** | **当前稳定版**：FinaSU + SUSFS v2.3.0 + SELinux 隐藏双层修复，春秋 native 4.6.2 探测通过（2026-11-07 实机验证） |
| `ak3-susfs-1` | 上一稳定版（2026-11-04）。SELinux 隐藏实际未生效（构建脚本在 step7 中断） |
| `star-test-<n>` | 主线测试构建，跟踪最新改动（`star-test-27` 与 `ak3-susfs-2` 为同一产物，sha256 一致） |

**历史**

| Tag | 内容 |
|---|---|
| `ak3-ksud-v3` | FinaSU + AK3 内置 ksud（2026-11-02 实机验证） |
| `pure-ak3-1` | 纯净内核（无 root），用于排查与回退 |
| `susfs-test-1` / `susfs-test-2` | 早期 FinaSU + SUSFS 试验包 |
| `ak3-1` / `ksuns-5` | 更早的构建产物 |

---

## 注意（很重要）

- 从 **FinaSU 管理器 / KernelFlasher** 这类 App 内刷写时，刷写器用 `magiskboot` 直接 patch boot 分区，**不执行 `update-binary`** —— 所以 AK3 脚本只在 **TWRP** 下生效。
- 刷 boot 分区不会清掉 `/data/adb/ksud`，因此只需在 TWRP 里成功装过一次。
- 「AK3 内置 ksud」是过渡方案：`ksu-su-fallback.sh` 已能保证首次刷完即有 root，后续计划改为管理器首次启动时自动安装，届时该脚本会移除。（已废弃）

---

## 踩坑速查

| 现象 | 原因 |
|---|---|
| 卡第一屏 / 黑屏重启 | 内核树 hook 调用点来自 v1.2.1 时代，却拼了 master 的实现（签名、符号名全对不上） |
| 卡小米 logo（recovery 可进、非 panic） | 默认 governor 设了 `schedutil` 却没应用 `pelt-force` 补丁：WALT util 信号路径早期挂死 → 应用 PELT 补丁，或回退 `conservative`/`performance` |
| FinaSU 报「获取 Root 失败」 | `/data/adb/ksud` 缺失 + Android 16 seccomp 拦 reboot syscall → 内核 fallback + AK3 内置 ksud 双保险 |
| SUSFS 页只读 / `unknown_protocol` | 内核汇报的版本字符串 ≠ `v2.3.0` → `susfs-version.sh` 对齐（v2.1.0 内核可如实汇报） |
| 管理器不识别 / 全功能不可用 | 管理器 APK 与内核内嵌签名/版本不对应（v1.2.1 内核不能配新 APK） |
| 春秋探测器报「zygote 有 selinuxfs 权限」 | 对 `/sys/fs/selinux/access` 的写没有按原生语义返回 `EACCES`（用了 `-EINVAL` 或随机化 type） |
| 春秋探测器报 `direct syscall and libc views disagree` | 对特权域也一律拒绝 → 只对非特权域拒绝 |
| 春秋报 `system_server execmem` / `zygote -> adb_data_file search` | type 层已拦住，探测器下探到 access 规则位 → `ksu54_mask_avd()` 掩码 |
| 改了 SELinux 代码但行为没变、`dmesg \| grep ksu54` 全空 | `susfs-setup.sh` 中途退出，后续 step 未执行 → 检查 CI 日志有没有 `=== [SUSFS] step4g` |
| `fatal error: 'linux/pgtable.h' file not found` | 5.8 才拆出的头文件，5.4 没有 → 交给头文件法兜底 |
| `undefined symbol: ksu_handle_devpts` 等 | vendor 树仍带旧 hook，FinaSU 已不实现 → 补签名精确匹配的 stub |
| `-DKSU_NO_PREINIT` 不生效 | 调用方自己 extern 声明，仍产生外部引用 → 摘掉对象 + 真实空实现 |
| AK3 里 `chcon: not found` / `ls: invalid option -- Z` | osm0sis busybox 精简 → 已加守卫，不影响功能 |
| 编译出「无 root」的 Image | `CONFIG_KSU` 依赖被静默丢弃（缺 `CONFIG_KPROBES` / `CONFIG_EXT4_FS`）→ 已有硬门禁拦截 |

---

## 刷机风险提示

- 涉及 boot 分区，**刷前务必备份原厂 boot**
- 首次刷建议备好原厂 `boot.img` 或可进入的 TWRP，方便回滚
- 内核与 ROM 版本强相关，跨大版本 ROM 升级后可能需要重刷
- 卡第一屏时 kernel panic 往往来不及写 pstore，TWRP 里读不到日志属于正常现象，不是「没有线索」

---

## 目录结构

```
.github/workflows/     CI 定义
scripts/               构建、功耗调优与 AK3 脚本
  sched-patches/       schedutil / cpu-boost / WALT 补丁
README.md              本文档
LICENSE                许可证
```

---

## 贡献者

| 贡献者 | 贡献 |
|---|---|
| **@cvbyisme** | 项目发起、内核 fork 维护、构建与实机验证 |
| **@LuNanzhi**（仓库共创者） | 关键贡献：preflight 兼容层思路、bugreport 定位、AK3 内置 ksud 可行路线与成功设备取证、功耗调优方案与实机二分 |
| 大肥鱼 | 代码实现、CI 调试、文档撰写 |

---

## 参考仓库

- [LyraVoid/FinaSU](https://github.com/LyraVoid/FinaSU) —— root 方案本体
- [MiYume0721/android_kernel_xiaomi_sm8350_miyume](https://github.com/MiYume0721/android_kernel_xiaomi_sm8350_miyume) —— 内核基线
- [osm0sis/AnyKernel3](https://github.com/osm0sis/AnyKernel3) —— 刷机包模板
- [LuNanzhi/star-kernel-finaisu](https://github.com/LuNanzhi/star-kernel-finaisu) —— 同设备参考实现

---

## License

见 [LICENSE](LICENSE)。
