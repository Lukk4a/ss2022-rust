# Shadowsocks-2022 (Rust) 一键安装脚本

这是一个专为 Linux VPS 设计的 Shell 脚本，用于快速部署 **Shadowsocks-Rust** 服务端。支持最新的 **Shadowsocks-2022** 协议，性能更强，安全性更高。

## ✨ 功能特点

- **自动部署**：自动检测架构 (x86_64/aarch64)，下载最新版 `shadowsocks-rust` musl 静态构建，并校验 SHA256。
- **协议支持**：支持 SS-2022 核心算法：
  - `2022-blake3-aes-128-gcm` (默认，推荐)
  - `2022-blake3-aes-256-gcm`
  - `2022-blake3-chacha20-poly1305`
- **交互配置**：支持自定义端口、自定义密钥或全自动生成；密钥会校验是否为 base64 编码且解码后恰好 16/32 字节。
- **链接生成**：安装完成后自动输出符合 SIP002 规范的 `ss://` 链接，客户端一键复制导入。
- **服务守护**：自动配置 Systemd 服务，以非 root 用户 `shadowsocks` 运行，支持开机自启与后台运行。
- **无损更新**：「更新版本」只替换程序并重启服务，保留现有配置。
- **时间校准**：启用系统 NTP 服务 (systemd-timesyncd / chrony)，不修改时区。
- **防火墙适配**：自动放行 UFW 或 Firewall-cmd 端口，修改端口或卸载时自动清理旧规则。

## 🚀 快速开始 (Usage)

在你的 VPS 终端中执行以下命令即可：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Lukk4a/ss2022-rust/main/install.sh)
