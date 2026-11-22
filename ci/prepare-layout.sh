#!/usr/bin/env bash
#
# ci/prepare-layout.sh — 为 theos 打包准备 layout/
#
# 本工程只含主 dylib 源码；设置面板（PetDFYPrefs.bundle）、Whale.metal、
# 素材 bundle 骨架来自参考包。CI 里从 vendor/base/ 的 deb 解出 layout，
# 再删掉其中的旧 dylib（由本次编译产物替代）。
#
set -euo pipefail
cd "$(dirname "$0")/.."

BASE="vendor/base/PetDFY_1.2.1_RootHide.deb"
[ -f "$BASE" ] || { echo "缺少 $BASE" >&2; exit 2; }

rm -rf layout
mkdir -p layout
dpkg-deb -x "$BASE" layout

# 清掉骨架里的旧 dylib / plist，避免和 theos 产物冲突
rm -f  layout/Library/MobileSubstrate/DynamicLibraries/PetDFY.dylib
rm -f  layout/Library/MobileSubstrate/DynamicLibraries/PetDFY.plist

# 旧版的设置面板入口保留（指向 PetDFYPrefs.bundle）
ls -la layout/Library/PreferenceBundles/PetDFYPrefs.bundle/ | head -20

# 素材 bundle 里不要带用户导入的素材（防泄漏体积）
rm -rf "layout/Library/Application Support/PetDFY.bundle/originals" || true
rm -rf "layout/Library/Application Support/PetDFY.bundle/live" || true
rm -rf "layout/Library/Application Support/PetDFY.bundle/.asset-state" || true

echo "layout prepared:"; du -sh layout
