#!/usr/bin/env bash
#
# ci/verify-deb.sh — 校验 CI 产出的 deb
#
set -euo pipefail
cd "$(dirname "$0")/.."

DEB=$(ls -1 packages/*.deb 2>/dev/null | head -1 || true)
[ -n "$DEB" ] || { echo "没有产出 deb" >&2; exit 1; }
echo "DEB: $DEB"
ls -la "$DEB"

echo "== deb 元数据 =="
dpkg-deb -f "$DEB"

echo "== 内容 =="
dpkg-deb -c "$DEB"

TMP=$(mktemp -d)
dpkg-deb -x "$DEB" "$TMP"

DYLIB="$TMP/Library/MobileSubstrate/DynamicLibraries/PetDFY.dylib"
[ -f "$DYLIB" ] || { echo "缺少 dylib" >&2; exit 1; }
echo "== 架构 =="
lipo -info "$DYLIB" || true
file "$DYLIB" || true

echo "== 注入过滤器 =="
cat "$TMP/Library/MobileSubstrate/DynamicLibraries/PetDFY.plist"

echo "== 设置面板 =="
[ -d "$TMP/Library/PreferenceBundles/PetDFYPrefs.bundle" ] || { echo "缺少 PetDFYPrefs.bundle" >&2; exit 1; }
ls "$TMP/Library/PreferenceBundles/PetDFYPrefs.bundle" | head

echo "== 素材 bundle 骨架 =="
[ -f "$TMP/Library/Application Support/PetDFY.bundle/Whale.metal" ] || echo "警告: 缺少 Whale.metal"

echo "== 修复点自检（符号/字符串）=="
if strings -a "$DYLIB" | grep -q "PetDFY.Import"; then echo "OK: 导入日志字符串存在"; else echo "警告: 未找到导入日志字符串"; fi
if strings -a "$DYLIB" | grep -q "AssetImports"; then echo "OK: AssetImports 路径存在"; else echo "警告: 未找到 AssetImports"; fi
if nm -gU "$DYLIB" 2>/dev/null | grep -qi "inflate"; then echo "OK: zlib inflate 已链接"; else echo "提示: 未在导出符号中看到 inflate（可能为静态内联）"; fi

echo "VERIFY OK"
