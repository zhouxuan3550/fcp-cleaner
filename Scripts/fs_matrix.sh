#!/bin/bash
set -uo pipefail

# ─── FCP Cleaner 多文件系统兼容矩阵 ───
# 在 APFS / HFS+ / ExFAT 稀疏镜像上各建一个最小 FCP 资源库，
# 用只读 CLI (fcp-library-scanner --dry-run --json) 验证白名单分类结果一致。
#
# 用法：Scripts/fs_matrix.sh            （跑全部三种格式）
#       SKIP_FORMATS="HFS+" Scripts/fs_matrix.sh
#
# 注意：需要本机 hdiutil 挂载权限；脚本自身不删除任何用户数据。

VOL_SIZE_MB=64
BUNDLE_NAME="Matrix Lib.fcpbundle"
WORKDIR=$(mktemp -d /tmp/fcp-fsmatrix.XXXXXX)
trap 'for m in "${MOUNTS[@]:-}"; do hdiutil detach "$m" -quiet >/dev/null 2>&1; done; rm -rf "$WORKDIR"' EXIT

FORMATS=()
[ "${SKIP_FORMATS#*APFS*}" = "$SKIP_FORMATS" ] && FORMATS+=("APFS")
[ "${SKIP_FORMATS#*HFS+*}" = "$SKIP_FORMATS" ] && FORMATS+=("HFS+")
[ "${SKIP_FORMATS#*ExFAT*}" = "$SKIP_FORMATS" ] && FORMATS+=("ExFAT")

SCANNER="$(cd "$(dirname "$0")/.." && pwd)/.build/debug/fcp-library-scanner"
if [ ! -x "$SCANNER" ]; then
    echo "✗ 未找到 CLI：$SCANNER （先运行 swift build）"
    exit 1
fi

FAILED=0
declare -A RESULTS

seed_library() {
    local root="$1/$BUNDLE_NAME"
    mkdir -p "$root/Event One/Render Files" \
             "$root/Event One/Transcoded Media/Proxy Media" \
             "$root/Event One/Transcoded Media/High Quality Media" \
             "$root/Event One/Original Media" \
             "$root/Event One/User Files/Render Files"
    printf 'db' > "$root/CurrentVersion.flexolibrary"
    printf 'db' > "$root/Event One/CurrentVersion.fcpevent"
    head -c 8192 /dev/zero > "$root/Event One/Render Files/render.mov"
    head -c 4096 /dev/zero > "$root/Event One/Transcoded Media/Proxy Media/proxy.mov"
    head -c 2048 /dev/zero > "$root/Event One/Transcoded Media/High Quality Media/optimized.mov"
    head -c 65536 /dev/zero > "$root/Event One/Original Media/source.mov"
}

run_format() {
    local fs="$1"
    local image="$WORKDIR/${fs//\//_}.sparseimage"
    local mount="" json items cleanable original

    echo "── $fs ──"
    if ! hdiutil create -size ${VOL_SIZE_MB}m -fs "$fs" -type SPARSE \
            -volname "FCP-Matrix-$fs" "$image" >/dev/null 2>&1; then
        RESULTS[$fs]="SKIP(无法创建镜像)"; return 0
    fi
    if mount=$(hdiutil attach "$image" -nobrowse -readonly off | awk '/\/Volumes\//{print $NF; exit}'); then
        :
    else
        RESULTS[$fs]="SKIP(无法挂载)"; return 0
    fi
    MOUNTS+=("$mount")

    seed_library "$mount"

    if ! json=$("$SCANNER" "$mount/$BUNDLE_NAME" --json); then
        RESULTS[$fs]="FAIL(scanner 报错)"
        FAILED=1
    else
        items=$(python3 -c "import json,sys;d=json.load(sys.stdin);print(len(d.get('plan',{}).get('entries',d.get('cacheItems',[]))))" <<<"$json")
        cleanable=$(python3 -c "import json,sys;d=json.load(sys.stdin);p=d.get('plan',{});print(p.get('spaceToFree', d.get('totalAllocatedSize',0)))" <<<"$json")
        original_exists=$([ -f "$mount/$BUNDLE_NAME/Event One/Original Media/source.mov" ] && echo yes || echo no)

        if [ "$items" = "3" ] && [ "$cleanable" != "0" ] && [ "$original_exists" = "yes" ]; then
            RESULTS[$fs]="PASS(清理项=3)"
        else
            RESULTS[$fs]="FAIL(清理项=$items 可清空间=$cleanable 原片在=$original_exists)"
            FAILED=1
        fi
    fi

    hdiutil detach "$mount" -quiet >/dev/null 2>&1 || true
}

echo "文件系统兼容矩阵（清理项应为 3，Original Media 必须原地存活）"
for fs in "${FORMATS[@]}"; do
    run_format "$fs"
done

echo ""
printf "%-10s %s\n" "格式" "结果"
for fs in "${FORMATS[@]}"; do
    printf "%-10s %s\n" "$fs" "${RESULTS[$fs]:-未执行}"
done

exit $FAILED
