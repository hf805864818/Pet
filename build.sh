#!/bin/bash
set -e
A=/var/containers/Bundle/Application/3AC47FFE-9E92-4F10-A751-679413E53E1D/CodexApp.app
T="$A/TheosRuntime"
SDK="$T/theos/sdks/iPhoneOS16.5.sdk"
CC="$T/usr/lib/llvm-16/bin/clang"
export PATH="$T/usr/bin:$T/usr/lib/llvm-16/bin:$PATH"
LIPO="$T/usr/bin/lipo"
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

FILES=$(find src -name '*.m' | sort)
FRAMEWORKS="-framework Foundation -framework UIKit -framework Metal -framework MetalKit -framework MetalPerformanceShaders -framework QuartzCore -framework AVFoundation -framework CoreMotion -framework AudioToolbox -framework CoreGraphics -framework Security -framework ImageIO"
# -lz：进程内 ZIP 解压（PDZipExtract）依赖 libz；iOS SDK 自带 libz.tbd
EXTRA_LIBS="-lz"

for ARCH in arm64 arm64e; do
  OBJ="build/obj-$ARCH"
  rm -rf "$OBJ"; mkdir -p "$OBJ"
  echo "== compiling $ARCH =="
  for f in $FILES; do
    o="$OBJ/$(echo "$f" | sed 's#/#_#g; s#\.m$#.o#')"
    "$CC" -target "$ARCH-apple-ios16.0" -isysroot "$SDK" -fobjc-arc \
      -I src -I src/Core -I src/Sources -O2 -Wno-everything -c "$f" -o "$o"
  done
  echo "== linking $ARCH =="
  "$CC" -target "$ARCH-apple-ios16.0" -isysroot "$SDK" -dynamiclib \
    -install_name /Library/MobileSubstrate/DynamicLibraries/PetDFY.dylib \
    $FRAMEWORKS $EXTRA_LIBS -L"$T/theos/vendor/lib" -lsubstrate -Wl,-undefined,dynamic_lookup \
    -o "build/PetDFY.$ARCH.dylib" "$OBJ"/*.o
done

echo "== lipo =="
"$LIPO" -create build/PetDFY.arm64.dylib build/PetDFY.arm64e.dylib -output build/PetDFY.dylib
"$LIPO" -info build/PetDFY.dylib
ls -la build/PetDFY.dylib
