#!/bin/bash
#
# package.sh — 把编译产物打成可安装 deb
#
# 用法：
#   ./package.sh <基础 deb>
#
# 说明：
#   本工程只包含 dylib 源码，不含设置面板（PreferenceBundle）源码。
#   设置面板与 Whale.metal / 素材 bundle 骨架需要从基础 deb 里取，
#   因此这里接受一个基础 deb 作为骨架，用本次编译的 PetDFY.dylib 替换进去。
#
#   基础 deb 建议用能正常导入素材的那份（PetDFY_1.2.1_RootHide.deb），
#   这样设置面板的“从文件导入 ZIP”行为与真机验证过的一致。
#
set -eu

BASE_DEB="${1:-}"
[ -n "$BASE_DEB" ] || { echo "用法: ./package.sh <基础 deb>" >&2; exit 2; }
[ -f "$BASE_DEB" ] || { echo "找不到基础 deb: $BASE_DEB" >&2; exit 2; }
[ -f build/PetDFY.dylib ] || { echo "先运行 ./build.sh 生成 build/PetDFY.dylib" >&2; exit 2; }

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

WORK="build/pkg"
rm -rf "$WORK"
mkdir -p "$WORK"

echo "== 解开基础 deb 作为骨架 =="
dpkg-deb -x "$BASE_DEB" "$WORK/layout"
dpkg-deb -e "$BASE_DEB" "$WORK/layout/DEBIAN"

echo "== 替换 dylib =="
DL="$WORK/layout/Library/MobileSubstrate/DynamicLibraries"
mkdir -p "$DL"
cp -f build/PetDFY.dylib "$DL/PetDFY.dylib"

# 注入过滤器（若基础包没带）
if [ ! -f "$DL/PetDFY.plist" ]; then
  cat > "$DL/PetDFY.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Filter</key>
	<dict>
		<key>Bundles</key>
		<array><string>com.apple.springboard</string></array>
	</dict>
</dict>
</plist>
PLIST
fi

echo "== 签名（ldid adhoc） =="
if command -v ldid >/dev/null 2>&1; then
  ldid -S "$DL/PetDFY.dylib"
else
  echo "  警告: 未找到 ldid，跳过签名" >&2
fi

echo "== 修正 control =="
CTRL="$WORK/layout/DEBIAN/control"
if [ -f "$CTRL" ]; then
  # 保留基础包元数据，只确保架构与版本可辨识
  sed -i '' 's/^Architecture:.*/Architecture: iphoneos-arm64e/' "$CTRL" 2>/dev/null || \
  sed -i 's/^Architecture:.*/Architecture: iphoneos-arm64e/' "$CTRL"
fi

echo "== 打包 =="
OUT="packages/out"
mkdir -p "$OUT"
DEB="$OUT/PetDFY_1.2.1_assetimport-fix_iphoneos-arm64e.deb"
dpkg-deb -bZxz "$WORK/layout" "$DEB"
echo "产物: $DEB"
ls -la "$DEB"
shasum -a 256 "$DEB" || sha256sum "$DEB"
