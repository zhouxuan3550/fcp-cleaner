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
FEED_URL="https://zhouxuan3550.github.io/${REPO_NAME}/appcast.xml"
VERSION="${1:?用法: ./release.sh <版本号> <构建号>  例如 3.2.0 320}"
BUILD="${2:?用法: ./release.sh <版本号> <构建号>  例如 3.2.0 320}"
DMG_NAME="FCP-Cleaner-${VERSION}-universal.dmg"
STAGING_DIR="Distribution/dmg-staging-$(date +%Y%m%d)-v${BUILD}"
DERIVED_DATA="build/XcodeRelease"
PRODUCT_APP="${DERIVED_DATA}/Build/Products/Release/${APP_NAME}.app"
RELEASE_APP="build/release-product/${APP_NAME}.app"

if [ -d "/Library/Developer/SDKs/WorkflowExtensionSDK.sdk" ]; then
    WORKFLOW_EXTENSION_SDK_PATH="/Library/Developer/SDKs/WorkflowExtensionSDK.sdk"
elif [ -d "${HOME}/Library/Developer/SDKs/WorkflowExtensionSDK.sdk" ]; then
    WORKFLOW_EXTENSION_SDK_PATH="${HOME}/Library/Developer/SDKs/WorkflowExtensionSDK.sdk"
else
    echo "✗ 未安装 Apple Workflow Extension SDK"
    echo "  下载地址: https://developer.apple.com/download/all/?q=WorkflowExtensions"
    exit 1
fi

echo "═══════════════════════════════════════════════"
echo "  FCP Cleaner Release Build"
echo "  Version: ${VERSION}  Build: ${BUILD}"
echo "═══════════════════════════════════════════════"

# ─── 1. 运行测试 ───
echo ""
echo "▶ [1/7] 运行测试..."
swift test
echo "  ✓ 测试通过"

# ─── 2. 生成 Xcode 工程 ───
echo ""
echo "▶ [2/7] 生成 Xcode 工程..."
command -v xcodegen >/dev/null || {
    echo "  ✗ 需要先安装 XcodeGen: brew install xcodegen"
    exit 1
}
xcodegen generate --spec project.yml
echo "  ✓ 工程已生成"

# ─── 3. 构建完整 universal2 App ───
echo ""
echo "▶ [3/7] 构建 universal2 Release..."
rm -rf "${DERIVED_DATA}" "build/release-product"
xcodebuild \
    -project FCPLibraryCleaner.xcodeproj \
    -scheme FCP-Cleaner \
    -configuration Release \
    -derivedDataPath "${DERIVED_DATA}" \
    -destination 'generic/platform=macOS' \
    ARCHS='arm64 x86_64' \
    ONLY_ACTIVE_ARCH=NO \
    MARKETING_VERSION="${VERSION}" \
    CURRENT_PROJECT_VERSION="${BUILD}" \
    WORKFLOW_EXTENSION_SDK_PATH="${WORKFLOW_EXTENSION_SDK_PATH}" \
    CODE_SIGNING_ALLOWED=NO \
    build

if [ ! -x "${PRODUCT_APP}/Contents/MacOS/${EXECUTABLE}" ]; then
    echo "  ✗ 构建失败: 找不到完整 App 产物"
    exit 1
fi

# ─── 4. 验证嵌入组件和架构 ───
echo ""
echo "▶ [4/7] 验证构建产物..."
WORKFLOW_APPEX="${PRODUCT_APP}/Contents/PlugIns/FCP-Cleaner-Workflow.appex"
WORKFLOW_EXECUTABLE="${WORKFLOW_APPEX}/Contents/MacOS/FCP-Cleaner-Workflow"
if [ ! -x "${WORKFLOW_EXECUTABLE}" ]; then
    echo "  ✗ Workflow Extension 未嵌入"
    exit 1
fi
if ! nm -gU "${WORKFLOW_EXECUTABLE}" | grep -q '_ProExtensionMain'; then
    echo "  ✗ Workflow Extension 未链接 Apple ProExtension 启动代码"
    exit 1
