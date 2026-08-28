#!/bin/bash
set -euo pipefail

# ─── FCP Cleaner GitHub 发布脚本 ───
# 将 DMG 发布到 GitHub Releases，将 appcast.xml 推送到 gh-pages
#
# 前置条件:
#   1. 已运行 ./release.sh 完成构建
#   2. gh CLI 已登录
#   3. 本地 git remote 已配置（首次运行会自动创建仓库）
#
# 用法: ./publish.sh [VERSION]
# 例如: ./publish.sh 3.2.0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="FCP Cleaner"
REPO_NAME="fcp-cleaner"
GITHUB_USER="zhouxuan3550"
REMOTE_URL="https://github.com/${GITHUB_USER}/${REPO_NAME}.git"
FEED_URL="https://${GITHUB_USER}.github.io/${REPO_NAME}/appcast.xml"

VERSION="${1:?用法: ./publish.sh <版本号>  例如 3.2.0}"
DMG_NAME="FCP-Cleaner-${VERSION}-universal.dmg"
DMG_PATH="Distribution/${DMG_NAME}"

if [ ! -f "$DMG_PATH" ]; then
    echo "✗ 找不到 DMG: ${DMG_PATH}"
    echo "  请先运行: ./release.sh ${VERSION} <构建号>"
    exit 1
fi

echo "═══════════════════════════════════════════════"
echo "  FCP Cleaner 发布"
echo "  版本: ${VERSION}"
echo "  DMG:  ${DMG_PATH}"
echo "═══════════════════════════════════════════════"

# ─── 1. 检查 gh CLI ───
echo ""
echo "▶ [1/5] 检查 GitHub CLI..."
if ! command -v gh &>/dev/null; then
    echo "  ✗ 需要安装 gh CLI: brew install gh"
    exit 1
fi
gh auth status >/dev/null 2>&1 || { echo "  ✗ gh 未登录"; exit 1; }
echo "  ✓ gh CLI 就绪"

# ─── 2. 确保远程仓库存在 ───
echo ""
echo "▶ [2/5] 检查远程仓库..."
if ! gh repo view "${GITHUB_USER}/${REPO_NAME}" &>/dev/null; then
    echo "  创建仓库 ${GITHUB_USER}/${REPO_NAME}..."
    gh repo create "${GITHUB_USER}/${REPO_NAME}" \
        --public \
        --description "FCP Cleaner - 安全清理 Final Cut Pro 渲染/代理/优化媒体" \
        --homepage "https://${GITHUB_USER}.github.io/${REPO_NAME}"
    echo "  ✓ 仓库已创建"
else
    echo "  ✓ 仓库已存在"
fi

# 配置 git remote
if ! git remote get-url origin &>/dev/null; then
    git remote add origin "$REMOTE_URL"
    echo "  ✓ remote origin 已添加"
elif [ "$(git remote get-url origin)" != "$REMOTE_URL" ]; then
    echo "  ⚠ origin 指向 $(git remote get-url origin)"
    echo "    预期: ${REMOTE_URL}"
    read -p "  是否更新 remote? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        git remote set-url origin "$REMOTE_URL"
        echo "  ✓ remote 已更新"
    fi
fi

# ─── 3. 推送源码 ───
echo ""
echo "▶ [3/5] 推送源码到 GitHub..."
git push -u origin main 2>/dev/null || echo "  (源码已是最新)"
echo "  ✓ 源码已同步"

# ─── 4. 发布 DMG 到 GitHub Releases ───
echo ""
echo "▶ [4/5] 发布 DMG 到 GitHub Releases..."
TAG="v${VERSION}"

if gh release view "$TAG" &>/dev/null; then
    echo "  Release ${TAG} 已存在，上传 DMG..."
    gh release upload "$TAG" "$DMG_PATH" --clobber
else
    echo "  创建 Release ${TAG}..."
    gh release create "$TAG" \
        --title "FCP Cleaner ${VERSION}" \
        --notes "FCP Cleaner ${VERSION}

- universal2 构建 (arm64 + x86_64)
- 最低系统要求: macOS 15.0
- 打开 DMG 后将应用拖入 Applications 文件夹安装" \
        "$DMG_PATH"
