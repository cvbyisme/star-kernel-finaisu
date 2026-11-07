# Security Patch Spoof 2026-09-01

把 Play Integrity 整条链路的补丁级别统一成 `2026-09-01`：

| 位置 | 作用 |
|---|---|
| `/data/adb/tricky_store/security_patch.txt` → `all=2026-09-01` | TEE attestation 里声明的补丁级别（AlwaysStrong / TEESimulator-RS 读它） |
| `pif.prop` / `custom.pif.prop` 的 `SECURITY_PATCH=` | AlwaysStrong 的 `sync_patch.sh` 的数据源，防止开机被改回指纹日期 |
| `ro.build.version.security_patch` 等 4 个属性 | 普通 App / `Build.VERSION` 读的值（必须与 attestation 一致，否则报 `OS patch differs`） |

生效时机：`post-fs-data.sh`（开机早期）+ `service.sh`（`sys.boot_completed` 后补一次）。

## 为什么需要它

这台设备上的 `/data/adb/modules/tricky_store` 实际是 **AlwaysStrong v1.0.4**（TEE-Simulator-RS + PlayIntegrityFork），不是原版 TrickyStore：

- 它的 `sync_patch.sh` 每次开机/action 都用 `printf 'all=%s\n' "$DOT" > security_patch.txt` **覆盖重写**该文件，唯一数据源是 `pif.prop` 的 `SECURITY_PATCH=`
- 所以网上流传的 `key26.sh`（写 `system=` / `boot=` / `vendor=` 三行）会失效或立刻被改回
- 它要求 attestation 与 prop 一致，v1.0.4 曾报 `OS patch differs: attestation=202607 prop=2026-05-01`

## 安装

```sh
# 在本目录内打包（module.prop 必须在 zip 根目录）
zip -r ../star_spoof_security_patch.zip module.prop post-fs-data.sh service.sh README.md
su -c '/data/adb/ksu/bin/ksud module install /sdcard/Download/star_spoof_security_patch.zip'
```

新装模块先落在 `/data/adb/modules_update/star_spoof_security_patch/`，重启后合并生效。

## 验证

```sh
su -c 'cat /data/adb/tricky_store/security_patch.txt'   # all=2026-09-01
su -c 'grep SECURITY_PATCH /data/adb/tricky_store/pif.prop'  # 2026-09-01
getprop ro.build.version.security_patch                 # 2026-09-01
```

## 注意

- 只改运行时属性与 `/data/adb` 下的配置，不动系统分区，卸载即恢复
- `pif.prop` 会被 autopif4 定期刷新，模块每次开机再改一次（治标）
- 若 Play Integrity 掉到 `DEVICE`，说明与 husky_beta 指纹自带日期（2026-06-05）冲突：把 `pif.prop` 的 `SECURITY_PATCH` 改回 `2026-06-05`，或 `touch /data/adb/tricky_store/no_spoof_patch_props` 关掉属性侧欺骗
