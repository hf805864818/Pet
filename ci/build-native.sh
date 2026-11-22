#!/usr/bin/env bash
#
# ci/build-native.sh — 不依赖 theos，用 clang + ld64.lld 交叉编译 iOS tweak
#
#   ARCHS 可指定，默认 "arm64 arm64e"。
#   arm64e 在某些 ld64.lld 版本上会拒绝 ptrauth 重定位
#   （INVALID relocation has width 8 bytes），此时自动降级为 arm64 单切片：
#   arm64e 设备可以正常加载 arm64 切片，功能不受影响。
#
set -euo pipefail
cd "$(dirname "$0")/.."

: "${IOS_SDK:?IOS_SDK 未设置（指向 iPhoneOS*.sdk 目录）}"
MIN_IOS="${MIN_IOS:-15.0}"
ARCHS="${ARCHS:-arm64 arm64e}"

[ -d "$IOS_SDK" ] || { echo "IOS_SDK 不存在: $IOS_SDK" >&2; exit 2; }
CC="${CC:-clang}"
command -v ld64.lld >/dev/null || { echo "缺少 ld64.lld（apt install lld）" >&2; exit 2; }

FRAMEWORKS="-framework Foundation -framework UIKit -framework Metal -framework MetalKit \
-framework MetalPerformanceShaders -framework QuartzCore -framework AVFoundation \
-framework CoreMotion -framework AudioToolbox -framework CoreGraphics \
-framework Security -framework ImageIO -lz"

echo "SDK: $IOS_SDK"
echo "clang: $($CC --version | head -1)"
echo "ARCHS: $ARCHS"

FILES=$(find src -name '*.m' | sort)
echo "源文件数: $(echo "$FILES" | wc -l)"

BUILT=""
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
    if $CC -target "${ARCH}-apple-ios${MIN_IOS}" -isysroot "$IOS_SDK" \
        -dynamiclib -fuse-ld=lld \
        -install_name /Library/MobileSubstrate/DynamicLibraries/PetDFY.dylib \
        -Wl,-undefined,dynamic_lookup \
        $FRAMEWORKS \
        -o "build/PetDFY.$ARCH.dylib" "$OBJ"/*.o ; then
        echo "OK: $ARCH"
        BUILT="$BUILT build/PetDFY.$ARCH.dylib"
    else
        echo "WARN: $ARCH 链接失败，跳过该切片" >&2
    fi
done

[ -n "$BUILT" ] || { echo "所有切片均链接失败" >&2; exit 1; }

echo "===== lipo ====="
# shellcheck disable=SC2086
llvm-lipo -create $BUILT -output build/PetDFY.dylib
llvm-lipo -info build/PetDFY.dylib || true
ls -la build/PetDFY.dylib

echo "===== 签名 ====="
ldid -S build/PetDFY.dylib
echo "signed"

echo "===== 打包 deb ====="
bash package.sh vendor/base/PetDFY_1.2.1_RootHide.deb