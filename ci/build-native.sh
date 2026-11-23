#!/usr/bin/env bash
#
# ci/build-native.sh — 不依赖 theos，用 clang + ld64.lld 交叉编译 iOS tweak
#
#   ARCHS 可指定，默认 "arm64 arm64e"。
#   arm64e 需要 clang 与 ld64.lld 同版本（否则 ptrauth 重定位报 INVALID relocation）。
#   拼 fat 用脚本自行完成（llvm-lipo 对 arm64/arm64e 子类型判定不稳）。
#
set -euo pipefail
cd "$(dirname "$0")/.."

: "${IOS_SDK:?IOS_SDK 未设置（指向 iPhoneOS*.sdk 目录）}"
MIN_IOS="${MIN_IOS:-15.0}"
ARCHS="${ARCHS:-arm64 arm64e}"
CC="${CC:-clang}"

[ -d "$IOS_SDK" ] || { echo "IOS_SDK 不存在: $IOS_SDK" >&2; exit 2; }
command -v ld64.lld >/dev/null || { echo "缺少 ld64.lld" >&2; exit 2; }

FRAMEWORKS="-framework Foundation -framework UIKit -framework Metal -framework MetalKit \
-framework MetalPerformanceShaders -framework QuartzCore -framework AVFoundation \
-framework CoreMotion -framework AudioToolbox -framework CoreGraphics \
-framework Security -framework ImageIO -lz"

echo "SDK: $IOS_SDK"
echo "clang: $($CC --version | head -1)"
echo "ld64.lld: $(ld64.lld --version 2>&1 | head -1 || echo unknown)"
echo "ARCHS: $ARCHS"

hdr() {
  python3 - "$1" <<'PY'
import struct, sys
d = open(sys.argv[1], "rb").read(32)
m = struct.unpack_from("<I", d, 0)[0]
if m == 0xFEEDFACF:
    ct, cs = struct.unpack_from("<II", d, 4)
    names = {0x0100000C: "arm64"}
    print(f"  {sys.argv[1]}: cputype={hex(ct)} subtype={hex(cs)}")
elif m == 0xBEBAFECA:
    print(f"  {sys.argv[1]}: FAT")
else:
    print(f"  {sys.argv[1]}: magic={hex(m)}")
PY
}

FILES=$(find src -name '*.m' | sort)
echo "源文件数: $(echo "$FILES" | wc -l)"

mkdir -p build
SLICES=""

for ARCH in $ARCHS; do
    OBJ="build/obj-$ARCH"
    rm -rf "$OBJ"; mkdir -p "$OBJ"
    echo "===== 编译 $ARCH ====="
    for f in $FILES; do
        o="$OBJ/$(echo "$f" | tr '/' '_').o"
        $CC -target "${ARCH}-apple-ios${MIN_IOS}" -isysroot "$IOS_SDK" \
            -fobjc-arc -O2 -Wno-everything \
            -I src -I src/Core -I src/Sources \
            -c "$f" -o "$o"
    done
    echo "--- 目标文件头（首个 .o）---"
    hdr "$(ls "$OBJ"/*.o | head -1)"

    echo "===== 链接 $ARCH ====="
    OUT="build/PetDFY.$ARCH.dylib"
    if $CC -target "${ARCH}-apple-ios${MIN_IOS}" -isysroot "$IOS_SDK" \
        -dynamiclib -fuse-ld=lld \
        -install_name /Library/MobileSubstrate/DynamicLibraries/PetDFY.dylib \
        -Wl,-undefined,dynamic_lookup \
        $FRAMEWORKS \
        -o "$OUT" "$OBJ"/*.o ; then
        echo "链接 OK: $ARCH"
        # ld64.lld 会把 arm64e 输出写成 subtype=0（而 .o 是 subtype=0x2，确为 arm64e ABI）。
        # 按 Apple ld64 的约定规范化为 0x80000002（arm64e + ptrauth ABI v0），
        # 否则打包架构只能是 iphoneos-arm64，arm64e 设备需用 Patcher 改包才能装。
        if [ "$ARCH" = "arm64e" ]; then
            python3 - "$OUT" <<'PY'
import struct, sys
p = sys.argv[1]
d = bytearray(open(p, "rb").read())
ct, cs = struct.unpack_from("<II", d, 4)
if ct == 0x0100000C and cs != 0x80000002:
    struct.pack_into("<I", d, 8, 0x80000002)
    open(p, "wb").write(bytes(d))
    print(f"  normalized subtype: {hex(cs)} -> 0x80000002")
else:
    print(f"  subtype already {hex(cs)}")
PY
        fi
        hdr "$OUT"
        SLICES="$SLICES $OUT"
    else
        echo "WARN: $ARCH 链接失败，跳过" >&2
        rm -f "$OUT"
    fi
done

[ -n "$SLICES" ] || { echo "所有切片均链接失败" >&2; exit 1; }

echo "===== 组装 fat（自行构造，不依赖 lipo 的子类型判定）====="
# shellcheck disable=SC2086
python3 - build/PetDFY.dylib $SLICES <<'PY'
import struct, sys, os

out = sys.argv[1]
inputs = sys.argv[2:]

slices = []
for p in inputs:
    d = open(p, "rb").read()
    ct, cs = struct.unpack_from("<II", d, 4)
    slices.append({"path": p, "ct": ct, "cs": cs, "data": d})
    print(f"  slice {os.path.basename(p)}: cputype={hex(ct)} subtype={hex(cs)} size={len(d)}")

# 去重：同 (ct,cs) 只保留一个；arm64e(0x80000002) 优先
uniq = {}
for s in slices:
    key = (s["ct"], s["cs"])
    if key in uniq:
        print(f"  跳过重复架构 {key}: {os.path.basename(s['path'])}")
        continue
    uniq[key] = s

if len(uniq) == 1:
    only = list(uniq.values())[0]
    open(out, "wb").write(only["data"])
    print(f"  单切片输出 -> {out}")
    sys.exit(0)

ALIGN = 14
align_bytes = 1 << ALIGN
entries = list(uniq.values())
header_size = 8 + 20 * len(entries)

offset = header_size
offsets = []
for s in entries:
    pad = (-offset) % align_bytes
    offset += pad
    offsets.append(offset)
    offset += len(s["data"])

buf = bytearray()
buf += struct.pack(">II", 0xCAFEBABE, len(entries))
for s, off in zip(entries, offsets):
    buf += struct.pack(">IIIII", s["ct"], s["cs"], off, len(s["data"]), ALIGN)
for s, off in zip(entries, offsets):
    buf += b"\x00" * (off - len(buf))
    buf += s["data"]
open(out, "wb").write(bytes(buf))
print(f"  fat 输出 -> {out} ({len(buf)} bytes, {len(entries)} slices)")
PY

ls -la build/PetDFY.dylib

echo "===== 签名 ====="
ldid -S build/PetDFY.dylib
echo "signed"

echo "===== 打包 deb ====="
bash package.sh vendor/base/PetDFY_1.2.1_RootHide.deb