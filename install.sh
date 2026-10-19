#!/usr/bin/env bash
#
# ============================================================
#  One-Click Installer — cloudflared + x-tunnel
#  GitHub: https://github.com/caichengle666/x-tunnel
# ============================================================
#  Usage:
#    bash <(curl -sL https://raw.githubusercontent.com/<YOU>/install.sh)
#  or:
#    wget -qO- https://raw.githubusercontent.com/<YOU>/install.sh | bash
# ============================================================

set -euo pipefail

# -------------------- Color helpers --------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }
header()  { echo -e "\n${CYAN}${BOLD}═══════════════════════════════════════════${NC}"; echo -e "${CYAN}${BOLD}  $*${NC}"; echo -e "${CYAN}${BOLD}═══════════════════════════════════════════${NC}\n"; }

# -------------------- Pre-flight checks --------------------
if [[ $EUID -ne 0 ]]; then
    error "请使用 root 用户运行此脚本，或加 sudo"
    exit 1
fi

if ! command -v systemctl &>/dev/null; then
    error "当前系统不支持 systemd，无法创建服务"
    exit 1
fi

# -------------------- Architecture detection --------------------
detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)       echo "amd64" ;;
        aarch64|arm64)      echo "arm64" ;;
        armv7l|armv7)       echo "armv7" ;;
        armv6l|armv6)       echo "armv6" ;;
        i386|i686)          echo "386" ;;
        s390x)              echo "s390x" ;;
        mips64le)           echo "mips64le" ;;
        mips64)             echo "mips64" ;;
        mipsle)             echo "mipsle" ;;
        mips)               echo "mips" ;;
        riscv64)            echo "riscv64" ;;
        *)
            error "不支持的架构: $arch"
            exit 1
            ;;
    esac
}

ARCH=$(detect_arch)
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
info "检测到系统: ${OS}, 架构: ${ARCH}"

# -------------------- Generate random password --------------------
generate_password() {
    # 24 chars, alphanumeric + special
    tr -dc 'A-Za-z0-9_@#%&*+=' </dev/urandom | head -c 24 2>/dev/null || \
    openssl rand -base64 18 2>/dev/null || \
    date +%s%N | sha256sum | head -c 24
}

# ==================== Part 1: Install x-tunnel ====================
header "第一步: 安装 x-tunnel 内核"

XTUNNEL_BIN="/usr/local/bin/x-tunnel"
RELEASE_API="https://api.github.com/repos/caichengle666/x-tunnel/releases/latest"

info "正在从 GitHub 获取最新版本信息..."

# Get latest release tag
if command -v curl &>/dev/null; then
    LATEST_JSON=$(curl -sL "$RELEASE_API")
elif command -v wget &>/dev/null; then
    LATEST_JSON=$(wget -qO- "$RELEASE_API")
else
    error "需要 curl 或 wget，请先安装"
    exit 1
fi

LATEST_TAG=$(echo "$LATEST_JSON" | grep '"tag_name"' | head -1 | sed -E 's/.*"tag_name":\s*"([^"]+)".*/\1/')

if [[ -z "$LATEST_TAG" ]]; then
    error "无法获取最新版本号，请检查网络或 GitHub API 限制"
    echo "$LATEST_JSON" | head -20
    exit 1
fi

info "最新版本: ${LATEST_TAG}"

# Construct download URL — adapt the naming pattern to the actual release assets
DOWNLOAD_URL=""
ASSET_NAMES=(
    "x-tunnel-${OS}-${ARCH}"
    "x-tunnel_${OS}_${ARCH}"
    "x-tunnel-${ARCH}"
)

# Parse all asset download URLs from the release
ASSET_URLS=$(echo "$LATEST_JSON" | grep -o '"browser_download_url":\s*"[^"]*"' | sed 's/"browser_download_url":\s*"//;s/"$//')

if [[ -z "$ASSET_URLS" ]]; then
    error "未找到任何可下载的资源文件"
    exit 1
