#!/usr/bin/env bash
# icloudctl 安装脚本：把命令装到 PATH，并确保可执行权限。
#
#   ./install.sh              # 装到 ~/.local/bin
#   ./install.sh /usr/local/bin   # 装到指定目录（可能需要 sudo）

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/icloudctl"
DEST_DIR="${1:-$HOME/.local/bin}"

if [ ! -f "$SRC" ]; then
    echo "找不到 icloudctl（期望在 $SRC）" >&2
    exit 1
fi

mkdir -p "$DEST_DIR"

if [ -w "$DEST_DIR" ]; then
    ln -sf "$SRC" "$DEST_DIR/icloudctl"
    echo "[✓] 已安装: $DEST_DIR/icloudctl"
else
    echo "需要写权限: $DEST_DIR" >&2
    echo "试试: sudo ./install.sh $DEST_DIR" >&2
    exit 1
fi

# 提示 PATH
case ":$PATH:" in
    *":$DEST_DIR:"*) ;;
    *)
        echo
        echo "[!] $DEST_DIR 不在 PATH 中，请把下面这行加到 shell 配置里："
        echo
        echo "    export PATH=\"$DEST_DIR:\$PATH\""
        echo
        ;;
esac

echo
echo "验证:"
echo "    icloudctl doctor"
echo
echo "用法:"
echo "    icloudctl off    # 关闭 iCloud 同步"
echo "    icloudctl on     # 打开 iCloud 同步"
