#!/usr/bin/env bash

# VPS SSH security bootstrap tool
# Supported targets: modern Debian/Ubuntu and Rocky/AlmaLinux installations

set -Eeuo pipefail

SCRIPT_VERSION="1.0.0"
STATE_DIR="/var/lib/vps-init"
STATE_FILE="${STATE_DIR}/state"
BACKUP_ROOT="/var/backups/vps-init"
LOG_FILE="/var/log/vps-init.log"
LOCK_FILE="/run/lock/vps-init.lock"

SSHD_MAIN="/etc/ssh/sshd_config"
SSHD_DROPIN_DIR="/etc/ssh/sshd_config.d"
HARDENING_FILE="${SSHD_DROPIN_DIR}/00-vps-hardening.conf"
PORT_FILE="${SSHD_DROPIN_DIR}/01-vps-port.conf"
FAIL2BAN_FILE="/etc/fail2ban/jail.d/sshd.local"

SSHD_BIN=""

info()  { printf '\n[信息] %s\n' "$*"; }
ok()    { printf '\n[完成] %s\n' "$*"; }
warn()  { printf '\n[警告] %s\n' "$*" >&2; }
error() { printf '\n[错误] %s\n' "$*" >&2; }

pause_screen() {
    printf '\n按 Enter 键继续...'
    read -r _ || true
}

require_root() {
    if [[ ${EUID} -ne 0 ]]; then
        error "请使用 root 用户运行此脚本。"
        printf '可以先执行：sudo -i\n'
        exit 1
    fi
}

initialize_runtime() {
    mkdir -p "$STATE_DIR" "$BACKUP_ROOT" "$(dirname "$LOG_FILE")" "$(dirname "$LOCK_FILE")"
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"

    if command -v flock >/dev/null 2>&1; then
        exec 9>"$LOCK_FILE"
        if ! flock -n 9; then
            error "已有另一个 vps-init 实例正在运行。"
            exit 1
        fi
    fi

    exec > >(tee -a "$LOG_FILE") 2>&1
}

find_sshd() {
    if command -v sshd >/dev/null 2>&1; then
        SSHD_BIN="$(command -v sshd)"
    elif [[ -x /usr/sbin/sshd ]]; then
        SSHD_BIN="/usr/sbin/sshd"
    else
        error "找不到 sshd，请先安装 OpenSSH Server。"
        return 1
    fi
}

state_get() {
    local key="$1"
    [[ -f "$STATE_FILE" ]] || return 1
    awk -F= -v wanted="$key" '
        $1 == wanted {
            sub(/^[^=]*=/, "")
            print
            found=1
            exit
        }
        END { if (!found) exit 1 }
    ' "$STATE_FILE"
}

state_set() {
    local key="$1" value="$2" tmp
    [[ "$key" =~ ^[A-Z0-9_]+$ ]] || return 1
    [[ "$value" != *$'\n'* ]] || return 1
    mkdir -p "$STATE_DIR"
    tmp="$(mktemp "${STATE_DIR}/.state.XXXXXX")"
    if [[ -f "$STATE_FILE" ]]; then
        awk -F= -v wanted="$key" '$1 != wanted' "$STATE_FILE" > "$tmp"
    fi
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$STATE_FILE"
}

state_unset() {
    local key="$1" tmp
    [[ -f "$STATE_FILE" ]] || return 0
    tmp="$(mktemp "${STATE_DIR}/.state.XXXXXX")"
    awk -F= -v wanted="$key" '$1 != wanted' "$STATE_FILE" > "$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$STATE_FILE"
}

create_backup_dir() {
    local label="$1" stamp dir
    stamp="$(date +%Y%m%d-%H%M%S)"
    dir="${BACKUP_ROOT}/${stamp}-${label}"
    local counter=0
    while [[ -e "$dir" ]]; do
        counter=$((counter + 1))
        dir="${BACKUP_ROOT}/${stamp}-${label}-${counter}"
    done
    mkdir -p "$dir/files" "$dir/absent"
    chmod 700 "$dir"
    printf '%s\n' "$dir"
}

backup_one() {
    local path="$1" dir="$2" rel
    rel="${path#/}"
    if [[ -e "$path" ]]; then
        mkdir -p "$dir/files/$(dirname "$rel")"
        cp -a "$path" "$dir/files/$rel"
    else
        mkdir -p "$dir/absent/$(dirname "$rel")"
        : > "$dir/absent/$rel"
    fi
}

restore_one() {
    local path="$1" dir="$2" rel
    rel="${path#/}"
    if [[ -e "$dir/files/$rel" ]]; then
        mkdir -p "$(dirname "$path")"
        cp -a "$dir/files/$rel" "$path"
    elif [[ -e "$dir/absent/$rel" ]]; then
        rm -f -- "$path"
    else
        error "备份中没有目标文件记录：$path"
        return 1
    fi
}

write_root_file() {
    local path="$1" mode="${2:-600}" tmp
    mkdir -p "$(dirname "$path")"
    tmp="$(mktemp "$(dirname "$path")/.vps-init.XXXXXX")"
    cat > "$tmp"
    chmod "$mode" "$tmp"
    chown root:root "$tmp"
    mv -f "$tmp" "$path"
}

has_sshd_dropin_include() {
    [[ -f "$SSHD_MAIN" ]] || return 1
    grep -Eq '^[[:space:]]*Include[[:space:]]+.*sshd_config\.d/\*\.conf' "$SSHD_MAIN"
}

