#!/bin/bash
set -euo pipefail

# ─── FCP Cleaner appcast 发布闸门 ───
# 用途：把 appcast.xml 推上 gh-pages 之前的强制自检。
# 任一检查失败即退出非零——"发出坏更新源"必须在物理上不可能发生。
#
# 用法：Scripts/publish_appcast.sh <含appcast.xml和DMG的目录> <最新构建号>
# 示例：Scripts/publish_appcast.sh /tmp/fcp-appcast360 360

STAGING="${1:?用法: $0 <staging目录> <最新构建号>}"
EXPECTED_BUILD="${2:?用法: $0 <staging目录> <最新构建号>}"
APPCAST="${STAGING}/appcast.xml"

[ -f "$APPCAST" ] || { echo "✗ 缺少 ${APPCAST}"; exit 1; }

FAILED=0

python3 - "$APPCAST" "$EXPECTED_BUILD" <<'PY'
import re, sys, pathlib

appcast = pathlib.Path(sys.argv[1]).read_text()
expected_build = sys.argv[2].lstrip("v")
problems = []

items = re.findall(r"<item>.*?</item>", appcast, re.S)
if not items:
    problems.append("appcast 中没有任何 <item>")

builds = []
for index, item in enumerate(items, 1):
    enclosure = re.search(r"<enclosure\b[^>]*/?>", item)
    if not enclosure:
        problems.append(f"条目{index}: 缺少 enclosure 标签")
        continue
    tag = enclosure.group(0)

    if 'sparkle:edSignature="' not in tag:
        problems.append(f"条目{index}: 缺少 EdDSA 签名（sparkle:edSignature）")

    url_match = re.search(r'url="([^"]+)"', tag)
    if not url_match:
        problems.append(f"条目{index}: enclosure 缺少 url 属性")
        continue
    print(f"CHECK-URL {url_match.group(1)}")

    version = re.search(r"<sparkle:version>(\d+)</sparkle:version>", item)
    if not version:
        problems.append(f"条目{index}: 缺少 sparkle:version")
    else:
        builds.append(int(version.group(1)))

if builds and str(max(builds)) != expected_build:
    problems.append(
        f"最新 sparkle:version={max(builds)} 与期望构建号 {expected_build} 不一致"
    )

for problem in problems:
    print(f"GATE-FAIL {problem}", file=sys.stderr)
sys.exit(1 if problems else 0)
PY
[ $? -eq 0 ] || FAILED=1

# enclosure 可达性：跟随跳转后必须返回 200
while IFS= read -r url; do
    code=$(curl -sIL -o /dev/null -w "%{http_code}" --max-time 60 "$url")
    if [ "$code" != "200" ]; then
        echo "GATE-FAIL enclosure 不可下载 (HTTP $code): $url" >&2
        FAILED=1
    fi
done < <(grep -o 'CHECK-URL .*' <<< "$(python3 -c "
import re,sys,pathlib
print('\n'.join(re.findall(r'<enclosure[^>]*url=\"([^\"]+)\"', pathlib.Path(sys.argv[1]).read_text())))
" "$APPCAST")" | sed 's/^CHECK-URL //')

if [ "$FAILED" -ne 0 ]; then
    echo "✗ 发布闸门未通过，禁止推送 appcast。" >&2
    exit 1
fi
echo "✓ 发布闸门通过：签名齐全、全部 enclosure 可达、最新版本号匹配。"
