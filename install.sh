#!/bin/bash

# ==========================================
# Shadowsocks-2022 (Rust) 全能管理脚本
# 版本: v2.2 (增加时间校准功能)
# ==========================================

# --- 全局变量 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

CONFIG_FILE="/etc/shadowsocks-rust/config.json"
SERVICE_FILE="/etc/systemd/system/shadowsocks-rust.service"
BIN_PATH="/usr/local/bin/ssserver"

# --- 基础函数 ---

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误: 请使用 sudo 或 root 权限运行此脚本。${PLAIN}"
        exit 1
    fi
}

install_dependencies() {
    echo -e "${YELLOW}>> 安装依赖...${PLAIN}"
    if [ -f /etc/debian_version ]; then
        apt-get update -y >/dev/null 2>&1
        # 修改点：增加了 ntpdate
        apt-get install -y wget curl tar openssl jq coreutils xz-utils ntpdate >/dev/null 2>&1
    elif [ -f /etc/redhat-release ]; then
        yum update -y >/dev/null 2>&1
        # 修改点：增加了 ntpdate
        yum install -y wget curl tar openssl jq coreutils xz ntpdate >/dev/null 2>&1
    fi
}

# --- 新增：时间校准函数 ---
sync_time() {
    echo -e "${YELLOW}>> 正在校准系统时间...${PLAIN}"
    
    # 1. 优先尝试 systemd 方式
    if command -v timedatectl > /dev/null; then
        timedatectl set-ntp true 2>/dev/null
    fi

    # 2. 强制使用 ntpdate 同步 (解决 systemd 同步慢的问题)
    # 先停止可能占用端口的服务
    systemctl stop ntp 2>/dev/null
    systemctl stop chronyd 2>/dev/null
    
    ntpdate pool.ntp.org >/dev/null 2>&1
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}时间同步成功!${PLAIN}"
    else
        echo -e "${RED}同步失败，尝试备用服务器...${PLAIN}"
        ntpdate time.nist.gov >/dev/null 2>&1
    fi

    # 3. 设置时区为上海 (可选，为了查看日志方便，也可以注释掉)
    timedatectl set-timezone Asia/Shanghai 2>/dev/null

    echo -e "当前服务器时间: ${GREEN}$(date)${PLAIN}"
    echo -e "${YELLOW}提示: SS-2022 要求客户端与服务器时间误差需在 30秒 以内。${PLAIN}"
}

get_status() {
    if [[ ! -f $BIN_PATH ]]; then
        echo -e "${RED}未安装${PLAIN}"
    else
        if systemctl is-active --quiet shadowsocks-rust; then
            echo -e "${GREEN}运行中${PLAIN}"
        else
            echo -e "${RED}已停止${PLAIN}"
        fi
    fi
}

# --- 核心功能函数 ---