fi

info "可用的资源文件:"
echo "$ASSET_URLS" | while read -r url; do
    echo "  - $(basename "$url")"
done

# Try to match architecture
for name in "${ASSET_NAMES[@]}"; do
    matched_url=$(echo "$ASSET_URLS" | grep -i "$name" | head -1 || true)
    if [[ -n "$matched_url" ]]; then
        DOWNLOAD_URL="$matched_url"
        break
    fi
done

# Fallback: try matching just the arch keyword
if [[ -z "$DOWNLOAD_URL" ]]; then
    matched_url=$(echo "$ASSET_URLS" | grep -i "${ARCH}" | grep -iv '\.sha\|\.md5\|\.sig\|\.txt' | head -1 || true)
    if [[ -n "$matched_url" ]]; then
        DOWNLOAD_URL="$matched_url"
    fi
fi

if [[ -z "$DOWNLOAD_URL" ]]; then
    error "未找到适配 ${OS}-${ARCH} 的二进制文件"
    error "请手动下载: https://github.com/caichengle666/x-tunnel/releases/tag/${LATEST_TAG}"
    exit 1
fi

FILENAME=$(basename "$DOWNLOAD_URL")
info "即将下载: ${FILENAME}"
info "下载地址: ${DOWNLOAD_URL}"

# Download
TMP_DIR=$(mktemp -d)
TMP_FILE="${TMP_DIR}/${FILENAME}"

if command -v curl &>/dev/null; then
    curl -L --progress-bar -o "$TMP_FILE" "$DOWNLOAD_URL"
else
    wget --show-progress -O "$TMP_FILE" "$DOWNLOAD_URL"
fi

# Handle compressed files
if [[ "$FILENAME" == *.tar.gz ]] || [[ "$FILENAME" == *.tgz ]]; then
    info "解压 tar.gz 文件..."
    tar -xzf "$TMP_FILE" -C "$TMP_DIR"
    EXTRACTED_BIN=$(find "$TMP_DIR" -type f -name "x-tunnel*" ! -name "*.tar.gz" ! -name "*.tgz" | head -1)
    if [[ -z "$EXTRACTED_BIN" ]]; then
        EXTRACTED_BIN=$(find "$TMP_DIR" -type f -executable | head -1)
    fi
    if [[ -n "$EXTRACTED_BIN" ]]; then
        mv "$EXTRACTED_BIN" "$XTUNNEL_BIN"
    else
        error "解压后未找到可执行文件"
        exit 1
    fi
elif [[ "$FILENAME" == *.zip ]]; then
    info "解压 zip 文件..."
    unzip -o "$TMP_FILE" -d "$TMP_DIR" >/dev/null
    EXTRACTED_BIN=$(find "$TMP_DIR" -type f -name "x-tunnel*" ! -name "*.zip" | head -1)
    if [[ -z "$EXTRACTED_BIN" ]]; then
        EXTRACTED_BIN=$(find "$TMP_DIR" -type f -executable | head -1)
    fi
    if [[ -n "$EXTRACTED_BIN" ]]; then
        mv "$EXTRACTED_BIN" "$XTUNNEL_BIN"
    else
        error "解压后未找到可执行文件"
        exit 1
    fi
elif [[ "$FILENAME" == *.gz ]] && [[ "$FILENAME" != *.tar.gz ]]; then
    info "解压 gz 文件..."
    gunzip -c "$TMP_FILE" > "$XTUNNEL_BIN"
else
    # Assume raw binary
    mv "$TMP_FILE" "$XTUNNEL_BIN"
fi

chmod +x "$XTUNNEL_BIN"
rm -rf "$TMP_DIR"
info "x-tunnel 已安装到 ${XTUNNEL_BIN}"

# ==================== Part 2: Install cloudflared ====================
header "第二步: 安装 cloudflared"

