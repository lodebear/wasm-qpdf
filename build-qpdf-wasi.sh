#!/usr/bin/env bash
# Cross-compile qpdf to a wasm32-wasip2 component with wasi-sdk-33.
# C++ exceptions (-fwasm-exceptions) + libjpeg setjmp in Pl_DCT (-wasm-enable-sjlj),
# standardized exnref EH (-wasm-use-legacy-eh=false). Native crypto (no OpenSSL/gnutls).
set -euo pipefail

APPS="${WASM_TOOLS_ROOT:-$(git -C "$(dirname "$0")" rev-parse --show-toplevel)/..}"
SDK="${WASI_SDK_PATH:-$APPS/.wasi-sdk/wasi-sdk-33.0-arm64-macos}"
SYSROOT="$SDK/share/wasi-sysroot"
HERE="$(cd "$(dirname "$0")" && pwd)"   # qpdf checkout root
DEPS="$HERE/deps/wasi"
BUILD="$HERE/build-wasi"
OUT="$HERE/build/wasm"

EH_C="-mllvm -wasm-enable-sjlj -mllvm -wasm-use-legacy-eh=false"
EH_CXX="-fwasm-exceptions -mllvm -wasm-enable-sjlj -mllvm -wasm-use-legacy-eh=false"

rm -rf "$BUILD"
# qpdf locates zlib/libjpeg via pkg-config. Point PKG_CONFIG_LIBDIR ONLY at our wasi deps'
# .pc files so it finds the cross-built libs and never the host (macOS zlib.pc / homebrew).
export PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig"
unset PKG_CONFIG_PATH
cmake -B "$BUILD" -S "$HERE" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$SDK/share/cmake/wasi-sdk-p2.cmake" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_SYSROOT="$SYSROOT" \
  -DCMAKE_FIND_ROOT_PATH="$SYSROOT;$DEPS" \
  -DCMAKE_C_FLAGS="-O2 $EH_C" \
  -DCMAKE_CXX_FLAGS="-O2 $EH_CXX" \
  -DCMAKE_EXE_LINKER_FLAGS="-L$SYSROOT/lib/wasm32-wasip2/eh -lunwind -lsetjmp" \
  -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
  -DBUILD_SHARED_LIBS=OFF \
  -DUSE_IMPLICIT_CRYPTO=OFF \
  -DREQUIRE_CRYPTO_NATIVE=ON \
  -DDEFAULT_CRYPTO=native \
  -DZLIB_LIBRARY="$DEPS/lib/libz.a" -DZLIB_INCLUDE_DIR="$DEPS/include" \
  -DJPEG_LIBRARY="$DEPS/lib/libjpeg.a" -DJPEG_INCLUDE_DIR="$DEPS/include" \
  -DBUILD_DOC=OFF -DBUILD_DOC_PDF=OFF -DENABLE_QTC=OFF

cmake --build "$BUILD" --target qpdf -j

mkdir -p "$OUT"
BIN="$(find "$BUILD" -type f -name qpdf | head -1)"
cp "$BIN" "$OUT/qpdf.wasm"
echo "built: $BIN -> $OUT/qpdf.wasm"
echo "magic: $(xxd -l8 "$OUT/qpdf.wasm" | awk '{print $2$3$4$5}')"
wasm-tools validate --features all "$OUT/qpdf.wasm" && echo "VALIDATE OK"
