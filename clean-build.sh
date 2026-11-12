#!/bin/bash
# clean-build.sh - 清理 mtk-t7xx-fix 的编译产物，保留源码
# 用法: ./clean-build.sh [--dry-run]

set -e

SRC_DIR="$(cd "$(dirname "$0")" && pwd)/src"
DRY_RUN=0

if [ "$1" = "--dry-run" ]; then
    DRY_RUN=1
fi

if [ ! -d "$SRC_DIR" ]; then
    echo "错误: 找不到 $SRC_DIR" >&2
    exit 1
fi

# 要删除的文件模式（相对于 src/）
PATTERNS=(
    "*.o"
    "*.ko"
    "*.mod"
    "*.mod.c"
    "modules.order"
    "Module.symvers"
    "*.cmd"
    ".mtk_t7xx.*"
)

# 先统计，再删除
count=0
for pat in "${PATTERNS[@]}"; do
    while IFS= read -r -d '' f; do
        if [ "$DRY_RUN" -eq 1 ]; then
            echo "[dry-run] 会删除: $f"
        else
            rm -f "$f"
            echo "已删除: $f"
        fi
        count=$((count + 1))
    done < <(find "$SRC_DIR" -maxdepth 1 -type f -name "$pat" -print0)
done

if [ "$DRY_RUN" -eq 1 ]; then
    echo "---"
    echo "共会删除 $count 个文件（dry-run，未实际删除）"
else
    echo "---"
    echo "共删除 $count 个文件"
    echo "保留的源码文件："
    ls "$SRC_DIR"/*.c "$SRC_DIR"/*.h "$SRC_DIR"/Makefile 2>/dev/null | sed 's|^|  |'
fi
