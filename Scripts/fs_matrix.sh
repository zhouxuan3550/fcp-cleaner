#!/bin/bash
set -uo pipefail

# ─── FCP Cleaner 多文件系统兼容矩阵 ───
# 在 APFS / HFS+ / ExFAT 稀疏镜像上各建一个最小 FCP 资源库，
# 用只读 CLI (fcp-library-scanner --json) 验证白名单分类结果一致。
#
# 用法：Scripts/fs_matrix.sh            （跑全部三种格式）
#       SKIP_FORMATS="HFS+" Scripts/fs_matrix.sh
#
# 注意：需要本机 hdiutil 挂载权限；脚本自身不删除任何用户数据。

VOL_SIZE_MB=64
BUNDLE_NAME="Matrix Lib.fcpbundle"
WORKDIR=$(mktemp -d /tmp/fcp-fsmatrix.XXXXXX)
trap 'for m in "${MOUNTS[@]:-}"; do hdiutil detach "$m" -quiet >/dev/null 2>&1; done; rm -rf "$WORKDIR"' EXIT

SKIP_FORMATS="${SKIP_FORMATS:-}"
FORMATS=()
[ "${SKIP_FORMATS#*APFS*}" = "$SKIP_FORMATS" ] && FORMATS+=("APFS")
[ "${SKIP_FORMATS#*HFS+*}" = "$SKIP_FORMATS" ] && FORMATS+=("HFS+")
[ "${SKIP_FORMATS#*ExFAT*}" = "$SKIP_FORMATS" ] && FORMATS+=("ExFAT")
if [ ${#FORMATS[@]} -eq 0 ]; then
    echo "✗ SKIP_FORMATS 过滤掉了全部格式，无事可做。"
    exit 1
fi

SCANNER="$(cd "$(dirname "$0")/.." && pwd)/.build/debug/fcp-library-scanner"
if [ ! -x "$SCANNER" ]; then
    echo "✗ 未找到 CLI：$SCANNER （先运行 swift build）"
    exit 1
fi

FAILED=0
# macOS 自带 bash 3.2 不支持 declare -A，用平行数组记录结果。
RESULT_FS=()
RESULT_MSG=()
record_result() { RESULT_FS+=("$1"); RESULT_MSG+=("$2"); }

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
        record_result "$fs" "SKIP(无法创建镜像)"; return 0
    fi
    if mount=$(hdiutil attach "$image" -nobrowse | awk '/\/Volumes\//{print $NF; exit}'); then
        :
    else
        record_result "$fs" "SKIP(无法挂载)"; return 0
    fi
    MOUNTS+=("$mount")

    seed_library "$mount"

    if ! json=$("$SCANNER" "$mount/$BUNDLE_NAME" --json --plan); then
        record_result "$fs" "FAIL(scanner 报错)"
        FAILED=1
    else
        items=$(python3 -c "import json,sys;d=json.load(sys.stdin);print(len(d.get('plan',{}).get('entries',d.get('cacheItems',[]))))" <<<"$json")
        # CleanupPlan 的 spaceToFree 是计算属性，JSON 里只有 entries；按条目求和断言。
        cleanable=$(python3 -c "import json,sys;d=json.load(sys.stdin);print(sum(e.get('item',{}).get('allocatedSize',0) for e in d.get('plan',{}).get('entries',[])))" <<<"$json")
        original_exists=$([ -f "$mount/$BUNDLE_NAME/Event One/Original Media/source.mov" ] && echo yes || echo no)

        if [ "$items" = "3" ] && [ "$cleanable" != "0" ] && [ "$original_exists" = "yes" ]; then
            record_result "$fs" "PASS(清理项=3)"
        else
            record_result "$fs" "FAIL(清理项=$items 可清空间=$cleanable 原片在=$original_exists)"
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
for i in "${!RESULT_FS[@]}"; do
    printf "%-10s %s\n" "${RESULT_FS[$i]}" "${RESULT_MSG[$i]}"
done

exit $FAILED