sshd_test() {
    "$SSHD_BIN" -t
}

effective_sshd_config() {
    local user="${1:-root}" host_name
    host_name="$(hostname 2>/dev/null || printf localhost)"
    "$SSHD_BIN" -T -C "user=${user},host=${host_name},addr=127.0.0.1"
}

effective_sshd_value() {
    local user="$1" key="$2"
    effective_sshd_config "$user" | awk -v wanted="$key" '$1 == wanted { print $2; exit }'
}

effective_ssh_ports() {
    effective_sshd_config root | awk '$1 == "port" { print $2 }' | sort -n -u
}

ports_csv() {
    effective_ssh_ports | paste -sd, -
}

detect_ssh_service() {
    if systemctl list-unit-files ssh.service --no-legend 2>/dev/null | grep -q '^ssh\.service'; then
        printf 'ssh\n'
    elif systemctl list-unit-files sshd.service --no-legend 2>/dev/null | grep -q '^sshd\.service'; then
        printf 'sshd\n'
    else
        return 1
    fi
}

reload_ssh() {
    local port_changed="${1:-no}" unit
    unit="$(detect_ssh_service)" || {
        error "未找到 ssh.service 或 sshd.service。"
        return 1
    }

    systemctl daemon-reload

    if [[ "$port_changed" == "yes" ]] && systemctl is-active --quiet ssh.socket 2>/dev/null; then
        systemctl restart ssh.socket
    fi

    if systemctl is-active --quiet "$unit"; then
        if ! systemctl reload "$unit"; then
            error "SSH 服务不支持安全 reload，脚本不会自动 restart。"
            return 1
        fi
    fi
}

install_package() {
    local package="$1"
    if command -v apt-get >/dev/null 2>&1; then
        if ! DEBIAN_FRONTEND=noninteractive apt-get install -y "$package"; then
            apt-get update
            DEBIAN_FRONTEND=noninteractive apt-get install -y "$package"
        fi
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y "$package"
    elif command -v yum >/dev/null 2>&1; then
        yum install -y "$package"
    else
        error "不支持当前系统的包管理器。"
        return 1
    fi
}

ensure_sudo() {
    if ! command -v sudo >/dev/null 2>&1 || ! command -v visudo >/dev/null 2>&1; then
        info "正在安装 sudo..."
        install_package sudo
    fi

    if ! grep -Eq '^[[:space:]]*([@#]includedir)[[:space:]]+/etc/sudoers\.d([[:space:]]|$)' /etc/sudoers; then
        error "/etc/sudoers 未启用 /etc/sudoers.d，脚本不会自动修改主 sudoers 文件。"
        return 1
    fi
}

eligible_users() {
    getent passwd | awk -F: '
        $3 >= 1000 && $3 < 65534 &&
        $1 != "nobody" &&
        $7 !~ /(nologin|false)$/ {
            print $1
        }
    '
}

valid_username() {
    [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]
}

create_admin_user() {
    local username
    while true; do
        read -rp '请输入新管理员用户名 [admin]：' username
        username="${username:-admin}"
        if ! valid_username "$username"; then
            warn "用户名只能包含小写字母、数字、下划线和连字符，并以字母或下划线开头。"
            continue
        fi
        if getent passwd "$username" >/dev/null; then
            warn "用户已经存在，请重新输入。"
            continue
        fi
        break
    done

    useradd -m -s /bin/bash "$username"
    passwd -l "$username" >/dev/null 2>&1 || true
    SELECTED_USER="$username"
    ok "已创建用户：$username"
}