fi
echo "  ✓ DMG 已发布"

# 获取 DMG 下载 URL
DMG_URL=$(gh release view "$TAG" --json assets -q ".assets[] | select(.name==\"${DMG_NAME}\") | .url")
echo "  下载链接: ${DMG_URL}"

# ─── 5. 推送 appcast.xml 到 gh-pages ───
echo ""
echo "▶ [5/5] 更新 GitHub Pages (appcast.xml)..."

APPCAST_PATH="Distribution/appcast.xml"
if [ ! -f "$APPCAST_PATH" ]; then
    echo "  ⚠ appcast.xml 不存在，跳过 gh-pages 更新"
    echo "    运行 release.sh 时会自动生成 appcast.xml"
    echo ""
    echo "  手动生成: .build/artifacts/sparkle/Sparkle/bin/generate_appcast Distribution/"
else
    # 防止构建机缺少旧 feed 时，用单版本 appcast 覆盖完整历史。
    REMOTE_APPCAST=$(mktemp)
    if curl --fail --silent --show-error --location "${FEED_URL}" -o "${REMOTE_APPCAST}"; then
        LOCAL_ITEMS=$(grep -c '<item>' "${APPCAST_PATH}" || true)
        REMOTE_ITEMS=$(grep -c '<item>' "${REMOTE_APPCAST}" || true)
        if [ "${LOCAL_ITEMS}" -lt "${REMOTE_ITEMS}" ]; then
            echo "  ✗ 本地 appcast 条目少于线上版本，拒绝覆盖 (${LOCAL_ITEMS} < ${REMOTE_ITEMS})"
            rm -f "${REMOTE_APPCAST}"
            exit 1
        fi
    fi
    rm -f "${REMOTE_APPCAST}"

    # 创建临时目录用于 gh-pages 内容
    PAGES_DIR=$(mktemp -d)
    trap "rm -rf $PAGES_DIR" EXIT

    # 检查 gh-pages 分支是否存在
    if git ls-remote --heads origin gh-pages | grep -q gh-pages; then
        git worktree add -f "$PAGES_DIR" gh-pages
    else
        git worktree add --orphan -b gh-pages "$PAGES_DIR"
        # 清空目录
        rm -rf "${PAGES_DIR:?}"/*
        rm -rf "${PAGES_DIR}"/.[!.]*
    fi

    # 复制 appcast.xml
    cp "$APPCAST_PATH" "${PAGES_DIR}/appcast.xml"

    # 创建简单的 index.html
    cat > "${PAGES_DIR}/index.html" <<'HTMLEOF'
<!DOCTYPE html>
<html lang="zh">
<head>
<meta charset="utf-8">
<title>FCP Cleaner Updates</title>
<style>
body { font-family: -apple-system, system-ui, sans-serif; max-width: 600px; margin: 80px auto; padding: 0 20px; color: #333; }
h1 { font-size: 1.5em; }
a { color: #0066cc; }
</style>
</head>
<body>
<h1>FCP Cleaner</h1>
<p>安全清理 Final Cut Pro 渲染文件、代理媒体和优化媒体。</p>
<p><a href="appcast.xml">Sparkle Appcast</a></p>
</body>
</html>
HTMLEOF

    # 提交并推送
    (
        cd "$PAGES_DIR"
        git add -A
        git commit -m "Update appcast for v${VERSION}" --allow-empty
        git push origin gh-pages
    )

    # 清理 worktree
    git worktree remove "$PAGES_DIR" --force
    trap - EXIT

    echo "  ✓ appcast.xml 已推送到 gh-pages"
    echo "  更新 Feed: ${FEED_URL}"
fi

# ─── 完成 ───
echo ""
echo "═══════════════════════════════════════════════"
echo "  ✓ 发布完成!"
echo ""
echo "  DMG:      ${DMG_URL}"
echo "  Appcast:  ${FEED_URL}"
echo "  Release:  https://github.com/${GITHUB_USER}/${REPO_NAME}/releases/tag/v${VERSION}"
echo "═══════════════════════════════════════════════"
