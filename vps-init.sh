#!/usr/bin/env bash

# VPS security bootstrap and maintenance tool
# Supported targets: modern Debian and Ubuntu installations

set -Eeuo pipefail

SCRIPT_VERSION="2.1.2"
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
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

MONITOR_LOG="/var/log/vps-init-monitor.log"
NETWORK_CONF="/etc/sysctl.d/99-vps-init-network.conf"
JOURNAL_CONF="/etc/systemd/journald.conf.d/60-vps-init-limits.conf"
DOCKER_CONF="/etc/docker/daemon.json"
ZRAM_CONF="/etc/default/zramswap"
XANMOD_REPO_CONF="/etc/apt/sources.list.d/xanmod-release.list"
XANMOD_KEYRING="/etc/apt/keyrings/xanmod-archive-keyring.gpg"
DISK_SWAP_FILE="/swapfile"
FSTAB_FILE="/etc/fstab"
MEMORY_CONF="/etc/sysctl.d/99-vps-init-memory.conf"

OS_ID=""
OS_NAME=""
OS_CODENAME=""

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

load_supported_os() {
    if [[ ! -r /etc/os-release ]]; then
        error "无法读取 /etc/os-release。"
        exit 1
    fi

    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_NAME="${PRETTY_NAME:-$OS_ID}"
    OS_CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"

    case "$OS_ID" in
        debian|ubuntu) ;;
        *)
            error "本脚本仅支持 Debian/Ubuntu；检测到：$OS_NAME"
            exit 1
            ;;
    esac

    if command -v pveversion >/dev/null 2>&1; then
        error "检测到 Proxmox VE。为避免影响宿主内核和网络，本脚本不适配 PVE。"
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