fi
if [ ! -d "${PRODUCT_APP}/Contents/Resources/Metadata.appintents" ]; then
    echo "  ✗ App Intents 元数据未生成"
    exit 1
fi
if [ ! -f "${PRODUCT_APP}/Contents/Resources/FCP-Cleaner.icns" ]; then
    echo "  ✗ App 图标未嵌入"
    exit 1
fi
ICON_NAME=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "${PRODUCT_APP}/Contents/Info.plist")
if [ "${ICON_NAME%.icns}" != "FCP-Cleaner" ]; then
    echo "  ✗ CFBundleIconFile 与图标资源不一致: ${ICON_NAME}"
    exit 1
fi
for BINARY in "${PRODUCT_APP}/Contents/MacOS/${EXECUTABLE}" "${WORKFLOW_EXECUTABLE}"; do
    ARCHS_FOUND=$(lipo -archs "${BINARY}")
    if [[ " ${ARCHS_FOUND} " != *" arm64 "* || " ${ARCHS_FOUND} " != *" x86_64 "* ]]; then
        echo "  ✗ 非 universal2 二进制: ${BINARY} (${ARCHS_FOUND})"
        exit 1
    fi
done
echo "  ✓ 主程序、App 图标、Workflow Extension、App Intents 完整"

# ─── 5. 复制并签名完整 App ───
echo ""
echo "▶ [5/7] 代码签名..."
mkdir -p "$(dirname "${RELEASE_APP}")"
ditto "${PRODUCT_APP}" "${RELEASE_APP}"
xattr -cr "${RELEASE_APP}"

# 先签嵌套代码，最后签主 App，避免嵌入扩展签名失效。
if [ -d "${RELEASE_APP}/Contents/Frameworks/Sparkle.framework" ]; then
    codesign --force --deep --sign - "${RELEASE_APP}/Contents/Frameworks/Sparkle.framework"
fi
codesign --force --sign - \
    --entitlements WorkflowExtension/WorkflowExtension.entitlements \
    "${RELEASE_APP}/Contents/PlugIns/FCP-Cleaner-Workflow.appex"
codesign --force --sign - "${RELEASE_APP}"
codesign --verify --deep --strict --verbose=1 "${RELEASE_APP}"
echo "  ✓ 签名完成"

# ─── 6. 创建 DMG ───
echo ""
echo "▶ [6/7] 创建 DMG..."
# 只保留本次构建的 staging；历史安装包由 GitHub Releases 托管
find Distribution -maxdepth 1 -type d -name 'dmg-staging-*' -exec rm -rf {} +
rm -rf "${STAGING_DIR}"
mkdir -p "${STAGING_DIR}"
ditto "${RELEASE_APP}" "${STAGING_DIR}/${APP_NAME}.app"

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

# ─── 7. 生成 Appcast ───
echo ""
echo "▶ [7/7] 生成 Sparkle Appcast..."
UPDATES_DIR="Distribution/updates"
SPARKLE_TOOLS=$(find "${DERIVED_DATA}/SourcePackages/artifacts" .build/artifacts \
    -type d -path '*/Sparkle/bin' -print -quit 2>/dev/null || true)
if [ -x "${SPARKLE_TOOLS}/generate_appcast" ]; then
    rm -rf "${UPDATES_DIR}"
    mkdir -p "${UPDATES_DIR}"
    cp "Distribution/${DMG_NAME}" "${UPDATES_DIR}/"

    # 复用线上 feed，确保生成器是在历史条目上追加，而不是重建成单版本。
    curl --fail --silent --show-error --location \
        "${FEED_URL}" -o "${UPDATES_DIR}/appcast.xml" || true

    DOWNLOAD_PREFIX="https://github.com/zhouxuan3550/${REPO_NAME:-fcp-cleaner}/releases/download/v${VERSION}/"
    "${SPARKLE_TOOLS}/generate_appcast" \
        --maximum-versions 0 \
        --download-url-prefix "${DOWNLOAD_PREFIX}" \
        "${UPDATES_DIR}/"

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
