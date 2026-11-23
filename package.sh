#!/bin/bash
#
# package.sh — 把编译产物打成可安装 deb（无 theos 依赖）
#
# 用法：
#   ./package.sh <基础 deb>
#
# 说明：
#   本工程只包含 dylib 源码，不含设置面板（PreferenceBundle）源码。
#   设置面板与 Whale.metal / 素材 bundle 骨架从基础 deb 取，
#   用本次编译的 build/PetDFY.dylib 替换进去。
#
set -eu

BASE_DEB="${1:-}"
[ -n "$BASE_DEB" ] || { echo "用法: ./package.sh <基础 deb>" >&2; exit 2; }
[ -f "$BASE_DEB" ] || { echo "找不到基础 deb: $BASE_DEB" >&2; exit 2; }
[ -f build/PetDFY.dylib ] || { echo "先构建 build/PetDFY.dylib" >&2; exit 2; }

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

WORK="build/pkg"
rm -rf "$WORK"
mkdir -p "$WORK"

echo "== 解开基础 deb 作为骨架 =="
dpkg-deb -x "$BASE_DEB" "$WORK/layout"
dpkg-deb -e "$BASE_DEB" "$WORK/layout/DEBIAN"

# 防御：若骨架里出现 rootfs/ 前缀（某些打包方式会把 staging 目录一起打进 data.tar），
# 会导致设备上 dpkg 去创建 ./rootfs/... 而 RootHide 的 rootfs 只读，安装必失败。
if [ -d "$WORK/layout/rootfs" ]; then
  echo "!! layout 含 rootfs/ 前缀，展开到根目录后再打包"
  cp -R "$WORK/layout/rootfs/." "$WORK/layout/"
  rm -rf "$WORK/layout/rootfs"
fi

echo "== 替换 dylib =="
DL="$WORK/layout/Library/MobileSubstrate/DynamicLibraries"
mkdir -p "$DL"
cp -f build/PetDFY.dylib "$DL/PetDFY.dylib"

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

echo "== 签名 =="
if command -v ldid >/dev/null 2>&1; then
  ldid -S "$DL/PetDFY.dylib" && echo "ldid ok"
else
  echo "  警告: 未找到 ldid，跳过签名" >&2
fi

echo "== 修正设置面板的服装列表（4 套 -> 15 套） =="
PREFS_PLIST="$WORK/layout/Library/PreferenceBundles/PetDFYPrefs.bundle/Root.plist"
if [ -f "$PREFS_PLIST" ]; then
  python3 - "$PREFS_PLIST" <<'PY'
import plistlib, sys

path = sys.argv[1]
with open(path, "rb") as f:
    data = plistlib.load(f)

OUTFITS = [
    ("maid",          "女仆装"),
    ("cape",          "冬装"),
    ("crew",          "店员装"),
    ("sailor",        "JK 水手服"),
    ("miko",          "深海巫女"),
    ("dragon",        "幻月龙姬"),
    ("nurse",         "深海护士"),
    ("winter_deep",   "深海冬雪"),
    ("violet_winter", "紫月冬雪"),
    ("frost_dragon",  "霜龙冬眠"),
    ("formal",        "深海礼装"),
    ("starsea",       "星海少女"),
    ("eclipse",       "月蚀魔女"),
    ("night_gala",    "夜潮礼裙"),
    ("pale_nurse",    "霜华看护"),
]
values = [v for v, _ in OUTFITS]
titles = [t for _, t in OUTFITS]

changed = False
for item in data.get("items", []):
    if item.get("key") == "Outfit":
        item["validValues"] = values
        item["validTitles"] = titles
        changed = True

if not changed:
    print("  !! 没找到 Outfit 项，跳过")
    sys.exit(0)

with open(path, "wb") as f:
    plistlib.dump(data, f, fmt=plistlib.FMT_BINARY)
print(f"  Outfit 列表已扩展到 {len(values)} 套")
PY
else
  echo "  !! 未找到 PetDFYPrefs.bundle/Root.plist"
fi