# 1. 安装服务
install_ss() {
    install_dependencies
    
    # 架构检测
    ARCH=$(uname -m)
    if [[ "$ARCH" == "x86_64" ]]; then ss_arch="x86_64-unknown-linux-gnu"
    elif [[ "$ARCH" == "aarch64" ]]; then ss_arch="aarch64-unknown-linux-gnu"
    else echo -e "${RED}不支持的架构${PLAIN}"; return; fi

    echo -e "${YELLOW}正在获取最新版本信息...${PLAIN}"
    LATEST_VER=$(curl -s "https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest" | jq -r .tag_name)
    [ -z "$LATEST_VER" ] && LATEST_VER="v1.15.3"

    echo -e "${GREEN}下载 Shadowsocks-Rust ${LATEST_VER}...${PLAIN}"
    wget -qO ss-rust.tar.xz "https://github.com/shadowsocks/shadowsocks-rust/releases/download/${LATEST_VER}/shadowsocks-${LATEST_VER}.${ss_arch}.tar.xz"
    
    tar -xf ss-rust.tar.xz
    mv ssserver /usr/local/bin/
    chmod +x /usr/local/bin/ssserver
    rm ss-rust.tar.xz sslocal ssmanager ssurl ssquery 2>/dev/null

    # 进入配置生成流程
    configure_ss "new"
    
    # 配置 Systemd
    cat > $SERVICE_FILE <<EOF
[Unit]
Description=Shadowsocks-Rust Server
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/ssserver -c $CONFIG_FILE
Restart=on-failure
LimitNOFILE=51200
[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable shadowsocks-rust >/dev/null 2>&1
    
    # 修改点：在启动服务前，强制校准一次时间
    sync_time
    
    start_ss
    
    echo -e "${GREEN}安装完成！${PLAIN}"
    view_config
}

# 2. 配置生成/修改逻辑 (通用)
configure_ss() {
    MODE=$1 # "new" or "modify"
    
    echo -e "\n${YELLOW}>> 配置参数设置${PLAIN}"
    
    # --- 加密方式 ---
    if [[ "$MODE" == "modify" ]]; then
        CURRENT_METHOD=$(jq -r .method $CONFIG_FILE 2>/dev/null)
        echo -e "当前加密: ${GREEN}$CURRENT_METHOD${PLAIN}"
    fi
    
    echo "请选择加密方式:"
    echo "1) 2022-blake3-aes-128-gcm (默认)"
    echo "2) 2022-blake3-aes-256-gcm"
    echo "3) 2022-blake3-chacha20-poly1305"
    read -p "选择 (留空保持默认/原值): " method_num
    
    if [[ -z "$method_num" && "$MODE" == "modify" ]]; then
        METHOD=$CURRENT_METHOD
    else
        case "$method_num" in
            2) METHOD="2022-blake3-aes-256-gcm"; KEY_BYTES=32; MIN_LEN=40 ;;
            3) METHOD="2022-blake3-chacha20-poly1305"; KEY_BYTES=32; MIN_LEN=40 ;;
            *) METHOD="2022-blake3-aes-128-gcm"; KEY_BYTES=16; MIN_LEN=20 ;;
        esac
    fi
    
    # 根据 Method 确定密钥长度参数 (用于后续校验)
    case "$METHOD" in
        *"aes-128"*) KEY_BYTES=16; MIN_LEN=20 ;;
        *) KEY_BYTES=32; MIN_LEN=40 ;;
    esac

    # --- 端口 ---
    if [[ "$MODE" == "modify" ]]; then
        CURRENT_PORT=$(jq -r .server_port $CONFIG_FILE 2>/dev/null)
        echo -e "当前端口: ${GREEN}$CURRENT_PORT${PLAIN}"
        read -p "新端口 (留空保持原值): " input_port
        PORT=${input_port:-$CURRENT_PORT}
    else
        read -p "端口 [默认 8388]: " input_port
        PORT=${input_port:-8388}
    fi

    # --- 密钥 ---
    AUTO_KEY=$(openssl rand -base64 $KEY_BYTES)
    if [[ "$MODE" == "modify" ]]; then
        CURRENT_PASS=$(jq -r .password $CONFIG_FILE 2>/dev/null)
        echo -e "当前密钥: ${GREEN}$CURRENT_PASS${PLAIN}"
        echo -e "注意: 如果更改了加密方式，建议重新生成密钥。"
        read -p "新密钥 (留空保持原值, 输入 'r' 随机生成): " input_key
        if [[ "$input_key" == "r" ]]; then
            PASSWORD=$AUTO_KEY
            echo -e "已随机生成新密钥。"
        elif [[ -z "$input_key" ]]; then
            PASSWORD=$CURRENT_PASS
        else
            PASSWORD=$input_key
        fi
    else
        read -p "密钥 [回车随机生成]: " input_key
        if [[ -z "$input_key" ]]; then
            PASSWORD=$AUTO_KEY
        else
            PASSWORD=$input_key
        fi
    fi
    
    # 最终密钥长度检查
    if [[ ${#PASSWORD} -lt $MIN_LEN ]]; then
        echo -e "${RED}警告: 密钥长度不符合 $METHOD 标准，已自动替换为随机密钥。${PLAIN}"
        PASSWORD=$AUTO_KEY
    fi

    # 写入配置
    mkdir -p /etc/shadowsocks-rust
    cat > $CONFIG_FILE <<EOF
{
    "server": "::",
    "server_port": $PORT,
    "password": "$PASSWORD",
    "method": "$METHOD",
    "timeout": 300,
    "fast_open": true
}
EOF
    
    # 放行端口
    if command -v ufw > /dev/null; then ufw allow $PORT >/dev/null 2>&1; fi
    if command -v firewall-cmd > /dev/null; then 
        firewall-cmd --permanent --add-port=$PORT/tcp >/dev/null 2>&1
        firewall-cmd --permanent --add-port=$PORT/udp >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    fi
}

# 3. 更新脚本
update_ss() {
    echo -e "${YELLOW}正在检查更新...${PLAIN}"
    if [[ ! -f $BIN_PATH ]]; then
        echo -e "${RED}未安装 SS-Rust，请先安装。${PLAIN}"
        return
    fi
    
    # 简单粗暴的更新逻辑：直接重新下载覆盖
    install_ss
    echo -e "${GREEN}更新完成。${PLAIN}"
}

# 4. 卸载
uninstall_ss() {
    read -p "确定要卸载 Shadowsocks-Rust 吗? (y/n): " confirm
    if [[ "$confirm" == "y" ]]; then
        systemctl stop shadowsocks-rust
        systemctl disable shadowsocks-rust
        rm $SERVICE_FILE
        rm $BIN_PATH
        rm -rf /etc/shadowsocks-rust
        systemctl daemon-reload
        echo -e "${GREEN}卸载完成。${PLAIN}"
    else
        echo "已取消。"
    fi
}

# 5. 查看配置与链接生成
view_config() {
    if [[ ! -f $CONFIG_FILE ]]; then
        echo -e "${RED}配置文件不存在。${PLAIN}"
        return
    fi

    echo -e "\n${YELLOW}>> 当前配置信息${PLAIN}"
    
    # 使用 jq 解析 JSON
    PORT=$(jq -r .server_port $CONFIG_FILE)
    PASSWORD=$(jq -r .password $CONFIG_FILE)
    METHOD=$(jq -r .method $CONFIG_FILE)
    
    # 获取 IP
    IP=$(curl -s4 ifconfig.me)
    if [[ -z "$IP" ]]; then IP=$(curl -s6 ifconfig.me); fi
    
    # 处理 IPv6 显示
    if [[ "$IP" =~ .*:.* ]]; then HOST="[${IP}]"; else HOST="${IP}"; fi
    
    # 生成 SIP002 链接
    AUTH_STR="${METHOD}:${PASSWORD}"
    AUTH_B64=$(echo -n "${AUTH_STR}" | base64 -w 0)
    SS_LINK="ss://${AUTH_B64}@${HOST}:${PORT}#SS-Rust"

    echo -e "地址:     ${GREEN}${HOST}${PLAIN}"
    echo -e "端口:     ${GREEN}${PORT}${PLAIN}"
    echo -e "加密:     ${GREEN}${METHOD}${PLAIN}"
    echo -e "密钥:     ${GREEN}${PASSWORD}${PLAIN}"
    echo -e "------------------------------------------------"
    echo -e "链接:     ${GREEN}${SS_LINK}${PLAIN}"
    echo -e "------------------------------------------------"
}

# 6. 修改配置
modify_config_action() {
    if [[ ! -f $CONFIG_FILE ]]; then
        echo -e "${RED}未找到配置文件，请先安装。${PLAIN}"
        return
    fi
    configure_ss "modify"
    restart_ss
    echo -e "${GREEN}配置已修改并重启服务。${PLAIN}"
    view_config
}

# 7. 删除配置
delete_config() {
    if [[ -f $CONFIG_FILE ]]; then
        read -p "确定要删除配置文件吗? 服务将停止 (y/n): " confirm
        if [[ "$confirm" == "y" ]]; then
            rm $CONFIG_FILE
            stop_ss
            echo -e "${GREEN}配置文件已删除。${PLAIN}"
        fi
    else
        echo -e "${RED}配置文件不存在。${PLAIN}"
    fi
}

# 服务控制封装
start_ss() { systemctl start shadowsocks-rust; echo -e "${GREEN}服务已启动${PLAIN}"; }
stop_ss() { systemctl stop shadowsocks-rust; echo -e "${GREEN}服务已停止${PLAIN}"; }
restart_ss() { systemctl restart shadowsocks-rust; echo -e "${GREEN}服务已重启${PLAIN}"; }

# --- 菜单界面 ---
menu() {
    clear
    check_root
    echo -e "================================================"
    echo -e "  Shadowsocks-2022 (Rust) 管理脚本 ${YELLOW}[v2.2]${PLAIN}"
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
    
    read -p "请输入选择 [0-10]: " choice
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
        *) echo -e "${RED}无效输入${PLAIN}" ;;
    esac
    
    echo -e "\n[按回车键返回菜单...]"
    read
    menu
}

# 脚本入口
menu
