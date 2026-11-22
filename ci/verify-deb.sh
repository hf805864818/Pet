#!/usr/bin/env bash
#
# ci/verify-deb.sh — 校验 CI 产出的 deb（Linux / macOS 均可运行）
#
set -euo pipefail
cd "$(dirname "$0")/.."

DEB=$(ls -1 packages/*.deb 2>/dev/null | head -1 || true)
[ -n "$DEB" ] || { echo "没有产出 deb" >&2; exit 1; }
echo "DEB: $DEB"
ls -la "$DEB"

echo "== deb 元数据 =="
dpkg-deb -f "$DEB"

echo "== 内容清单 =="
dpkg-deb -c "$DEB"

TMP=$(mktemp -d)
dpkg-deb -x "$DEB" "$TMP"

DYLIB="$TMP/Library/MobileSubstrate/DynamicLibraries/PetDFY.dylib"
[ -f "$DYLIB" ] || { echo "缺少 dylib" >&2; exit 1; }
echo "== dylib 大小 =="
ls -la "$DYLIB"

echo "== Mach-O 架构（fat 头解析）=="
python3 - "$DYLIB" <<'PY'
import struct, sys
p = sys.argv[1]
d = open(p, "rb").read()
magic = struct.unpack_from("<I", d, 0)[0]
if magic == 0xBEBAFECA:
    n = struct.unpack_from(">I", d, 4)[0]
    print(f"FAT nfat_arch={n}")
    names = {0x0100000C: "arm64", 0x01000007: "arm", 0x0000000C: "x86_64"}
    have = []
    for i in range(n):
        ct, cs, off, size, al = struct.unpack_from(">5I", d, 8 + i * 20)
        nm = names.get(ct, hex(ct))
        have.append(nm)
        print(f"  arch[{i}] {nm} subtype={hex(cs)} size={size}")
    if "arm64" not in have:
        print("FAIL: 缺少 arm64 切片"); sys.exit(1)
elif magic == 0xFEEDFACF:
    ct = struct.unpack_from("<I", d, 4)[0]
    print(f"thin mach-o cputype={hex(ct)}")
    if ct != 0x0100000C:
        print("FAIL: 不是 arm64"); sys.exit(1)
else:
    print(f"FAIL: 未知 magic {hex(magic)}"); sys.exit(1)
print("ARCH OK")
PY

echo "== 注入过滤器 =="
cat "$TMP/Library/MobileSubstrate/DynamicLibraries/PetDFY.plist"

echo "== 设置面板 =="
if [ -d "$TMP/Library/PreferenceBundles/PetDFYPrefs.bundle" ]; then
  ls "$TMP/Library/PreferenceBundles/PetDFYPrefs.bundle" | head
else
  echo "FAIL: 缺少 PetDFYPrefs.bundle" >&2; exit 1
fi

echo "== 素材 bundle 骨架 =="
[ -f "$TMP/Library/Application Support/PetDFY.bundle/Whale.metal" ] && echo "OK: Whale.metal" || echo "警告: 缺少 Whale.metal"

echo "== 修复点自检 =="
if strings -a "$DYLIB" | grep -q "PetDFY.Import"; then echo "OK: 导入日志字符串存在"; else echo "FAIL: 未找到导入日志字符串" >&2; exit 1; fi
if strings -a "$DYLIB" | grep -q "AssetImports"; then echo "OK: AssetImports 路径存在"; else echo "FAIL: 未找到 AssetImports" >&2; exit 1; fi
if strings -a "$DYLIB" | grep -q "asset-import-token"; then echo "OK: 去重标记字符串存在"; else echo "警告: 未找到 dedupe 标记"; fi

echo "VERIFY OK"