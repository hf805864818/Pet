#!/usr/bin/env bash
#
# ci/build-native.sh — 不走 theos，直接用 clang + ld64.lld 交叉编译 iOS tweak
#
# 为什么：
#   theos 的 linux/iphone 工具链目录不存在，用系统 clang 顶替时，Darwin 目标
#   会被驱动退回到 GNU ld.bfd（报 "unrecognised emulation mode: llvm"）。
#   直接给 clang 加 -fuse-ld=lld，就会用 ld64.lld 产出 Mach-O。
#
# 环境变量：
#   IOS_SDK   指向 .sdk 目录（例如 $PWD/sdks/iPhoneOS16.5.sdk）
#   MIN_IOS   最低部署版本，默认 15.0
#
set -euo pipefail
cd "$(dirname "$0")/.."

: "${IOS_SDK:?IOS_SDK 未设置（指向 iPhoneOS*.sdk 目录）}"
MIN_IOS="${MIN_IOS:-15.0}"
[ -d "$IOS_SDK" ] || { echo "IOS_SDK 不存在: $IOS_SDK" >&2; exit 2; }

CC="${CC:-clang}"
FRAMEWORKS="-framework Foundation -framework UIKit -framework Metal -framework MetalKit \
-framework MetalPerformanceShaders -framework QuartzCore -framework AVFoundation \
-framework CoreMotion -framework AudioToolbox -framework CoreGraphics \
-framework Security -framework ImageIO -lz"

echo "SDK: $IOS_SDK"
echo "clang: $($CC --version | head -1)"
command -v ld64.lld >/dev/null || { echo "缺少 ld64.lld（apt install lld）" >&2; exit 2; }

FILES=$(find src -name '*.m' | sort)
echo "源文件数: $(echo "$FILES" | wc -l)"

for ARCH in arm64 arm64e; do
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
    $CC -target "${ARCH}-apple-ios${MIN_IOS}" -isysroot "$IOS_SDK" \
        -dynamiclib -fuse-ld=lld \
        -install_name /Library/MobileSubstrate/DynamicLibraries/PetDFY.dylib \
        -Wl,-undefined,dynamic_lookup \
        $FRAMEWORKS \
        -o "build/PetDFY.$ARCH.dylib" "$OBJ"/*.o
    ls -la "build/PetDFY.$ARCH.dylib"
done

echo "===== lipo ====="
llvm-lipo -create build/PetDFY.arm64.dylib build/PetDFY.arm64e.dylib -output build/PetDFY.dylib
llvm-lipo -info build/PetDFY.dylib || true

echo "===== 签名 ====="
ldid -S build/PetDFY.dylib
echo "signed"

echo "===== 打包 deb ====="
bash package.sh vendor/base/PetDFY_1.2.1_RootHide.deb