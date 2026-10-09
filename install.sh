#!/usr/bin/env bash

# ==========================================
# Shadowsocks-2022 (Rust) 全能管理脚本
# 版本: v3.1
# ==========================================

set -o pipefail

# --- 全局变量 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

SCRIPT_VER="v3.1"
CONFIG_DIR="/etc/shadowsocks-rust"
CONFIG_FILE="${CONFIG_DIR}/config.json"
SERVICE_NAME="shadowsocks-rust"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
BIN_PATH="/usr/local/bin/ssserver"
SS_USER="shadowsocks"
REPO="shadowsocks/shadowsocks-rust"

# 可选环境变量:
#   GH_PROXY   GitHub 下载加速/镜像前缀，例如 https://mirror.example.com/ (纯 IPv6 机器可用)
#   SS_VERSION 指定安装版本，例如 v1.21.2 (跳过联网获取最新版本)
GH_PROXY="${GH_PROXY:-}"
SS_VERSION="${SS_VERSION:-}"

# --- 基础函数 ---

info() { echo -e "${GREEN}$*${PLAIN}"; }
warn() { echo -e "${YELLOW}$*${PLAIN}"; }
err() { echo -e "${RED}$*${PLAIN}" >&2; }

# 读取输入；标准输入结束 (EOF / Ctrl-D) 时退出，避免死循环
ask() {
    if ! read -rp "$1" "$2"; then
        echo
        err "输入已结束，退出脚本。"
        exit 1
    fi
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        err "错误: 请使用 sudo 或 root 权限运行此脚本。"
        exit 1
    fi
}

detect_pm() {
    if command -v apt-get >/dev/null; then PM="apt-get"
    elif command -v dnf >/dev/null; then PM="dnf"
    elif command -v yum >/dev/null; then PM="yum"
    else PM=""
    fi
}

APT_UPDATED=0
pkg_install() {
    detect_pm
    case "$PM" in
        apt-get)
            if [[ $APT_UPDATED -eq 0 ]]; then
                apt-get update -y >/dev/null && APT_UPDATED=1
            fi
            DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" >/dev/null
            ;;
        dnf|yum)
            "$PM" install -y "$@" >/dev/null
            ;;
        *)
            err "未识别的包管理器，请手动安装: $*"
            return 1
            ;;
    esac
}

install_dependencies() {
    warn ">> 检查依赖..."
    local missing=() cmd pkg
    # 只安装缺失的命令，避免与已有包冲突 (如 EL9 的 curl-minimal)
    for cmd in curl tar openssl jq xz sha256sum base64 mktemp install; do
        command -v "$cmd" >/dev/null && continue
        case "$cmd" in
            xz) [[ -f /etc/debian_version ]] && pkg="xz-utils" || pkg="xz" ;;
            sha256sum|base64|mktemp|install) pkg="coreutils" ;;
            *) pkg="$cmd" ;;
        esac
        [[ " ${missing[*]} " == *" $pkg "* ]] || missing+=("$pkg")
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        warn ">> 安装依赖: ${missing[*]}"
        pkg_install "${missing[@]}"
        # RHEL/CentOS 系 jq 可能位于 EPEL
        if ! command -v jq >/dev/null && [[ "$PM" == "dnf" || "$PM" == "yum" ]]; then
            warn ">> 未找到 jq，尝试启用 EPEL..."
            pkg_install epel-release && pkg_install jq
        fi
    fi

    for cmd in curl tar openssl jq xz sha256sum base64 mktemp install; do
        if ! command -v "$cmd" >/dev/null; then
            err "依赖安装失败: 缺少命令 '$cmd'，请手动安装后重试。"
            return 1
        fi
    done
}

