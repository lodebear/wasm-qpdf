#!/usr/bin/env bash
# Cross-compile qpdf's dependencies (zlib, libjpeg-turbo) to wasm32-wasip2 static libs.
# libjpeg uses setjmp/longjmp -> needs the SjLj EH lowering; everything forces exnref EH.
set -euo pipefail

APPS="${WASM_TOOLS_ROOT:-$(git -C "$(dirname "$0")" rev-parse --show-toplevel)/..}"
SDK="${WASI_SDK_PATH:-$APPS/.wasi-sdk/wasi-sdk-33.0-arm64-macos}"
SYSROOT="$SDK/share/wasi-sysroot"
HERE="$(cd "$(dirname "$0")" && pwd)"   # qpdf/deps
SRC="$HERE/src"; PREFIX="$HERE/wasi"
mkdir -p "$SRC" "$PREFIX/lib" "$PREFIX/include"

CC="$SDK/bin/clang"; AR="$SDK/bin/llvm-ar"
TARGET=(--target=wasm32-wasip2 --sysroot="$SYSROOT")
EH=(-mllvm -wasm-use-legacy-eh=false)
SJLJ=(-mllvm -wasm-enable-sjlj)

echo "=== zlib ==="
[ -d "$SRC/zlib" ] || git clone --depth 1 -b v1.3.1 https://github.com/madler/zlib "$SRC/zlib"
cd "$SRC/zlib"; rm -f ./*.o
ZSRCS=(adler32.c crc32.c deflate.c infback.c inffast.c inflate.c inftrees.c trees.c zutil.c compress.c uncompr.c gzclose.c gzlib.c gzread.c gzwrite.c)
# zlib uses no setjmp/exceptions -> compile plain (the bare -wasm-use-legacy-eh flag ICEs without an EH mode).
"$CC" "${TARGET[@]}" -O2 -DHAVE_UNISTD_H -c "${ZSRCS[@]}"
"$AR" rcs "$PREFIX/lib/libz.a" ./*.o
cp zlib.h zconf.h "$PREFIX/include/"
echo "zlib -> $PREFIX/lib/libz.a"

echo "=== libjpeg-turbo ==="
[ -d "$SRC/libjpeg-turbo" ] || git clone --depth 1 https://github.com/libjpeg-turbo/libjpeg-turbo "$SRC/libjpeg-turbo"
cd "$SRC/libjpeg-turbo"; rm -rf build-wasi
cmake -B build-wasi -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$SDK/share/cmake/wasi-sdk-p2.cmake" \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_C_FLAGS="-O2 -mllvm -wasm-enable-sjlj -mllvm -wasm-use-legacy-eh=false" \
  -DENABLE_SHARED=0 -DENABLE_STATIC=1 -DWITH_SIMD=0 -DWITH_TURBOJPEG=0
# Build only the static lib (the example/tool executables need -lsetjmp at link and aren't needed).
cmake --build build-wasi --target jpeg-static -j
cp build-wasi/libjpeg.a "$PREFIX/lib/"
cp build-wasi/jconfig.h "$PREFIX/include/"
for h in jpeglib.h jerror.h jmorecfg.h; do
  cp "$(find "$SRC/libjpeg-turbo" -maxdepth 2 -name "$h" | head -1)" "$PREFIX/include/"
done
echo "libjpeg-turbo -> $PREFIX/lib/libjpeg.a"

echo "=== pkg-config files ==="
mkdir -p "$PREFIX/lib/pkgconfig"
cat > "$PREFIX/lib/pkgconfig/zlib.pc" <<EOF
prefix=$PREFIX
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: zlib
Description: zlib compression library
Version: 1.3.1
Libs: -L\${libdir} -lz
Cflags: -I\${includedir}
EOF
cat > "$PREFIX/lib/pkgconfig/libjpeg.pc" <<EOF
prefix=$PREFIX
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: libjpeg
Description: libjpeg-turbo
Version: 3.0.0
Libs: -L\${libdir} -ljpeg
Cflags: -I\${includedir}
EOF

echo "=== verify ==="
"$SDK/bin/llvm-nm" "$PREFIX/lib/libz.a" | grep -qE ' T deflate$' && echo "libz.a: deflate present"
"$SDK/bin/llvm-nm" "$PREFIX/lib/libjpeg.a" 2>/dev/null | grep -qE ' T jpeg_read_header$' && echo "libjpeg.a: jpeg_read_header present"
ls -la "$PREFIX/lib/" "$PREFIX/include/" | sed -n '1,40p'