if command -v apt-get &>/dev/null; then
    # Debian / Ubuntu — always configure Cloudflare's official apt repository.
    # This also ensures existing installations do not bypass the official package source.
    info "检测到 apt 包管理器，使用 Cloudflare 官方源安装..."

    mkdir -p --mode=0755 /usr/share/keyrings
    CLOUDFLARE_KEYRING="/usr/share/keyrings/cloudflare-main.gpg"
    CLOUDFLARE_KEY_URL="https://pkg.cloudflare.com/cloudflare-main.gpg"

    if command -v curl &>/dev/null; then
        curl -fsSL "$CLOUDFLARE_KEY_URL" | tee "$CLOUDFLARE_KEYRING" >/dev/null
    elif command -v wget &>/dev/null; then
        wget -qO- "$CLOUDFLARE_KEY_URL" | tee "$CLOUDFLARE_KEYRING" >/dev/null
    else
        error "需要 curl 或 wget 下载 Cloudflare GPG 密钥"
        exit 1
    fi
    chmod 0644 "$CLOUDFLARE_KEYRING"
    info "GPG 密钥已添加: ${CLOUDFLARE_KEYRING}"

    echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' > /etc/apt/sources.list.d/cloudflared.list
    info "Cloudflare 官方 apt 源已添加"

    apt-get update -qq
    apt-get install -y cloudflared
    info "cloudflared 已通过 Cloudflare 官方 apt 源安装完成（后续可通过 apt upgrade 更新）"
elif command -v cloudflared &>/dev/null; then
    # Non-apt Linux systems may already have cloudflared installed.
    info "cloudflared 已安装 ($(cloudflared --version 2>/dev/null || echo '未知版本'))，跳过安装"
else
    # 非 Debian 系统 — 回退到直接下载二进制文件
    warn "未检测到 apt，回退为直接下载二进制文件..."

    CLOUDFLARED_BIN="/usr/bin/cloudflared"
    case "$ARCH" in
        amd64) CF_ARCH="amd64" ;;
        arm64) CF_ARCH="arm64" ;;
        armv7) CF_ARCH="arm" ;;
        386)   CF_ARCH="386" ;;
        *)
            warn "cloudflared 可能不支持 ${ARCH} 架构，尝试下载..."
            CF_ARCH="$ARCH"
            ;;
    esac

    CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}"
    info "下载地址: ${CF_URL}"

    if command -v curl &>/dev/null; then
        curl -L --progress-bar -o "$CLOUDFLARED_BIN" "$CF_URL"
    else
        wget --show-progress -O "$CLOUDFLARED_BIN" "$CF_URL"
    fi

    chmod +x "$CLOUDFLARED_BIN"
    info "cloudflared 已安装到 ${CLOUDFLARED_BIN}"
fi
# 确认 cloudflared 路径
CLOUDFLARED_BIN=$(command -v cloudflared)
info "cloudflared 路径: ${CLOUDFLARED_BIN}"

# ==================== Part 3: Configure cf-tunnel.service ====================
header "第三步: 配置 cf-tunnel.service (cloudflared)"

CF_SERVICE_FILE="/etc/systemd/system/cf-tunnel.service"

echo ""
echo -e "${BOLD}请输入 cloudflared tunnel token:${NC}"
echo -e "${YELLOW}  (以 eyJ 开头的一长串字符)${NC}"
echo -e "${YELLOW}  直接按回车可跳过，稍后手动编辑配置文件${NC}"
echo ""
read -rp "Token: " CF_TOKEN

if [[ -z "$CF_TOKEN" ]]; then
    CF_TOKEN="YOUR_TOKEN_HERE"
    warn "已跳过 token 设置，请稍后手动编辑: ${CF_SERVICE_FILE}"
    warn "将 YOUR_TOKEN_HERE 替换为实际 token"
    NEED_MANUAL_CF=true
else
    NEED_MANUAL_CF=false
fi

cat > "$CF_SERVICE_FILE" <<EOF
[Unit]
Description=cloudflared
After=network-online.target
Wants=network-online.target