# --- 时间校准 ---
sync_time() {
    warn ">> 正在校准系统时间..."

    if ! command -v timedatectl >/dev/null; then
        warn "未找到 timedatectl，跳过自动校时，请手动确认系统时间准确。"
    else
        # 启用系统自带的 NTP 服务 (systemd-timesyncd / chronyd)，不停止任何现有服务
        if ! timedatectl set-ntp true 2>/dev/null; then
            warn "未检测到可用的 NTP 服务，正在安装 chrony..."
            if pkg_install chrony; then
                systemctl enable --now chrony >/dev/null 2>&1 \
                    || systemctl enable --now chronyd >/dev/null 2>&1
            else
                err "chrony 安装失败。"
            fi
        fi

        # chrony 存在时立即步进校正，无需等待渐进同步
        if command -v chronyc >/dev/null; then
            chronyc -a makestep >/dev/null 2>&1
        fi

        local i synced=0
        for ((i = 0; i < 30; i++)); do
            if timedatectl status 2>/dev/null | grep -Eq 'synchronized: yes'; then
                synced=1
                break
            fi
            sleep 1
        done

        if [[ $synced -eq 1 ]]; then
            info "时间同步成功!"
        else
            warn "暂未确认时间已同步 (可能仍在同步中，或运行在无法修改时间的容器内)。"
        fi
    fi

    echo -e "当前服务器时间: ${GREEN}$(date)${PLAIN}"
    warn "提示: SS-2022 要求客户端与服务器时间误差需在 30 秒以内。"
}

get_status() {
    if [[ ! -f $BIN_PATH ]]; then
        echo -e "${RED}未安装${PLAIN}"
    elif systemctl is-active --quiet "$SERVICE_NAME"; then
        echo -e "${GREEN}运行中${PLAIN}"
    else
        echo -e "${RED}已停止${PLAIN}"
    fi
}

# --- 校验函数 ---

