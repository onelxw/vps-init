# VPS Init

一个面向新购 VPS 或系统重装后的交互式安全开荒与维护脚本，仅支持 Debian 和 Ubuntu。

它把 SSH 密钥登录、固定随机端口、Fail2ban 与常用系统维护集中在一个菜单中。高风险操作会先确认，关键配置修改前会备份；脚本不会自动重启服务器。

> [!WARNING]
> SSH、内核、防火墙和 Swap 配置错误可能造成失联或无法启动。使用前请确认 VPS 厂商提供网页控制台或救援模式，最好先创建快照；修改 SSH 时不要关闭当前会话。

## 一键运行

```bash
tmp_script=$(mktemp) && { curl --proto '=https' --tlsv1.2 -fsSL https://raw.githubusercontent.com/onelxw/vps-init/main/vps-init.sh -o "$tmp_script" && { if [ "$(id -u)" -eq 0 ]; then bash "$tmp_script"; else sudo bash "$tmp_script"; fi; }; result=$?; rm -f "$tmp_script"; (exit "$result"); }
```

该命令先下载到临时文件，运行结束后自动删除；root 用户直接执行，普通 sudo 管理员会自动使用 `sudo`。它每次获取 `main` 分支的最新版本，重要服务器执行前建议先查看仓库中的脚本内容。

如果系统还没有 `curl`，先安装：

```bash
apt update && apt install -y curl
```

## 主菜单

```text
==================================================
          VPS 安全初始化与维护工具 v2.1.1
==================================================
当前用户：root
SSH 端口：22

[1] 密钥登录与账号加固      [未完成]
[2] SSH 固定随机端口        [未开始]
[3] Fail2ban 防爆破         [未安装]
[4] 系统现状体检（只读）
[5] BBR 管理（系统 BBR / XanMod + BBRv3）
[6] 内存与 Swap 管理（zRAM / 磁盘 Swap）
[7] Docker 与 Compose 管理
[8] 配置 journald 容量与保留期限
[9] 设置 Asia/Shanghai 时区
[10] 安全清理（逐项预览确认）
[11] 安装每周只读磁盘监控
[0] 退出
==================================================
安全开荒推荐顺序：1 → 测试密钥 → 2 → 测试新端口 → 3；其余功能按需使用
```

## 功能

### 1. 密钥登录与账号加固

- 检测或创建普通管理员用户。
- 安装、追加并验证 SSH 公钥。
- 为管理员创建独立的免密码 `sudo` 配置。
- 关闭密码和键盘交互式认证。
- 设置 `PermitRootLogin no`，禁止 root 远程登录。
- 修改前备份，检查 `sshd` 配置和实际生效值后再重新加载服务。

脚本不会删除 `/root/.ssh/authorized_keys`，也不会锁定 root 的本地密码，方便通过厂商控制台救援。

### 2. SSH 固定随机端口

随机端口只生成一次，确认后长期使用，不会在每次登录时变化。迁移采用两个阶段：

1. 先让 SSH 同时监听新旧端口，并同步 UFW 与 Fail2ban。
2. 从另一终端通过公网测试新端口，成功后再确认关闭旧端口。

脚本无法修改云厂商安全组。操作前必须先在厂商控制台放行新 TCP 端口。脚本只处理已启用的 UFW；未启用时不会自行安装或打开防火墙。

### 3. Fail2ban 防爆破

- 安装 Fail2ban 并启用 `sshd` jail。
- 通过 systemd journal 读取 SSH 日志。
- 自动使用 SSH 当前实际监听端口。
- 10 分钟内失败 5 次后封禁，首次 1 小时，重复攻击逐步延长，最长 7 天。
- 支持查看状态、查看封禁 IP、手动解封和恢复上次配置。

### 4. 系统现状体检（只读）

- 显示操作系统、当前内核和时区。
- 检查当前 TCP 拥塞控制算法与默认队列算法，即 BBR/FQ 状态。
- 显示物理内存、`vm.swappiness`、zRAM 和磁盘 Swap。
- 检查根文件系统、块设备类型、虚拟化类型和磁盘占用。
- 显示 Docker 版本、实际日志驱动与 Docker 数据占用。
- 显示 journald 和 APT 缓存占用。

该功能只读取状态，不安装软件、不修改配置，也不执行清理，适合在调优前后对比。

### 5. BBR 管理

#### 当前内核 BBR + FQ

