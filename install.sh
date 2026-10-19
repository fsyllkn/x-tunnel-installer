#!/usr/bin/env bash
#
# ============================================================
#  One-Click Installer — cloudflared + x-tunnel
#  GitHub: https://github.com/fsyllkn/x-tunnel-installer
# ============================================================
#  Usage:
#    bash <(curl -fsSL https://raw.githubusercontent.com/fsyllkn/x-tunnel-installer/main/install.sh)
#  or:
#    wget -qO- https://raw.githubusercontent.com/fsyllkn/x-tunnel-installer/main/install.sh | bash
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

if [[ ! -r /dev/tty ]]; then
    error "交互式安装需要终端，请在终端内运行脚本"
    exit 1
fi

mkdir -p /usr/local/bin

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
if [[ "$OS" != linux ]]; then
    error "安装脚本仅支持 Linux"
    exit 1
fi
info "检测到系统: ${OS}, 架构: ${ARCH}"

# -------------------- Generate random password --------------------
generate_password() {
    # 16 random bytes encoded as 32 safe hexadecimal characters.
    if command -v od &>/dev/null; then
        od -An -N16 -tx1 /dev/urandom | tr -d '[:space:]'
    elif command -v openssl &>/dev/null; then
        openssl rand -hex 16
    else
        error "需要 od 或 openssl 生成随机密码"
        return 1
    fi
}

# ==================== Part 1: Install x-tunnel ====================
header "第一步: 安装 x-tunnel 内核"

XTUNNEL_BIN="/usr/local/bin/x-tunnel"
# Pinned to the build that matches the user-provided working amd64 binary.
RELEASE_TAG="verified-d219c34"

if [[ -n "${XTUNNEL_BINARY:-}" ]]; then
    if [[ ! -f "$XTUNNEL_BINARY" ]]; then
        error "指定的 x-tunnel 二进制文件不存在: ${XTUNNEL_BINARY}"
        exit 1
    fi
    EXTRACTED_BIN="$XTUNNEL_BINARY"
    info "使用本地 x-tunnel 二进制文件: ${EXTRACTED_BIN}"
else
    case "$ARCH" in
        amd64) EXPECTED_SHA256="ae3a79a4d2a6a8d7e1377afb2e022c5ed75b0157a694fb6aead9d86ab873ccc2" ;;
        arm64) EXPECTED_SHA256="18b08c599c717696f44a540da6af039c5d0efaf4112679d2a04c9122d077f047" ;;
        *)
            error "已验证的 Release 暂无 ${ARCH} 产物；请自行构建并通过 XTUNNEL_BINARY 指定本地二进制"
            exit 1
            ;;
    esac

    if ! command -v sha256sum &>/dev/null; then
        error "需要 sha256sum 验证下载的二进制文件"
        exit 1
    fi
    TMP_DIR=$(mktemp -d)
    trap 'rm -rf "$TMP_DIR"; if [[ -n "${STAGED_BIN:-}" ]]; then rm -f "$STAGED_BIN"; fi' EXIT
    EXTRACTED_BIN="${TMP_DIR}/x-tunnel-linux-${ARCH}"
    DOWNLOAD_URL="https://github.com/fsyllkn/x-tunnel-installer/releases/download/${RELEASE_TAG}/x-tunnel-linux-${ARCH}"
    info "下载本项目已验证的 ${ARCH} 构建产物: ${DOWNLOAD_URL}"
    if command -v curl &>/dev/null; then
        curl -fL --retry 3 --progress-bar -o "$EXTRACTED_BIN" "$DOWNLOAD_URL"
    elif command -v wget &>/dev/null; then
        wget --show-progress -O "$EXTRACTED_BIN" "$DOWNLOAD_URL"
    else
        error "需要 curl 或 wget 下载 x-tunnel"
        exit 1
    fi
    printf '%s  %s\n' "$EXPECTED_SHA256" "$EXTRACTED_BIN" | sha256sum -c - || {
        error "下载文件 SHA-256 不符，拒绝安装"
        exit 1
    }
fi

# Stage in the destination directory, then rename atomically even if the old binary is running.
STAGED_BIN=$(mktemp "${XTUNNEL_BIN}.XXXXXXXX")
install -m 0755 "$EXTRACTED_BIN" "$STAGED_BIN"
if ! "$STAGED_BIN" -h >/dev/null 2>&1; then
    error "x-tunnel 二进制文件无法在当前系统执行，原安装文件未替换"
    exit 1