echo "== 设置包架构标签 =="
# 设备侧 dpkg 只接受 iphoneos-arm64e；包内是 arm64 切片（arm64e 设备可正常加载）。
# 需要别的标签时用 PKG_ARCH 覆盖。
ARCH_SUFFIX="${PKG_ARCH:-arm64e}"
echo "  Architecture: iphoneos-${ARCH_SUFFIX}"
python3 - "$DL/PetDFY.dylib" <<'PY'
import struct, sys
d = open(sys.argv[1], "rb").read()
m = struct.unpack_from("<I", d, 0)[0]
if m == 0xBEBAFECA:
    n = struct.unpack_from(">I", d, 4)[0]
    subs = [hex(struct.unpack_from(">I", d, 8 + i * 20 + 4)[0]) for i in range(n)]
    print("  dylib slices:", subs)
else:
    print("  dylib thin subtype:", hex(struct.unpack_from("<I", d, 8)[0]))
PY

CTRL="$WORK/layout/DEBIAN/control"
if [ -f "$CTRL" ]; then
  sed -i "s/^Architecture:.*/Architecture: iphoneos-${ARCH_SUFFIX}/" "$CTRL"
  sed -i "s/^Version:.*/Version: 1.2.1-3/" "$CTRL" || true

  # 用仓库内 control 的展示字段覆盖骨架里的旧字段（Package/Depends 等保留骨架值）
  if [ -f control ]; then
    for key in Name Description Maintainer Author Section; do
      val=$(grep -m1 "^${key}:" control | sed "s/^${key}:[[:space:]]*//" || true)
      [ -n "${val:-}" ] || continue
      if grep -q "^${key}:" "$CTRL"; then
        # 用占位避免 sed 特殊字符问题
        python3 - "$CTRL" "$key" "$val" <<'PY'
import sys
path, key, val = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path, encoding="utf-8").read().splitlines()
out, done = [], False
for l in lines:
    if l.startswith(key + ":") and not done:
        out.append(f"{key}: {val}")
        done = True
    else:
        out.append(l)
open(path, "w", encoding="utf-8").write("\n".join(out) + "\n")
PY
      fi
    done
  fi

  echo "---- control ----"
  cat "$CTRL"
fi

echo "== 给 postinst 追加 jbroot 镜像逻辑（RootHide 注入路径兜底） =="
POSTINST="$WORK/layout/DEBIAN/postinst"
if [ -f "$POSTINST" ]; then
  python3 - "$POSTINST" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
extra = """
# --- PetDFY: 把 dylib 同时镜像进 jbroot，覆盖 RootHide 注入路径 ---
for real in /var/containers/Bundle/Application/.jbroot-* \\
            /var/containers/Bundle/Application/*/.jbroot-* \\
            /.jbroot-* /var/jb; do
  [ -d "$real" ] || continue
  [ -L "$real" ] && continue
  tgt="$real/Library/MobileSubstrate/DynamicLibraries"
  mkdir -p "$tgt" 2>/dev/null || continue
  cp -f /Library/MobileSubstrate/DynamicLibraries/PetDFY.dylib "$tgt/PetDFY.dylib" 2>/dev/null || true
  cp -f /Library/MobileSubstrate/DynamicLibraries/PetDFY.plist "$tgt/PetDFY.plist" 2>/dev/null || true
  echo "PetDFY: mirrored dylib into $tgt" >&2
done
"""
idx = s.rfind("exit 0")
if idx != -1:
    s = s[:idx] + extra + "\n" + s[idx:]
else:
    s = s + "\n" + extra
open(p, "w", encoding="utf-8").write(s)
print("  postinst patched")
PY
else
  echo "  警告: 没有 postinst，跳过" >&2
fi

echo "== 打包 =="
OUT="packages/out"
mkdir -p "$OUT"
DEB="$OUT/PetDFY_1.2.1_assetimport-fix_iphoneos-${ARCH_SUFFIX}.deb"
rm -f "$DEB"
dpkg-deb -bZxz "$WORK/layout" "$DEB"
echo "产物: $DEB"
ls -la "$DEB"
sha256sum "$DEB" 2>/dev/null || shasum -a 256 "$DEB"

# 给 workflow 用
mkdir -p packages
cp -f "$DEB" "packages/$(basename "$DEB")"
ls -la packages/
