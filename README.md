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
- **无损更新**：「更新版本」保留现有配置；已是最新版本时不下载、不重启。
- **时间校准**：启用系统 NTP 服务 (systemd-timesyncd / chrony)，不修改时区。
- **防火墙适配**：自动放行 UFW 或 Firewall-cmd 端口，修改端口或卸载时自动清理旧规则。

## 🚀 快速开始 (Usage)

在你的 VPS 终端中执行以下命令即可：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Lukk4a/ss2022-rust/main/install.sh)
```

> ⚠️ 请使用上面的 `bash <(curl ...)` 形式运行，不要写成 `curl ... | bash`：脚本是交互式的，需要从终端读取输入。

运行后在菜单中选择 `1` 安装。安装完成后会输出 `ss://` 链接，复制到客户端导入即可。

### 云服务商安全组

脚本只会修改服务器本机的防火墙 (UFW / firewalld)。如果你的 VPS 有云服务商的**安全组 / 防火墙规则**，请在控制台中手动放行所选端口的 **TCP 和 UDP**。

### 可选环境变量

| 变量 | 作用 | 示例 |
|---|---|---|
| `SS_VERSION` | 指定安装版本，跳过联网获取最新版本 | `SS_VERSION=v1.21.2` |
| `GH_PROXY` | GitHub 下载镜像前缀 (纯 IPv6 机器无法直连 GitHub 时使用) | `GH_PROXY=https://mirror.example.com/` |

```bash
SS_VERSION=v1.21.2 GH_PROXY=https://mirror.example.com/ bash <(curl -fsSL https://raw.githubusercontent.com/Lukk4a/ss2022-rust/main/install.sh)
```

> 使用 `GH_PROXY` 时，程序和 SHA256 校验文件都经由镜像下载，请只使用你信任的镜像。

## 🗑️ 卸载

再次运行脚本，在菜单中选择 `3. 卸载服务`。会停止并删除服务、程序、配置文件、`shadowsocks` 运行用户，并清理防火墙规则。

## 📝 注意事项

- **时间同步**：SS-2022 要求客户端与服务器时间误差在 30 秒以内，连不上时先检查两端时间。
- **非 root 运行 (v3.0 起)**：服务以 `shadowsocks` 用户运行。从旧版本升级的机器，执行一次「更新版本」即可自动迁移。
- **链接格式 (v3.0 起)**：`ss://` 链接按 SIP002 规范使用百分号编码的明文 `method:password`，极老的客户端可能无法识别。
- **IPv6**：内核禁用 IPv6 的机器会自动改为仅监听 IPv4 (`0.0.0.0`)。
- **CentOS 7 等老系统**：systemd 版本过低 (< 229) 时不支持 `AmbientCapabilities`，非 root 运行无法监听 1024 以下端口，请使用 1024 以上的端口。