- 检查当前内核是否真正提供 BBR；不支持时不会写入无效配置。
- 搜索 `/etc/sysctl.conf` 和 `/etc/sysctl.d/` 中重复的 BBR、队列参数并提示冲突。
- 写入独立的 `/etc/sysctl.d/99-vps-init-network.conf`，配置对整台服务器全局生效。
- 设置 `net.ipv4.tcp_congestion_control=bbr` 和 `net.core.default_qdisc=fq`。
- 应用后检查实际生效值；应用失败时恢复原文件。

#### XanMod + BBRv3

- 仅适用于能够自行更换内核的 Debian/Ubuntu x86_64 VPS。
- OpenVZ、LXC、Docker、Podman、WSL 等不能自行更换宿主内核的环境会被拒绝。
- 使用 XanMod 官方 APT 仓库与官方签名密钥，不执行远程检测脚本。
- 根据本机 glibc 检测 x86-64 psABI 等级并选择匹配的软件包；无法可靠判断时使用最保守等级。
- 默认推荐 XanMod LTS，也可选择 Main 稳定内核。
- x86-64-v4 CPU 使用官方 x64v3 包，BBRv3 功能不受 CPU 包名影响。
- 安装前检查 `/boot` 可用空间，并提示准备快照和厂商控制台/VNC。
- 保留发行版原内核作为启动回退，不自动执行 `autoremove`。
- 不自动重启；重启进入 XanMod 后，才会使用其内置的 Google BBRv3。

普通发行版内核可以启用 BBR，但不能仅凭拥塞控制名称显示为 `bbr` 就认定它是 BBRv3。更换内核前请确认快照、控制台和救援模式可用。

### 6. 内存与 Swap 管理

#### zRAM

- 安装 Debian/Ubuntu 官方 `zram-tools`。
- 允许选择 zRAM 占物理内存的比例，范围为 10%–100%。
- 使用 `lz4` 压缩算法，zRAM Swap 优先级为 100。
- 保留已有磁盘 Swap 作为低优先级兜底，不会自动删除。
- 启动失败时恢复原 zRAM 配置。
- 不自动修改 `vm.swappiness`，需要时可在同一菜单中单独设置。

#### 磁盘 Swap

- 检测根文件系统、块设备旋转标志和虚拟化类型。
- 云 VPS 无法确认宿主机真实介质时会明确提示，不把虚拟盘强行认定为 SSD。
- 使用 `dd` 创建无空洞的 `/swapfile`，避免 `truncate` 或部分文件系统中 `fallocate` 的兼容问题。
- 创建前检查现有文件、`fstab` 条目、输入范围和磁盘剩余空间。
- 仅自动支持 ext2/3/4 与 XFS；Btrfs 等需要特殊处理的文件系统会拒绝自动创建。
- 写入前备份并验证 `/etc/fstab`，失败时自动回滚并删除本次创建的无效文件。
- 磁盘 Swap 优先级为 10，低于 zRAM 的 100，只作为最后兜底。
- 不自动修改 `vm.swappiness`，也不会停用 zRAM。

HDD 上的 Swap 明显慢于 SSD/NVMe，但作为低优先级、低频使用的 OOM 兜底仍有价值。云 VPS 显示的旋转标志来自虚拟块设备，不一定代表宿主机的真实硬盘类型。

#### vm.swappiness

- 允许设置内核支持的 0–200 范围。
- 写入独立的 `/etc/sysctl.d/99-vps-init-memory.conf`。
- 修改前显示其他文件中的重复设置，不会自动篡改这些文件。
- 应用后检查实际值；如果被加载顺序更晚的配置覆盖，会自动回滚。
- zRAM 与磁盘 Swap 共同受这个全局值影响，但两种 Swap 的使用顺序仍由优先级决定。

常用参考值为 10（保守）、60（均衡）和 100（更积极使用 zRAM），具体应根据内存大小和实际负载选择。

### 7. Docker 与 Compose 管理

- 通过 Docker 官方 APT 仓库安装或更新 Docker Engine、Buildx 与 Compose 插件。
- 不使用 `get.docker.com` 更新已有环境。
- 配置日志轮转时合并而不是覆盖 `/etc/docker/daemon.json` 的其他字段。
- 使用 `dockerd --validate` 检查临时配置，验证成功后才替换原文件并重启 Docker。
- 可查看每个现有容器实际使用的日志驱动、日志文件和轮转参数。
- 卸载时只删除 Docker 程序包，明确保留 `/var/lib/docker`、`/var/lib/containerd` 和现有配置。

默认日志轮转建议：

```json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "20m",
    "max-file": "3",
    "compress": "true"
  }
}
```

全局日志配置只影响新建或重建的容器；现有容器仍保留创建时的设置。Compose 服务或 1Panel 应用中明确声明的 `logging` 配置优先级更高，应通过原 Compose/1Panel 配置重建，不要根据 `docker inspect` 猜测并自动重建。

