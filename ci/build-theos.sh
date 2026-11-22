#!/usr/bin/env bash
#
# ci/build-theos.sh — 在已就绪的 theos 环境里编译打包
# 由 workflow 调用；要求 THEOS 已设置、SDK 已放入 $THEOS/sdks。
#
set -euo pipefail
cd "$(dirname "$0")/.."

: "${THEOS:?THEOS 未设置}"

SDK_DIR=$(basename "$(ls -d "$THEOS"/sdks/iPhoneOS*.sdk | tail -1)")
SDK_VER=${SDK_DIR#iPhoneOS}
SDK_VER=${SDK_VER%.sdk}
echo "TARGET SDK: $SDK_VER (dir $SDK_DIR)"

bash ci/prepare-layout.sh

make clean 2>&1 | tail -5 || true
set -o pipefail
make package FINALPACKAGE=1 DEBUG=0 TARGET="iphone:clang:${SDK_VER}:15.0" 2>&1 | tee build.log
