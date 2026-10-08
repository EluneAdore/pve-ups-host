# PVE UPS HID Monitor

基于 Linux USB HID、Python 标准库和 systemd 的轻量 UPS 监控工具，适用于具备相应接口的 Proxmox VE 主机。

无需 apcupsd、NUT、pip 依赖、额外容器或 PVE API Token。是否兼容取决于 UPS 是否提供可刷新且可正确读取的 HID 放电状态。

## 安装

在具备 root 权限的 PVE 宿主机执行：

```sh
curl -fsSL https://raw.githubusercontent.com/EluneAdore/pve-ups-host/main/install.sh | sh
```

**注意：全新安装默认启用正式关机模式。** 连续检测到 UPS 放电 1800 秒（30 分钟）后，请求 PVE 正常关机。使用前应确认 UPS 续航足以覆盖等待和关机过程，并验证客户机能够正常退出。

安装器自动扫描 `/sys/class/usbmisc/hiddev*`，通过 HID 报告检查放电状态；不固定 USB 厂商 ID、产品 ID 或设备节点编号。要求恰好存在一个符合读取条件、且当前未放电的设备，否则安装失败。

## 升级现有安装

普通安装命令会保留现有完整安装，不覆盖配置。如需更新监控核心：

```sh
curl -fsSL -o /root/pve-ups-install.sh https://raw.githubusercontent.com/EluneAdore/pve-ups-host/main/install.sh
sh /root/pve-ups-install.sh --upgrade
```

升级前会执行设备探测；成功后备份旧监控程序并替换监控核心，保留现有运行模式、倒计时、管理菜单和 systemd 配置。

## 使用

```sh
# 打开 UPS 中文管理菜单
pve-ups

# 查看运行状态及当前参数
pve-ups status

# 主动读取 UPS 实时放电状态
/usr/local/sbin/pve-ups-hid probe

# 实时查看监控日志，按 Ctrl+C 退出
journalctl -u pve-ups-hid.service -f -o cat
```

中文管理菜单支持状态查询、模拟模式、正式模式、监测间隔调整、日志查看和监控启停。

## 工作原理与限制

- 定时器约每 10 秒启动一次短时监控进程。
- 使用 `HIDIOCGREPORT` 主动刷新，读取 `Discharging` 状态。
- 市电恢复时清除停电倒计时；监控异常、结果不明确或多个候选设备时，不触发关机。
- 状态保存在宿主运行时目录，系统重启后不会恢复上一轮停电倒计时。
- 不向 UPS 发送断电指令。
- 没有独立的低电量关机保护。若 UPS 续航不足，可能来不及安全关机。
- 不保证所有 USB HID UPS 型号兼容，也不保证所有虚拟机/容器能及时正常退出。

## 项目文件

- `install.sh`：完整安装与监控核心升级脚本
- `src/ups.py`：监控源码
- `src/pve-ups`：管理菜单源码