[Service]
TimeoutStartSec=15
Type=notify
ExecStart=/usr/bin/cloudflared --no-autoupdate tunnel run --token ${CF_TOKEN}
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

info "cf-tunnel.service 已创建"

# ==================== Part 4: Configure cf-x-tunnel.service ====================
header "第四步: 配置 cf-x-tunnel.service (x-tunnel)"

XTUNNEL_SERVICE_FILE="/etc/systemd/system/cf-x-tunnel.service"
DEFAULT_PORT="53393"

echo ""
echo -e "${BOLD}请输入 x-tunnel 监听端口:${NC}"
echo -e "${YELLOW}  默认端口: ${DEFAULT_PORT}，直接按回车使用默认值${NC}"
echo ""
read -rp "端口 [${DEFAULT_PORT}]: " XTUNNEL_PORT

if [[ -z "$XTUNNEL_PORT" ]]; then
    XTUNNEL_PORT="$DEFAULT_PORT"
fi

# Validate port number
if ! [[ "$XTUNNEL_PORT" =~ ^[0-9]+$ ]] || [[ "$XTUNNEL_PORT" -lt 1 ]] || [[ "$XTUNNEL_PORT" -gt 65535 ]]; then
    warn "端口号无效，将使用默认端口 ${DEFAULT_PORT}"
    XTUNNEL_PORT="$DEFAULT_PORT"
fi

echo ""
echo -e "${BOLD}请输入 x-tunnel 认证密码 (token):${NC}"
echo -e "${YELLOW}  直接按回车使用随机生成的安全密码${NC}"
echo ""
read -rp "密码 [随机生成]: " XTUNNEL_TOKEN

RANDOM_GENERATED=false
if [[ -z "$XTUNNEL_TOKEN" ]]; then
    XTUNNEL_TOKEN=$(generate_password)
    RANDOM_GENERATED=true
    info "已生成随机密码"
fi

cat > "$XTUNNEL_SERVICE_FILE" <<EOF
[Unit]
Description=X Tunnel Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/x-tunnel -l wss://0.0.0.0:${XTUNNEL_PORT} -token ${XTUNNEL_TOKEN}
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EOF

info "cf-x-tunnel.service 已创建"

# ==================== Part 5: Enable & Start services ====================
header "第五步: 启用并启动服务"

systemctl daemon-reload

# Enable services
systemctl enable cf-tunnel.service 2>/dev/null && info "cf-tunnel.service 已设为开机自启" || warn "cf-tunnel.service 设置开机自启失败"
systemctl enable cf-x-tunnel.service 2>/dev/null && info "cf-x-tunnel.service 已设为开机自启" || warn "cf-x-tunnel.service 设置开机自启失败"

# Start cf-x-tunnel (always start since it has a valid config)
systemctl start cf-x-tunnel.service && info "cf-x-tunnel.service 已启动" || warn "cf-x-tunnel.service 启动失败，请检查配置"

# Start cf-tunnel only if token was provided
if [[ "$NEED_MANUAL_CF" == false ]]; then
    systemctl start cf-tunnel.service && info "cf-tunnel.service 已启动" || warn "cf-tunnel.service 启动失败，请检查 token 是否正确"
else
    warn "cf-tunnel.service 未启动 (token 未设置)"
fi

# ==================== Summary ====================
header "安装完成 ✓"

