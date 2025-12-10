#!/bin/bash

# ==========================================
# Shadowsocks-2022 (Rust) 全能安装脚本
# 功能：选加密方式 + 自定义端口/密钥 + 链接生成
# ==========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误: 请使用 sudo 或 root 权限运行此脚本。${PLAIN}" 
   exit 1
fi

echo -e "${GREEN}--- 开始安装 Shadowsocks-2022 (Rust) ---${PLAIN}"

# --- 1. 交互式配置 ---
echo -e "${YELLOW}>> 进入配置向导...${PLAIN}"

# 1.1 选择加密方式
echo -e "\n请选择加密方式 (输入数字):"
echo "1) 2022-blake3-aes-128-gcm (默认, 适合手机/低性能设备)"
echo "2) 2022-blake3-aes-256-gcm (更高安全性)"
echo "3) 2022-blake3-chacha20-poly1305 (适合无AES指令集的CPU)"
read -p "请选择 [1-3]: " method_num

# 逻辑判断：确定算法名称和所需密钥长度(字节)
case "$method_num" in
    2)
        METHOD="2022-blake3-aes-256-gcm"
        KEY_BYTES=32
        MIN_CHAR_LEN=40 # Base64 32bytes approx 44 chars
        ;;
    3)
        METHOD="2022-blake3-chacha20-poly1305"
        KEY_BYTES=32
        MIN_CHAR_LEN=40
        ;;
    *)
        METHOD="2022-blake3-aes-128-gcm"
        KEY_BYTES=16
        MIN_CHAR_LEN=20 # Base64 16bytes approx 24 chars
        ;;
esac

echo -e "已选择加密: ${GREEN}${METHOD}${PLAIN}"

# 1.2 设置端口
read -p "请输入服务器端口 [回车默认 8388]: " input_port
PORT=${input_port:-8388}
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}错误: 端口必须是数字。${PLAIN}"
    exit 1
fi

# 1.3 设置密钥 (根据上面的选择自动适配长度)
AUTO_KEY=$(openssl rand -base64 $KEY_BYTES)
echo -e "\n${YELLOW}>> 密钥设置:${PLAIN}"
echo "当前算法要求密钥必须是 Base64 编码的 ${KEY_BYTES} 字节数据。"
read -p "请输入密钥 [回车随机生成]: " input_key

if [[ -z "$input_key" ]]; then
    PASSWORD=$AUTO_KEY
    echo -e "已自动生成合规密钥。"
else
    # 简单的长度检查
    if [[ ${#input_key} -lt $MIN_CHAR_LEN ]]; then
        echo -e "${RED}警告: 你输入的密钥长度太短，不符合 ${METHOD} 的标准。${PLAIN}"
        echo -e "${YELLOW}已强制切换为随机合规密钥，防止服务启动失败。${PLAIN}"
        PASSWORD=$AUTO_KEY
    else
        PASSWORD=$input_key
    fi
fi

# --- 2. 安装环境 ---
echo -e "\n[1/4] 安装依赖..."
if [ -f /etc/debian_version ]; then
    apt-get update -y >/dev/null 2>&1 && apt-get install -y wget curl tar openssl jq coreutils >/dev/null 2>&1
elif [ -f /etc/redhat-release ]; then
    yum update -y >/dev/null 2>&1 && yum install -y wget curl tar openssl jq coreutils >/dev/null 2>&1
fi

# --- 3. 下载 SS-Rust ---
echo "[2/4] 下载 Shadowsocks-Rust..."
ARCH=$(uname -m)
if [[ "$ARCH" == "x86_64" ]]; then
    ss_arch="x86_64-unknown-linux-gnu"
elif [[ "$ARCH" == "aarch64" ]]; then
    ss_arch="aarch64-unknown-linux-gnu"
else
    echo -e "${RED}不支持的架构: $ARCH${PLAIN}"
    exit 1
fi

LATEST_VER=$(curl -s "https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest" | jq -r .tag_name)
[ -z "$LATEST_VER" ] && LATEST_VER="v1.15.3"

DOWNLOAD_URL="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${LATEST_VER}/shadowsocks-${LATEST_VER}.${ss_arch}.tar.xz"
wget -qO ss-rust.tar.xz "$DOWNLOAD_URL"

tar -xf ss-rust.tar.xz
mv ssserver /usr/local/bin/ 2>/dev/null
chmod +x /usr/local/bin/ssserver
rm ss-rust.tar.xz sslocal ssmanager ssurl ssquery 2>/dev/null

# --- 4. 写入配置 ---
echo "[3/4] 写入配置文件..."
mkdir -p /etc/shadowsocks-rust
cat > /etc/shadowsocks-rust/config.json <<EOF
{
    "server": "::",
    "server_port": $PORT,
    "password": "$PASSWORD",
    "method": "$METHOD",
    "timeout": 300,
    "fast_open": true
}
EOF

# --- 5. 启动服务 ---
echo "[4/4] 启动服务..."
cat > /etc/systemd/system/shadowsocks-rust.service <<EOF
[Unit]
Description=Shadowsocks-Rust Server
After=network.target

[Service]
Type=simple
User=root
Group=root
LimitNOFILE=51200
ExecStart=/usr/local/bin/ssserver -c /etc/shadowsocks-rust/config.json
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable shadowsocks-rust >/dev/null 2>&1
systemctl restart shadowsocks-rust

# 防火墙
if command -v ufw > /dev/null; then
    ufw allow $PORT >/dev/null 2>&1
elif command -v firewall-cmd > /dev/null; then
    firewall-cmd --permanent --add-port=$PORT/tcp >/dev/null 2>&1
    firewall-cmd --permanent --add-port=$PORT/udp >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1
fi

# --- 6. 生成链接与输出信息 ---
IP=$(curl -s4 ifconfig.me)

# 格式: method:password@ip:port
SS_STRING="${METHOD}:${PASSWORD}@${IP}:${PORT}"
SS_BASE64=$(echo -n "${SS_STRING}" | base64 -w 0)
SS_LINK="ss://${SS_BASE64}#SS2022_Rust"

echo ""
echo "================================================"
echo -e "✅ ${GREEN}安装成功！客户端配置信息如下：${PLAIN}"
echo "================================================"
echo -e "服务器 (IP):   ${GREEN}${IP}${PLAIN}"
echo -e "端口 (Port):   ${GREEN}${PORT}${PLAIN}"
echo -e "加密 (Method): ${GREEN}${METHOD}${PLAIN}"
echo -e "密码 (Key):    ${GREEN}${PASSWORD}${PLAIN}"
echo "================================================"
echo -e "🚀 一键导入链接 (复制整行):"
echo -e "${GREEN}${SS_LINK}${PLAIN}"
echo "================================================"
