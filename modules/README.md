# modules

本仓库自用的 KernelSU / FinaSU 模块源码。每个子目录对应一个模块，可直接打包成 zip 安装（`ksud module install xxx.zip`，**module.prop 必须在 zip 根目录**）。

## 列表

| 目录 | 模块 id | 作用 |
|---|---|---|
| [security-patch-spoof](security-patch-spoof/) | `star_spoof_security_patch` | 把 Play Integrity 全链路的补丁级别统一为 `2026-09-01`：`tricky_store/security_patch.txt`（attestation）+ `pif.prop` 的 `SECURITY_PATCH=` + 4 个 `ro.*.security_patch` 属性 |

## 安装

```sh
# 把子目录内的 module.prop / *.sh 打包成 zip（module.prop 在根目录）
cd security-patch-spoof && zip -r ../star_spoof_security_patch.zip module.prop post-fs-data.sh service.sh README.md
# 安装
su -c '/data/adb/ksu/bin/ksud module install /sdcard/Download/star_spoof_security_patch.zip'
```

新装模块会先落在 `/data/adb/modules_update/<id>/`，**重启后**合并进 `/data/adb/modules/<id>/` 并执行 `post-fs-data.sh` / `service.sh`。

## 注意

- 这些脚本只改运行时属性与 `/data/adb` 下的配置，不动系统分区，卸载即恢复。
- `security-patch-spoof` 适用于 **AlwaysStrong（TEESimulator-RS）/ TrickyStore 1.2.1+**；若使用原版 TrickyStore，`security_patch.txt` 支持 `system=/boot=/vendor=` 分项写法。
- `pif.prop` 会被 autopif4 定期刷新，所以模块在每次开机时再改一次（治标）。