fi
mv -f -- "$STAGED_BIN" "$XTUNNEL_BIN"
STAGED_BIN=""
if [[ -n "${TMP_DIR:-}" ]]; then
    rm -rf "$TMP_DIR"
fi
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
    CLOUDFLARED_PACKAGE_BIN=$(dpkg-query -L cloudflared 2>/dev/null | grep -m1 -E '/(s?bin)/cloudflared$' || true)
    if [[ -n "$CLOUDFLARED_PACKAGE_BIN" && ! -x "$CLOUDFLARED_PACKAGE_BIN" ]]; then
        warn "APT 记录 cloudflared 已安装，但包内可执行文件缺失或不可执行，正在修复..."
        apt-get install --reinstall -y cloudflared
    else
        apt-get install -y cloudflared
    fi
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

    CF_TMP_BIN=$(mktemp)

    if command -v curl &>/dev/null; then
        curl -fL --progress-bar -o "$CF_TMP_BIN" "$CF_URL"
    else
        wget --show-progress -O "$CF_TMP_BIN" "$CF_URL"
    fi

    CF_STAGED_BIN=$(mktemp "${CLOUDFLARED_BIN}.XXXXXXXX")
    install -m 0755 "$CF_TMP_BIN" "$CF_STAGED_BIN"
    rm -f "$CF_TMP_BIN"
    if ! "$CF_STAGED_BIN" --version >/dev/null 2>&1; then
        error "cloudflared 二进制文件无法在当前系统执行"
        exit 1
    fi
    mv -f -- "$CF_STAGED_BIN" "$CLOUDFLARED_BIN"
    info "cloudflared 已安装到 ${CLOUDFLARED_BIN}"
fi

# 检测 cloudflared 的实际可执行文件路径，供 systemd 服务使用
if ! CLOUDFLARED_PATH=$(command -v cloudflared); then
    error "安装后找不到 cloudflared 可执行文件，请检查软件包安装结果"
    exit 1
fi
CLOUDFLARED_BIN=$(readlink -f "$CLOUDFLARED_PATH")
if [[ ! -x "$CLOUDFLARED_BIN" ]]; then
    error "cloudflared 文件不可执行: ${CLOUDFLARED_BIN}"
    exit 1
fi
info "cloudflared 路径: ${CLOUDFLARED_BIN}"

# ==================== Part 3: Configure cf-tunnel.service ====================
header "第三步: 配置 cf-tunnel.service (cloudflared)"

CF_SERVICE_FILE="/etc/systemd/system/cf-tunnel.service"

echo ""
echo -e "${BOLD}请输入 cloudflared tunnel token:${NC}"
echo -e "${YELLOW}  (以 eyJ 开头的一长串字符)${NC}"
echo -e "${YELLOW}  直接按回车可跳过，稍后手动编辑配置文件${NC}"
echo ""
read -rp "Token: " CF_TOKEN </dev/tty || { error "无法从终端读取 Cloudflare token"; exit 1; }

if [[ -z "$CF_TOKEN" ]]; then
    CF_TOKEN="YOUR_TOKEN_HERE"
    warn "已跳过 token 设置，请稍后手动编辑: ${CF_SERVICE_FILE}"
    warn "将 YOUR_TOKEN_HERE 替换为实际 token"
    NEED_MANUAL_CF=true
else
    if ! [[ "$CF_TOKEN" =~ ^[A-Za-z0-9._+/=-]+$ ]]; then
        error "Cloudflare token 格式无效，请只输入 token，不要粘贴整条安装命令"
        exit 1
    fi
    NEED_MANUAL_CF=false
fi

cat > "$CF_SERVICE_FILE" <<EOF
[Unit]
Description=cloudflared
After=network-online.target
Wants=network-online.target

[Service]
TimeoutStartSec=0
Type=notify
ExecStart="${CLOUDFLARED_BIN}" --no-autoupdate tunnel run --token ${CF_TOKEN}
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
read -rp "端口 [${DEFAULT_PORT}]: " XTUNNEL_PORT </dev/tty || { error "无法从终端读取端口"; exit 1; }

if [[ -z "$XTUNNEL_PORT" ]]; then
    XTUNNEL_PORT="$DEFAULT_PORT"
fi