echo -e "${BOLD}═══════════════════════════════════════════${NC}"
echo -e "${BOLD} 安装摘要${NC}"
echo -e "${BOLD}═══════════════════════════════════════════${NC}"
echo ""
echo -e "  ${GREEN}●${NC} cloudflared:    ${CLOUDFLARED_BIN}"
echo -e "  ${GREEN}●${NC} x-tunnel:       ${XTUNNEL_BIN}"
echo ""
echo -e "${BOLD}  服务状态:${NC}"
echo -e "  ├─ cf-tunnel.service      $(systemctl is-active cf-tunnel.service 2>/dev/null || echo 'inactive')"
echo -e "  └─ cf-x-tunnel.service    $(systemctl is-active cf-x-tunnel.service 2>/dev/null || echo 'inactive')"
echo ""
echo -e "${BOLD}  x-tunnel 配置:${NC}"
echo -e "  ├─ 监听地址:  wss://0.0.0.0:${XTUNNEL_PORT}"
echo -e "  └─ 认证密码:  ${CYAN}${BOLD}${XTUNNEL_TOKEN}${NC}"
if [[ "$RANDOM_GENERATED" == true ]]; then
    echo ""
    echo -e "  ${RED}${BOLD}⚠ 请妥善保存上述随机生成的密码！${NC}"
fi
echo ""
echo -e "${BOLD}═══════════════════════════════════════════${NC}"
echo -e "${BOLD} 服务配置文件位置${NC}"
echo -e "${BOLD}═══════════════════════════════════════════${NC}"
echo ""
echo -e "  cf-tunnel:    ${CF_SERVICE_FILE}"
echo -e "  cf-x-tunnel:  ${XTUNNEL_SERVICE_FILE}"
echo ""

if [[ "$NEED_MANUAL_CF" == true ]]; then
    echo -e "${YELLOW}${BOLD}═══════════════════════════════════════════${NC}"
    echo -e "${YELLOW}${BOLD} ⚠ 待办事项${NC}"
    echo -e "${YELLOW}${BOLD}═══════════════════════════════════════════${NC}"
    echo ""
    echo -e "  1. 编辑 ${CF_SERVICE_FILE}"
    echo -e "     将 ${RED}YOUR_TOKEN_HERE${NC} 替换为实际的 token"
    echo ""
    echo -e "  2. 重新加载并启动服务:"
    echo -e "     ${CYAN}systemctl daemon-reload${NC}"
    echo -e "     ${CYAN}systemctl restart cf-tunnel.service${NC}"
    echo ""
fi

echo -e "${BOLD}═══════════════════════════════════════════${NC}"
echo -e "${BOLD} 常用命令${NC}"
echo -e "${BOLD}═══════════════════════════════════════════${NC}"
echo ""
echo -e "  ${CYAN}# 查看服务状态${NC}"
echo -e "  systemctl status cf-tunnel.service"
echo -e "  systemctl status cf-x-tunnel.service"
echo ""
echo -e "  ${CYAN}# 查看服务日志${NC}"
echo -e "  journalctl -u cf-tunnel.service -f"
echo -e "  journalctl -u cf-x-tunnel.service -f"
echo ""
echo -e "  ${CYAN}# 重启服务${NC}"
echo -e "  systemctl restart cf-tunnel.service"
echo -e "  systemctl restart cf-x-tunnel.service"
echo ""
echo -e "  ${CYAN}# 停止服务${NC}"
echo -e "  systemctl stop cf-tunnel.service"
echo -e "  systemctl stop cf-x-tunnel.service"
echo ""
echo -e "  ${RED}# 手动修改配置文件后，务必执行:${NC}"
echo -e "  ${BOLD}systemctl daemon-reload${NC}"
echo -e "  ${BOLD}systemctl restart <服务名>${NC}"
echo ""
echo -e "${BOLD}═══════════════════════════════════════════${NC}"
echo -e "${BOLD} 卸载命令${NC}"
echo -e "${BOLD}═══════════════════════════════════════════${NC}"
echo ""
echo -e "  systemctl stop cf-tunnel.service cf-x-tunnel.service"
echo -e "  systemctl disable cf-tunnel.service cf-x-tunnel.service"
echo -e "  rm -f ${CF_SERVICE_FILE} ${XTUNNEL_SERVICE_FILE}"
echo -e "  rm -f ${CLOUDFLARED_BIN} ${XTUNNEL_BIN}"
echo -e "  systemctl daemon-reload"
echo ""
info "感谢使用！如有问题请提交 Issue 🎉"
