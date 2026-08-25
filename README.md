# VPS Init

一个面向新购 VPS 或系统重装后的交互式 SSH 安全开荒脚本。

脚本用于配置普通管理员公钥登录、关闭 SSH 密码认证和 root 远程登录、安装 Fail2ban，并以双端口迁移方式生成和固定新的 SSH 端口。

> [!WARNING]
> SSH 和防火墙配置错误可能导致服务器无法远程连接。首次使用前请确认 VPS 厂商提供网页控制台或救援模式，最好先创建快照；执行过程中不要关闭当前 SSH 会话。

## 主要功能

- 检测或创建普通管理员用户。
- 安装、追加和验证 SSH 公钥。
- 为管理员配置免密码 `sudo`。
- 强制 SSH 仅使用公钥认证。
- 关闭密码、键盘交互式认证及 root SSH 登录。
- 安装和配置 Fail2ban 的 `sshd` jail。
- 首次随机生成一个 SSH 端口并永久保存。
- 新旧端口并行迁移，外部测试成功后再关闭旧端口。
- SSH 端口变化时自动同步 Fail2ban。
- 仅操作已经启用的 UFW，不安装或启用 firewalld。
- 修改前自动备份，关键验证失败时自动恢复。
- 支持重复运行，不重复添加公钥或每次重新生成端口。

## 主菜单

运行后显示以下一级菜单，状态内容会根据服务器实际配置变化：

```text
==================================================
          VPS SSH 安全初始化工具 v1.0.0
==================================================
当前用户：root
SSH 端口：22

[1] 密钥登录与账号加固      [未完成]
[2] Fail2ban 防爆破         [未安装]
[3] SSH 固定随机端口        [未开始]
[0] 退出
==================================================
推荐顺序：1 → 测试密钥 → 3 → 测试新端口 → 2
```

### 1. 密钥登录与账号加固

该模块会：

1. 检测当前是否由 root 运行，不是 root 则直接退出。
2. 检测已有普通用户，或者引导创建新管理员。
3. 为管理员创建独立的免密码 sudoers 配置。
4. 从 HTTPS 地址、手动粘贴内容或 root 的 `authorized_keys` 获取公钥。
5. 验证公钥格式、显示指纹并写入管理员家目录。
6. 强制使用公钥认证，关闭密码和交互式认证。
7. 设置 `PermitRootLogin no`，禁止 root 通过 SSH 登录。
8. 检查 SSH 配置语法和实际生效值后重新加载服务。

脚本不会删除 `/root/.ssh/authorized_keys`，也不会锁定 root 的本地密码；限制仅作用于 SSH 登录，方便通过 VPS 控制台进行故障恢复。

### 2. Fail2ban 防爆破

该模块会安装 Fail2ban、启用 `sshd` jail，并使用当前实际 SSH 端口。默认策略为：

- 10 分钟内失败 5 次后封禁。
- 首次封禁 1 小时。
- 重复攻击逐渐延长封禁时间。
- 最长封禁 7 天。

菜单还可以查看服务状态、查看封禁 IP、手动解封 IP，以及重新同步 SSH 端口。

### 3. SSH 固定随机端口

“随机端口”仅在迁移时生成一次，确认后永久使用，并不会在每次登录或每次运行脚本时改变。

端口迁移分为两个阶段：

1. 生成或手动指定新端口，检查端口占用，并让 SSH 暂时同时监听新旧端口。
2. 用户从另一终端通过公网测试新端口，输入新端口号确认后，脚本才停止监听旧端口。

脚本无法自动修改 VPS 厂商的安全组或云防火墙。准备新端口前，必须先在厂商控制台放行对应 TCP 端口。

## 环境要求

- 使用 systemd 的现代 Linux 发行版。
- 已安装并运行 OpenSSH Server。
- `sshd_config` 已启用 `/etc/ssh/sshd_config.d/*.conf`。
- 使用 root 用户运行脚本。
- 推荐 Debian、Ubuntu、Rocky Linux 或 AlmaLinux 的较新版本。

端口模块只自动处理已启用的 UFW：

- UFW 已启用：自动放行本次生成的新端口。
- UFW 未启用：不安装、不启用，也不修改本地防火墙。
- 检测到 firewalld 正在运行：停止自动端口迁移并提示手动处理。

## 下载和运行

先进入 root 环境：

```bash
sudo -i
```

下载脚本：

```bash
curl -fLO https://raw.githubusercontent.com/onelxw/vps-init/main/vps-init.sh
```

添加执行权限并运行：

```bash
chmod +x vps-init.sh
./vps-init.sh
```

也可以克隆整个仓库：

```bash
git clone https://github.com/onelxw/vps-init.git
cd vps-init
chmod +x vps-init.sh
./vps-init.sh
```

## 推荐操作顺序

1. 运行“密钥登录与账号加固”。
2. 保持原 SSH 会话开启，从另一终端测试普通管理员公钥登录。
3. 登录后执行 `sudo -n true` 和 `sudo -i`，确认免密码 sudo 正常。
4. 运行“SSH 固定随机端口”，先准备新端口。
5. 从另一终端测试新端口。
6. 返回菜单并输入新端口号，确认停止监听旧端口。
7. 安装并配置 Fail2ban。
8. 最后在 VPS 厂商安全组中关闭旧端口。

## 配置与备份位置

```text
脚本状态：/var/lib/vps-init/state
执行日志：/var/log/vps-init.log
配置备份：/var/backups/vps-init/
端口记录：/root/ssh-port.txt

SSH 加固：/etc/ssh/sshd_config.d/00-vps-hardening.conf
SSH 端口：/etc/ssh/sshd_config.d/01-vps-port.conf
Fail2ban： /etc/fail2ban/jail.d/sshd.local
```

## 安全说明

- 管理员被配置为 `NOPASSWD: ALL`，因此管理员私钥一旦泄漏，攻击者可以直接通过 `sudo` 获得 root 权限。建议为私钥设置强口令并妥善备份。
- 不要把私钥、GitHub Token、VPS 密码、日志、状态文件或服务器备份提交到仓库。
- Fail2ban 和修改 SSH 端口主要减少自动扫描和日志噪音，不能替代系统更新、公钥保护和最小权限管理。
- 脚本会检查 `sshd -t` 和 `sshd -T`，但无法从服务器内部证明你的电脑一定可以通过公网新建 SSH 连接，因此必须保留原会话进行外部测试。

## 卸载与恢复

脚本的各模块提供针对最近一次配置的恢复选项，备份保存在：

```text
/var/backups/vps-init/
```

不要在没有 VPS 控制台或有效备用 SSH 会话的情况下手动删除 SSH 配置文件或关闭端口。
