#!/bin/bash
set -euo pipefail

# ─── FCP Cleaner Release Build Script ───
# Usage: ./release.sh [VERSION] [BUILD]
# Example: ./release.sh 3.2.0 320

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="FCP Cleaner"
BUNDLE_ID="com.fcpcleaner.app"
EXECUTABLE="FCP-Cleaner"
REPO_NAME="fcp-cleaner"
BUNDLE_TEMPLATE="Distribution/${APP_NAME}.app"
PLIST="${BUNDLE_TEMPLATE}/Contents/Info.plist"

VERSION="${1:?用法: ./release.sh <版本号> <构建号>  例如 3.2.0 320}"
BUILD="${2:?用法: ./release.sh <版本号> <构建号>  例如 3.2.0 320}"
DMG_NAME="FCP-Cleaner-${VERSION}-universal.dmg"
STAGING_DIR="Distribution/dmg-staging-$(date +%Y%m%d)-v${BUILD}"

SPARKLE_TOOLS=".build/artifacts/sparkle/Sparkle/bin"

echo "═══════════════════════════════════════════════"
echo "  FCP Cleaner Release Build"
echo "  Version: ${VERSION}  Build: ${BUILD}"
echo "═══════════════════════════════════════════════"

# ─── 1. 运行测试 ───
echo ""
echo "▶ [1/8] 运行测试..."
swift test
echo "  ✓ 测试通过"

# ─── 2. 更新 Info.plist 版本号 ───
echo ""
echo "▶ [2/8] 更新版本号..."
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD}" "$PLIST"
echo "  ✓ ${VERSION} (${BUILD})"

# ─── 3. 构建 universal2 Release ───
echo ""
echo "▶ [3/8] 构建 universal2 Release..."
swift build -c release --product "${EXECUTABLE}" --arch arm64 --arch x86_64

BUILD_DIR=".build/apple/Products/Release"
if [ ! -f "${BUILD_DIR}/${EXECUTABLE}" ]; then
    echo "  ✗ 构建失败: 找不到 ${BUILD_DIR}/${EXECUTABLE}"
    exit 1
fi

ARCH_CHECK=$(file "${BUILD_DIR}/${EXECUTABLE}")
echo "  架构: ${ARCH_CHECK}"
if ! echo "$ARCH_CHECK" | grep -q "universal"; then
    echo "  ✗ 不是 universal 二进制!"
    exit 1
fi
echo "  ✓ universal2 构建成功"

# ─── 4. 组装 App Bundle ───
echo ""
echo "▶ [4/8] 组装 App Bundle..."

# 清理旧的构建产物
rm -rf "${BUNDLE_TEMPLATE}/Contents/MacOS"
rm -rf "${BUNDLE_TEMPLATE}/Contents/Frameworks"
rm -rf "${BUNDLE_TEMPLATE}/Contents/Resources"
rm -rf "${BUNDLE_TEMPLATE}/_CodeSignature"

mkdir -p "${BUNDLE_TEMPLATE}/Contents/MacOS"
mkdir -p "${BUNDLE_TEMPLATE}/Contents/Frameworks"
mkdir -p "${BUNDLE_TEMPLATE}/Contents/Resources"

# 复制可执行文件
cp "${BUILD_DIR}/${EXECUTABLE}" "${BUNDLE_TEMPLATE}/Contents/MacOS/${EXECUTABLE}"

# 复制 Sparkle.framework (universal)
SPARKLE_FW="${BUILD_DIR}/Sparkle.framework"
if [ ! -d "$SPARKLE_FW" ]; then
    echo "  ✗ 找不到 Sparkle.framework"
    exit 1
fi
cp -R "$SPARKLE_FW" "${BUNDLE_TEMPLATE}/Contents/Frameworks/Sparkle.framework"

# 复制图标
cp "Assets/FCP-Cleaner.icns" "${BUNDLE_TEMPLATE}/Contents/Resources/FCP-Cleaner.icns"

echo "  ✓ App Bundle 组装完成"

# ─── 5. 设置 rpath ───
echo ""
echo "▶ [5/8] 设置 rpath..."
install_name_tool -add_rpath '@executable_path/../Frameworks' \
    "${BUNDLE_TEMPLATE}/Contents/MacOS/${EXECUTABLE}" 2>/dev/null || true
echo "  ✓ rpath 已设置"

# ─── 6. 签名 ───
echo ""
echo "▶ [6/8] 代码签名..."
xattr -cr "${BUNDLE_TEMPLATE}"
codesign --force --deep --sign - "${BUNDLE_TEMPLATE}"
codesign --verify --deep --strict --verbose=1 "${BUNDLE_TEMPLATE}"
echo "  ✓ 签名完成"

# ─── 7. 创建 DMG ───
echo ""
echo "▶ [7/8] 创建 DMG..."
# 只保留本次构建的 staging；历史安装包由 GitHub Releases 托管
find Distribution -maxdepth 1 -type d -name 'dmg-staging-*' -exec rm -rf {} +
rm -rf "${STAGING_DIR}"
mkdir -p "${STAGING_DIR}"
cp -R "${BUNDLE_TEMPLATE}" "${STAGING_DIR}/${APP_NAME}.app"

# 创建 Applications 软链接
ln -s /Applications "${STAGING_DIR}/Applications"

# 删除旧 DMG
rm -f "Distribution/${DMG_NAME}"

hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${STAGING_DIR}" \
    -ov \
    -format UDZO \
    "Distribution/${DMG_NAME}"

DMG_SIZE=$(du -h "Distribution/${DMG_NAME}" | cut -f1)
echo "  ✓ DMG 创建完成: Distribution/${DMG_NAME} (${DMG_SIZE})"

# ─── 8. 生成 Appcast ───
echo ""
echo "▶ [8/8] 生成 Sparkle Appcast..."
UPDATES_DIR="Distribution/updates"
if [ -x "${SPARKLE_TOOLS}/generate_appcast" ]; then
    rm -rf "${UPDATES_DIR}"
    mkdir -p "${UPDATES_DIR}"
    cp "Distribution/${DMG_NAME}" "${UPDATES_DIR}/"

    DOWNLOAD_PREFIX="https://github.com/zhouxuan3550/${REPO_NAME:-fcp-cleaner}/releases/download/v${VERSION}/"
    "${SPARKLE_TOOLS}/generate_appcast" --download-url-prefix "${DOWNLOAD_PREFIX}" "${UPDATES_DIR}/"

    if [ -f "${UPDATES_DIR}/appcast.xml" ]; then
        # 复制到 Distribution 根目录供 publish.sh 使用
        cp "${UPDATES_DIR}/appcast.xml" "Distribution/appcast.xml"
        echo "  ✓ appcast.xml 已生成"
    else
        echo "  ⚠ appcast.xml 未生成（可能需要配置 EdDSA 密钥）"
    fi
else
    echo "  ⚠ generate_appcast 工具不可用，跳过 appcast 生成"
    echo "    运行 swift build 后工具会出现在 ${SPARKLE_TOOLS}/"
fi

# ─── 完成 ───
echo ""
echo "═══════════════════════════════════════════════"
echo "  ✓ 构建完成!"
echo "  DMG: Distribution/${DMG_NAME}"
echo "  版本: ${VERSION} (${BUILD})"
echo "  架构: universal2 (arm64 + x86_64)"
echo "═══════════════════════════════════════════════"
echo ""
echo "后续步骤:"
echo "  1. 测试 DMG: 双击挂载并安装到 Applications"
echo "  2. 发布 DMG 到 GitHub Releases"
echo "  3. 更新 appcast.xml 到 gh-pages 分支"
