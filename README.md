# x-tunnel-installer
# x-tunnel-installer

一键安装 cloudflared + x-tunnel 的自动化脚本。

## 快速使用

```bash
bash <(curl -sL https://raw.githubusercontent.com/fsyllkn/x-tunnel-installer/main/install.sh)
```

## 功能

- 🔍 自动检测系统架构（amd64/arm64/armv7/armv6 等）
- 📦 从 [GitHub Releases](https://github.com/caichengle666/x-tunnel/releases) 拉取最新 x-tunnel 内核
- ☁️ Debian/Ubuntu 通过 Cloudflare 官方 APT 源安装或更新 cloudflared；其他系统使用官方二进制文件回退
- ⚙️ 交互式配置两个 systemd 服务：
  - `cf-tunnel.service` — cloudflared tunnel
  - `cf-x-tunnel.service` — x-tunnel
- 🔐 支持随机密码生成
- 🚀 自动启用开机自启并启动服务

## 交互配置项

| 配置项 | 说明 | 默认值 |
|--------|------|--------|
| cloudflared token | Tunnel 认证令牌 | 可跳过，稍后手动填写 |
| x-tunnel 端口 | 本机监听端口 | `53393` |
| x-tunnel WebSocket 路径 | WebSocket 接口路径，需与 Cloudflare 公网路由和客户端连接路径一致 | `/tunnel` |
| x-tunnel 密码 | 认证密码 | 随机生成 24 位 |

## Cloudflare Tunnel 配置

安装脚本会让 x-tunnel 以普通 HTTP WebSocket（`ws://127.0.0.1`）监听本机回环地址；公网 TLS 由 Cloudflare 处理。Cloudflare Tunnel 的源站服务 URL 应填写：

```text
http://localhost:53393
```

Cloudflare 公网路由的路径、客户端连接 URL 的路径，必须与安装时填写的 x-tunnel WebSocket 路径一致。默认均为 `/tunnel`，例如客户端使用 `wss://你的域名/tunnel`。如果 Cloudflare 路由要继续使用 `/about`，安装时也把 x-tunnel 路径填为 `/about`，客户端路径也使用 `/about`。

不要把本机源站 URL 配成 `https://localhost:53393`：该安装配置在本机使用明文 HTTP，只有公网入口使用 HTTPS。

## 常用命令

```bash
# 查看服务状态
systemctl status cf-tunnel.service
systemctl status cf-x-tunnel.service

# 查看日志
journalctl -u cf-tunnel.service -f
journalctl -u cf-x-tunnel.service -f

# 重启服务
systemctl restart cf-tunnel.service
systemctl restart cf-x-tunnel.service

# ⚠️ 手动修改配置文件后务必执行
systemctl daemon-reload
systemctl restart <服务名>
```

## 卸载

```bash
systemctl stop cf-tunnel.service cf-x-tunnel.service
systemctl disable cf-tunnel.service cf-x-tunnel.service
rm -f /etc/systemd/system/cf-tunnel.service /etc/systemd/system/cf-x-tunnel.service
rm -f /usr/bin/cloudflared /usr/local/bin/x-tunnel
systemctl daemon-reload
```

## 系统要求

- Linux（支持 systemd）
- root 权限
- curl 或 wget