# Validate port number
if ! [[ "$XTUNNEL_PORT" =~ ^[0-9]+$ ]] || [[ "$XTUNNEL_PORT" -lt 1 ]] || [[ "$XTUNNEL_PORT" -gt 65535 ]]; then
    warn "端口号无效，将使用默认端口 ${DEFAULT_PORT}"
    XTUNNEL_PORT="$DEFAULT_PORT"
fi

# The verified source has no Web GUI handler; its "/" handler accepts /about as well.
DEFAULT_PATH="/"
echo ""
echo -e "${BOLD}请输入 x-tunnel WebSocket 路径:${NC}"
echo -e "${YELLOW}  默认根路径 / 可接收 Cloudflare 转发的 /about 等路径${NC}"
echo ""
read -rp "路径 [${DEFAULT_PATH}]: " XTUNNEL_PATH </dev/tty || { error "无法从终端读取 WebSocket 路径"; exit 1; }

if [[ -z "$XTUNNEL_PATH" ]]; then
    XTUNNEL_PATH="$DEFAULT_PATH"
fi

if ! [[ "$XTUNNEL_PATH" =~ ^(/|(/[A-Za-z0-9._~-]+)+)$ ]]; then
    warn "路径格式无效，将使用默认路径 ${DEFAULT_PATH}"
    XTUNNEL_PATH="$DEFAULT_PATH"
fi

XTUNNEL_LISTEN_ADDR="ws://127.0.0.1:${XTUNNEL_PORT}${XTUNNEL_PATH}"

echo ""
echo -e "${BOLD}请输入 x-tunnel 认证密码 (token):${NC}"
echo -e "${YELLOW}  直接按回车使用随机生成的安全密码${NC}"
echo ""
read -rp "密码 [随机生成]: " XTUNNEL_TOKEN </dev/tty || { error "无法从终端读取认证密码"; exit 1; }

RANDOM_GENERATED=false
if [[ -z "$XTUNNEL_TOKEN" ]]; then
    XTUNNEL_TOKEN=$(generate_password)
    RANDOM_GENERATED=true
    info "已生成随机密码"
fi

if ! [[ "$XTUNNEL_TOKEN" =~ ^[A-Za-z0-9_-]+$ ]]; then
    error "x-tunnel 密码只能包含字母、数字、下划线和连字符（WebSocket 子协议格式限制）"
    exit 1
fi

cat > "$XTUNNEL_SERVICE_FILE" <<EOF
[Unit]
Description=X Tunnel Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${XTUNNEL_BIN} -l ${XTUNNEL_LISTEN_ADDR} -token ${XTUNNEL_TOKEN}
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
if [[ "$NEED_MANUAL_CF" == false ]]; then
    systemctl enable cf-tunnel.service 2>/dev/null && info "cf-tunnel.service 已设为开机自启" || warn "cf-tunnel.service 设置开机自启失败"
else
    systemctl stop cf-tunnel.service 2>/dev/null || true
    systemctl disable cf-tunnel.service 2>/dev/null || true
    warn "未设置 Cloudflare token，cf-tunnel.service 已停止且未启用开机自启"
fi
systemctl enable cf-x-tunnel.service 2>/dev/null && info "cf-x-tunnel.service 已设为开机自启" || warn "cf-x-tunnel.service 设置开机自启失败"

# Start cf-x-tunnel (always start since it has a valid config)
systemctl restart cf-x-tunnel.service && info "cf-x-tunnel.service 已启动" || warn "cf-x-tunnel.service 启动失败，请检查配置"

# Start cf-tunnel only if token was provided
if [[ "$NEED_MANUAL_CF" == false ]]; then
    systemctl restart cf-tunnel.service && info "cf-tunnel.service 已启动" || warn "cf-tunnel.service 启动失败，请检查 token 是否正确"
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
echo -e "  ├─ cf-tunnel.service      $(systemctl is-active cf-tunnel.service 2>/dev/null || true)"
echo -e "  └─ cf-x-tunnel.service    $(systemctl is-active cf-x-tunnel.service 2>/dev/null || true)"
echo ""
echo -e "${BOLD}  x-tunnel 配置:${NC}"
echo -e "  ├─ 监听地址:  ${XTUNNEL_LISTEN_ADDR}"
echo -e "  ├─ Cloudflare 源站 URL: http://127.0.0.1:${XTUNNEL_PORT}"
echo -e "  ├─ 本机 WebSocket 路径: ${XTUNNEL_PATH}"
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
    echo -e "     ${CYAN}systemctl enable --now cf-tunnel.service${NC}"
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