valid_port() {
    [[ $1 =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

key_bytes_for() {
    case "$1" in
        *aes-128*) echo 16 ;;
        *) echo 32 ;;
    esac
}

# SS-2022 要求密钥为 base64 编码，且解码后恰好为 16/32 字节
valid_key() {
    local key=$1 bytes=$2
    (( ${#key} == 4 * ((bytes + 2) / 3) )) || return 1
    [[ $key =~ ^[A-Za-z0-9+/]+={0,2}$ ]] || return 1
    [[ $(printf '%s' "$key" | base64 -d 2>/dev/null | wc -c) -eq $bytes ]]
}

# 内核禁用 IPv6 时无法监听 "::"，改为仅监听 IPv4
listen_addr() {
    if [[ -f /proc/net/if_inet6 ]]; then echo "::"; else echo "0.0.0.0"; fi
}

gen_key() {
    openssl rand -base64 "$1"
}

# --- 防火墙 ---

open_port() {
    local port=$1
    if command -v ufw >/dev/null; then ufw allow "$port" >/dev/null 2>&1; fi
    if command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="$port"/tcp >/dev/null 2>&1
        firewall-cmd --permanent --add-port="$port"/udp >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    fi
}

close_port() {
    local port=$1
    valid_port "$port" || return 0
    if command -v ufw >/dev/null; then ufw delete allow "$port" >/dev/null 2>&1; fi
    if command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --permanent --remove-port="$port"/tcp >/dev/null 2>&1
        firewall-cmd --permanent --remove-port="$port"/udp >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    fi
}

# --- 下载与系统配置 ---

get_latest_version() {
    local ver
    if [[ -n $SS_VERSION ]]; then
        [[ $SS_VERSION == v* ]] || SS_VERSION="v${SS_VERSION}"
        [[ $SS_VERSION =~ ^v[0-9]+\.[0-9]+ ]] || return 1
        echo "$SS_VERSION"
        return
    fi
    ver=$(curl -fsSL --max-time 10 "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null \
        | jq -r '.tag_name // empty' 2>/dev/null)
    # API 被限流时，通过 releases/latest 的重定向地址获取版本号
    if [[ ! $ver =~ ^v[0-9]+\.[0-9]+ ]]; then
        ver=$(curl -fsSLI -o /dev/null -w '%{url_effective}' --max-time 10 \
            "${GH_PROXY}https://github.com/${REPO}/releases/latest" 2>/dev/null)
        ver=${ver##*/}
    fi
    [[ $ver =~ ^v[0-9]+\.[0-9]+ ]] || return 1
    echo "$ver"
}

installed_version() {
    [[ -x $BIN_PATH ]] || return 1
    local v
    v=$("$BIN_PATH" --version 2>/dev/null | awk '{print $2; exit}')
    [[ -n $v ]] && echo "v${v#v}"
}

# 用法: download_ss <版本号>
download_ss() {
    local ver=$1 target tmp file url expected actual

    # 使用 musl 静态构建，避免旧系统 glibc 版本过低
    case "$(uname -m)" in
        x86_64|amd64) target="x86_64-unknown-linux-musl" ;;
        aarch64|arm64) target="aarch64-unknown-linux-musl" ;;
        *) err "不支持的架构: $(uname -m)"; return 1 ;;
    esac

    file="shadowsocks-${ver}.${target}.tar.xz"
    url="${GH_PROXY}https://github.com/${REPO}/releases/download/${ver}/${file}"
    tmp=$(mktemp -d) || return 1

    info "下载 Shadowsocks-Rust ${ver}..."
    if ! curl -fL --retry 3 --connect-timeout 10 -o "${tmp}/${file}" "$url" \
        || ! curl -fsSL --retry 3 --connect-timeout 10 -o "${tmp}/${file}.sha256" "${url}.sha256"; then
        err "下载失败: $url"
        rm -rf "$tmp"
        return 1
    fi

    expected=$(awk '{print $1; exit}' "${tmp}/${file}.sha256")
    actual=$(sha256sum "${tmp}/${file}" | awk '{print $1}')
    if [[ ! $expected =~ ^[0-9a-fA-F]{64}$ || "${expected,,}" != "${actual,,}" ]]; then
        err "SHA256 校验失败，已中止安装。"
        rm -rf "$tmp"
        return 1
    fi

    if ! tar -xJf "${tmp}/${file}" -C "$tmp" ssserver || [[ ! -f "${tmp}/ssserver" ]]; then
        err "解压失败。"
        rm -rf "$tmp"
        return 1
    fi

    # 先写临时文件再原子替换，运行中的旧进程不受影响
    if ! install -m 755 "${tmp}/ssserver" "${BIN_PATH}.new" || ! mv -f "${BIN_PATH}.new" "$BIN_PATH"; then
        err "安装二进制文件失败。"
        rm -f "${BIN_PATH}.new"
        rm -rf "$tmp"
        return 1
    fi

    rm -rf "$tmp"
    info "已安装: $("$BIN_PATH" --version 2>/dev/null || echo "$ver")"
}

ensure_user() {
    id -u "$SS_USER" >/dev/null 2>&1 && return 0
    # 同名用户组已存在 (如其他软件残留) 时，加入该组而不是新建
    local group_opt=(--user-group)
    if getent group "$SS_USER" >/dev/null 2>&1; then
        group_opt=(-g "$SS_USER")
    fi
    useradd --system "${group_opt[@]}" --no-create-home \
        --shell "$(command -v nologin || echo /bin/false)" "$SS_USER"
}

fix_config_perms() {
    [[ -d $CONFIG_DIR ]] || return 0
    chown root:"$SS_USER" "$CONFIG_DIR"
    chmod 750 "$CONFIG_DIR"
    if [[ -f $CONFIG_FILE ]]; then
        chown root:"$SS_USER" "$CONFIG_FILE"
        chmod 640 "$CONFIG_FILE"
    fi
}

fetch_version() {
    warn "正在获取最新版本信息..." >&2
    if ! get_latest_version; then
        err "获取版本信息失败。请检查服务器能否访问 GitHub，或通过 SS_VERSION / GH_PROXY 环境变量指定版本和镜像。"
        return 1
    fi
}

# 写入 systemd 服务文件；内容有变化时设置 SERVICE_CHANGED=1
write_service() {
    local new
    SERVICE_CHANGED=0
    new=$(cat <<EOF
[Unit]
Description=Shadowsocks-Rust Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SS_USER}
Group=${SS_USER}
ExecStart=${BIN_PATH} -c ${CONFIG_FILE}
Restart=on-failure
RestartSec=3
LimitNOFILE=51200
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
)
    if [[ ! -f $SERVICE_FILE ]] || [[ "$(cat "$SERVICE_FILE")" != "$new" ]]; then
        printf '%s\n' "$new" > "$SERVICE_FILE"
        SERVICE_CHANGED=1
    fi
    systemctl daemon-reload
}

# --- 核心功能函数 ---

# 1. 安装服务
install_ss() {
    local confirm
    if [[ -f $CONFIG_FILE ]]; then
        warn "检测到已有配置，继续安装将重新生成配置 (如只需升级程序请使用「更新版本」)。"
        ask "是否继续? (y/n): " confirm
        [[ "$confirm" == "y" ]] || { echo "已取消。"; return; }
    fi

    local ver
    install_dependencies || return 1
    ver=$(fetch_version) || return 1
    download_ss "$ver" || return 1
    ensure_user || { err "创建运行用户 ${SS_USER} 失败。"; return 1; }

    configure_ss "new" || return 1

    write_service
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1

    # 启动服务前校准一次时间
    sync_time

    restart_ss || return 1

    info "安装完成！"
    view_config
}

# 2. 配置生成/修改逻辑 (通用)
configure_ss() {
    local mode=$1 # "new" or "modify"
    local cur_method="" cur_port="" cur_pass="" old_port="" method_num input_port input_key key_bytes

    echo -e "\n${YELLOW}>> 配置参数设置${PLAIN}"

    # 记录旧端口，用于修改后关闭防火墙规则
    if [[ -f $CONFIG_FILE ]]; then
        old_port=$(jq -r '.server_port // empty' "$CONFIG_FILE" 2>/dev/null)
    fi
    if [[ "$mode" == "modify" ]]; then
        cur_method=$(jq -r '.method // empty' "$CONFIG_FILE" 2>/dev/null)
        cur_port=$(jq -r '.server_port // empty' "$CONFIG_FILE" 2>/dev/null)
        cur_pass=$(jq -r '.password // empty' "$CONFIG_FILE" 2>/dev/null)
    fi

    # --- 加密方式 ---
    [[ -n $cur_method ]] && echo -e "当前加密: ${GREEN}${cur_method}${PLAIN}"
    echo "请选择加密方式:"
    echo "1) 2022-blake3-aes-128-gcm (默认)"
    echo "2) 2022-blake3-aes-256-gcm"
    echo "3) 2022-blake3-chacha20-poly1305"
    while true; do
        ask "选择 (留空保持默认/原值): " method_num
        if [[ -z "$method_num" && -n "$cur_method" ]]; then
            METHOD=$cur_method
            break
        fi
        case "$method_num" in
            ""|1) METHOD="2022-blake3-aes-128-gcm"; break ;;
            2) METHOD="2022-blake3-aes-256-gcm"; break ;;
            3) METHOD="2022-blake3-chacha20-poly1305"; break ;;
            *) err "无效选择，请输入 1-3。" ;;
        esac
    done
    key_bytes=$(key_bytes_for "$METHOD")

    # --- 端口 ---
    [[ -n $cur_port ]] && echo -e "当前端口: ${GREEN}${cur_port}${PLAIN}"
    while true; do
        if [[ -n $cur_port ]]; then
            ask "新端口 (留空保持原值): " input_port
            PORT=${input_port:-$cur_port}
        else
            ask "端口 [默认 8388]: " input_port
            PORT=${input_port:-8388}
        fi
        if valid_port "$PORT"; then
            PORT=$((10#$PORT))
            break
        fi
        err "端口无效，请输入 1-65535 之间的数字。"
    done

    # --- 密钥 ---
    if [[ -n $cur_pass ]]; then
        echo -e "当前密钥: ${GREEN}${cur_pass}${PLAIN}"
        echo -e "注意: 如果更改了加密方式，建议重新生成密钥。"
    fi
    while true; do
        if [[ -n $cur_pass ]]; then
            ask "新密钥 (留空保持原值, 输入 'r' 随机生成): " input_key
        else
            ask "密钥 [回车随机生成]: " input_key
        fi

        if [[ "$input_key" == "r" || ( -z "$input_key" && -z "$cur_pass" ) ]]; then
            PASSWORD=$(gen_key "$key_bytes")
            echo "已随机生成新密钥。"
            break
        elif [[ -z "$input_key" ]]; then
            if valid_key "$cur_pass" "$key_bytes"; then
                PASSWORD=$cur_pass
            else
                warn "原密钥不符合 ${METHOD} 的要求 (需 ${key_bytes} 字节)，已自动替换为随机密钥。"
                PASSWORD=$(gen_key "$key_bytes")
            fi
            break
        elif valid_key "$input_key" "$key_bytes"; then
            PASSWORD=$input_key
            break
        else
            err "密钥无效: ${METHOD} 需要 base64 编码的 ${key_bytes} 字节密钥 (可用 'openssl rand -base64 ${key_bytes}' 生成)。"
        fi
    done

    # 写入配置 (强制开启 tcp_and_udp)；用 jq 生成，避免特殊字符破坏 JSON
    ensure_user || { err "创建运行用户 ${SS_USER} 失败。"; return 1; }
    mkdir -p "$CONFIG_DIR"
    fix_config_perms
    # umask 077: 临时文件创建时即仅 root 可读，避免密钥短暂暴露
    if ! (umask 077 && jq -n \
        --arg server "$(listen_addr)" \
        --arg password "$PASSWORD" \
        --arg method "$METHOD" \
        --argjson port "$PORT" \
        '{server: $server, server_port: $port, password: $password, method: $method,
          mode: "tcp_and_udp", timeout: 300, fast_open: true}' > "${CONFIG_FILE}.tmp"); then
        err "生成配置文件失败。"
        rm -f "${CONFIG_FILE}.tmp"
        return 1
    fi
    mv -f "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    fix_config_perms

    # 放行新端口，关闭旧端口
    open_port "$PORT"
    if [[ -n $old_port && "$old_port" != "$PORT" ]]; then
        close_port "$old_port"
    fi
}

# 3. 更新版本 (只替换程序，保留配置)
update_ss() {
    warn "正在检查更新..."
    if [[ ! -f $BIN_PATH ]]; then
        err "未安装 SS-Rust，请先安装。"
        return
    fi

    local ver cur updated=0
    install_dependencies || return 1
    ver=$(fetch_version) || return 1
    cur=$(installed_version)

    if [[ "$cur" == "$ver" ]]; then
        info "当前已是最新版本 (${ver})，无需下载。"
    else
        echo -e "当前版本: ${GREEN}${cur:-未知}${PLAIN} -> 最新版本: ${GREEN}${ver}${PLAIN}"
        download_ss "$ver" || return 1
        updated=1
    fi

    # 同步迁移旧版本的服务配置 (以非 root 用户运行)
    ensure_user || { err "创建运行用户 ${SS_USER} 失败。"; return 1; }
    fix_config_perms
    write_service

    # 程序或服务配置有变化时才重启，避免无谓地断开连接
    if [[ -f $CONFIG_FILE ]] && (( updated || SERVICE_CHANGED )); then
        restart_ss || return 1
    fi
    info "更新完成。"
}

# 4. 卸载
uninstall_ss() {
    local confirm
    ask "确定要卸载 Shadowsocks-Rust 吗? (y/n): " confirm
    if [[ "$confirm" == "y" ]]; then
        local port=""
        [[ -f $CONFIG_FILE ]] && port=$(jq -r '.server_port // empty' "$CONFIG_FILE" 2>/dev/null)
        systemctl stop "$SERVICE_NAME" 2>/dev/null
        systemctl disable "$SERVICE_NAME" 2>/dev/null
        rm -f "$SERVICE_FILE" "$BIN_PATH"
        rm -rf "$CONFIG_DIR"
        systemctl daemon-reload
        [[ -n $port ]] && close_port "$port"
        id -u "$SS_USER" >/dev/null 2>&1 && userdel "$SS_USER" 2>/dev/null
        info "卸载完成。"
    else
        echo "已取消。"
    fi
}

get_public_ip() {
    local ip url
    for url in https://api.ipify.org https://ifconfig.me https://ipv4.icanhazip.com; do
        ip=$(curl -s4 --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')
        [[ $ip =~ ^[0-9]+(\.[0-9]+){3}$ ]] && { echo "$ip"; return; }
    done
    for url in https://api64.ipify.org https://ifconfig.me https://ipv6.icanhazip.com; do
        ip=$(curl -s6 --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')
        [[ $ip =~ ^[0-9a-fA-F:]+$ && $ip == *:* ]] && { echo "$ip"; return; }
    done
}

uri_encode() {
    jq -rn --arg s "$1" '$s | @uri'
}

# 5. 查看配置与链接生成
view_config() {
    if [[ ! -f $CONFIG_FILE ]]; then
        err "配置文件不存在。"
        return
    fi

    echo -e "\n${YELLOW}>> 当前配置信息${PLAIN}"

    local port password method ip host link
    port=$(jq -r .server_port "$CONFIG_FILE")
    password=$(jq -r .password "$CONFIG_FILE")
    method=$(jq -r .method "$CONFIG_FILE")

    ip=$(get_public_ip)
    if [[ -z "$ip" ]]; then
        warn "无法获取公网 IP，请将链接中的 YOUR_IP 替换为服务器地址。"
        ip="YOUR_IP"
    fi

    # 处理 IPv6 显示
    if [[ "$ip" == *:* ]]; then host="[${ip}]"; else host="${ip}"; fi

    # SIP002: 2022 系列算法的 userinfo 不使用 base64，而是百分号编码的明文
    link="ss://$(uri_encode "$method"):$(uri_encode "$password")@${host}:${port}#SS-Rust"

    echo -e "地址:     ${GREEN}${host}${PLAIN}"
    echo -e "端口:     ${GREEN}${port}${PLAIN}"
    echo -e "加密:     ${GREEN}${method}${PLAIN}"
    echo -e "密钥:     ${GREEN}${password}${PLAIN}"
    echo -e "------------------------------------------------"
    echo -e "链接:     ${GREEN}${link}${PLAIN}"
    echo -e "------------------------------------------------"
}

# 6. 修改配置
modify_config_action() {
    if [[ ! -f $CONFIG_FILE ]]; then
        err "未找到配置文件，请先安装。"
        return
    fi
    configure_ss "modify" || return 1
    restart_ss || return 1
    info "配置已修改并重启服务。"
    view_config
}

# 7. 删除配置
delete_config() {
    local confirm
    if [[ -f $CONFIG_FILE ]]; then
        ask "确定要删除配置文件吗? 服务将停止并取消开机自启 (y/n): " confirm
        if [[ "$confirm" == "y" ]]; then
            local port
            port=$(jq -r '.server_port // empty' "$CONFIG_FILE" 2>/dev/null)
            stop_ss
            systemctl disable "$SERVICE_NAME" >/dev/null 2>&1
            rm -f "$CONFIG_FILE"
            close_port "$port"
            info "配置文件已删除。"
        fi
    else
        err "配置文件不存在。"
    fi
}

# 服务控制封装
check_started() {
    sleep 1
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        return 0
    fi
    err "服务启动失败，请查看日志: journalctl -u ${SERVICE_NAME} -n 50 --no-pager"
    return 1
}

start_ss() {
    if [[ ! -f $CONFIG_FILE ]]; then err "配置文件不存在，请先安装或修改配置。"; return 1; fi
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
    systemctl start "$SERVICE_NAME" && check_started && info "服务已启动"
}

stop_ss() {
    systemctl stop "$SERVICE_NAME" && info "服务已停止"
}

restart_ss() {
    if [[ ! -f $CONFIG_FILE ]]; then err "配置文件不存在，请先安装或修改配置。"; return 1; fi
    systemctl restart "$SERVICE_NAME" && check_started && info "服务已重启"
}

# --- 菜单界面 ---
show_menu() {
    clear
    echo -e "================================================"
    echo -e "  Shadowsocks-2022 (Rust) 管理脚本 ${YELLOW}[${SCRIPT_VER}]${PLAIN}"
    echo -e "  当前状态: $(get_status)"
    echo -e "================================================"
    echo -e "  1. 安装服务 (Install)"
    echo -e "  2. 更新版本 (Update)"
    echo -e "  3. 卸载服务 (Uninstall)"
    echo -e "------------------------------------------------"
    echo -e "  4. 查看配置 & 链接 (View Config)"
    echo -e "  5. 修改配置 (Modify Config)"
    echo -e "  6. 删除配置 (Delete Config)"
    echo -e "------------------------------------------------"
    echo -e "  7. 启动服务 (Start)"
    echo -e "  8. 停止服务 (Stop)"
    echo -e "  9. 重启服务 (Restart)"
    echo -e "  10. 校准时间 (Sync Time)"
    echo -e "------------------------------------------------"
    echo -e "  0. 退出脚本 (Exit)"
    echo -e "================================================"
}

main() {
    local choice
    check_root
    while true; do
        show_menu
        ask "请输入选择 [0-10]: " choice
        case "$choice" in
            1) install_ss ;;
            2) update_ss ;;
            3) uninstall_ss ;;
            4) view_config ;;
            5) modify_config_action ;;
            6) delete_config ;;
            7) start_ss ;;
            8) stop_ss ;;
            9) restart_ss ;;
            10) sync_time ;;
            0) exit 0 ;;
            *) err "无效输入" ;;
        esac

        echo -e "\n[按回车键返回菜单...]"
        read -r || exit 0
    done
}

# 脚本入口
main
