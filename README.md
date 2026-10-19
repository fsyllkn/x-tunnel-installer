# x-tunnel-installer

一键安装 cloudflared + x-tunnel 的自动化脚本。

## 快速使用

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/fsyllkn/x-tunnel-installer/main/install.sh)
```

## 功能

- 🔍 自动检测系统架构（amd64/arm64/armv7/armv6 等）
- 📦 从 [GitHub Releases](https://github.com/caichengle666/x-tunnel/releases) 拉取最新 x-tunnel 内核
- ☁️ Debian/Ubuntu 通过 Cloudflare 官方 APT 源安装或更新 cloudflared；其他系统使用官方二进制文件回退
- ⚙️ 交互式配置两个 systemd 服务：
  - `cf-tunnel.service` — cloudflared tunnel
  - `cf-x-tunnel.service` — x-tunnel
- 🔐 生成 32 位十六进制随机密码；手动输入密码仅允许字母、数字、`_` 和 `-`
- 🚀 启用并启动已配置的服务；未提供 Cloudflare token 时不会启用隧道服务

## 交互配置项

| 配置项 | 说明 | 默认值 |
|--------|------|--------|
| cloudflared token | Tunnel 认证令牌 | 可跳过，稍后手动填写 |
| x-tunnel 端口 | 本机监听端口 | `53393` |
| x-tunnel WebSocket 路径 | WebSocket 接口路径，需与 Cloudflare 公网路由和客户端连接路径一致 | `/tunnel` |
| x-tunnel 密码 | 认证密码 | 随机生成 32 位十六进制字符 |

## Cloudflare Tunnel 配置

安装脚本会让 x-tunnel 以普通 HTTP WebSocket（`ws://127.0.0.1`）监听本机回环地址；公网 TLS 由 Cloudflare 处理。Cloudflare Tunnel 的源站服务 URL 应填写：

```text
http://127.0.0.1:53393
```

Cloudflare 公网路由的路径、客户端连接 URL 的路径，必须与安装时填写的 x-tunnel WebSocket 路径一致。默认均为 `/tunnel`，例如客户端使用 `wss://你的域名/tunnel`。如果 Cloudflare 路由要继续使用 `/about`，安装时也把 x-tunnel 路径填为 `/about`，客户端路径也使用 `/about`。

不要把本机源站 URL 配成 `https://127.0.0.1:53393`：该安装配置在本机使用明文 HTTP，只有公网入口使用 HTTPS。

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
- 可交互的终端（脚本使用 `/dev/tty` 读取配置）

## 从本项目源码构建 x-tunnel

仓库根目录的 `x-tunnel.go` 是用户提供并与可用 Linux amd64 内核核对过的源码，包含客户端和服务端。以此文件为后续构建依据，首次纳入时未修改源码逻辑。

构建环境固定为 Go `1.26.0`、`CGO_ENABLED=0`；依赖固定在 `go.mod` / `go.sum`：

| 依赖 | 版本 |
|---|---|
| github.com/google/uuid | v1.6.0 |
| github.com/gorilla/websocket | v1.5.3 |
| github.com/xtaci/smux | v1.5.57 |

### 在 GitHub 网页构建

1. 打开本仓库 **Actions → Build x-tunnel → Run workflow**。
2. 等待构建成功，打开这次运行，下载页面底部的 `x-tunnel-linux-<提交 SHA>` 产物。
3. 解压后选择 `x-tunnel-linux-amd64`（普通 x86 VPS）或 `x-tunnel-linux-arm64`（ARM64 VPS）。

修改源码、依赖或构建文件并推送时，也会自动构建。产物保留 30 天，可随时重新运行。每个二进制附带 `.sha256` 和 `.buildinfo.txt`；CI 会检查代码、构建两种架构，并在 amd64 上验证帮助参数与 WSS 服务启动监听。此启动检查不代表已完成真实 Cloudflare 隧道端到端测试。

### 在本地构建

安装 Go 1.26.0，或安装支持自动下载工具链的 Go 1.21+；首次构建需能访问 Go 工具链与模块下载服务。

```bash
git clone https://github.com/fsyllkn/x-tunnel-installer.git
cd x-tunnel-installer
bash build.sh          # Linux amd64
bash build.sh arm64    # Linux arm64
bash build.sh all      # 同时构建两种架构
```

输出在 `dist/`。构建脚本使用 `-trimpath -buildvcs=false -ldflags='-s -w'`，不依赖系统 libc。它不向系统目录安装文件，也不启动服务。

### 使用已验证的构建产物安装

从 Actions 下载并解压本仓库的构建产物，在目标 VPS 上进入解压目录，以 amd64 为例：

```bash
sha256sum -c x-tunnel-linux-amd64.sha256
XTUNNEL_BINARY="$(pwd)/x-tunnel-linux-amd64" bash <(curl -fsSL https://raw.githubusercontent.com/fsyllkn/x-tunnel-installer/main/install.sh)
```

安装脚本会先验证指定二进制可执行，再原子替换已安装文件。ARM64 请将文件名改为 `x-tunnel-linux-arm64`。若不指定 `XTUNNEL_BINARY`，脚本仍下载上游 `caichengle666/x-tunnel` 的最新 Release；该上游版本在此前的 VPS 测试中无法启动，不应与本仓库构建产物混淆。Actions 产物没有自动发布为 Releases。

### 仅替换已安装的内核

在目标 VPS 上进入解压产物所在目录，以 amd64 为例：

```bash
sha256sum -c x-tunnel-linux-amd64.sha256
chmod +x x-tunnel-linux-amd64
./x-tunnel-linux-amd64 -h
STAGED_BIN=$(mktemp /usr/local/bin/x-tunnel.XXXXXXXX)
install -m 0755 x-tunnel-linux-amd64 "$STAGED_BIN"
mv -f "$STAGED_BIN" /usr/local/bin/x-tunnel
systemctl restart cf-x-tunnel.service
systemctl status cf-x-tunnel.service --no-pager -l
```

ARM64 请将文件名改为 `x-tunnel-linux-arm64`。合并后的安装脚本默认在本机以 `ws://127.0.0.1:53393/tunnel` 监听；替换内核后沿用该服务的 `ExecStart` 配置。

不指定 `XTUNNEL_BINARY` 而重新运行安装脚本会再次下载上游内核。

