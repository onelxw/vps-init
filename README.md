# VPS Init

一个面向新购 VPS 或系统重装后的交互式安全开荒与维护脚本，仅支持 Debian 和 Ubuntu。

它把 SSH 密钥登录、固定随机端口、Fail2ban 与常用系统维护集中在一个菜单中。高风险操作会先确认，关键配置修改前会备份；脚本不会自动重启服务器。

> [!WARNING]
> SSH、内核、防火墙和 Swap 配置错误可能造成失联或无法启动。使用前请确认 VPS 厂商提供网页控制台或救援模式，最好先创建快照；修改 SSH 时不要关闭当前会话。

## 主菜单

```text
==================================================
          VPS 安全初始化与维护工具 v2.0.0
==================================================
当前用户：root
SSH 端口：22

[1] 密钥登录与账号加固      [未完成]
[2] SSH 固定随机端口        [未开始]
[3] Fail2ban 防爆破         [未安装]
[4] 系统调优与维护          [按需使用]
[0] 退出
==================================================
安全开荒推荐顺序：1 → 测试密钥 → 2 → 测试新端口 → 3；系统维护按需进入 4
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

### 4. 系统调优与维护

子菜单整合了以下功能：

1. 系统、磁盘、内存、Swap、Docker、BBR 与日志占用体检（只读）。
2. 启用当前内核 BBR + FQ，或按需安装 XanMod + BBRv3。
3. 配置 zRAM、创建低优先级磁盘 Swap、设置 `vm.swappiness`。
4. 从 Docker 官方仓库安装或更新 Docker 与 Compose，安全合并日志轮转配置，查看容器日志配置，或仅卸载程序并保留数据。
5. 限制 journald 最大占用与保留期限。
6. 设置 `Asia/Shanghai` 时区。
7. 逐项预览并确认 APT 缓存、无用包和 Docker 悬空镜像清理。
8. 安装每周一 06:06 执行的只读磁盘监控定时器。

安装 XanMod 内核前请准备快照和控制台。脚本保留原发行版内核且不会自动重启，但更换内核本身仍有启动风险。

## 环境要求

- Debian 或 Ubuntu，使用 systemd 和 APT。
- 已安装并运行 OpenSSH Server。
- `sshd_config` 已启用 `/etc/ssh/sshd_config.d/*.conf`。
- 交互菜单使用 root 运行。
- 不支持 Rocky Linux、AlmaLinux、CentOS、PVE 或其他发行版。

## 下载和运行

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

## 来源说明

系统调优与维护功能整合自同一作者的 `onelxw/vpsgood`。相关来源和上游许可注意事项保留在 [NOTICE.md](NOTICE.md)。
