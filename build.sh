#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

target=${1:-amd64}
case "$target" in
    amd64|arm64) targets=("$target") ;;
    all) targets=(amd64 arm64) ;;
    *) echo '用法: bash build.sh [amd64|arm64|all]' >&2; exit 2 ;;
esac
command -v go >/dev/null || { echo '请先安装 Go 1.26.0（或支持自动工具链下载的 Go 1.21+）' >&2; exit 1; }
export GOTOOLCHAIN=go1.26.0 CGO_ENABLED=0 GOOS=linux GOAMD64=v1
go mod download
go mod verify
mkdir -p dist
for arch in "${targets[@]}"; do
    output="dist/x-tunnel-linux-${arch}"
    GOARCH="$arch" go build -mod=readonly -trimpath -buildvcs=false -ldflags='-s -w' -o "$output" ./x-tunnel.go
    go version -m "$output" > "${output}.buildinfo.txt"
    (cd dist && sha256sum "x-tunnel-linux-${arch}" > "x-tunnel-linux-${arch}.sha256")
    echo "构建完成: $output"
done
