@echo off
setlocal enabledelayedexpansion

set V8_VERSION=%1
set BUILD_ARGS=%2

echo ==========================================
echo Building v8dasm for Windows x64
echo V8 Version: %V8_VERSION%
echo Build Args: %BUILD_ARGS%
echo ==========================================

REM 检测运行环境 (GitHub Actions 或本地)
if "%GITHUB_WORKSPACE%"=="" (
    echo 检测到本地环境
    set WORKSPACE_DIR=%~dp0..\..
    set IS_LOCAL=true
    echo 本地环境，跳过依赖安装 (请确保已安装: git, python, Visual Studio/clang^)
) else (
    echo 检测到 GitHub Actions 环境
    set WORKSPACE_DIR=%GITHUB_WORKSPACE%
    set IS_LOCAL=false
)

echo 工作空间: %WORKSPACE_DIR%

REM 配置 Git
git config --global user.name "V8 Disassembler Builder"
git config --global user.email "v8dasm.builder@localhost"
git config --global core.autocrlf false
git config --global core.filemode false

cd %HOMEPATH%

REM 获取 Depot Tools
if not exist depot_tools (
    echo =====[ Getting Depot Tools ]=====
    powershell -command "Invoke-WebRequest https://storage.googleapis.com/chrome-infra/depot_tools.zip -O depot_tools.zip"
    powershell -command "Expand-Archive depot_tools.zip -DestinationPath depot_tools"
    del depot_tools.zip
)

set PATH=%CD%\depot_tools;%PATH%
set DEPOT_TOOLS_WIN_TOOLCHAIN=0
call gclient

REM 创建工作目录
if not exist v8 mkdir v8
cd v8

REM 获取 V8 源码
if not exist v8 (
    echo =====[ Fetching V8 ]=====
    call fetch v8
    echo target_os = ['win'] >> .gclient
)

cd v8
set V8_DIR=%CD%

REM Checkout 指定版本
echo =====[ Checking out V8 %V8_VERSION% ]=====
call git fetch --all --tags
call git checkout %V8_VERSION%
call gclient sync

REM 应用补丁（使用多级退避策略）
echo =====[ Applying v8.patch ]=====
set PATCH_FILE=%WORKSPACE_DIR%\Disassembler\v8.patch
set PATCH_LOG=%WORKSPACE_DIR%\scripts\v8dasm-builders\patch-utils\patch-state.log

REM 调用统一的 patch 应用脚本
call "%WORKSPACE_DIR%\scripts\v8dasm-builders\patch-utils\apply-patch.cmd" ^
    "%PATCH_FILE%" ^
    "%V8_DIR%" ^
    "%PATCH_LOG%" ^
    "true"

if %errorlevel% neq 0 (
    echo ❌ Patch application failed. Build aborted.
    echo 请检查日志文件: %PATCH_LOG%
    exit /b 1
)

echo ✅ Patch applied successfully


REM 配置构建
echo =====[ Configuring V8 Build ]=====
REM 第一步：创建基础配置
call python tools\dev\v8gen.py x64.release

REM 第二步：编辑 args.gn 文件
echo =====[ Writing build configuration to args.gn ]=====
(
echo target_os = "win"
echo target_cpu = "x64"
echo is_component_build = false
echo is_debug = false
echo use_custom_libcxx = false
echo v8_monolithic = true
echo v8_static_library = true
echo v8_enable_disassembler = true
echo v8_enable_object_print = true
echo v8_use_external_startup_data = false
echo dcheck_always_on = false
echo symbol_level = 0
echo is_clang = true
) > out.gn\x64.release\args.gn

REM 如果有额外的构建参数，追加到 args.gn
if not "%BUILD_ARGS%"=="" (
    echo %BUILD_ARGS% >> out.gn\x64.release\args.gn
)

echo Build configuration:
type out.gn\x64.release\args.gn

REM 构建 V8 静态库
echo =====[ Building V8 Monolith ]=====
call ninja -C out.gn\x64.release v8_monolith

REM 编译 v8dasm
echo =====[ Compiling v8dasm ]=====
set DASM_SOURCE=%WORKSPACE_DIR%\Disassembler\v8dasm.cpp
set OUTPUT_NAME=v8dasm-%V8_VERSION%.exe

clang++ %DASM_SOURCE% ^
    -std=c++20 ^
    -O2 ^
    -Iinclude ^
    -Lout.gn\x64.release\obj ^
    -lv8_libbase ^
    -lv8_libplatform ^
    -lv8_monolith ^
    -o %OUTPUT_NAME%

REM 验证编译
if exist %OUTPUT_NAME% (
    echo =====[ Build Successful ]=====
    dir %OUTPUT_NAME%
    echo.
    echo ✅ 编译完成: %OUTPUT_NAME%
    echo    位置: %CD%\%OUTPUT_NAME%
) else (
    echo ERROR: %OUTPUT_NAME% not found!
    exit /b 1
)
