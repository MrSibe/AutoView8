#!/bin/bash
set -e

V8_VERSION=$1
BUILD_ARGS=$2

echo "=========================================="
echo "Building v8dasm for Linux x64"
echo "V8 Version: $V8_VERSION"
echo "Build Args: $BUILD_ARGS"
echo "=========================================="

# 检测运行环境 (GitHub Actions 或本地)
if [ -z "$GITHUB_WORKSPACE" ]; then
    echo "检测到本地环境"
    # 本地环境：使用脚本所在目录的父目录作为工作空间
    SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
    WORKSPACE_DIR="$( cd "$SCRIPT_DIR/../.." && pwd )"
    IS_LOCAL=true
else
    echo "检测到 GitHub Actions 环境"
    WORKSPACE_DIR="$GITHUB_WORKSPACE"
    IS_LOCAL=false
fi

echo "工作空间: $WORKSPACE_DIR"

# 安装依赖 (仅在 GitHub Actions 环境中)
if [ "$IS_LOCAL" = false ]; then
    echo "=====[ Installing Dependencies ]====="
    sudo apt-get update
    sudo apt-get install -y \
        pkg-config \
        git \
        curl \
        wget \
        build-essential \
        python3 \
        python3-pip \
        xz-utils \
        zip \
        clang \
        lld
else
    echo "本地环境，跳过依赖安装 (请确保已安装: git, python3, clang, ninja)"
fi

# 配置 Git
git config --global user.name "V8 Disassembler Builder"
git config --global user.email "v8dasm.builder@localhost"
git config --global core.autocrlf false
git config --global core.filemode false

# 获取 Depot Tools
cd ~
if [ ! -d "depot_tools" ]; then
    echo "=====[ Getting Depot Tools ]====="
    git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git
fi
export PATH=$(pwd)/depot_tools:$PATH
gclient

# 创建工作目录
mkdir -p v8
cd v8

# 获取 V8 源码
if [ ! -d "v8" ]; then
    echo "=====[ Fetching V8 ]====="
    fetch v8
    echo "target_os = ['linux']" >> .gclient
fi

cd v8

# Checkout 指定版本
echo "=====[ Checking out V8 $V8_VERSION ]====="
git fetch --all --tags
git checkout $V8_VERSION
gclient sync

# 应用补丁
echo "=====[ Applying v8.patch ]====="
PATCH_FILE="$WORKSPACE_DIR/view8-jsc-decode/Disassembler/v8.patch"

# 检查补丁是否已应用
if git apply --check $PATCH_FILE 2>/dev/null; then
    git apply --verbose $PATCH_FILE
    echo "Patch applied successfully"
elif git apply --check --reverse $PATCH_FILE 2>/dev/null; then
    echo "Patch already applied, skipping"
else
    echo "Attempting 3-way merge..."
    git apply -3 $PATCH_FILE || {
        echo "WARNING: Patch failed with conflicts. Attempting manual resolution..."
        # 尝试忽略空白字符
        git apply --ignore-whitespace $PATCH_FILE || {
            echo "ERROR: Failed to apply patch. Manual intervention required."
            exit 1
        }
    }
fi

# 配置构建
echo "=====[ Configuring V8 Build ]====="
python3 tools/dev/v8gen.py x64.release -vv -- "
target_os = \"linux\"
target_cpu = \"x64\"
is_component_build = false
is_debug = false
use_custom_libcxx = false
v8_monolithic = true
v8_static_library = true
v8_enable_disassembler = true
v8_enable_object_print = true
v8_use_external_startup_data = false
dcheck_always_on = false
symbol_level = 0
$BUILD_ARGS
"

# 构建 V8 静态库
echo "=====[ Building V8 Monolith ]====="
ninja -C out.gn/x64.release v8_monolith

# 编译 v8dasm
echo "=====[ Compiling v8dasm ]====="
DASM_SOURCE="$WORKSPACE_DIR/view8-jsc-decode/Disassembler/v8dasm.cpp"
OUTPUT_NAME="v8dasm-$V8_VERSION"

clang++ $DASM_SOURCE \
    -std=c++20 \
    -O2 \
    -Iinclude \
    -Lout.gn/x64.release/obj \
    -lv8_libbase \
    -lv8_libplatform \
    -lv8_monolith \
    -pthread \
    -ldl \
    -o $OUTPUT_NAME

# 验证编译
if [ -f "$OUTPUT_NAME" ]; then
    echo "=====[ Build Successful ]====="
    ls -lh $OUTPUT_NAME
    file $OUTPUT_NAME
    echo ""
    echo "✅ 编译完成: $OUTPUT_NAME"
    echo "   位置: $(pwd)/$OUTPUT_NAME"
else
    echo "ERROR: $OUTPUT_NAME binary not found!"
    exit 1
fi
