#!/bin/bash

# Versions
VPX_VERSION=1.15.2
OPENSSL_VERSION=3.0.14
FFMPEG_VERSION=6.1.3

# Directories
BASE_DIR=$(cd "$(dirname "$0")" && pwd)
BUILD_DIR=$BASE_DIR/build
OUTPUT_DIR=$BASE_DIR/output
SOURCES_DIR=$BASE_DIR/sources
FFMPEG_DIR=$SOURCES_DIR/ffmpeg-$FFMPEG_VERSION
VPX_DIR=$SOURCES_DIR/libvpx-$VPX_VERSION
OPENSSL_DIR=$SOURCES_DIR/openssl-$OPENSSL_VERSION

# Configuration
ANDROID_ABIS="x86 x86_64 armeabi-v7a arm64-v8a"
ANDROID_PLATFORM=21
ENABLED_DECODERS="vorbis opus flac alac pcm_mulaw pcm_alaw mp3 amrnb amrwb aac ac3 eac3 dca mlp truehd h264 hevc mpeg2video mpegvideo libvpx_vp8 libvpx_vp9"
JOBS=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || sysctl -n hw.pysicalcpu || echo 4)

# Host platform
HOST_PLATFORM="linux-x86_64"
case "$OSTYPE" in
darwin*) HOST_PLATFORM="darwin-x86_64" ;;
linux*) HOST_PLATFORM="linux-x86_64" ;;
msys)
  case "$(uname -m)" in
  x86_64) HOST_PLATFORM="windows-x86_64" ;;
  i686) HOST_PLATFORM="windows" ;;
  esac
  ;;
esac

# Build tools
TOOLCHAIN_PREFIX="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/${HOST_PLATFORM}"
CMAKE_EXECUTABLE="${ANDROID_SDK_HOME}/cmake/${ANDROID_CMAKE_VERSION}/bin/cmake"

mkdir -p $SOURCES_DIR

function downloadLibVpx() {
  pushd $SOURCES_DIR
  echo "Downloading libvpx version $VPX_VERSION..."
  VPX_FILE=libvpx-$VPX_VERSION.tar.gz
  curl -L "https://github.com/webmproject/libvpx/archive/refs/tags/v${VPX_VERSION}.tar.gz" -o $VPX_FILE
  [ -e $VPX_FILE ] || { echo "$VPX_FILE does not exist. Exiting..."; exit 1; }
  tar -zxf $VPX_FILE
  rm $VPX_FILE
  popd
}

function downloadOpenssl() {
  pushd $SOURCES_DIR
  echo "Downloading OpenSSL version $OPENSSL_VERSION..."
  OPENSSL_FILE=openssl-$OPENSSL_VERSION.tar.gz
  curl -LO "https://www.openssl.org/source/openssl-$OPENSSL_VERSION.tar.gz"
  [ -e $OPENSSL_FILE ] || { echo "$OPENSSL_FILE does not exist. Exiting..."; exit 1; }
  tar -zxf $OPENSSL_FILE
  rm $OPENSSL_FILE
  popd
}

function downloadFfmpeg() {
  pushd $SOURCES_DIR
  echo "Downloading FFmpeg version $FFMPEG_VERSION..."
  FFMPEG_FILE=ffmpeg-$FFMPEG_VERSION.tar.gz
  curl -L "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.gz" -o $FFMPEG_FILE
  [ -e $FFMPEG_FILE ] || { echo "$FFMPEG_FILE does not exist. Exiting..."; exit 1; }
  tar -zxf $FFMPEG_FILE
  rm $FFMPEG_FILE
  popd
}

function buildLibVpx() {
  pushd $VPX_DIR
  VPX_AS=${TOOLCHAIN_PREFIX}/bin/llvm-as
  for ABI in $ANDROID_ABIS; do
    case $ABI in
    armeabi-v7a)
      EXTRA_BUILD_FLAGS="--force-target=armv7-android-gcc --disable-neon"
      TOOLCHAIN=armv7a-linux-androideabi21-
      ;;
    arm64-v8a)
      EXTRA_BUILD_FLAGS="--force-target=armv8-android-gcc"
      TOOLCHAIN=aarch64-linux-android21-
      ;;
    x86)
      EXTRA_BUILD_FLAGS="--force-target=x86-android-gcc --disable-sse2 --disable-sse3 --disable-ssse3 --disable-sse4_1 --disable-avx --disable-avx2 --enable-pic"
      VPX_AS=${TOOLCHAIN_PREFIX}/bin/yasm
      TOOLCHAIN=i686-linux-android21-
      ;;
    x86_64)
      EXTRA_BUILD_FLAGS="--force-target=x86_64-android-gcc --disable-sse2 --disable-sse3 --disable-ssse3 --disable-sse4_1 --disable-avx --disable-avx2 --enable-pic --disable-neon --disable-neon-asm"
      VPX_AS=${TOOLCHAIN_PREFIX}/bin/yasm
      TOOLCHAIN=x86_64-linux-android21-
      ;;
    esac

    CC=${TOOLCHAIN_PREFIX}/bin/${TOOLCHAIN}clang \
    CXX=${CC}++ \
    AR=${TOOLCHAIN_PREFIX}/bin/llvm-ar \
    AS=${VPX_AS} \
    ./configure \
      --prefix=$BUILD_DIR/external/$ABI \
      --libc="${TOOLCHAIN_PREFIX}/sysroot" \
      --enable-vp8 \
      --enable-vp9 \
      --enable-static \
      --disable-shared \
      --disable-unit-tests \
      --disable-tools \
      --disable-examples \
      --disable-docs \
      --enable-realtime-only \
      --enable-install-libs \
      --enable-multithread \
      --disable-webm-io \
      --disable-libyuv \
      --disable-runtime-cpu-detect \
      ${EXTRA_BUILD_FLAGS}

    make clean
    make -j$JOBS
    make install
  done
  popd
}

