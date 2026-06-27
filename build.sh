#!/usr/bin/env bash
set -euo pipefail

LLVM_TAG="latest"
ARCH="x64"
ABI_NAMESPACE="__1"
CLEAN=0
SKIP_CLONE=0
PACKAGE=0

while [[ $# -gt 0 ]]; do
    case $1 in
        --llvm-tag)       LLVM_TAG="$2";       shift 2 ;;
        --arch)           ARCH="$2";            shift 2 ;;
        --abi-namespace)  ABI_NAMESPACE="$2";   shift 2 ;;
        --clean)          CLEAN=1;              shift ;;
        --skip-clone)     SKIP_CLONE=1;         shift ;;
        --package)        PACKAGE=1;            shift ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Run '$0' without arguments or check the header comments for usage." >&2
            exit 1 ;;
    esac
done

if [[ "$ABI_NAMESPACE" != __* ]]; then
    echo "Error: --abi-namespace must start with __ (got '$ABI_NAMESPACE')" >&2
    exit 1
fi

case "$ARCH" in
    x64|arm64) ;;
    *) echo "Error: --arch must be x64 or arm64 (got '$ARCH')" >&2; exit 1 ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$ROOT/llvm-project"
INSTALL_DIR="$ROOT/install/libcxx-linux-$ARCH-$ABI_NAMESPACE"

step() { echo -e "\n=== $* ==="; }

if [[ "$LLVM_TAG" == "latest" ]]; then
    step "Resolving latest LLVM release"
    LLVM_TAG=$(curl -fsSL "https://api.github.com/repos/llvm/llvm-project/releases/latest" \
               | grep -m1 '"tag_name"' \
               | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')
    echo "Resolved to: $LLVM_TAG"
fi

LLVM_VERSION="${LLVM_TAG#llvmorg-}"

step "Locating Clang"
CLANG_CC="${CLANG_CC:-$(command -v clang 2>/dev/null || true)}"
CLANG_CXX="${CLANG_CXX:-$(command -v clang++ 2>/dev/null || true)}"

if [[ -z "$CLANG_CC" || ! -x "$CLANG_CC" ]]; then
    echo "Error: clang not found. Install LLVM or set CLANG_CC=/path/to/clang" >&2
    exit 1
fi
if [[ -z "$CLANG_CXX" || ! -x "$CLANG_CXX" ]]; then
    echo "Error: clang++ not found. Install LLVM or set CLANG_CXX=/path/to/clang++" >&2
    exit 1
fi

echo "C   compiler: $CLANG_CC"
echo "C++ compiler: $CLANG_CXX"
"$CLANG_CXX" --version

if command -v ninja &>/dev/null; then
    CMAKE_GENERATOR="Ninja"
else
    CMAKE_GENERATOR="Unix Makefiles"
fi

case "$ARCH" in
    arm64) TARGET_TRIPLE="aarch64-unknown-linux-gnu" ;;
    x64)   TARGET_TRIPLE="x86_64-unknown-linux-gnu"  ;;
esac

if [[ $SKIP_CLONE -eq 0 ]]; then
    step "Cloning LLVM ($LLVM_TAG)"
    if [[ $CLEAN -eq 1 && -d "$SOURCE_DIR" ]]; then
        rm -rf "$SOURCE_DIR"
    fi
    if [[ ! -d "$SOURCE_DIR" ]]; then
        git clone --depth 1 --branch "$LLVM_TAG" \
            https://github.com/llvm/llvm-project.git "$SOURCE_DIR"
    else
        echo "Source already exists — skipping clone. Use --clean to re-clone."
    fi
fi

CONFIGS=("Release" "Debug")

for CONFIG in "${CONFIGS[@]}"; do
    BUILD_DIR="$ROOT/build/$ARCH/$CONFIG"
    TEMP_INSTALL="$ROOT/install/_temp_${ARCH}_${CONFIG}"

    step "Configuring libc++ ($CONFIG, $ARCH)"
    if [[ $CLEAN -eq 1 && -d "$BUILD_DIR" ]]; then
        rm -rf "$BUILD_DIR"
    fi

    cmake \
        -G "$CMAKE_GENERATOR" \
        -S "$SOURCE_DIR/runtimes" \
        -B "$BUILD_DIR" \
        -DCMAKE_C_COMPILER="$CLANG_CC" \
        -DCMAKE_CXX_COMPILER="$CLANG_CXX" \
        -DCMAKE_C_COMPILER_TARGET="$TARGET_TRIPLE" \
        -DCMAKE_CXX_COMPILER_TARGET="$TARGET_TRIPLE" \
        -DCMAKE_BUILD_TYPE="$CONFIG" \
        -DCMAKE_INSTALL_PREFIX="$TEMP_INSTALL" \
        -DLLVM_ENABLE_RUNTIMES="libcxx;libcxxabi" \
        -DLIBCXX_ENABLE_SHARED=ON \
        -DLIBCXX_ENABLE_STATIC=ON \
        -DLIBCXX_INCLUDE_BENCHMARKS=OFF \
        -DLIBCXX_INCLUDE_TESTS=OFF \
        -DLLVM_INCLUDE_TESTS=OFF \
        -DLIBCXX_ABI_NAMESPACE="$ABI_NAMESPACE" \
        -DLIBCXXABI_ENABLE_SHARED=ON \
        -DLIBCXXABI_ENABLE_STATIC=ON \
        -DLIBCXXABI_INCLUDE_TESTS=OFF

    step "Building libc++ ($CONFIG)"
    cmake --build "$BUILD_DIR" --config "$CONFIG" --parallel "$(nproc)"

    step "Installing libc++ ($CONFIG)"
    rm -rf "$TEMP_INSTALL"
    cmake --install "$BUILD_DIR" --config "$CONFIG"
done

step "Merging into multi-config layout"
rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"

cp -r "$ROOT/install/_temp_${ARCH}_Release/include" "$INSTALL_DIR/include"
if [[ -d "$ROOT/install/_temp_${ARCH}_Release/share" ]]; then
    cp -r "$ROOT/install/_temp_${ARCH}_Release/share" "$INSTALL_DIR/share"
fi

for CONFIG in "${CONFIGS[@]}"; do
    SRC="$ROOT/install/_temp_${ARCH}_${CONFIG}"
    mkdir -p "$INSTALL_DIR/lib/$CONFIG"
    cp -r "$SRC/lib/." "$INSTALL_DIR/lib/$CONFIG/"
done

for CONFIG in "${CONFIGS[@]}"; do
    rm -rf "$ROOT/install/_temp_${ARCH}_${CONFIG}"
done

if [[ $PACKAGE -eq 1 ]]; then
    step "Packaging"
    TARBALL="libcxx-$LLVM_VERSION-linux-$ARCH-$ABI_NAMESPACE.tar.gz"
    TARBALL_PATH="$ROOT/$TARBALL"
    rm -f "$TARBALL_PATH"
    tar -czf "$TARBALL_PATH" -C "$INSTALL_DIR" .
    echo "Package: $TARBALL_PATH"
fi

step "Done (LLVM $LLVM_VERSION, $ARCH, ABI namespace: $ABI_NAMESPACE)"
echo "Installed to: $INSTALL_DIR"