find_unmanaged_hardening_conflicts() {
    local -a files=("$SSHD_MAIN")
    local file

    shopt -s nullglob
    for file in "$SSHD_DROPIN_DIR"/*.conf; do
        [[ "$file" == "$HARDENING_FILE" ]] || files+=("$file")
    done
    shopt -u nullglob

    awk '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
        {
            key=tolower($1)
            value=tolower($2)
            conflict=0

            if (key == "authenticationmethods" && value != "publickey") conflict=1
            else if (key == "pubkeyauthentication" && value != "yes") conflict=1
            else if (key == "passwordauthentication" && value != "no") conflict=1
            else if (key == "kbdinteractiveauthentication" && value != "no") conflict=1
            else if (key == "challengeresponseauthentication" && value != "no") conflict=1
            else if (key == "permitemptypasswords" && value != "no") conflict=1
            else if (key == "permitrootlogin" && value != "no") conflict=1

            if (conflict) printf "%s:%d:%s\n", FILENAME, FNR, $0
        }
    ' "${files[@]}" 2>/dev/null || true
}

show_unmanaged_hardening_conflicts() {
    local conflicts
    conflicts="$(find_unmanaged_hardening_conflicts)"
    if [[ -z "$conflicts" ]]; then
        ok "未发现脚本管理范围外的 SSH 登录加固冲突。"
        return 0
    fi

    warn "发现脚本管理范围外的潜在 SSH 登录冲突："
    printf '%s\n' "$conflicts"
    warn "脚本不会自动修改这些文件；当前是否安全仍以界面显示的 sshd 实际生效值为准。"
    warn "以后若恢复、删除或重命名 00-vps-hardening.conf，这些设置可能重新生效。"
    return 1
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
    if ! command -v apt-get >/dev/null 2>&1; then
        error "找不到 apt-get；本脚本仅支持 Debian/Ubuntu。"
        return 1
    fi
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y "$package"; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y "$package"
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

    show_unmanaged_hardening_conflicts || true

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
    printf '\n'
    show_unmanaged_hardening_conflicts || true
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
backend = systemd

findtime = 10m
maxretry = 5
bantime = 1h

bantime.increment = true
bantime.factor = 2
bantime.maxtime = 7d
EOF
}

restart_fail2ban() {
    local attempt
    fail2ban-client -t
    systemctl enable fail2ban >/dev/null
    systemctl restart fail2ban

    # systemctl may return before fail2ban-server creates its control socket.
    # Wait up to 10 seconds instead of treating that short startup window as a
    # configuration failure.
    for ((attempt = 1; attempt <= 20; attempt++)); do
        if fail2ban-client ping >/dev/null 2>&1 && fail2ban-client status sshd >/dev/null 2>&1; then
            return 0
        fi
        if systemctl is-failed --quiet fail2ban; then
            break
        fi
        sleep 0.5
    done

    error "Fail2ban 未能在 10 秒内进入可用状态。"
    systemctl --no-pager --full status fail2ban 2>&1 || true
    journalctl -u fail2ban --no-pager -n 30 2>&1 || true
    return 1
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
        install_package fail2ban
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

wait_for_port_listening() {
    local port="$1" attempt
    for ((attempt = 0; attempt < 30; attempt++)); do
        port_is_listening "$port" && return 0
        sleep 0.2
    done
    return 1
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
    local backup_dir="$1" new_port="$2" ufw_added="$3"
    restore_one "$PORT_FILE" "$backup_dir" || true
    restore_one "$FAIL2BAN_FILE" "$backup_dir" || true
    sshd_test && reload_ssh yes || true
    if fail2ban_installed; then
        systemctl restart fail2ban 2>/dev/null || true
    fi
    remove_ufw_port_if_added "$new_port" "$ufw_added"
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
    local ufw_added=0 confirm

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

    write_port_config "$old_port" "$NEW_PORT"

    if ! sshd_test; then
        rollback_port_prepare_changes "$backup_dir" "$NEW_PORT" "$ufw_added"
        error "SSH 端口配置检查失败，已经回滚。"
        return 1
    fi

    if ! reload_ssh yes || ! wait_for_port_listening "$NEW_PORT"; then
        rollback_port_prepare_changes "$backup_dir" "$NEW_PORT" "$ufw_added"
        error "新端口没有正常监听，已经回滚。"
        return 1
    fi

    if fail2ban_installed && ! sync_fail2ban_ports "${old_port},${NEW_PORT}"; then
        rollback_port_prepare_changes "$backup_dir" "$NEW_PORT" "$ufw_added"
        error "Fail2ban 端口同步失败，SSH 端口迁移已经回滚。"
        return 1
    fi

    state_set PORT_STAGE prepared
    state_set SSH_OLD_PORT "$old_port"
    state_set SSH_NEW_PORT "$NEW_PORT"
    state_set LAST_PORT_BACKUP "$backup_dir"
    state_set UFW_NEW_RULE_ADDED "$ufw_added"
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

    if ! sshd_test || ! reload_ssh yes || ! wait_for_port_listening "$new_port"; then
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
    local stage backup_dir new_port ufw_added
    stage="$(state_get PORT_STAGE 2>/dev/null || true)"
    if [[ "$stage" != prepared ]]; then
        warn "当前没有处于准备阶段的端口迁移。已完成的端口迁移不会自动回退，请重新选择手动指定端口进行安全迁移。"
        return 0
    fi
    backup_dir="$(state_get LAST_PORT_BACKUP)"
    new_port="$(state_get SSH_NEW_PORT)"
    ufw_added="$(state_get UFW_NEW_RULE_ADDED 2>/dev/null || printf 0)"
    read -rp '输入 ROLLBACK 确认取消本次端口迁移：' _confirm
    [[ "$_confirm" == ROLLBACK ]] || return 0
    rollback_port_prepare_changes "$backup_dir" "$new_port" "$ufw_added"
    for key in PORT_STAGE SSH_OLD_PORT SSH_NEW_PORT LAST_PORT_BACKUP UFW_NEW_RULE_ADDED; do
        state_unset "$key"
    done
    ok "端口迁移已回滚。"
}

maintenance_die() {
    error "$*"
    exit 1
}

maintenance_run() {
    local status
    set +e
    (
        set -Eeuo pipefail
        "$@"
    )
    status=$?
    set -e
    if (( status != 0 )); then
        error "该项操作未完成（退出码：${status}），已返回维护菜单。"
    fi
    return 0
}

confirm() {
    local prompt="$1" answer
    read -rp "$prompt [y/N]：" answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || maintenance_die "缺少命令：$1"
}

backup_file() {
    local target="$1" label backup_dir
    [[ "$target" == /* ]] || maintenance_die "备份目标必须使用绝对路径：$target"
    label="$(basename "$target" | tr -c 'A-Za-z0-9._-' '_')"
    backup_dir="$(create_backup_dir "maintenance-${label}")"
    backup_one "$target" "$backup_dir"
    info "已备份修改前状态：$target -> $backup_dir" >&2
    printf '%s\n' "$backup_dir"
}

rollback_path() {
    local target="$1" backup_dir="$2"
    restore_one "$target" "$backup_dir"
}

apt_is_busy() {
    pgrep -x apt >/dev/null 2>&1 ||
        pgrep -x apt-get >/dev/null 2>&1 ||
        pgrep -x dpkg >/dev/null 2>&1 ||
        pgrep -x unattended-upgrade >/dev/null 2>&1
}

ensure_apt_available() {
    if apt_is_busy; then
        maintenance_die "APT/dpkg 正在运行。脚本不会强杀进程或删除锁文件，请稍后重试。"
    fi
}

human_size() {
    local path="$1" size
    if [[ -e "$path" ]]; then
        size="$(du -sh "$path" 2>/dev/null | awk '{print $1}' || true)"
        printf '%s\n' "${size:-无法读取}"
    else
        printf '0\n'
    fi
}

ensure_jq() {
    command -v jq >/dev/null 2>&1 && return 0
    warn "安全合并 JSON 需要 jq，但当前尚未安装。"
    confirm "现在通过 APT 安装 jq 吗" || return 1
    ensure_apt_available
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y jq
}

maintenance_header() {
    clear 2>/dev/null || true
    printf '%s\n' '============================================================'
    printf ' VPS 系统调优与维护 v%s\n' "$SCRIPT_VERSION"
    printf '%s\n' '============================================================'
}

root_storage_summary() {
    local root_source root_device root_fstype virt disk_line rota tran medium
    root_source=$(findmnt -n -o SOURCE / 2>/dev/null || true)
    root_fstype=$(findmnt -n -o FSTYPE / 2>/dev/null || printf '未知')
    root_device=$(readlink -f "$root_source" 2>/dev/null || printf '%s' "$root_source")
    virt=$(systemd-detect-virt 2>/dev/null || true)
    disk_line=$(lsblk -s -n -r -o NAME,TYPE,ROTA,TRAN "$root_device" 2>/dev/null |
        awk '$2=="disk" {print; exit}' || true)

    if [[ -n "$disk_line" ]]; then
        read -r _ _ rota tran <<<"$disk_line"
        case "${tran:-}:${rota:-}" in
            nvme:*) medium="NVMe（非旋转存储）" ;;
            *:1) medium="HDD/旋转盘标志" ;;
            *:0) medium="SSD或虚拟非旋转盘" ;;
            *) medium="介质类型未知" ;;
        esac
        printf '%s，根设备=%s，文件系统=%s' "$medium" "$root_source" "$root_fstype"
    else
        printf '无法从虚拟块设备识别介质，根设备=%s，文件系统=%s' "${root_source:-未知}" "$root_fstype"
    fi

    if [[ -n "$virt" && "$virt" != "none" ]]; then
        printf '；虚拟化=%s，宿主真实硬盘类型无法确认' "$virt"
    fi
    printf '\n'
}

system_report() {
    local bbr="未知" fq="未知" docker_status="未安装" docker_driver="-"
    bbr=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf '不可用')
    fq=$(sysctl -n net.core.default_qdisc 2>/dev/null || printf '不可用')

    if command -v docker >/dev/null 2>&1; then
        docker_status=$(docker --version 2>/dev/null || printf '已安装但不可用')
        docker_driver=$(docker info --format '{{.LoggingDriver}}' 2>/dev/null || printf '无法查询')
    fi

    printf "操作系统      : %s\n" "$OS_NAME"
    printf "内核          : %s\n" "$(uname -r)"
    printf "BBR/FQ        : %s / %s\n" "$bbr" "$fq"
    printf "时区          : %s\n" "$(timedatectl show -p Timezone --value 2>/dev/null || readlink -f /etc/localtime)"
    printf "Docker        : %s\n" "$docker_status"
    printf "Docker日志驱动: %s\n" "$docker_driver"
    printf "Journal占用   : %s\n" "$(journalctl --disk-usage 2>/dev/null | sed 's/^Archived and active journals take up //' || printf '无法查询')"
    printf "APT缓存       : %s\n" "$(human_size /var/cache/apt/archives)"
    printf "根存储        : %s\n" "$(root_storage_summary)"
    printf "swappiness    : %s\n" "$(sysctl -n vm.swappiness 2>/dev/null || printf '不可用')"
    printf "\n内存与Swap：\n"
    free -h || true
    printf "\nSwap设备：\n"
    swapon --show || true
    printf "\n磁盘：\n"
    df -hT -x tmpfs -x devtmpfs || true
    if command -v docker >/dev/null 2>&1; then
        printf "\nDocker占用：\n"
        docker system df 2>/dev/null || warn "无法读取 Docker 占用。"
    fi
}

find_sysctl_conflicts() {
    local key_pattern='^[[:space:]]*(net\.core\.default_qdisc|net\.ipv4\.tcp_congestion_control)[[:space:]]*='
    grep -RnsE "$key_pattern" /etc/sysctl.conf /etc/sysctl.d 2>/dev/null |
        grep -v "^${NETWORK_CONF}:" || true
}

configure_bbr() {
    require_root
    require_command sysctl
    local conflicts backup_dir tmp log_tmp

    conflicts=$(find_sysctl_conflicts)
    if [[ -n "$conflicts" ]]; then
        warn "发现其他 BBR/队列配置："
        printf '%s\n' "$conflicts"
        confirm "继续创建独立全局配置吗？后加载的重复参数可能覆盖前面的值" || return 0
    fi

    if [[ ! -e /proc/sys/net/ipv4/tcp_congestion_control ]]; then
        maintenance_die "当前内核不提供 TCP 拥塞控制参数。"
    fi

    modprobe tcp_bbr 2>/dev/null || true
    if ! sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
        maintenance_die "当前内核未提供 BBR，未修改配置。"
    fi

    backup_dir=$(backup_file "$NETWORK_CONF")
    install -d -m 0755 /etc/sysctl.d
    tmp=$(mktemp) || maintenance_die "无法创建BBR临时配置。"
    if ! log_tmp=$(mktemp); then
        rm -f -- "$tmp"
        maintenance_die "无法创建BBR验证日志。"
    fi
    printf '%s\n' \
        '# Managed by vps-init.sh' \
        'net.core.default_qdisc=fq' \
        'net.ipv4.tcp_congestion_control=bbr' > "$tmp"
    install -m 0644 "$tmp" "$NETWORK_CONF"
    rm -f "$tmp"

    if ! sysctl --system >"$log_tmp" 2>&1; then
        warn "sysctl 应用失败，输出如下："
        sed -n '1,160p' "$log_tmp"
        rollback_path "$NETWORK_CONF" "$backup_dir"
        sysctl --system >/dev/null 2>&1 || true
        rm -f -- "$log_tmp"
        maintenance_die "已回滚 BBR 配置。"
    fi
    rm -f -- "$log_tmp"

    if [[ $(sysctl -n net.ipv4.tcp_congestion_control) == bbr ]] &&
       [[ $(sysctl -n net.core.default_qdisc) == fq ]]; then
        ok "BBR+FQ 已全局生效。"
    else
        warn "配置已写入，但实际值未达到预期，请检查重复 sysctl 配置。"
    fi
}

detect_x86_64_level() {
    local loader output level
    for loader in /lib64/ld-linux-x86-64.so.2 /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2; do
        [[ -x "$loader" ]] || continue
        output=$($loader --help 2>/dev/null || true)
        for level in 4 3 2; do
            if grep -Eq "x86-64-v${level} .*supported" <<<"$output"; then
                printf '%s\n' "$level"
                return 0
            fi
        done
    done

    # 无法获得 glibc 的完整 psABI 判断时选择最保守的 v1，避免非法指令。
    printf '1\n'
}

xanmod_select_package() {
    local cpu_level=$1 track=$2
    local effective_level=$cpu_level
    local candidates=()

    (( effective_level > 3 )) && effective_level=3
    if [[ "$track" == "lts" ]]; then
        candidates=("linux-xanmod-lts-x64v${effective_level}")
    else
        candidates=("linux-xanmod-x64v${effective_level}" "linux-xanmod-lts-x64v${effective_level}")
    fi

    # XanMod mainline 可能不提供 x64v1；v1 始终尝试 LTS。
    if (( effective_level == 1 )); then
        candidates=("linux-xanmod-lts-x64v1")
    fi

    local package
    for package in "${candidates[@]}"; do
        if apt-cache show "$package" >/dev/null 2>&1; then
            printf '%s\n' "$package"
            return 0
        fi
    done
    return 1
}

xanmod_environment_check() {
    local arch virt boot_avail_kb
    arch=$(uname -m)
    [[ "$arch" == "x86_64" ]] || maintenance_die "XanMod官方仓库目前只提供x86_64构建；当前架构：$arch"

    virt=$(systemd-detect-virt 2>/dev/null || true)
    case "$virt" in
        openvz|lxc|lxc-libvirt|docker|podman|systemd-nspawn|wsl)
            maintenance_die "当前虚拟化类型为 $virt，通常不能自行更换宿主内核。"
            ;;
    esac

    boot_avail_kb=$(df -Pk /boot 2>/dev/null | awk 'NR==2 {print $4}')
    if [[ "$boot_avail_kb" =~ ^[0-9]+$ ]] && (( boot_avail_kb < 600000 )); then
        warn "/boot 可用空间不足约600MB：$((boot_avail_kb / 1024))MB。安装前请确认旧内核数量。"
        confirm "仍要继续吗" || return 1
    fi

    printf "虚拟化类型：%s\n" "${virt:-物理机或未识别}"
    printf "当前内核：%s\n" "$(uname -r)"
    warn "更换内核存在无法启动风险，请确认VPS控制台/VNC可用，并提前建立快照。"
}

install_xanmod_bbr3() {
    require_root
    load_supported_os
    xanmod_environment_check || return 0
    ensure_apt_available

    local cpu_level track package key_tmp repo_backup key_backup
    cpu_level=$(detect_x86_64_level)
    printf "检测到CPU最高psABI等级：x86-64-v%s\n" "$cpu_level"
    if (( cpu_level == 4 )); then
        info "XanMod当前使用x64v3包覆盖v4级CPU，BBRv3功能不受影响。"
    fi

    printf "1. LTS内核（推荐用于长期运行的VPS）\n"
    printf "2. Main稳定内核（版本更新）\n"
    read -r -p "请选择 [1]: " track
    case "${track:-1}" in
        1) track="lts" ;;
        2) track="main" ;;
        *) maintenance_die "无效选择。" ;;
    esac

    confirm "从XanMod官方仓库安装内核并保留现有内核" || return 0
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gnupg

    install -d -m 0755 /etc/apt/keyrings /etc/apt/sources.list.d
    key_backup=$(backup_file "$XANMOD_KEYRING")
    repo_backup=$(backup_file "$XANMOD_REPO_CONF")
    key_tmp=$(mktemp)
    if ! curl --proto '=https' --tlsv1.2 -fsSL https://dl.xanmod.org/archive.key -o "$key_tmp"; then
        rm -f "$key_tmp"
        maintenance_die "无法从XanMod官方下载仓库密钥，未修改软件源。"
    fi
    if ! gpg --batch --yes --dearmor --output "$XANMOD_KEYRING" "$key_tmp"; then
        rm -f "$key_tmp"
        rollback_path "$XANMOD_KEYRING" "$key_backup"
        maintenance_die "XanMod密钥转换失败。"
    fi
    rm -f "$key_tmp"
    chmod 0644 "$XANMOD_KEYRING"

    local repo_tmp
    repo_tmp=$(mktemp)
    printf 'deb [signed-by=%s] https://deb.xanmod.org %s main\n' \
        "$XANMOD_KEYRING" "$OS_CODENAME" > "$repo_tmp"
    install -m 0644 "$repo_tmp" "$XANMOD_REPO_CONF"
    rm -f "$repo_tmp"

    if ! apt-get update; then
        rollback_path "$XANMOD_REPO_CONF" "$repo_backup"
        rollback_path "$XANMOD_KEYRING" "$key_backup"
        maintenance_die "XanMod软件源更新失败，已恢复原配置。"
    fi

    if ! package=$(xanmod_select_package "$cpu_level" "$track"); then
        warn "当前系统代号为：$OS_CODENAME；仓库中没有匹配的XanMod包。"
        apt-cache search '^linux-xanmod' | sed -n '1,40p' || true
        rollback_path "$XANMOD_REPO_CONF" "$repo_backup"
        rollback_path "$XANMOD_KEYRING" "$key_backup"
        maintenance_die "未安装任何内核，已恢复软件源配置。"
    fi

    printf "将安装：%s\n" "$package"
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y "$package"; then
        warn "内核安装未完成；为便于检查和重试，已配置的XanMod官方软件源予以保留。"
        maintenance_die "请检查上方APT错误。在修复dpkg/APT状态前不要重启。"
    fi
    dpkg-query -W -f='${db:Status-Status}\n' "$package" 2>/dev/null | grep -q '^installed$' ||
        maintenance_die "XanMod元包安装验证失败，请检查APT输出。"
    command -v update-grub >/dev/null 2>&1 && update-grub

    ok "XanMod内核包已安装，现有发行版内核保持不动。"
    printf "当前运行内核：%s\n" "$(uname -r)"
    printf "已安装元包：%s\n" "$package"
    warn "必须重启后才会运行XanMod/BBRv3；脚本不会自动重启。"
    modprobe tcp_bbr 2>/dev/null || true
    if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
        if confirm "同时写入BBR+FQ全局配置吗？重启XanMod后将使用BBRv3"; then
            configure_bbr
        fi
    else
        warn "当前旧内核不提供BBR，因此暂不写入sysctl配置。重启进入XanMod后，再运行BBR菜单的选项1。"
    fi
}

show_bbr_status() {
    local kernel cc qdisc
    kernel=$(uname -r)
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf '不可用')
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || printf '不可用')
    printf "当前内核：%s\n" "$kernel"
    printf "拥塞控制：%s\n" "$cc"
    printf "队列算法：%s\n" "$qdisc"
    printf "已安装XanMod包：\n"
    dpkg-query -W -f='${db:Status-Status} ${binary:Package} ${Version}\n' 'linux-*xanmod*' 2>/dev/null |
        awk '$1=="installed" {print "  " $2 " " $3}' || true
    if [[ "$kernel" == *xanmod* && "$cc" == "bbr" ]]; then
        ok "正在运行XanMod内核的内置BBR（XanMod当前集成Google BBRv3）。"
    elif [[ "$cc" == "bbr" ]]; then
        warn "BBR已启用，但当前内核不是XanMod，通常不能据此认定为BBRv3。"
    else
        warn "当前没有启用BBR。"
    fi
}

bbr_menu() {
    while true; do
        maintenance_header
        printf "1. 启用当前内核自带的 BBR+FQ\n"
        printf "2. 安装/更新 XanMod 内核 + BBRv3\n"
        printf "3. 查看 BBR/XanMod 状态\n"
        printf "0. 返回\n"
        read -r -p "请选择: " choice
        case "$choice" in
            1) maintenance_run configure_bbr; pause_screen ;;
            2) maintenance_run install_xanmod_bbr3; pause_screen ;;
            3) maintenance_run show_bbr_status; pause_screen ;;
            0) return 0 ;;
            *) warn "无效选择。"; sleep 1 ;;
        esac
    done
}

configure_zram() {
    require_root
    ensure_apt_available
    local total_mb default_percent percent current_swap backup_dir
    total_mb=$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo)
    default_percent=50
    current_swap=$(swapon --show --noheadings 2>/dev/null || true)

    printf "物理内存：%s MB\n" "$total_mb"
    printf "当前 swappiness：%s\n" "$(sysctl -n vm.swappiness)"
    printf "当前 Swap：\n%s\n" "${current_swap:-无}"
    info "建议保留磁盘 Swap 作为低优先级兜底，zRAM 使用高优先级。"
    read -r -p "zRAM 占物理内存比例 [${default_percent}%]: " percent
    percent=${percent:-$default_percent}
    if [[ ! "$percent" =~ ^[0-9]+$ ]] || (( percent < 10 || percent > 100 )); then
        maintenance_die "比例必须是 10-100 的整数。"
    fi

    confirm "安装/更新 zram-tools 并配置 zRAM=${percent}%、优先级=100" || return 0
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y zram-tools

    backup_dir=$(backup_file "$ZRAM_CONF")
    local tmp
    tmp=$(mktemp)
    printf '%s\n' \
        '# Managed by vps-init.sh' \
        'ALGO=lz4' \
        "PERCENT=${percent}" \
        'PRIORITY=100' > "$tmp"
    install -m 0644 "$tmp" "$ZRAM_CONF"
    rm -f "$tmp"

    if ! systemctl restart zramswap; then
        rollback_path "$ZRAM_CONF" "$backup_dir"
        systemctl restart zramswap 2>/dev/null || true
        maintenance_die "zRAM 启动失败，已恢复原配置。"
    fi

    zramctl || true
    swapon --show || true
    ok "zRAM 已配置；磁盘 Swap 未被删除。"
    warn "脚本没有自动修改 vm.swappiness。可观察后再决定是否从当前值调整到 40 或 60。"
}

find_swappiness_conflicts() {
    grep -RnsE '^[[:space:]]*vm\.swappiness[[:space:]]*=' \
        /etc/sysctl.conf /etc/sysctl.d /run/sysctl.d /usr/local/lib/sysctl.d /usr/lib/sysctl.d /lib/sysctl.d \
        2>/dev/null | grep -v "^${MEMORY_CONF}:" || true
}

configure_swappiness() {
    require_root
    require_command sysctl
    local current value conflicts backup_dir tmp log_tmp actual
    current=$(sysctl -n vm.swappiness)
    conflicts=$(find_swappiness_conflicts)

    printf "当前 vm.swappiness：%s\n" "$current"
    printf "  10  = 保守使用Swap，适合同时有磁盘Swap的通用VPS\n"
    printf "  60  = Linux常见默认值，较均衡\n"
    printf "  100 = 更积极使用zRAM；zRAM耗尽后仍可能使用低优先级磁盘Swap\n"
    printf "  0-200均为内核允许范围，具体效果取决于负载\n"
    if [[ -n "$conflicts" ]]; then
        warn "发现其他持久化 swappiness 配置："
        printf '%s\n' "$conflicts"
        warn "脚本不会修改这些文件；如果它们加载更晚，新值可能被覆盖并触发自动回滚。"
    fi

    read -r -p "新的 vm.swappiness [${current}]: " value
    value=${value:-$current}
    if [[ ! "$value" =~ ^[0-9]+$ ]] || (( value < 0 || value > 200 )); then
        maintenance_die "vm.swappiness必须是0-200之间的整数。"
    fi
    confirm "将 vm.swappiness 设置为 ${value} 并立即应用" || return 0

    backup_dir=$(backup_file "$MEMORY_CONF")
    tmp=$(mktemp) || maintenance_die "无法创建swappiness临时配置。"
    if ! log_tmp=$(mktemp); then
        rm -f -- "$tmp"
        maintenance_die "无法创建swappiness验证日志。"
    fi
    printf '%s\n' \
        '# Managed by vps-init.sh' \
        '# Global setting shared by zRAM and disk Swap' \
        "vm.swappiness=${value}" > "$tmp"
    install -d -m 0755 /etc/sysctl.d
    if ! install -m 0644 "$tmp" "$MEMORY_CONF"; then
        rm -f -- "$tmp" "$log_tmp"
        rollback_path "$MEMORY_CONF" "$backup_dir"
        maintenance_die "swappiness配置写入失败，已回滚。"
    fi
    rm -f -- "$tmp"

    if ! sysctl --system >"$log_tmp" 2>&1; then
        warn "sysctl应用失败，输出如下："
        sed -n '1,120p' "$log_tmp"
        rollback_path "$MEMORY_CONF" "$backup_dir"
        sysctl --system >/dev/null 2>&1 || sysctl -w "vm.swappiness=$current" >/dev/null
        rm -f -- "$log_tmp"
        maintenance_die "已恢复原swappiness配置。"
    fi
    actual=$(sysctl -n vm.swappiness)
    if [[ "$actual" != "$value" ]]; then
        warn "实际值为 ${actual}，目标值为 ${value}；存在加载顺序更晚的重复配置。"
        [[ -n "$conflicts" ]] && printf '%s\n' "$conflicts"
        rollback_path "$MEMORY_CONF" "$backup_dir"
        sysctl --system >/dev/null 2>&1 || sysctl -w "vm.swappiness=$current" >/dev/null
        rm -f -- "$log_tmp"
        maintenance_die "未保留无效配置，已回滚。"
    fi
    rm -f -- "$log_tmp"
    ok "vm.swappiness=${actual} 已立即生效并持久化。"
    info "它控制系统整体使用Swap的倾向；zRAM和磁盘Swap之间仍由各自PRIO决定顺序。"
}

create_disk_swap() {
    require_root
    require_command findmnt
    require_command lsblk
    require_command dd
    require_command mkswap
    require_command swapon

    local root_fstype total_mb default_mb size_mb free_mb required_mb backup_dir tmp
    root_fstype=$(findmnt -n -o FSTYPE / 2>/dev/null || true)
    printf "根存储检测：%s\n" "$(root_storage_summary)"

    case "$root_fstype" in
        ext2|ext3|ext4|xfs) ;;
        btrfs)
            maintenance_die "Btrfs交换文件需要NOCOW等专门处理，本脚本为避免创建不可用Swap而拒绝自动操作。"
            ;;
        *)
            maintenance_die "当前根文件系统为 ${root_fstype:-未知}，不在安全支持范围（ext2/3/4、XFS）。"
            ;;
    esac

    if swapon --show=NAME --noheadings --raw 2>/dev/null | grep -Fxq "$DISK_SWAP_FILE"; then
        ok "$DISK_SWAP_FILE 已经作为磁盘Swap启用。"
        swapon --show
        return 0
    fi
    [[ ! -e "$DISK_SWAP_FILE" && ! -L "$DISK_SWAP_FILE" ]] ||
        maintenance_die "$DISK_SWAP_FILE 已存在但未启用。为避免覆盖未知文件，脚本不会处理它。"
    if awk -v path="$DISK_SWAP_FILE" '$1==path && $3=="swap" {found=1} END{exit !found}' "$FSTAB_FILE"; then
        maintenance_die "$FSTAB_FILE 已存在 $DISK_SWAP_FILE 条目，但文件当前不存在。请先人工检查。"
    fi

    total_mb=$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo)
    if (( total_mb <= 2048 )); then
        default_mb=1024
    else
        default_mb=2048
    fi
    free_mb=$(df -Pm / | awk 'NR==2 {print $4}')
    printf "物理内存：%s MB；根分区可用：%s MB\n" "$total_mb" "$free_mb"
    info "磁盘Swap优先级设为10，低于zRAM的100；只有内存和zRAM压力较大时才会使用。"
    read -r -p "磁盘Swap大小（MB）[${default_mb}]: " size_mb
    size_mb=${size_mb:-$default_mb}
    if [[ ! "$size_mb" =~ ^[0-9]+$ ]] || (( size_mb < 256 || size_mb > 16384 )); then
        maintenance_die "大小必须是256-16384之间的整数（MB）。"
    fi
    required_mb=$((size_mb + 512))
    (( free_mb >= required_mb )) ||
        maintenance_die "磁盘空间不足：创建后还需至少保留512MB，当前需要 ${required_mb}MB。"

    warn "HDD上的Swap明显慢于SSD/NVMe，但低优先级应急兜底仍可防止部分OOM。"
    confirm "使用dd创建 ${DISK_SWAP_FILE}（${size_mb}MB）并写入fstab" || return 0

    backup_dir=$(backup_file "$FSTAB_FILE")
    if ! (umask 077; dd if=/dev/zero of="$DISK_SWAP_FILE" bs=1M count="$size_mb" status=progress conv=fsync); then
        rm -f -- "$DISK_SWAP_FILE"
        maintenance_die "Swap文件创建失败；未修改fstab。"
    fi
    chmod 0600 "$DISK_SWAP_FILE"
    if ! mkswap -L vps-init-swap "$DISK_SWAP_FILE"; then
        rm -f -- "$DISK_SWAP_FILE"
        maintenance_die "mkswap失败；已删除本次创建的文件，未修改fstab。"
    fi

    if ! tmp=$(mktemp); then
        rm -f -- "$DISK_SWAP_FILE"
        maintenance_die "无法创建fstab临时文件；已删除本次Swap文件。"
    fi
    if ! cp -a -- "$FSTAB_FILE" "$tmp"; then
        rm -f -- "$tmp" "$DISK_SWAP_FILE"
        maintenance_die "无法读取fstab；已删除本次Swap文件。"
    fi
    printf '%s\n' "$DISK_SWAP_FILE none swap sw,pri=10,nofail 0 0" >> "$tmp"
    if ! findmnt --verify --tab-file "$tmp" >/dev/null 2>&1; then
        rm -f -- "$tmp" "$DISK_SWAP_FILE"
        maintenance_die "新fstab验证失败；已删除本次Swap文件，原fstab未修改。"
    fi
    if ! install -m 0644 "$tmp" "$FSTAB_FILE"; then
        rm -f -- "$tmp" "$DISK_SWAP_FILE"
        rollback_path "$FSTAB_FILE" "$backup_dir"
        maintenance_die "fstab写入失败，已回滚。"
    fi
    rm -f -- "$tmp"

    if ! swapon --priority 10 "$DISK_SWAP_FILE"; then
        rollback_path "$FSTAB_FILE" "$backup_dir"
        rm -f -- "$DISK_SWAP_FILE"
        maintenance_die "Swap启用失败；已恢复fstab并删除本次创建的文件。"
    fi

    ok "磁盘Swap已创建并立即生效。"
    swapon --show
    warn "脚本没有修改swappiness，也没有停用zRAM。"
}

swap_menu() {
    while true; do
        maintenance_header
        printf "1. 查看内存、Swap与根存储类型\n"
        printf "2. 配置 zRAM（优先级100）\n"
        printf "3. 创建磁盘 Swap 文件（优先级10）\n"
        printf "4. 设置 vm.swappiness（全局Swap倾向）\n"
        printf "0. 返回\n"
        read -r -p "请选择: " choice
        case "$choice" in
            1)
                free -h
                printf "\nvm.swappiness：%s\n" "$(sysctl -n vm.swappiness 2>/dev/null || printf '不可用')"
                printf "\nSwap设备：\n"
                swapon --show || true
                printf "\n根存储：%s\n" "$(root_storage_summary)"
                pause_screen
                ;;
            2) maintenance_run configure_zram; pause_screen ;;
            3) maintenance_run create_disk_swap; pause_screen ;;
            4) maintenance_run configure_swappiness; pause_screen ;;
            0) return 0 ;;
            *) warn "无效选择。"; sleep 1 ;;
        esac
    done
}

docker_repo_setup() {
    ensure_apt_available
    local repo_os=$OS_ID keyring source_file arch key_backup source_backup key_tmp tmp
    arch=$(dpkg --print-architecture)
    [[ -n "$OS_CODENAME" ]] || maintenance_die "无法识别系统代号。"

    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gnupg
    install -m 0755 -d /etc/apt/keyrings
    keyring="/etc/apt/keyrings/docker.asc"
    source_file="/etc/apt/sources.list.d/docker.sources"
    key_backup=$(backup_file "$keyring")
    source_backup=$(backup_file "$source_file")

    key_tmp=$(mktemp)
    if ! curl --proto '=https' --tlsv1.2 -fsSL "https://download.docker.com/linux/${repo_os}/gpg" -o "$key_tmp" ||
       ! gpg --batch --show-keys "$key_tmp" >/dev/null 2>&1; then
        rm -f -- "$key_tmp"
        maintenance_die "Docker 官方仓库密钥下载或验证失败，未修改软件源。"
    fi
    if ! install -m 0644 "$key_tmp" "$keyring"; then
        rm -f -- "$key_tmp"
        rollback_path "$keyring" "$key_backup"
        maintenance_die "Docker 仓库密钥写入失败，已恢复原密钥。"
    fi
    rm -f -- "$key_tmp"

    tmp=$(mktemp)
    printf '%s\n' \
        'Types: deb' \
        "URIs: https://download.docker.com/linux/${repo_os}" \
        "Suites: ${OS_CODENAME}" \
        'Components: stable' \
        "Architectures: ${arch}" \
        "Signed-By: ${keyring}" > "$tmp"
    if ! install -m 0644 "$tmp" "$source_file"; then
        rm -f -- "$tmp"
        rollback_path "$keyring" "$key_backup"
        rollback_path "$source_file" "$source_backup"
        maintenance_die "Docker 软件源配置写入失败，已恢复原配置。"
    fi
    rm -f "$tmp"

    if ! apt-get update; then
        rollback_path "$source_file" "$source_backup"
        rollback_path "$keyring" "$key_backup"
        apt-get update >/dev/null 2>&1 || true
        maintenance_die "Docker 软件源不可用，已恢复原配置。"
    fi
}

install_or_update_docker() {
    require_root
    if command -v docker >/dev/null 2>&1; then
        docker --version || true
        docker compose version 2>/dev/null || true
        apt-cache policy docker-ce docker-compose-plugin | sed -n '1,100p'
        confirm "通过 Docker 官方 APT 仓库更新现有 Docker/Compose" || return 0
    else
        confirm "配置 Docker 官方 APT 仓库并安装 Docker/Compose" || return 0
    fi

    docker_repo_setup
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
    docker --version
    docker compose version
    ok "Docker/Compose 安装或更新完成。"
}

uninstall_docker_keep_data() {
    require_root
    command -v docker >/dev/null 2>&1 || { warn "Docker 未安装。"; return 0; }
    docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}' || true
    printf "Docker数据目录：%s\n" "$(human_size /var/lib/docker)"
    warn "本操作仅卸载程序包，明确保留 /var/lib/docker 和 /var/lib/containerd。"
    confirm "确定停止 Docker 并卸载程序包吗" || return 0
    ensure_apt_available
    systemctl stop docker 2>/dev/null || true
    apt-get purge docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    ok "Docker程序包已卸载，Docker数据目录仍保留。"
}

merge_docker_logging() {
    require_root
    require_command docker
    require_command dockerd
    local max_size max_file current_driver backup_dir tmp
    max_size="20m"
    max_file="3"
    read -r -p "单个日志文件上限 [20m]: " max_size
    max_size=${max_size:-20m}
    read -r -p "最多保留文件数 [3]: " max_file
    max_file=${max_file:-3}
    [[ "$max_size" =~ ^[1-9][0-9]*[kKmMgG]$ ]] || maintenance_die "日志大小格式示例：20m、100m、1g。"
    [[ "$max_file" =~ ^[1-9][0-9]*$ ]] || maintenance_die "保留数量必须为正整数。"

    if systemctl cat docker 2>/dev/null | grep -Eq -- '--log-driver|--log-opt' ||
       pgrep -a -x dockerd 2>/dev/null | grep -Eq -- '--log-driver|--log-opt'; then
        maintenance_die "dockerd 启动参数已包含 --log-driver/--log-opt，请先消除重复配置。"
    fi

    if [[ -s "$DOCKER_CONF" ]]; then
        ensure_jq || maintenance_die "没有 jq，未修改 Docker 配置。"
        jq empty "$DOCKER_CONF" || maintenance_die "$DOCKER_CONF 当前不是合法 JSON。"
        current_driver=$(jq -r '."log-driver" // "json-file"' "$DOCKER_CONF")
    else
        ensure_jq || maintenance_die "没有 jq，未修改 Docker 配置。"
        current_driver="json-file"
    fi

    if [[ "$current_driver" != "json-file" ]]; then
        warn "当前全局日志驱动是：$current_driver"
        confirm "确定改为 json-file 吗" || return 0
    fi

    printf "将设置：json-file，max-size=%s，max-file=%s，compress=true\n" "$max_size" "$max_file"
    confirm "合并到 Docker 全局配置" || return 0

    install -d -m 0755 /etc/docker
    backup_dir=$(backup_file "$DOCKER_CONF")
    tmp=$(mktemp)
    if [[ -s "$DOCKER_CONF" ]]; then
        jq --arg size "$max_size" --arg files "$max_file" '
          . + {
            "log-driver": "json-file",
            "log-opts": ((."log-opts" // {}) + {
              "max-size": $size,
              "max-file": $files,
              "compress": "true"
            })
          }
        ' "$DOCKER_CONF" > "$tmp"
    else
        jq -n --arg size "$max_size" --arg files "$max_file" '{
          "log-driver": "json-file",
          "log-opts": {
            "max-size": $size,
            "max-file": $files,
            "compress": "true"
          }
        }' > "$tmp"
    fi

    if ! dockerd --validate --config-file="$tmp"; then
        rm -f "$tmp"
        maintenance_die "Docker配置验证失败，原配置没有变化。"
    fi
    install -m 0644 "$tmp" "$DOCKER_CONF"
    rm -f "$tmp"

    ok "Docker全局日志配置已安全合并并通过验证。"
    warn "现有容器不会改变；只对新建或通过原 Compose/1Panel 重建的容器生效。"
    if confirm "现在重启 Docker 服务吗？现有容器可能短暂中断"; then
        if ! systemctl restart docker; then
            rollback_path "$DOCKER_CONF" "$backup_dir"
            systemctl restart docker 2>/dev/null || true
            maintenance_die "Docker重启失败，已恢复原配置。"
        fi
        ok "Docker已重启。请在1Panel中逐个重建容器。"
    fi
}

show_container_log_configs() {
    command -v docker >/dev/null 2>&1 || { warn "Docker 未安装。"; return 0; }
    printf "%-30s %-12s %s\n" "容器" "驱动" "选项"
    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        docker inspect --format '{{.Name}}|{{.HostConfig.LogConfig.Type}}|{{json .HostConfig.LogConfig.Config}}' "$id" |
            sed 's#^/##' | awk -F'|' '{printf "%-30s %-12s %s\n",$1,$2,$3}'
    done < <(docker ps -aq)
}

journal_size_is_valid() {
    local value="${1^^}"
    [[ "$value" =~ ^[1-9][0-9]*[KMGTPE]$ ]]
}

journal_timespan_is_valid() {
    local value="$1"
    [[ "$value" =~ [[:alpha:]] ]] || return 1
    systemd-analyze timespan "$value" >/dev/null 2>&1
}

configure_journal_limits() {
    require_root
    local max_use retention keep_free backup_dir tmp
    require_command systemd-analyze

    while true; do
        read -r -p "Journal最大占用 [500M]: " max_use || return 0
        max_use=${max_use:-500M}
        journal_size_is_valid "$max_use" && break
        warn "容量必须带单位 K/M/G/T/P/E，例如 500M 或 1G；不能只输入数字。"
    done

    while true; do
        read -r -p "最长保留时间 [30day]: " retention || return 0
        retention=${retention:-30day}
        journal_timespan_is_valid "$retention" && break
        warn "时间必须带单位，例如 7day、30day、12h 或 2week；不能只输入数字。"
    done

    while true; do
        read -r -p "至少为系统保留磁盘空间 [1G]: " keep_free || return 0
        keep_free=${keep_free:-1G}
        journal_size_is_valid "$keep_free" && break
        warn "容量必须带单位 K/M/G/T/P/E，例如 500M 或 1G；不能只输入数字。"
    done

    printf '\n将设置：最大占用=%s，最长保留=%s，磁盘保留=%s\n' "$max_use" "$retention" "$keep_free"
    confirm "写入 journald 容量和保留期限配置（不会立即清空日志）" || return 0

    backup_dir=$(backup_file "$JOURNAL_CONF")
    install -d -m 0755 /etc/systemd/journald.conf.d
    tmp=$(mktemp)
    printf '%s\n' \
        '# Managed by vps-init.sh' \
        '[Journal]' \
        "SystemMaxUse=${max_use}" \
        "SystemKeepFree=${keep_free}" \
        "MaxRetentionSec=${retention}" > "$tmp"
    install -m 0644 "$tmp" "$JOURNAL_CONF"
    rm -f "$tmp"

    if ! systemd-analyze cat-config systemd/journald.conf >/dev/null 2>&1; then
        rollback_path "$JOURNAL_CONF" "$backup_dir"
        maintenance_die "journald 配置检查失败，已回滚。"
    fi
    if ! systemctl restart systemd-journald; then
        rollback_path "$JOURNAL_CONF" "$backup_dir"
        systemctl restart systemd-journald 2>/dev/null || true
        maintenance_die "journald 重启失败，已恢复原配置。"
    fi
    ok "journald 限制已配置；没有执行 vacuum-time=1s。"
}

set_timezone() {
    require_root
    local current
    current=$(timedatectl show -p Timezone --value)
    printf "当前时区：%s\n" "$current"
    [[ "$current" == "Asia/Shanghai" ]] && { ok "已经是 Asia/Shanghai。"; return 0; }
    confirm "设置为 Asia/Shanghai" || return 0
    timedatectl set-timezone Asia/Shanghai
    ok "时区已设置为 $(timedatectl show -p Timezone --value)。"
}

safe_cleanup() {
    require_root
    printf "APT缓存：%s\n" "$(human_size /var/cache/apt/archives)"
    journalctl --disk-usage 2>/dev/null || true
    if command -v docker >/dev/null 2>&1; then
        docker system df || true
    fi

    if confirm "清理APT已下载的 .deb 缓存吗"; then
        ensure_apt_available
        apt-get clean
        ok "APT缓存已清理。"
    fi

    info "以下仅模拟 apt autoremove，不会删除："
    apt-get -s autoremove 2>/dev/null | sed -n '1,160p' || true
    if confirm "确认根据上面列表执行 apt autoremove --purge 吗"; then
        ensure_apt_available
        apt-get autoremove --purge
    fi

    if command -v docker >/dev/null 2>&1 && confirm "清理Docker悬空镜像吗？不会使用 -a，也不会清理volume"; then
        docker image prune
    fi
    ok "安全清理流程结束。系统日志、Docker日志、/tmp 和 Docker volume 均未被直接删除。"
}

monitor_report() {
    printf "===== vps-init monitor %s =====\n" "$(date --iso-8601=seconds)"
    df -hT -x tmpfs -x devtmpfs
    journalctl --disk-usage 2>/dev/null || true
    printf "APT cache: %s\n" "$(human_size /var/cache/apt/archives)"
    if command -v docker >/dev/null 2>&1; then
        docker system df 2>/dev/null || true
        printf "Large Docker json logs (>200M):\n"
        find /var/lib/docker/containers -type f -name '*-json.log' -size +200M \
            -printf '%s %p\n' 2>/dev/null | sort -nr || true
    fi
}

install_monitor_timer() {
    require_root
    local service=/etc/systemd/system/vps-init-monitor.service
    local timer=/etc/systemd/system/vps-init-monitor.timer
    confirm "安装每周一06:06只读磁盘监控任务吗？它不会自动删除任何文件" || return 0
    [[ -f "$SCRIPT_PATH" ]] || maintenance_die "定时任务需要从已下载的脚本文件安装，不能通过进程替换方式运行。"
    if [[ "$SCRIPT_PATH" != /usr/local/sbin/vps-init ]]; then
        backup_file /usr/local/sbin/vps-init >/dev/null
        install -m 0755 "$SCRIPT_PATH" /usr/local/sbin/vps-init
    fi
    backup_file "$service" >/dev/null
    backup_file "$timer" >/dev/null
    local tmp
    tmp=$(mktemp)
    printf '%s\n' \
        '[Unit]' \
        'Description=vps-init read-only disk monitor' \
        '' \
        '[Service]' \
        'Type=oneshot' \
        "ExecStart=/bin/bash -c '/usr/local/sbin/vps-init --monitor >> ${MONITOR_LOG} 2>&1'" > "$tmp"
    install -m 0644 "$tmp" "$service"
    printf '%s\n' \
        '[Unit]' \
        'Description=Run vps-init disk monitor weekly' \
        '' \
        '[Timer]' \
        'OnCalendar=Mon *-*-* 06:06:00' \
        'Persistent=true' \
        'RandomizedDelaySec=5m' \
        '' \
        '[Install]' \
        'WantedBy=timers.target' > "$tmp"
    install -m 0644 "$tmp" "$timer"
    rm -f "$tmp"
    systemctl daemon-reload
    systemctl enable --now vps-init-monitor.timer
    systemctl list-timers vps-init-monitor.timer --no-pager
    ok "只读监控任务已安装，报告保存至 $MONITOR_LOG。"
}

docker_menu() {
    while true; do
        maintenance_header
        printf "1. 安装/更新 Docker 与 Compose\n"
        printf "2. 配置 Docker 全局日志轮转\n"
        printf "3. 查看现有容器日志配置\n"
        printf "4. 卸载 Docker 程序（保留全部数据）\n"
        printf "0. 返回\n"
        read -r -p "请选择: " choice
        case "$choice" in
            1) maintenance_run install_or_update_docker; pause_screen ;;
            2) maintenance_run merge_docker_logging; pause_screen ;;
            3) maintenance_run show_container_log_configs; pause_screen ;;
            4) maintenance_run uninstall_docker_keep_data; pause_screen ;;
            0) return 0 ;;
            *) warn "无效选择。"; sleep 1 ;;
        esac
    done
}

hardening_menu() {
    local choice
    while true; do
        clear 2>/dev/null || true
        printf '%s\n' '--------------------------------------------------'
        printf '密钥登录与账号加固\n'
        printf '%s\n' '--------------------------------------------------'
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
        printf '          VPS 安全初始化与维护工具 v%s\n' "$SCRIPT_VERSION"
        printf '==================================================\n'
        printf '当前用户：root\n'
        printf 'SSH 端口：%s\n\n' "$(ports_csv)"
        printf '[1] 密钥登录与账号加固      [%s]\n' "$(hardening_summary)"
        printf '[2] SSH 固定随机端口        [%s]\n' "$(state_get PORT_STAGE 2>/dev/null || printf 未开始)"
        printf '[3] Fail2ban 防爆破         [%s]\n' "$(fail2ban_summary)"
        printf '[4] 系统现状体检（只读）\n'
        printf '[5] BBR 管理（系统 BBR / XanMod + BBRv3）\n'
        printf '[6] 内存与 Swap 管理（zRAM / 磁盘 Swap）\n'
        printf '[7] Docker 与 Compose 管理\n'
        printf '[8] 配置 journald 容量与保留期限\n'
        printf '[9] 设置 Asia/Shanghai 时区\n'
        printf '[10] 安全清理（逐项预览确认）\n'
        printf '[11] 安装每周只读磁盘监控\n'
        printf '[0] 退出\n'
        printf '==================================================\n'
        printf '安全开荒推荐顺序：1 → 测试密钥 → 2 → 测试新端口 → 3；其余功能按需使用\n'
        read -rp '请选择：' choice || return 0
        case "$choice" in
            1) hardening_menu ;;
            2) port_menu ;;
            3) fail2ban_menu ;;
            4) maintenance_run system_report; pause_screen ;;
            5) bbr_menu ;;
            6) swap_menu ;;
            7) docker_menu ;;
            8) maintenance_run configure_journal_limits; pause_screen ;;
            9) maintenance_run set_timezone; pause_screen ;;
            10) maintenance_run safe_cleanup; pause_screen ;;
            11) maintenance_run install_monitor_timer; pause_screen ;;
            0) return 0 ;;
            *) warn "无效选择。"; pause_screen ;;
        esac
    done
}

usage() {
    cat <<EOF
VPS 安全初始化与维护工具 ${SCRIPT_VERSION}

仅支持 Debian 和 Ubuntu，不适配 PVE。

用法：
  sudo bash vps-init.sh            打开交互菜单
  sudo bash vps-init.sh --monitor  输出只读磁盘报告
  bash vps-init.sh --help          显示帮助
EOF
}

main() {
    case "${1:-}" in
        --help|-h)
            usage
            ;;
        --monitor)
            load_supported_os
            monitor_report
            ;;
        "")
            require_root
            load_supported_os
            initialize_runtime
            find_sshd
            main_menu
            ;;
        *)
            usage
            return 2
            ;;
    esac
}

main "$@"