select_admin_user() {
    local -a users=()
    local user choice i
    while IFS= read -r user; do
        [[ -n "$user" ]] && users+=("$user")
    done < <(eligible_users)

    printf '\n可用的普通用户：\n'
    if ((${#users[@]} == 0)); then
        printf '  未检测到合适的普通用户。\n'
    else
        for i in "${!users[@]}"; do
            user="${users[$i]}"
            printf '  [%d] %-16s 家目录：%-24s Shell：%s\n' \
                "$((i + 1))" "$user" "$(getent passwd "$user" | cut -d: -f6)" "$(getent passwd "$user" | cut -d: -f7)"
        done
    fi
    printf '  [%d] 创建新管理员用户\n' "$(( ${#users[@]} + 1 ))"

    while true; do
        read -rp '请选择：' choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#users[@]})); then
            SELECTED_USER="${users[$((choice - 1))]}"
            return 0
        fi
        if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice == ${#users[@]} + 1)); then
            create_admin_user
            return 0
        fi
        warn "无效选择。"
    done
}

configure_nopasswd_sudo() {
    local user="$1" sudo_file backup_dir
    sudo_file="/etc/sudoers.d/90-${user}-nopasswd"

    ensure_sudo
    backup_dir="$(create_backup_dir "sudo-${user}")"
    backup_one "$sudo_file" "$backup_dir"

    printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$user" | write_root_file "$sudo_file" 440

    if ! visudo -cf "$sudo_file" || ! visudo -c; then
        restore_one "$sudo_file" "$backup_dir"
        error "sudoers 检查失败，已经恢复原配置。"
        return 1
    fi

    if getent group sudo >/dev/null 2>&1; then
        usermod -aG sudo "$user"
    elif getent group wheel >/dev/null 2>&1; then
        usermod -aG wheel "$user"
    fi

    if command -v runuser >/dev/null 2>&1; then
        if ! runuser -u "$user" -- sudo -n true; then
            restore_one "$sudo_file" "$backup_dir"
            error "用户无法免密码执行 sudo，已经恢复 sudoers 配置。"
            return 1
        fi
    fi

    ok "已为 $user 配置免密码 sudo。"
}

validate_public_key_file() {
    local file="$1"
    [[ -s "$file" ]] || return 1
    awk '
        /^[[:space:]]*($|#)/ { next }
        $1 !~ /^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)$/ { bad=1 }
        END { exit bad }
    ' "$file" || return 1
    ssh-keygen -lf "$file" >/dev/null 2>&1
}

obtain_public_key() {
    local destination="$1" choice url line root_keys
    while true; do
        printf '\n请选择公钥来源：\n'
        printf '  [1] 从 HTTPS 地址下载\n'
        printf '  [2] 手动粘贴公钥\n'
        printf '  [3] 复制当前 root 的 authorized_keys\n'
        printf '  [0] 取消\n'
        read -rp '请选择：' choice

        case "$choice" in
            1)
                read -rp '请输入公钥 HTTPS 地址：' url
                if [[ "$url" != https://* ]]; then
                    warn "只允许 HTTPS 地址。"
                    continue
                fi
                if command -v curl >/dev/null 2>&1; then
                    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 "$url" -o "$destination" || continue
                elif command -v wget >/dev/null 2>&1; then
                    wget --https-only -qO "$destination" "$url" || continue
                else
                    error "系统没有 curl 或 wget。"
                    return 1
                fi
                ;;
            2)
                printf '请粘贴一整行 SSH 公钥：\n'
                read -r line
                printf '%s\n' "$line" > "$destination"
                ;;
            3)
                root_keys="/root/.ssh/authorized_keys"
                if [[ ! -s "$root_keys" ]]; then
                    warn "root 的 authorized_keys 不存在或为空。"
                    continue
                fi
                cp "$root_keys" "$destination"
                ;;
            0)
                return 1
                ;;
            *)
                warn "无效选择。"
                continue
                ;;
        esac

        sed -i 's/\r$//' "$destination"
        if ! validate_public_key_file "$destination"; then
            warn "公钥格式验证失败，仅支持无 authorized_keys 限制选项的标准 SSH 公钥。"
            continue
        fi

        printf '\n即将安装以下公钥指纹：\n'
        ssh-keygen -lf "$destination"
        read -rp '确认安装这些公钥？[y/N]：' choice
        [[ "$choice" =~ ^[Yy]$ ]] && return 0
    done
}

install_authorized_keys() {
    local user="$1" home group ssh_dir auth_file incoming combined
    home="$(getent passwd "$user" | cut -d: -f6)"
    group="$(id -gn "$user")"
    ssh_dir="${home}/.ssh"
    auth_file="${ssh_dir}/authorized_keys"
    incoming="$(mktemp)"
    combined="$(mktemp)"

    if ! obtain_public_key "$incoming"; then
        rm -f "$incoming" "$combined"
        return 1
    fi

    install -d -m 700 -o "$user" -g "$group" "$ssh_dir"
    if [[ -f "$auth_file" ]]; then
        cat "$auth_file" "$incoming" | awk 'NF && !seen[$0]++' > "$combined"
    else
        awk 'NF && !seen[$0]++' "$incoming" > "$combined"
    fi
    install -m 600 -o "$user" -g "$group" "$combined" "$auth_file"
    rm -f "$incoming" "$combined"

    if command -v restorecon >/dev/null 2>&1; then
        restorecon -RF "$ssh_dir" >/dev/null 2>&1 || true
    fi

    validate_public_key_file "$auth_file" || {
        error "写入后的 authorized_keys 验证失败。"
        return 1
    }
    ok "公钥已安装到：$auth_file"
}

verify_hardening_effective() {
    local admin="$1"
    local auth_methods pubkey password kbd root_login
    auth_methods="$(effective_sshd_value "$admin" authenticationmethods)"
    pubkey="$(effective_sshd_value "$admin" pubkeyauthentication)"
    password="$(effective_sshd_value "$admin" passwordauthentication)"
    kbd="$(effective_sshd_value "$admin" kbdinteractiveauthentication)"
    root_login="$(effective_sshd_value root permitrootlogin)"

    printf '\nSSH 实际生效值：\n'
    printf '  authenticationmethods     %s\n' "$auth_methods"
    printf '  pubkeyauthentication       %s\n' "$pubkey"
    printf '  passwordauthentication     %s\n' "$password"
    printf '  kbdinteractiveauthentication %s\n' "$kbd"
    printf '  permitrootlogin            %s\n' "$root_login"

    [[ "$auth_methods" == publickey && "$pubkey" == yes && "$password" == no && "$kbd" == no && "$root_login" == no ]]
}

configure_key_hardening() {
    local backup_dir
    SELECTED_USER=""

    has_sshd_dropin_include || {
        error "sshd_config 未启用 /etc/ssh/sshd_config.d/*.conf，脚本不会修改主配置文件。"
        return 1
    }

    select_admin_user
    configure_nopasswd_sudo "$SELECTED_USER" || return 1
    install_authorized_keys "$SELECTED_USER" || return 1

    backup_dir="$(create_backup_dir ssh-hardening)"
    backup_one "$HARDENING_FILE" "$backup_dir"

    cat <<'EOF' | write_root_file "$HARDENING_FILE" 600
# Managed by vps-init.sh
AuthenticationMethods publickey
PubkeyAuthentication yes

PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitEmptyPasswords no

PermitRootLogin no
EOF

    if ! sshd_test || ! verify_hardening_effective "$SELECTED_USER"; then
        restore_one "$HARDENING_FILE" "$backup_dir"
        error "SSH 配置未通过验证，已经恢复原配置。"
        return 1
    fi

    if ! reload_ssh no; then
        restore_one "$HARDENING_FILE" "$backup_dir"
        reload_ssh no || true
        error "SSH reload 失败，已经恢复原配置。"
        return 1
    fi

    state_set ADMIN_USER "$SELECTED_USER"
    state_set LAST_HARDENING_BACKUP "$backup_dir"

    ok "普通用户密钥登录和 SSH 加固已配置。"
    warn "请勿关闭当前 root 会话！"
    printf '\n请从另一个终端测试：\n'
    printf '  ssh -p %s %s@服务器IP\n' "$(effective_ssh_ports | head -n1)" "$SELECTED_USER"
    printf '\n登录后测试免密码 sudo：\n'
    printf '  sudo -n true && echo OK\n'
    printf '  sudo -i\n'
}

hardening_status() {
    local admin
    admin="$(state_get ADMIN_USER 2>/dev/null || true)"
    [[ -n "$admin" ]] || admin=root
    if verify_hardening_effective "$admin" 2>/dev/null; then
        ok "SSH 密钥加固配置已生效。"
    else
        warn "SSH 密钥加固配置未完全生效。"
    fi
    if [[ "$admin" != root ]] && getent passwd "$admin" >/dev/null; then
        printf '\n管理员用户：%s\n' "$admin"
        sudo -l -U "$admin" 2>/dev/null || true
    fi
}

update_admin_key() {
    local admin
    admin="$(state_get ADMIN_USER 2>/dev/null || true)"
    if [[ -z "$admin" ]] || ! getent passwd "$admin" >/dev/null; then
        warn "尚未记录管理员用户，请先执行完整配置。"
        return 1
    fi
    install_authorized_keys "$admin"
}

test_admin_permissions() {
    local admin home auth_file
    admin="$(state_get ADMIN_USER 2>/dev/null || true)"
    if [[ -z "$admin" ]] || ! getent passwd "$admin" >/dev/null; then
        error "没有有效的管理员用户记录。"
        return 1
    fi
    home="$(getent passwd "$admin" | cut -d: -f6)"
    auth_file="${home}/.ssh/authorized_keys"
    printf '用户：%s\n家目录：%s\nShell：%s\n' "$admin" "$home" "$(getent passwd "$admin" | cut -d: -f7)"
    if validate_public_key_file "$auth_file"; then
        ok "authorized_keys 格式正确。"
        ssh-keygen -lf "$auth_file"
    else
        error "authorized_keys 缺失或格式错误。"
    fi
    if command -v runuser >/dev/null 2>&1 && runuser -u "$admin" -- sudo -n true; then
        ok "免密码 sudo 验证成功。"
    else
        error "免密码 sudo 验证失败。"
    fi
}

restore_hardening() {
    local backup_dir
    backup_dir="$(state_get LAST_HARDENING_BACKUP 2>/dev/null || true)"
    if [[ -z "$backup_dir" || ! -d "$backup_dir" ]]; then
        error "没有可用的 SSH 加固备份。"
        return 1
    fi
    printf '将从以下备份恢复 SSH 加固文件：\n%s\n' "$backup_dir"
    read -rp '输入 RESTORE 确认：' _confirm
    [[ "$_confirm" == RESTORE ]] || return 0
    restore_one "$HARDENING_FILE" "$backup_dir"
    sshd_test || {
        error "恢复后的 SSH 配置检查失败。"
        return 1
    }
    reload_ssh no
    ok "SSH 加固配置已恢复。用户、公钥和 sudoers 文件没有删除。"
}

fail2ban_installed() {
    command -v fail2ban-client >/dev/null 2>&1
}

write_fail2ban_config() {
    local port_list="$1"
    cat <<EOF | write_root_file "$FAIL2BAN_FILE" 644
# Managed by vps-init.sh
[sshd]
enabled = true
port = ${port_list}
filter = sshd

findtime = 10m
maxretry = 5
bantime = 1h

bantime.increment = true
bantime.factor = 2
bantime.maxtime = 7d
EOF
}

restart_fail2ban() {
    fail2ban-client -t
    systemctl enable fail2ban >/dev/null
    systemctl restart fail2ban
    fail2ban-client status sshd >/dev/null
}

sync_fail2ban_ports() {
    local port_list="$1"
    fail2ban_installed || return 0
    write_fail2ban_config "$port_list"
    restart_fail2ban
}

configure_fail2ban() {
    local ports backup_dir
    if ! fail2ban_installed; then
        info "正在安装 Fail2ban..."
        if command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
            if ! install_package fail2ban; then
                info "尝试安装 EPEL 后重试..."
                install_package epel-release
                install_package fail2ban
            fi
        else
            install_package fail2ban
        fi
    fi

    ports="$(ports_csv)"
    [[ -n "$ports" ]] || {
        error "无法读取 SSH 实际监听端口。"
        return 1
    }

    backup_dir="$(create_backup_dir fail2ban)"
    backup_one "$FAIL2BAN_FILE" "$backup_dir"
    write_fail2ban_config "$ports"
    if ! restart_fail2ban; then
        restore_one "$FAIL2BAN_FILE" "$backup_dir"
        systemctl restart fail2ban 2>/dev/null || true
        error "Fail2ban 配置失败，已经恢复原配置。"
        return 1
    fi
    state_set LAST_FAIL2BAN_BACKUP "$backup_dir"
    ok "Fail2ban 已配置，当前保护 SSH 端口：$ports"
    fail2ban-client status sshd
}

show_fail2ban_status() {
    if ! fail2ban_installed; then
        warn "Fail2ban 尚未安装。"
        return 0
    fi
    systemctl --no-pager --full status fail2ban || true
    printf '\n'
    fail2ban-client status sshd || true
}

unban_ip() {
    local ip
    fail2ban_installed || {
        error "Fail2ban 尚未安装。"
        return 1
    }
    read -rp '请输入需要解封的 IPv4 或 IPv6 地址：' ip
    if [[ ! "$ip" =~ ^[0-9A-Fa-f:.]+$ ]]; then
        error "IP 地址格式不合法。"
        return 1
    fi
    fail2ban-client set sshd unbanip "$ip"
}

restore_fail2ban() {
    local backup_dir
    backup_dir="$(state_get LAST_FAIL2BAN_BACKUP 2>/dev/null || true)"
    if [[ -z "$backup_dir" || ! -d "$backup_dir" ]]; then
        error "没有可用的 Fail2ban 备份。"
        return 1
    fi
    read -rp '输入 RESTORE 确认恢复上次 Fail2ban 配置：' _confirm
    [[ "$_confirm" == RESTORE ]] || return 0
    restore_one "$FAIL2BAN_FILE" "$backup_dir"
    if [[ -f "$FAIL2BAN_FILE" ]]; then
        restart_fail2ban
    else
        systemctl restart fail2ban 2>/dev/null || true
    fi
    ok "Fail2ban 配置已恢复。"
}

port_is_listening() {
    local port="$1"
    ss -H -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"
}

port_in_ephemeral_range() {
    local port="$1" low high
    if [[ -r /proc/sys/net/ipv4/ip_local_port_range ]]; then
        read -r low high < /proc/sys/net/ipv4/ip_local_port_range
        ((port >= low && port <= high))
    else
        return 1
    fi
}

port_is_available() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    ((port >= 1024 && port <= 65535)) || return 1
    ((port != 22)) || return 1
    ! port_is_listening "$port" || return 1
    ! port_in_ephemeral_range "$port" || return 1
    ! awk -v wanted="${port}/tcp" '$2 == wanted { found=1 } END { exit found ? 0 : 1 }' /etc/services 2>/dev/null
}

