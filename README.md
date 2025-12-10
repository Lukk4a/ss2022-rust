# Shadowsocks-2022 (Rust) 一键安装脚本

这是一个专为 Linux VPS 设计的 Shell 脚本，用于快速部署 **Shadowsocks-Rust** 服务端。支持最新的 **Shadowsocks-2022** 协议，性能更强，安全性更高。

## ✨ 功能特点

- **自动部署**：自动检测架构 (x86_64/aarch64) 并下载最新版 `shadowsocks-rust` 二进制文件。
- **协议支持**：支持 SS-2022 核心算法：
  - `2022-blake3-aes-128-gcm` (默认，推荐)
  - `2022-blake3-aes-256-gcm`
  - `2022-blake3-chacha20-poly1305`
- **交互配置**：支持自定义端口、自定义密钥（自动校验长度）或全自动生成。
- **链接生成**：安装完成后自动输出 `ss://` 链接，客户端一键复制导入。
- **服务守护**：自动配置 Systemd 服务，支持开机自启与后台运行。
- **防火墙适配**：自动放行 UFW 或 Firewall-cmd 端口。

## 🚀 快速开始 (Usage)

在你的 VPS 终端中执行以下命令即可：

```bash
bash <(curl -sL https://raw.githubusercontent.com/Lukk4a/ss2022-rust/main/install.sh)
