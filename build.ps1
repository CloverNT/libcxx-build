#Requires -Version 7.0
<#
.SYNOPSIS
    Build LLVM libc++ for Windows using Clang-cl.
    Produces both Debug and Release libraries in a single install tree.
.PARAMETER LLVMTag
    LLVM git tag (default: "latest" → auto-detect newest release).
.PARAMETER Arch
    Target architecture: x64 or arm64 (default: x64).
.PARAMETER ABINamespace
    libc++ inline ABI namespace (default: __1). Must start with __.
.PARAMETER Clean
    Remove existing build/install directories before building.
.PARAMETER SkipClone
    Skip cloning LLVM source (use existing).
.PARAMETER Package
    Create a zip archive of the install directory.
#>
param(
    [string]$LLVMTag       = "latest",
    [ValidateSet("x64","arm64")]
    [string]$Arch          = "x64",
    [string]$ABINamespace  = "__1",
    [switch]$Clean,
    [switch]$SkipClone,
    [switch]$Package
)

if ($ABINamespace -notmatch '^__') {
    throw "ABINamespace must start with __ (got '$ABINamespace')"
}

$ErrorActionPreference = "Stop"
$ROOT       = $PSScriptRoot
$SOURCE_DIR = "$ROOT\llvm-project"
$INSTALL_DIR = "$ROOT\install\libcxx-windows-$Arch-$ABINamespace"

function Write-Step([string]$msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }

# ---------- Resolve "latest" tag ----------
if ($LLVMTag -eq "latest") {
    Write-Step "Resolving latest LLVM release"
    $release = Invoke-RestMethod "https://api.github.com/repos/llvm/llvm-project/releases/latest"
    $LLVMTag = $release.tag_name
    Write-Host "Resolved to: $LLVMTag"
}

$LLVMVersion = $LLVMTag -replace '^llvmorg-', ''

# ---------- Find Visual Studio ----------
Write-Step "Finding Visual Studio"
$vsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vsWhere)) { throw "vswhere.exe not found - install Visual Studio." }
$VS_PATH = (& $vsWhere -latest -property installationPath).Trim()
Write-Host "VS path: $VS_PATH"

# ---------- Set up MSVC developer environment ----------
# For ARM64 cross-compilation from x64 host, use amd64_arm64
$vcArch = if ($Arch -eq "arm64") { "amd64_arm64" } else { $Arch }
Write-Step "Setting up MSVC environment ($vcArch)"
$vcvarsall = "$VS_PATH\VC\Auxiliary\Build\vcvarsall.bat"
if (-not (Test-Path $vcvarsall)) { throw "vcvarsall.bat not found" }

$envLines = cmd /c "`"$vcvarsall`" $vcArch >nul 2>&1 && set"
foreach ($line in $envLines) {
    if ($line -match "^([^=]+)=(.*)$") {
        [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], "Process")
    }
}
Write-Host "MSVC developer environment loaded."

# ---------- Locate compilers ----------
$CLANG_CL = "$VS_PATH\VC\Tools\Llvm\x64\bin\clang-cl.exe"
if (-not (Test-Path $CLANG_CL)) {
    $CLANG_CL = (Get-Command clang-cl -ErrorAction SilentlyContinue).Source
}
if (-not $CLANG_CL) { throw "clang-cl not found" }
Write-Host "Compiler: $CLANG_CL"
& $CLANG_CL --version

# ---------- Cross-compilation target ----------
$targetTriple = switch ($Arch) {
    "arm64" { "aarch64-pc-windows-msvc" }
    default { "x86_64-pc-windows-msvc" }
}

# ---------- Clone LLVM ----------
if (-not $SkipClone) {
    Write-Step "Cloning LLVM ($LLVMTag)"
    if ($Clean -and (Test-Path $SOURCE_DIR)) {
        Remove-Item -Recurse -Force $SOURCE_DIR
    }
    if (-not (Test-Path $SOURCE_DIR)) {
        git clone --depth 1 --branch $LLVMTag `
            https://github.com/llvm/llvm-project.git $SOURCE_DIR
        if ($LASTEXITCODE -ne 0) { throw "git clone failed" }
    } else {
        Write-Host "Source already exists - skipping clone. Use -Clean to re-clone."
    }
}

# ---------- Build both configurations ----------
$configs = @("Release", "Debug")