generate_random_port() {
    local port attempts=0
    while ((attempts < 500)); do
        if command -v shuf >/dev/null 2>&1; then
            port="$(shuf -i 10000-49151 -n 1)"
        else
            port="$((10000 + (RANDOM * 32768 + RANDOM) % 39152))"
        fi
        if port_is_available "$port"; then
            printf '%s\n' "$port"
            return 0
        fi
        attempts=$((attempts + 1))
    done
    return 1
}

find_unmanaged_port_directives() {
    local -a files=("$SSHD_MAIN")
    local file
    shopt -s nullglob
    for file in "$SSHD_DROPIN_DIR"/*.conf; do
        [[ "$file" == "$PORT_FILE" ]] || files+=("$file")
    done
    shopt -u nullglob
    grep -HnE '^[[:space:]]*Port[[:space:]]+[0-9]+' "${files[@]}" 2>/dev/null || true
}

ufw_is_active() {
    command -v ufw >/dev/null 2>&1 && LC_ALL=C ufw status 2>/dev/null | grep -q '^Status: active'
}

ufw_has_port() {
    local port="$1"
    ufw_is_active || return 1
    LC_ALL=C ufw status 2>/dev/null | grep -Eq "^${port}/tcp[[:space:]]+ALLOW"
}

add_ufw_port() {
    local port="$1"
    if ufw_has_port "$port"; then
        printf '0\n'
        return 0
    fi
    ufw allow "${port}/tcp" comment 'vps-init SSH'
    printf '1\n'
}

remove_ufw_port_if_added() {
    local port="$1" added="$2"
    if [[ "$added" == 1 ]] && ufw_is_active; then
        ufw --force delete allow "${port}/tcp" >/dev/null 2>&1 || true
    fi
}

selinux_ssh_port_has() {
    local wanted="$1" type proto ranges item start end
    command -v semanage >/dev/null 2>&1 || return 1
    while read -r type proto ranges; do
        [[ "$type" == ssh_port_t && "$proto" == tcp ]] || continue
        ranges="${ranges//,/ }"
        for item in $ranges; do
            if [[ "$item" == *-* ]]; then
                start="${item%-*}"
                end="${item#*-}"
                ((wanted >= start && wanted <= end)) && return 0
            elif [[ "$item" =~ ^[0-9]+$ ]] && ((wanted == item)); then
                return 0
            fi
        done
    done < <(semanage port -l 2>/dev/null)
    return 1
}

add_selinux_ssh_port() {
    local port="$1"
    if ! command -v getenforce >/dev/null 2>&1 || [[ "$(getenforce)" != Enforcing ]]; then
        printf '0\n'
        return 0
    fi
    if ! command -v semanage >/dev/null 2>&1; then
        error "SELinux 正在强制模式运行，但系统没有 semanage。请先安装 policycoreutils-python-utils。"
        return 1
    fi
    if selinux_ssh_port_has "$port"; then
        printf '0\n'
        return 0
    fi
    semanage port -a -t ssh_port_t -p tcp "$port"
    printf '1\n'
}

remove_selinux_port_if_added() {
    local port="$1" added="$2"
    if [[ "$added" == 1 ]] && command -v semanage >/dev/null 2>&1; then
        semanage port -d -t ssh_port_t -p tcp "$port" >/dev/null 2>&1 || true
    fi
}

write_port_config() {
    local old_port="$1" new_port="${2:-}"
    if [[ -n "$new_port" ]]; then
        cat <<EOF | write_root_file "$PORT_FILE" 600
# Managed by vps-init.sh
# Migration mode: keep both ports until external login is confirmed.
Port ${old_port}
Port ${new_port}
EOF
    else
        cat <<EOF | write_root_file "$PORT_FILE" 600
# Managed by vps-init.sh
Port ${old_port}
EOF
    fi
}

rollback_port_prepare_changes() {
    local backup_dir="$1" new_port="$2" ufw_added="$3" selinux_added="$4"
    restore_one "$PORT_FILE" "$backup_dir" || true
    restore_one "$FAIL2BAN_FILE" "$backup_dir" || true
    sshd_test && reload_ssh yes || true
    if fail2ban_installed; then
        systemctl restart fail2ban 2>/dev/null || true
    fi
    remove_ufw_port_if_added "$new_port" "$ufw_added"
    remove_selinux_port_if_added "$new_port" "$selinux_added"
}

choose_new_port() {
    local mode="$1" candidate choice
    if [[ "$mode" == random ]]; then
        while true; do
            candidate="$(generate_random_port)" || {
                error "无法生成可用随机端口。"
                return 1
            }
            printf '\n生成的新端口：%s\n' "$candidate"
            printf '  [1] 接受\n  [2] 重新生成\n  [0] 取消\n'
            read -rp '请选择：' choice
            case "$choice" in
                1) NEW_PORT="$candidate"; return 0 ;;
                2) continue ;;
                0) return 1 ;;
                *) warn "无效选择。" ;;
            esac
        done
    fi

    while true; do
        read -rp '请输入新的固定 SSH 端口（1024-65535）：' candidate
        if port_is_available "$candidate"; then
            NEW_PORT="$candidate"
            return 0
        fi
        warn "端口不可用、已被占用、属于系统临时端口范围，或是常见保留端口。"
    done
}

prepare_port_migration() {
    local mode="$1" stage unmanaged current_ports old_port backup_dir
    local ufw_added=0 selinux_added=0 confirm

    stage="$(state_get PORT_STAGE 2>/dev/null || true)"
    if [[ "$stage" == prepared ]]; then
        error "已有等待确认的新端口，请先确认或回滚当前迁移。"
        return 1
    fi

    unmanaged="$(find_unmanaged_port_directives)"
    if [[ -n "$unmanaged" ]]; then
        error "检测到脚本管理范围外的有效 Port 配置，无法安全自动修改："
        printf '%s\n' "$unmanaged"
        return 1
    fi

    current_ports="$(effective_ssh_ports)"
    if [[ "$(printf '%s\n' "$current_ports" | sed '/^$/d' | wc -l)" -ne 1 ]]; then
        error "当前 SSH 不是单端口状态，无法开始自动迁移："
        printf '%s\n' "$current_ports"
        return 1
    fi
    old_port="$current_ports"

    choose_new_port "$mode" || return 0

    if systemctl is-active --quiet firewalld 2>/dev/null; then
        error "检测到 firewalld 正在运行。此脚本不会安装或修改 firewalld，请先手动放行端口 ${NEW_PORT}。"
        return 1
    fi

    printf '\n请先在 VPS 厂商的安全组/云防火墙开放 TCP %s。\n' "$NEW_PORT"
    printf '脚本只能配置服务器本地，无法验证厂商安全组。\n'
    read -rp '确认已经开放？[y/N]：' confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || {
        warn "操作已取消，未修改 SSH。"
        return 0
    }

    backup_dir="$(create_backup_dir ssh-port)"
    backup_one "$PORT_FILE" "$backup_dir"
    backup_one "$FAIL2BAN_FILE" "$backup_dir"

    if ufw_is_active; then
        ufw_added="$(add_ufw_port "$NEW_PORT" | tail -n1)"
    else
        warn "UFW 未启用，脚本没有安装或启用任何本地防火墙。"
    fi

    if ! selinux_added="$(add_selinux_ssh_port "$NEW_PORT" | tail -n1)"; then
        remove_ufw_port_if_added "$NEW_PORT" "$ufw_added"
        return 1
    fi

    write_port_config "$old_port" "$NEW_PORT"

    if ! sshd_test; then
        rollback_port_prepare_changes "$backup_dir" "$NEW_PORT" "$ufw_added" "$selinux_added"
        error "SSH 端口配置检查失败，已经回滚。"
        return 1
    fi

    if ! reload_ssh yes || ! port_is_listening "$NEW_PORT"; then
        rollback_port_prepare_changes "$backup_dir" "$NEW_PORT" "$ufw_added" "$selinux_added"
        error "新端口没有正常监听，已经回滚。"
        return 1
    fi

    if fail2ban_installed && ! sync_fail2ban_ports "${old_port},${NEW_PORT}"; then
        rollback_port_prepare_changes "$backup_dir" "$NEW_PORT" "$ufw_added" "$selinux_added"
        error "Fail2ban 端口同步失败，SSH 端口迁移已经回滚。"
        return 1
    fi

    state_set PORT_STAGE prepared
    state_set SSH_OLD_PORT "$old_port"
    state_set SSH_NEW_PORT "$NEW_PORT"
    state_set LAST_PORT_BACKUP "$backup_dir"
    state_set UFW_NEW_RULE_ADDED "$ufw_added"
    state_set SELINUX_NEW_PORT_ADDED "$selinux_added"
    printf '%s\n' "$NEW_PORT" > /root/ssh-port.txt
    chmod 600 /root/ssh-port.txt

    ok "新端口已经准备完成，旧端口仍然保留。"
    warn "请勿关闭当前 SSH 会话！"
    printf '\n请从自己的电脑测试：\n'
    printf '  ssh -p %s %s@服务器IP\n' "$NEW_PORT" "$(state_get ADMIN_USER 2>/dev/null || printf 用户名)"
    printf '\n测试成功后，返回菜单选择“确认新端口并关闭旧端口”。\n'
}

finalize_port_migration() {
    local stage old_port new_port confirm backup_dir
    stage="$(state_get PORT_STAGE 2>/dev/null || true)"
    old_port="$(state_get SSH_OLD_PORT 2>/dev/null || true)"
    new_port="$(state_get SSH_NEW_PORT 2>/dev/null || true)"

    if [[ "$stage" != prepared || -z "$old_port" || -z "$new_port" ]]; then
        error "没有等待确认的端口迁移。"
        return 1
    fi

    printf '\n请确认已经从公网成功执行：\n'
    printf '  ssh -p %s %s@服务器IP\n' "$new_port" "$(state_get ADMIN_USER 2>/dev/null || printf 用户名)"
    read -rp "输入新端口号 ${new_port} 以关闭旧端口 ${old_port}：" confirm
    if [[ "$confirm" != "$new_port" ]]; then
        warn "输入不匹配，未关闭旧端口。"
        return 0
    fi

    backup_dir="$(create_backup_dir ssh-port-finalize)"
    backup_one "$PORT_FILE" "$backup_dir"
    backup_one "$FAIL2BAN_FILE" "$backup_dir"
    write_port_config "$new_port"

    if ! sshd_test || ! reload_ssh yes || ! port_is_listening "$new_port"; then
        restore_one "$PORT_FILE" "$backup_dir"
        sshd_test && reload_ssh yes || true
        error "关闭旧端口时验证失败，已经恢复双端口配置。"
        return 1
    fi

    if fail2ban_installed && ! sync_fail2ban_ports "$new_port"; then
        restore_one "$PORT_FILE" "$backup_dir"
        restore_one "$FAIL2BAN_FILE" "$backup_dir"
        sshd_test && reload_ssh yes || true
        systemctl restart fail2ban 2>/dev/null || true
        error "Fail2ban 同步失败，已经恢复双端口配置。"
        return 1
    fi

    state_set PORT_STAGE finalized
    state_set SSH_PREVIOUS_PORT "$old_port"
    state_set SSH_CURRENT_PORT "$new_port"
    state_set LAST_PORT_FINALIZE_BACKUP "$backup_dir"
    printf '%s\n' "$new_port" > /root/ssh-port.txt
    chmod 600 /root/ssh-port.txt

    ok "SSH 已固定使用端口：$new_port"
    if ufw_is_active && ufw_has_port "$old_port"; then
        warn "UFW 中仍有旧端口 ${old_port} 的放行规则。脚本不会删除非本次创建的旧规则，请检查：ufw status numbered"
    fi
    warn "请自行在 VPS 厂商安全组中关闭旧端口 ${old_port}。"
}

show_port_status() {
    local stage old_port new_port
    stage="$(state_get PORT_STAGE 2>/dev/null || printf 未记录)"
    old_port="$(state_get SSH_OLD_PORT 2>/dev/null || true)"
    new_port="$(state_get SSH_NEW_PORT 2>/dev/null || true)"
    printf '实际 SSH 端口：%s\n' "$(ports_csv)"
    printf '迁移状态：%s\n' "$stage"
    [[ -n "$old_port" ]] && printf '旧端口：%s\n' "$old_port"
    [[ -n "$new_port" ]] && printf '新端口：%s\n' "$new_port"
    if [[ -n "$new_port" ]]; then
        if port_is_listening "$new_port"; then
            printf '新端口监听：正常\n'
        else
            printf '新端口监听：异常\n'
        fi
    fi
    if ufw_is_active; then
        printf '\nUFW 状态：\n'
        ufw status
    else
        printf '\nUFW：未启用\n'
    fi
}

rollback_prepared_port() {
    local stage backup_dir new_port ufw_added selinux_added
    stage="$(state_get PORT_STAGE 2>/dev/null || true)"
    if [[ "$stage" != prepared ]]; then
        warn "当前没有处于准备阶段的端口迁移。已完成的端口迁移不会自动回退，请重新选择手动指定端口进行安全迁移。"
        return 0
    fi
    backup_dir="$(state_get LAST_PORT_BACKUP)"
    new_port="$(state_get SSH_NEW_PORT)"
    ufw_added="$(state_get UFW_NEW_RULE_ADDED 2>/dev/null || printf 0)"
    selinux_added="$(state_get SELINUX_NEW_PORT_ADDED 2>/dev/null || printf 0)"
    read -rp '输入 ROLLBACK 确认取消本次端口迁移：' _confirm
    [[ "$_confirm" == ROLLBACK ]] || return 0
    rollback_port_prepare_changes "$backup_dir" "$new_port" "$ufw_added" "$selinux_added"
    for key in PORT_STAGE SSH_OLD_PORT SSH_NEW_PORT LAST_PORT_BACKUP UFW_NEW_RULE_ADDED SELINUX_NEW_PORT_ADDED; do
        state_unset "$key"
    done
    ok "端口迁移已回滚。"
}

hardening_menu() {
    local choice
    while true; do
        clear 2>/dev/null || true
        printf '--------------------------------------------------\n'
        printf '密钥登录与账号加固\n'
        printf '--------------------------------------------------\n'
        printf '[1] 开始配置/修复\n'
        printf '[2] 检查当前配置\n'
        printf '[3] 添加或更新管理员公钥\n'
        printf '[4] 测试用户和 sudo 权限\n'
        printf '[5] 恢复上次 SSH 加固配置（仅 sshd 配置）\n'
        printf '[0] 返回主菜单\n'
        read -rp '请选择：' choice || return 0
        case "$choice" in
            1) configure_key_hardening || true; pause_screen ;;
            2) hardening_status || true; pause_screen ;;
            3) update_admin_key || true; pause_screen ;;
            4) test_admin_permissions || true; pause_screen ;;
            5) restore_hardening || true; pause_screen ;;
            0) return 0 ;;
            *) warn "无效选择。"; pause_screen ;;
        esac
    done
}

fail2ban_menu() {
    local choice
    while true; do
        clear 2>/dev/null || true
        printf '%s\n' '--------------------------------------------------'
        printf '%s\n' 'Fail2ban 防爆破'
        printf '%s\n' '--------------------------------------------------'
        printf '[1] 安装并配置 Fail2ban\n'
        printf '[2] 检查 Fail2ban 状态\n'
        printf '[3] 查看当前封禁 IP\n'
        printf '[4] 手动解封 IP\n'
        printf '[5] 重新同步 SSH 端口\n'
        printf '[6] 恢复上次配置\n'
        printf '[0] 返回主菜单\n'
        read -rp '请选择：' choice || return 0
        case "$choice" in
            1) configure_fail2ban || true; pause_screen ;;
            2) show_fail2ban_status || true; pause_screen ;;
            3) fail2ban-client status sshd 2>/dev/null || warn "sshd jail 不可用。"; pause_screen ;;
            4) unban_ip || true; pause_screen ;;
            5) sync_fail2ban_ports "$(ports_csv)" || true; pause_screen ;;
            6) restore_fail2ban || true; pause_screen ;;
            0) return 0 ;;
            *) warn "无效选择。"; pause_screen ;;
        esac
    done
}

port_menu() {
    local choice
    while true; do
        clear 2>/dev/null || true
        printf '%s\n' '--------------------------------------------------'
        printf '%s\n' 'SSH 固定随机端口'
        printf '%s\n' '--------------------------------------------------'
        printf '当前实际端口：%s\n' "$(ports_csv)"
        printf '迁移状态：%s\n\n' "$(state_get PORT_STAGE 2>/dev/null || printf 未开始)"
        printf '[1] 生成并准备新端口\n'
        printf '[2] 使用手动指定端口\n'
        printf '[3] 检查新端口状态\n'
        printf '[4] 确认新端口并关闭旧端口\n'
        printf '[5] 回滚尚未确认的端口迁移\n'
        printf '[0] 返回主菜单\n'
        read -rp '请选择：' choice || return 0
        case "$choice" in
            1) prepare_port_migration random || true; pause_screen ;;
            2) prepare_port_migration manual || true; pause_screen ;;
            3) show_port_status || true; pause_screen ;;
            4) finalize_port_migration || true; pause_screen ;;
            5) rollback_prepared_port || true; pause_screen ;;
            0) return 0 ;;
            *) warn "无效选择。"; pause_screen ;;
        esac
    done
}

hardening_summary() {
    local admin
    admin="$(state_get ADMIN_USER 2>/dev/null || true)"
    if [[ -n "$admin" ]] && verify_hardening_effective "$admin" >/dev/null 2>&1; then
        printf '已配置（%s）' "$admin"
    else
        printf '未完成'
    fi
}

fail2ban_summary() {
    if fail2ban_installed && systemctl is-active --quiet fail2ban 2>/dev/null && fail2ban-client status sshd >/dev/null 2>&1; then
        printf '运行中'
    elif fail2ban_installed; then
        printf '已安装/未正常运行'
    else
        printf '未安装'
    fi
}

main_menu() {
    local choice
    while true; do
        clear 2>/dev/null || true
        printf '==================================================\n'
        printf '          VPS SSH 安全初始化工具 v%s\n' "$SCRIPT_VERSION"
        printf '==================================================\n'
        printf '当前用户：root\n'
        printf 'SSH 端口：%s\n\n' "$(ports_csv)"
        printf '[1] 密钥登录与账号加固      [%s]\n' "$(hardening_summary)"
        printf '[2] Fail2ban 防爆破         [%s]\n' "$(fail2ban_summary)"
        printf '[3] SSH 固定随机端口        [%s]\n' "$(state_get PORT_STAGE 2>/dev/null || printf 未开始)"
        printf '[0] 退出\n'
        printf '==================================================\n'
        printf '推荐顺序：1 → 测试密钥 → 3 → 测试新端口 → 2\n'
        read -rp '请选择：' choice || return 0
        case "$choice" in
            1) hardening_menu ;;
            2) fail2ban_menu ;;
            3) port_menu ;;
            0) return 0 ;;
            *) warn "无效选择。"; pause_screen ;;
        esac
    done
}

main() {
    require_root
    initialize_runtime
    find_sshd
    main_menu
}

main "$@"