### 8. journald 容量与保留期限

- 可设置 journald 最大占用、至少为系统保留的磁盘空间和最长保留期限。
- 容量必须带单位，例如 `500M` 或 `1G`；时间必须带单位，例如 `12h`、`30day` 或 `2week`。
- 默认建议最大占用 500M、至少保留 1G 磁盘、最长保留 30 天。
- 写入独立的 `/etc/systemd/journald.conf.d/60-vps-init-limits.conf`。
- 修改前创建备份，重启后检查服务状态。
- 不执行 `journalctl --vacuum-time=1s`，不会立即清空现有系统日志。

### 9. Asia/Shanghai 时区

- 显示当前时区并请求确认。
- 通过 systemd 将系统时区设置为 `Asia/Shanghai`。
- 设置后再次读取并显示实际时区。

### 10. 安全清理

- 先显示 APT、journald 和 Docker 的当前占用。
- `apt clean` 单独确认，只清理已下载的软件包缓存。
- `apt autoremove --purge` 必须先模拟并显示计划删除的列表，再次确认后才执行。
- Docker 只允许交互式清理悬空镜像。
- 不清理 Docker volume，不执行 `docker image prune -a`。
- 不截断 Docker 日志，不清空系统日志，也不清空 `/tmp`。

### 11. 每周只读磁盘监控

- 安装每周一 06:06 运行的 systemd timer。
- 记录磁盘、APT、journald、Docker 占用和超大 Docker 日志。
- 报告写入 `/var/log/vps-init-monitor.log`。
- 定时任务只检查和记录，不自动删除任何文件。

系统日志由 journald 自身轮转，普通日志由 logrotate 管理，临时文件由 systemd-tmpfiles 管理，Docker 日志使用 Docker 自带轮转。脚本不会定时执行 `apt autoremove`、镜像或 volume 清理、日志截断以及 `/tmp` 清空。

## 环境要求

- Debian 或 Ubuntu，使用 systemd 和 APT。
- 已安装并运行 OpenSSH Server。
- `sshd_config` 已启用 `/etc/ssh/sshd_config.d/*.conf`。
- 交互菜单使用 root 运行。
- 不支持 Rocky Linux、AlmaLinux、CentOS、PVE 或其他发行版。

## 下载和运行

下载后再运行：

```bash
sudo -i
curl -fLO https://raw.githubusercontent.com/onelxw/vps-init/main/vps-init.sh
chmod +x vps-init.sh
./vps-init.sh
```

或者克隆仓库：

```bash
git clone https://github.com/onelxw/vps-init.git
cd vps-init
chmod +x vps-init.sh
sudo ./vps-init.sh
```

查看帮助或手动输出只读监控报告：

```bash
bash vps-init.sh --help
sudo bash vps-init.sh --monitor
```

## 推荐开荒顺序

1. 配置普通管理员和密钥登录。
2. 保持原 SSH 会话开启，从另一终端测试普通用户密钥登录与 `sudo -n true`。
3. 准备新 SSH 端口，在云安全组放行后从另一终端测试。
4. 确认新端口，关闭旧端口。
5. 安装并配置 Fail2ban。
6. 根据实际需要使用系统调优功能，不建议不看提示连续执行全部选项。

## 配置、日志与备份

```text
脚本状态：/var/lib/vps-init/state
执行日志：/var/log/vps-init.log
配置备份：/var/backups/vps-init/
端口记录：/root/ssh-port.txt
监控报告：/var/log/vps-init-monitor.log

SSH 加固：/etc/ssh/sshd_config.d/00-vps-hardening.conf
SSH 端口：/etc/ssh/sshd_config.d/01-vps-port.conf
Fail2ban： /etc/fail2ban/jail.d/sshd.local
网络参数：/etc/sysctl.d/99-vps-init-network.conf
内存参数：/etc/sysctl.d/99-vps-init-memory.conf
journald： /etc/systemd/journald.conf.d/60-vps-init-limits.conf
Docker：   /etc/docker/daemon.json
```

## 安全说明

- 管理员使用 `NOPASSWD: ALL`，私钥泄漏后攻击者可直接取得 root 权限。建议加密私钥并妥善备份。
- 不要把私钥、Token、密码、服务器日志或备份提交到仓库。
- 修改 SSH 端口和 Fail2ban 主要减少扫描与爆破噪音，不能代替系统更新、公钥保护和最小权限管理。
- BBR、zRAM、Swap 和 Docker 参数没有适合所有 VPS 的统一最优值，请根据内存、磁盘和业务负载选择。