foreach ($config in $configs) {
    $BUILD_DIR    = "$ROOT\build\$Arch\$config"
    $TEMP_INSTALL = "$ROOT\install\_temp_${Arch}_$config"

    Write-Step "Configuring libc++ ($config, $Arch)"
    if ($Clean -and (Test-Path $BUILD_DIR)) {
        Remove-Item -Recurse -Force $BUILD_DIR
    }

    $cmakeArgs = @(
        "-G", "Ninja"
        "-S", "$SOURCE_DIR\runtimes"
        "-B", $BUILD_DIR
        "-DCMAKE_C_COMPILER=clang-cl"
        "-DCMAKE_CXX_COMPILER=clang-cl"
        "-DCMAKE_C_COMPILER_TARGET=$targetTriple"
        "-DCMAKE_CXX_COMPILER_TARGET=$targetTriple"
        "-DCMAKE_BUILD_TYPE=$config"
        "-DCMAKE_INSTALL_PREFIX=$TEMP_INSTALL"
        "-DLLVM_ENABLE_RUNTIMES=libcxx"
        "-DLIBCXX_ENABLE_SHARED=ON"
        "-DLIBCXX_ENABLE_STATIC=ON"
        "-DLIBCXX_INCLUDE_BENCHMARKS=OFF"
        "-DLIBCXX_INCLUDE_TESTS=OFF"
        "-DLLVM_INCLUDE_TESTS=OFF"
        "-DLIBCXX_ABI_NAMESPACE=$ABINamespace"
        "-DLIBCXX_SHARED_OUTPUT_NAME=libc++"
        "-DLIBCXX_STATIC_OUTPUT_NAME=c++_static"
    )

    & cmake @cmakeArgs
    if ($LASTEXITCODE -ne 0) { throw "CMake configure ($config) failed" }

    Write-Step "Building libc++ ($config)"
    cmake --build $BUILD_DIR --config $config -- -j $([Environment]::ProcessorCount)
    if ($LASTEXITCODE -ne 0) { throw "Build ($config) failed" }

    Write-Step "Installing libc++ ($config)"
    if (Test-Path $TEMP_INSTALL) { Remove-Item -Recurse -Force $TEMP_INSTALL }
    cmake --install $BUILD_DIR --config $config
    if ($LASTEXITCODE -ne 0) { throw "Install ($config) failed" }
}

# ---------- Merge into final multi-config layout ----------
Write-Step "Merging into multi-config layout"
if (Test-Path $INSTALL_DIR) { Remove-Item -Recurse -Force $INSTALL_DIR }
New-Item -ItemType Directory -Path $INSTALL_DIR -Force | Out-Null

Copy-Item -Recurse "$ROOT\install\_temp_${Arch}_Release\include" "$INSTALL_DIR\include"

if (Test-Path "$ROOT\install\_temp_${Arch}_Release\share") {
    Copy-Item -Recurse "$ROOT\install\_temp_${Arch}_Release\share" "$INSTALL_DIR\share"
}

foreach ($config in $configs) {
    $src = "$ROOT\install\_temp_${Arch}_$config"
    New-Item -ItemType Directory -Path "$INSTALL_DIR\lib\$config" -Force | Out-Null
    Copy-Item "$src\lib\*" "$INSTALL_DIR\lib\$config\" -Recurse

    if (Test-Path "$src\bin") {
        New-Item -ItemType Directory -Path "$INSTALL_DIR\bin\$config" -Force | Out-Null
        Copy-Item "$src\bin\*" "$INSTALL_DIR\bin\$config\" -Recurse
    }
}

foreach ($config in $configs) {
    Remove-Item -Recurse -Force "$ROOT\install\_temp_${Arch}_$config"
}

# ---------- Package ----------
if ($Package) {
    Write-Step "Packaging"
    $zipName = "libcxx-$LLVMVersion-windows-$Arch-$ABINamespace.zip"
    $zipPath = "$ROOT\$zipName"
    if (Test-Path $zipPath) { Remove-Item $zipPath }
    Compress-Archive -Path "$INSTALL_DIR\*" -DestinationPath $zipPath
    Write-Host "Package: $zipPath"
}

Write-Step "Done (LLVM $LLVMVersion, $Arch, ABI namespace: $ABINamespace)"
Write-Host "Installed to: $INSTALL_DIR" -ForegroundColor Green
