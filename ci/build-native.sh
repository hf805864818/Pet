#!/usr/bin/env bash
#
# ci/build-native.sh — clang + ld64.lld 交叉编译 iOS tweak（不依赖 theos）
#
#  重要：clang 以 -target arm64e 编译出的 .o 确实带 arm64e ABI，
#  但 ld64.lld 链接输出的 Mach-O 里没有真正的 PAC 指令（pacibsp/autibsp=0），
#  把 header 改写成 arm64e 属于「假 arm64e」，dyld 可能直接拒绝加载。
#  因此默认只出 arm64 切片：arm64 在 arm64e 设备上可正常加载。
#
set -euo pipefail
cd "$(dirname "$0")/.."

: "${IOS_SDK:?IOS_SDK 未设置（指向 iPhoneOS*.sdk 目录）}"
MIN_IOS="${MIN_IOS:-15.0}"
ARCHS="${ARCHS:-arm64}"
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
    print(f"  {sys.argv[1]}: cputype={hex(ct)} subtype={hex(cs)}")
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

    echo "===== 链接 $ARCH ====="
    OUT="build/PetDFY.$ARCH.dylib"
    if $CC -target "${ARCH}-apple-ios${MIN_IOS}" -isysroot "$IOS_SDK" \
        -dynamiclib -fuse-ld=lld \
        -install_name /Library/MobileSubstrate/DynamicLibraries/PetDFY.dylib \
        -Wl,-undefined,dynamic_lookup \
        $FRAMEWORKS \
        -o "$OUT" "$OBJ"/*.o ; then
        echo "链接 OK: $ARCH"
        hdr "$OUT"
        # 真实性质检：arm64e 必须有 PAC 指令，否则丢弃该切片（假 arm64e 会加载失败）
        if [ "$ARCH" = "arm64e" ]; then
            PAC=$(python3 - "$OUT" <<'PY'
import sys
d = open(sys.argv[1], "rb").read()
print(d.count(b"\x7f\x23\x03\xd5") + d.count(b"\xff\x23\x03\xd5"))
PY
)
            echo "  PAC 指令数: $PAC"
            if [ "$PAC" = "0" ]; then
                echo "  WARN: 该切片没有 PAC 指令，不是真 arm64e，丢弃" >&2
                rm -f "$OUT"
                continue
            fi
        fi
        SLICES="$SLICES $OUT"
    else
        echo "WARN: $ARCH 链接失败，跳过" >&2
        rm -f "$OUT"
    fi
done

[ -n "$SLICES" ] || { echo "所有切片均链接失败" >&2; exit 1; }

echo "===== 组装 fat ====="
# shellcheck disable=SC2086
python3 - build/PetDFY.dylib $SLICES <<'PY'
import struct, sys, os

out = sys.argv[1]
inputs = sys.argv[2:]
entries = []
for p in inputs:
    d = open(p, "rb").read()
    ct, cs = struct.unpack_from("<II", d, 4)
    entries.append({"path": p, "ct": ct, "cs": cs, "data": d})
    print(f"  {os.path.basename(p)}: cputype={hex(ct)} subtype={hex(cs)}")

if len(entries) == 1:
    open(out, "wb").write(entries[0]["data"])
    print(f"  单切片 -> {out}")
    sys.exit(0)

ALIGN = 14
align_bytes = 1 << ALIGN
header = 8 + 20 * len(entries)
offset = header
offsets = []
for e in entries:
    offset += (-offset) % align_bytes
    offsets.append(offset)
    offset += len(e["data"])

buf = bytearray(struct.pack(">II", 0xCAFEBABE, len(entries)))
for e, off in zip(entries, offsets):
    buf += struct.pack(">IIIII", e["ct"], e["cs"], off, len(e["data"]), ALIGN)
for e, off in zip(entries, offsets):
    buf += b"\x00" * (off - len(buf))
    buf += e["data"]
open(out, "wb").write(bytes(buf))
print(f"  fat -> {out} ({len(buf)} bytes, {len(entries)} slices)")
PY

ls -la build/PetDFY.dylib

echo "===== 签名 ====="
ldid -S build/PetDFY.dylib
echo "signed"

echo "===== 打包 deb ====="
bash package.sh vendor/base/PetDFY_1.2.1_RootHide.deb