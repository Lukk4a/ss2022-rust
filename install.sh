#!/bin/bash

# ==========================================
# Shadowsocks-2022 (Rust) SIP002 专版
# 特性：支持 SIP002 格式链接、IPv6 自动识别、自定义备注
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
echo -e "${YELLOW}>> 1. 基础配置${PLAIN}"

# 1.1 选择加密方式
echo -e "\n请选择加密方式 (输入数字):"
echo "1) 2022-blake3-aes-128-gcm (默认, 推荐)"
echo "2) 2022-blake3-aes-256-gcm"
echo "3) 2022-blake3-chacha20-poly1305"
read -p "请选择 [1-3]: " method_num

case "$method_num" in
    2) METHOD="2022-blake3-aes-256-gcm"; KEY_BYTES=32; MIN_LEN=40 ;;
    3) METHOD="2022-blake3-chacha20-poly1305"; KEY_BYTES=32; MIN_LEN=40 ;;
    *) METHOD="2022-blake3-aes-128-gcm"; KEY_BYTES=16; MIN_LEN=20 ;;
esac
echo -e "已选择: ${GREEN}${METHOD}${PLAIN}"

# 1.2 设置端口
read -p "请输入端口 [回车默认 8388]: " input_port
PORT=${input_port:-8388}

# 1.3 设置密钥
AUTO_KEY=$(openssl rand -base64 $KEY_BYTES)
echo -e "\n请输入密钥 [回车随机生成]:"
read -p ": " input_key
if [[ -z "$input_key" ]] || [[ ${#input_key} -lt $MIN_LEN ]]; then
    PASSWORD=$AUTO_KEY
    echo -e "已使用随机合规密钥: ${GREEN}$PASSWORD${PLAIN}"
else
    PASSWORD=$input_key
fi

# 1.4 设置备注 (用于生成链接)
echo -e "\n请输入节点备注 (如 '🇯🇵 My Server') [回车默认 'SS-Rust']:"
read -p ": " input_remark
REMARK=${input_remark:-SS-Rust}

# --- 2. 安装环境与下载 ---
echo -e "\n${YELLOW}>> 2. 安装与部署...${PLAIN}"

if [ -f /etc/debian_version ]; then
    apt-get update -y >/dev/null 2>&1 && apt-get install -y wget curl tar openssl jq coreutils >/dev/null 2>&1
elif [ -f /etc/redhat-release ]; then
    yum update -y >/dev/null 2>&1 && yum install -y wget curl tar openssl jq coreutils >/dev/null 2>&1
fi

ARCH=$(uname -m)
if [[ "$ARCH" == "x86_64" ]]; then ss_arch="x86_64-unknown-linux-gnu"
elif [[ "$ARCH" == "aarch64" ]]; then ss_arch="aarch64-unknown-linux-gnu"
else echo -e "${RED}不支持的架构${PLAIN}"; exit 1; fi

LATEST_VER=$(curl -s "https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest" | jq -r .tag_name)
[ -z "$LATEST_VER" ] && LATEST_VER="v1.15.3"

wget -qO ss-rust.tar.xz "https://github.com/shadowsocks/shadowsocks-rust/releases/download/${LATEST_VER}/shadowsocks-${LATEST_VER}.${ss_arch}.tar.xz"
tar -xf ss-rust.tar.xz && mv ssserver /usr/local/bin/ && chmod +x /usr/local/bin/ssserver
rm ss-rust.tar.xz sslocal ssmanager ssurl ssquery 2>/dev/null

# --- 3. 配置文件 ---
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

# --- 4. Systemd 服务 ---
cat > /etc/systemd/system/shadowsocks-rust.service <<EOF
[Unit]
Description=Shadowsocks-Rust Server
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/ssserver -c /etc/shadowsocks-rust/config.json
Restart=on-failure
LimitNOFILE=51200
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable shadowsocks-rust >/dev/null 2>&1
systemctl restart shadowsocks-rust

# 放行端口
if command -v ufw > /dev/null; then ufw allow $PORT >/dev/null 2>&1
elif command -v firewall-cmd > /dev/null; then
    firewall-cmd --permanent --add-port=$PORT/tcp >/dev/null 2>&1
    firewall-cmd --permanent --add-port=$PORT/udp >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1
fi

# --- 5. 生成 SIP002 格式链接 (关键修改) ---
echo -e "\n${YELLOW}>> 3. 生成链接${PLAIN}"

# 5.1 获取 IP (优先获取公网 IPv4，如果没有则获取 IPv6)
IP=$(curl -s4 ifconfig.me)
if [[ -z "$IP" ]]; then
    IP=$(curl -s6 ifconfig.me)
fi

# 5.2 处理 IPv6 格式 (如果是 IPv6，必须加 [])
if [[ "$IP" =~ .*:.* ]]; then
    HOST="[${IP}]"
else
    HOST="${IP}"
fi

# 5.3 编码 UserInfo (仅编码 method:password)
# 注意： SIP002 标准格式为 ss://Base64(method:password)@host:port#remark
AUTH_STR="${METHOD}:${PASSWORD}"
AUTH_B64=$(echo -n "${AUTH_STR}" | base64 -w 0)

# 5.4 拼接最终链接
SS_LINK="ss://${AUTH_B64}@${HOST}:${PORT}#${REMARK}"

echo ""
echo "================================================"
echo -e "✅ ${GREEN}安装完成！${PLAIN}"
echo "================================================"
echo -e "IP 地址:  ${HOST}"
echo -e "端口:     ${PORT}"
echo -e "加密方式: ${METHOD}"
echo -e "密码:     ${PASSWORD}"
echo "================================================"
echo -e "🔗 SIP002 标准链接 (与你的示例格式一致):"
echo -e "${GREEN}${SS_LINK}${PLAIN}"
echo "================================================"