function buildOpenssl() {
  pushd $OPENSSL_DIR
  for ABI in $ANDROID_ABIS; do
    case $ABI in
      armeabi-v7a) TARGET="android-arm" ;;
      arm64-v8a)   TARGET="android-arm64" ;;
      x86)         TARGET="android-x86" ;;
      x86_64)      TARGET="android-x86_64" ;;
    esac
    INSTALL_DIR=$BUILD_DIR/external/$ABI
    ./Configure $TARGET no-shared no-unit-test \
      --prefix=$INSTALL_DIR \
      --openssldir=$INSTALL_DIR/ssl
    make clean
    make -j$JOBS
    make install_sw
  done
  popd
}

function buildFfmpeg() {
  pushd $FFMPEG_DIR
  EXTRA_BUILD_CONFIGURATION_FLAGS=""
  COMMON_OPTIONS=""
  for decoder in $ENABLED_DECODERS; do
    COMMON_OPTIONS="${COMMON_OPTIONS} --enable-decoder=${decoder}"
  done

  for ABI in $ANDROID_ABIS; do
    case $ABI in
    armeabi-v7a) TOOLCHAIN=armv7a-linux-androideabi21-; CPU=armv7-a; ARCH=arm ;;
    arm64-v8a)   TOOLCHAIN=aarch64-linux-android21-; CPU=armv8-a; ARCH=aarch64 ;;
    x86)         TOOLCHAIN=i686-linux-android21-; CPU=i686; ARCH=i686; EXTRA_BUILD_CONFIGURATION_FLAGS=--disable-asm ;;
    x86_64)      TOOLCHAIN=x86_64-linux-android21-; CPU=x86_64; ARCH=x86_64 ;;
    esac

    DEP_CFLAGS="-I$BUILD_DIR/external/$ABI/include"
    DEP_LD_FLAGS="-L$BUILD_DIR/external/$ABI/lib"

    ./configure \
      --prefix=$BUILD_DIR/$ABI \
      --enable-cross-compile \
      --arch=$ARCH \
      --cpu=$CPU \
      --cross-prefix="${TOOLCHAIN_PREFIX}/bin/$TOOLCHAIN" \
      --nm="${TOOLCHAIN_PREFIX}/bin/llvm-nm" \
      --ar="${TOOLCHAIN_PREFIX}/bin/llvm-ar" \
      --ranlib="${TOOLCHAIN_PREFIX}/bin/llvm-ranlib" \
      --strip="${TOOLCHAIN_PREFIX}/bin/llvm-strip" \
      --extra-cflags="-O3 -fPIC $DEP_CFLAGS" \
      --extra-ldflags="$DEP_LD_FLAGS -Wl,-z,max-page-size=16384" \
      --pkg-config="$(which pkg-config)" \
      --target-os=android \
      --enable-shared \
      --disable-static \
      --disable-doc \
      --disable-programs \
      --disable-everything \
      --disable-vulkan \
      --disable-avdevice \
      --disable-postproc \
      --disable-avfilter \
      --disable-symver \
      --enable-parsers \
      --enable-demuxers \
      --enable-swresample \
      --enable-avformat \
      --enable-libvpx \
      --enable-protocol=file,http,https,mmsh,mmst,pipe,rtmp,rtmps,rtmpt,rtmpts,rtp,tls \
      --enable-version3 \
      --enable-openssl \
      --extra-ldexeflags=-pie \
      --disable-debug \
      ${EXTRA_BUILD_CONFIGURATION_FLAGS} \
      ${COMMON_OPTIONS}

    echo "Building FFmpeg for $ARCH..."
    make clean
    make -j$JOBS
    make install

    OUTPUT_LIB=${OUTPUT_DIR}/lib/${ABI}
    mkdir -p "${OUTPUT_LIB}"
    cp "${BUILD_DIR}"/"${ABI}"/lib/*.so "${OUTPUT_LIB}"

    OUTPUT_HEADERS=${OUTPUT_DIR}/include/${ABI}
    mkdir -p "${OUTPUT_HEADERS}"
    cp -r "${BUILD_DIR}"/"${ABI}"/include/* "${OUTPUT_HEADERS}"
  done
  popd
}

if [[ ! -d "$OUTPUT_DIR" && ! -d "$BUILD_DIR" ]]; then
  [[ ! -d "$VPX_DIR" ]] && downloadLibVpx
  [[ ! -d "$OPENSSL_DIR" ]] && downloadOpenssl
  [[ ! -d "$FFMPEG_DIR" ]] && downloadFfmpeg

  buildOpenssl
  buildLibVpx
  buildFfmpeg
fi