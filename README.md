# star-kernel-finaisu
> 小米 11 Ultra（star / SM8350）5.4 非 GKI 内核，内置 [FinaSU](https://github.com/LyraVoid/FinaSU)。
>
> 整套构建与移植修法来自同 SoC 的姊妹仓 [venus-kernel-finaisu](https://github.com/cvbyisme/venus-kernel-finaisu)（小米 11），换了设备代号与 defconfig 后**首次构建即实机一次开机**。
>
> 一切改动都来自公开上游，大肥鱼参与了搭建、排错与文档撰写。
>
> ⚠️ 只在少量机器上验证过，刷机风险自负。

---
## 目标设备

| 项 | 值 |
|---|---|
| 机型 | Xiaomi 11 Ultra（star / M2102K1C） |
| SoC | Snapdragon 888 / SM8350 |
| 内核基线 | Linux 5.4.302（`cvbyisme/android_kernel_xiaomi_sm8350_miyume`，与 venus 同一棵树） |
| defconfig | `arch/arm64/configs/star_defconfig` |
| 工具链 | ZyCromerZ Clang 14.0.6 |
| 内核类型 | **非 GKI**，vendor 树 |
| 内核版本串 | `5.4.302-Neko-CL-<日期>-<随机>` |

---
## 快速开始

1. 到 **[Releases](../../releases)** 下载最新的 `star-test-*`
2. 进 **TWRP** 刷入，或者用内核刷写 App 刷入
3. 重启，打开 FinaSU —— 首屏显示 **「工作中」** 即完成

**管理器版本要对上**：内核编入的是 FinaSU 的管理器签名与协议版本，管理器 APK 与内核不匹配时会表现为「不识别 / 只读」。

| 内核侧 | 用哪个管理器 |
|---|---|
| FinaSU `v1.5.0`（现行主线，`ksu_ref` 默认） | FinaSU v1.5.0 及同签 APK（`FinaSU_v1.5.0_33174-release.apk`） |
| FinaSU `v1.4.2` | 必须配 v1.4.2 时期及同签 APK |

**确认刷的是自编内核**：`uname -r` 形如 `5.4.302-Neko-CL-<日期>-<随机>`；若仍是原厂 `5.4.274-...`，说明 boot 没刷进去。
> 注意：FinaSU 管理器首页显示的内核版本是**从 boot 分区镜像里读出来的**，不代表正在运行的内核。判定生效看 `uname -r` 或 `/proc/version`。

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

`preflight.sh`（现行 v2）另外处理四件事：
- **devpts / vfs_fstat 等桩函数**从 `feature/sucompat.c` 挪到 `extension/` 独立对象，避免与 SUSFS 关闭时的链接缺符号互斥
- **preinit 关闭不能只靠 `-DKSU_NO_PREINIT`**（调用方自己 extern 声明会继续产生外部引用）→ 改从 Kbuild 摘掉 `preinit/*.o` 并注册真实空实现 `.c`
- **SUSFS 关闭时**补一份签名与 vendor 树 extern 完全匹配的 `ksu_handle_*` stub（`sys_reboot` 必须返回 `-EINVAL`，让真 reboot 流程继续）
- **SELinux avc 限流**：把 `security/selinux/avc.c` 里 `SELinux: avc: seqno %d < latest_notif %d` 的 `pr_warn` 换成 `pr_warn_ratelimited`（FinaSU v1.5.0 传真实 policy seqno，5.4 的 `avc_cache.latest_notif` 不同步，实测 0.04 秒刷 7000+ 行打满 ring buffer）

> `scripts/ksu54-compat.sh` / `ksu54-v121.sh` 是早期「逐文件打补丁」版本，现在只作排查与备用；主线已切到 `preflight.sh`。

### 二、ksud 策略：默认不内嵌 + 内核侧 fallback 兜底
**为什么可以不内嵌**：Android 16 的 app seccomp 拦掉了 `syscall(SYS_reboot, ...)`，ksud 只能先扫 `/proc/self/fd` 拿内核注入的 fd；而内核 sucompat 注入 fd 时重定向的目标固定是 `/data/adb/ksud`。所以只要 `/data/adb/ksud` 存在，root 就通。

**现在的做法**：
- `embed_ksud` 默认 **false** → 包内不带 ksud，体积从 ~30 MB 降到 ~24 MB
- 内核侧 fallback（`scripts/ksu-su-fallback.sh`）：`/data/adb/ksud` 缺失时 `SH_PATH=/system/bin/sh` 直通，保证首次刷完也能拿到 root
- 之后由 FinaSU v1.5.0 管理器自己动态部署新版 ksud（实测：把 `/data/adb/ksud` 与 `/system/bin/su` 全删掉重启，两者会自动重建，root 依然可用）

需要老式「AK3 内置 ksud」时，dispatch 时把 `embed_ksud` 勾成 true 即可（`scripts/ak3-ksud.sh` 会 append 到 `anykernel.sh`）：

| 认知 | 说明 |
|---|---|
| `/data/adb` 在 TWRP **可写** | 它是 DE 区，只要 `/data` 挂载成功就写得了；拿 `/data/system`（CE 区）判断会误判成「加密未解」 |
| TWRP 的 busybox 很精简 | 常见缺 `chcon`、不支持 `ls -Z`；脚本已做守卫，上下文由 ksud 运行时自设 |
| App 内刷写**不执行** `update-binary` | FinaSU / KernelFlasher 直接用 magiskboot patch boot 分区，AK3 脚本只在 TWRP 下生效 |
| 刷 boot 不会清 `/data/adb` | 所以 ksud 只需装一次，之后换内核包也不会丢 |

### 三、SUSFS 集成与协议对齐（v2.3.0）
本树**自带** SUSFS v2.1.0（源码在 `fs/susfs.c` 等，不从上游下载），`scripts/susfs-setup.sh` 负责把它接进 FinaSU 与 5.4 内核。

FinaSU 的 ksud 要求内核 SUSFS 版本字符串**精确等于 `v2.3.0`**，否则判定 `unknown_protocol`，管理器 SUSFS 页只读、全功能不可用。v2.1.0 与 v2.3.0 的用户态协议完全兼容（23 个 `CMD_SUSFS_*` 编号逐一相同、`st_susfs_*` wire 结构布局一致，差异只在内核内部实现）。因此 `scripts/susfs-version.sh` 让内核如实汇报 `v2.3.0`，并顺手修掉 v2.1.0 的 `KSTAT_SPOOF_CTIME_TV_SEC (1 < 8)` 笔误（应为 `(1 << 8)`）。

钩子后端采用 **Tracepoint**：FinaSU 的 `SUSFS Inline` 后端在 5.4 上会导致内核 panic（init exec 路径，连 recovery 也无法进入），已实机复现，故不采用。

`scripts/susfs-setup.sh` 还会注入 FinaSU v1.5.0 需要的两处适配：`latest_granting` 字段与 `ksu54_policy_generation` 计数。

> 历史现象：早期版本 SUSFS 一直报「未知协议」，dmesg 里 `show_version` / `show_variant` / `get_enabled_features` 均 `ret:0`（内核能响应 ioctl），最终定位为版本字符串不一致 —— 已由 `susfs-version.sh` 彻底解决，不是集成方式问题。

### 四、SELinux 隐藏（5.7+ API 的 5.4 backport，双层拦截）
5.4 没有 `struct selinux_policy`（5.7 才引入），早期的兼容层直接把 `selinux_hide` 整块 stub 成空实现，等于该功能不存在。现在改为**真正的 backport**，并且行为语义按探测器文档对齐：

探测器不是单点检查，而是**分层的**：`type 名存在性` → `access 规则位` → `status/sequence 自洽` → `重复性 / syscall-libc 交叉比对`。所以这里按层拦截。

#### 第一层：原生 type 白名单（context oracle）
启动时对 policydb 做一次快照，记下全部原生 type 名（venus 上实测 3903 个）。写入 `/sys/fs/selinux/context` 的 context 若满足下列任一条件，返回 `-EINVAL`（探测器把 `EINVAL` 判为「不存在」）：
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

### 五、功耗调优（沿用 venus 实机验证方案）
**背景**：`star_defconfig` 与 `venus_defconfig` 一样没有设置默认 governor，Kconfig 兜底成 `performance` —— 8 核恒满频，日常功耗/发热偏高。

**排查记录**（小米 11 / venus 实机，star 沿用同一套结论）：
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

补丁由 `scripts/sched-tune.sh` 在 CI 克隆内核后应用，带幂等与 `git apply --check` 门禁；内核树漂移时显式失败，不静默跳过。**workflow 默认即省电形态**，无需额外勾选。

> MGLRU 保持 venus `run29` 基线的样子：`CONFIG_LRU_GEN=y` 但不设 `CONFIG_LRU_GEN_ENABLED`（编译进来但默认不启用）。venus 上实测启用 MGLRU 会导致明显卡顿，故本仓不启用。

---
## 构建

唯一的 workflow 是 **`workflow_dispatch` 手动触发**，单次全量约 **30–45 分钟**，产物在 Actions artifact 与 Releases 里。

### Workflows
| 文件 | 作用 |
|---|---|
| `build-susfs.yml` | **现行主线**：FinaSU + SUSFS + preflight v2 + 功耗调优（PELT）+ 不内嵌 ksud；带 `disable_preinit` / `disable_susfs` / `embed_ksud` 开关，发布 `star-test-<n>`，并可指定 `kernel_repo` / `kernel_ref` / `ksu_ref` |

### Scripts
| 文件 | 作用 |
|---|---|
| `scripts/preflight.sh` | **现行** 5.4 兼容层施工（头文件壳、`-include` 注入、桩函数对象迁移、avc 限流、前置校验） |
| `scripts/ksu54-compat.h` | 兼容头本体（被 `-include` 全局注入） |
| `scripts/susfs-setup.sh` | SUSFS 5.4 移植（接进 FinaSU 与内核树，含 v1.5.0 的 `latest_granting` / `ksu54_policy_generation` 适配） |
| `scripts/susfs-version.sh` | SUSFS 版本对齐（v2.1.0 内核如实汇报 v2.3.0 协议，修 ctime 笔误） |
| `scripts/power-tune.sh` | 默认 governor 改 `schedutil`（含 verify 模式） |
| `scripts/sched-tune.sh` | 应用 `scripts/sched-patches/*.patch`（幂等 + `git apply --check`） |
| `scripts/sched-patches/` | `pelt-force` / `s1-input-boost-off` / `s2-io-is-busy-off` 三个补丁 |
| `scripts/star-selftest.sh` | **刷完自检**：内核身份 / KSU feature / SELinux 域 / governor / zram / 电池 / 补丁日期 / 模块 / dmesg 异常扫描 / boot 备份，输出 PASS-WARN-FAIL 表 |
| `scripts/collect-logs.sh` | 一键收集日志打包 zip，给别人排错用（dmesg、logcat、pstore、ksud.log 全带） |
| `scripts/ak3-ksud.sh` | AK3 内置 ksud 安装器（`embed_ksud=true` 时启用） |
| `scripts/ksu-su-fallback.sh` | 内核侧 sucompat fallback（默认生效） |
| `scripts/ksu54-compat.sh`、`scripts/ksu54-v121.sh` | 早期逐文件补丁版，历史·备用 |

> CI 里 `actions/checkout` 用 `path: ci`，所以脚本的真实路径是 `ci/scripts/*`（= 仓库 `scripts/*`）。

### 构建门禁
`ksu_handle_*`、`CONFIG_KSU`、`CONFIG_KSU_SUSFS_*`、`CONFIG_KPROBES` 这些符号**静默缺失**（`scripts/config` 不校验依赖，`olddefconfig` 阶段被丢弃且不报错）是踩过最深的坑之一。现在 workflow 有两道门禁：
1. **Fast compile gate**：只编 `drivers/kernelsu/kernelsu.o`，3–5 分钟暴露编译错误
2. **配置硬门禁**：编译前逐项 grep `.config`，缺任一项就 `::error::` + 打印依赖诊断并 `exit 1`

绝不放出「能刷但没有 root」的产物。

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
| 1 | `/proc/version` 是否含 `Neko-CL`（`uname -r` 会被 uts spoof 改写成原厂串，**不可信**） |
| 2 | `ksud -V` 与 `selinux_hide` / `avc_spoof` / `su_compat` / `kernel_umount` 是否 ENABLED |
| 3 | `getenforce`、root 域是否 `u:r:ksu:s0`、`dmesg` 里 `ksu54` 掩码日志 |
| 4 | 三个簇的 governor 是否 `schedutil`、`input_boost` / `io_is_busy` 是否关闭 |
| 5 | meminfo、`zram0` disksize 与压缩算法 |
| 6 | 电池 `capacity` / `status` / `charge_counter` / `voltage_now`（star 的充电 IC 是 BQ2597X，值得留意） |
| 7 | 三个安全补丁属性，以及与 `/system/build.prop` 的差异（差异属伪装正常） |
| 8 | 已装模块数、`security-patch-spoof` / `tricky_store` / `zygisksu` 是否在 `modules` 而非 `modules_update` |
| 9 | dmesg 扫 `Kernel panic` / `Oops` / `soft lockup` / `sleeping function` / `Call trace` / `Watchdog bark`；另统计 `avc denied` 条数与 top3 来源域；`audit_lost` 只在仍在增长时告警（开机阶段累计属正常） |
| 10 | `boot_a` / `vendor_boot_a` / `dtbo_a` 备份是否存在且体积正常 |

> 想给别人看日志用 `scripts/collect-logs.sh`；想确认自己刷成功用 `scripts/star-selftest.sh`。

---
## Releases

| Tag | 内容 |
|---|---|
| **[`star-test-1`](https://github.com/cvbyisme/star-kernel-finaisu/releases/tag/star-test-1)** | 首个构建（2026-11-07）：FinaSU v1.5.0 + SUSFS（v2.3.0 协议对齐）+ preflight v2 + 功耗调优 + 不内嵌 ksud。**实机一次开机成功**（star），其余功能项仍在验证中 |
| `star-test-<n>` | 主线测试构建，跟踪最新改动 |

包名格式 `star-FinaSU-<日期>-run<n>.zip`，首包 24,238,874 B。

---
## 与 venus 仓的关系

两仓共用同一内核源码树与同一套 CI 脚本，只差设备代号：

| 项 | venus（小米 11） | star（本仓，小米 11 Ultra） |
|---|---|---|
| defconfig | `venus_defconfig` | `star_defconfig` |
| AnyKernel `device.name1` | `venus` | `star` |
| 产物 / release 前缀 | `venus-FinaSU-…` / `venus-test-<n>` | `star-FinaSU-…` / `star-test-<n>` |
| 自检脚本 | `venus-selftest.sh` | `star-selftest.sh` |

`star_defconfig` 与 `venus_defconfig` 的差异只有 5 行：

```
CONFIG_MACH_XIAOMI_STAR=y            （venus 为 CONFIG_MACH_XIAOMI_VENUS=y）
CONFIG_INPUT_QCOM_HV_HAPTICS=y       （star 的 HV 震动）
CONFIG_QTI_BATTERY_CHARGER=y         （venus 为 CONFIG_QTI_BATTERY_CHARGER_VENUS=y）
CONFIG_BQ2597X=y                     （star 的充电 IC，venus 为 not set）
```

所以整套 5.4 移植修法可以原样复用 —— 这也是本仓首次构建就能开机的原因。

---
## 注意（很重要）

- 从 **FinaSU 管理器 / KernelFlasher** 这类 App 内刷写时，刷写器用 `magiskboot` 直接 patch boot 分区，**不执行 `update-binary`** —— 所以 AK3 脚本只在 **TWRP** 下生效。
- 刷 boot 分区不会清掉 `/data/adb/ksud`，因此只需在 TWRP 里成功装过一次。
- AK3 里 `BLOCK=/dev/block/bootdevice/by-name/boot` + `IS_SLOT_DEVICE=1`：取不到 `ro.boot.slot_suffix` 会直接 `abort`（不刷任何分区），不会误写；`device.name1=star` 不匹配也会拒绝刷。
- 本仓**尚未**在 star 上逐项验证 SELinux 隐藏 / SUSFS 功能 / 充电 / 震动 / 相机，首次刷入前请备份 boot。

---
## 踩坑速查

| 现象 | 原因 |
|---|---|
| 卡第一屏 / 黑屏重启 | 内核树 hook 调用点来自 v1.2.1 时代，却拼了 master 的实现（签名、符号名全对不上） |
| 卡小米 logo（recovery 可进、非 panic） | 默认 governor 设了 `schedutil` 却没应用 `pelt-force` 补丁：WALT util 信号路径早期挂死 → 应用 PELT 补丁，或回退 `conservative`/`performance` |
| FinaSU 报「获取 Root 失败」 | `/data/adb/ksud` 缺失 + Android 16 seccomp 拦 reboot syscall → 内核 fallback 兜底，或 dispatch 时打开 `embed_ksud` |
| SUSFS 页只读 / `unknown_protocol` | 内核汇报的版本字符串 ≠ `v2.3.0` → `susfs-version.sh` 对齐（v2.1.0 内核可如实汇报） |
| 管理器不识别 / 全功能不可用 | 管理器 APK 与内核内嵌签名/版本不对应（v1.4.2 内核不能配 v1.5.0 APK，反之亦然） |
| dmesg 被 `SELinux: avc: seqno N < latest_notif M` 刷屏、机器变卡 | FinaSU v1.5.0 的 policy generation 与 5.4 `avc_cache` 不同步 → `preflight.sh` 已改为 `pr_warn_ratelimited` |
| 春秋探测器报「zygote 有 selinuxfs 权限」 | 对 `/sys/fs/selinux/access` 的写没有按原生语义返回 `EACCES`（用了 `-EINVAL` 或随机化 type） |
| 春秋探测器报 `direct syscall and libc views disagree` | 对特权域也一律拒绝 → 只对非特权域拒绝 |
| 春秋报 `system_server execmem` / `zygote -> adb_data_file search` | type 层已拦住，探测器下探到 access 规则位 → `ksu54_mask_avd()` 掩码 |
| 改了 SELinux 代码但行为没变、`dmesg | grep ksu54` 全空 | `susfs-setup.sh` 中途退出，后续 step 未执行 → 检查 CI 日志有没有 `=== [SUSFS] step4g` |
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
| **@LuNanzhi**（venus 仓共创者） | 关键贡献：preflight 兼容层思路、bugreport 定位、AK3 内置 ksud 可行路线与成功设备取证、功耗调优方案与实机二分 |
| 大肥鱼 | 代码实现、CI 调试、文档撰写 |

---
## 参考仓库
- [LyraVoid/FinaSU](https://github.com/LyraVoid/FinaSU) —— root 方案本体
- [MiYume0721/android_kernel_xiaomi_sm8350_miyume](https://github.com/MiYume0721/android_kernel_xiaomi_sm8350_miyume) —— 内核基线（同一棵树同时含 `venus_defconfig` 与 `star_defconfig`）
- [osm0sis/AnyKernel3](https://github.com/osm0sis/AnyKernel3) —— 刷机包模板
- [cvbyisme/venus-kernel-finaisu](https://github.com/cvbyisme/venus-kernel-finaisu) —— 同平台姊妹仓，本仓的全部修法来源

---
## License
见 [LICENSE](LICENSE)。
