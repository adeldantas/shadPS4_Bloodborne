param(
    [string]$SourceRoot = (Get-Location).Path,
    [string]$BuildRoot = "",
    [switch]$CompilerGateSelfTest
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Normalize-CompilerPath([string]$Value) {
    if ($null -eq $Value) { return $null }
    $v = $Value.Trim()
    if ($v.Length -ge 2 -and (($v.StartsWith('"') -and $v.EndsWith('"')) -or ($v.StartsWith("'") -and $v.EndsWith("'")))) {
        $v = $v.Substring(1, $v.Length - 2).Trim()
    }
    $v = $v -replace '/', '\\'
    while ($v.Length -gt 3 -and $v.EndsWith('\')) { $v = $v.Substring(0, $v.Length - 1) }
    return $v.ToLowerInvariant()
}

function Get-CMakeCacheValue([string]$CacheText, [string]$Key) {
    $pattern = '(?m)^' + [regex]::Escape($Key) + ':(?<type>[^=\r\n]+)=(?<value>[^\r\n]*)$'
    $matches = [regex]::Matches($CacheText, $pattern)
    if ($matches.Count -ne 1) {
        throw "CMake cache key $Key expected exactly once; found $($matches.Count)"
    }
    return [pscustomobject]@{
        Key = $Key
        Type = $matches[0].Groups['type'].Value
        Raw = $matches[0].Groups['value'].Value
        Normalized = Normalize-CompilerPath $matches[0].Groups['value'].Value
    }
}

function Assert-PinnedCompilerCache([string]$CacheText, [string]$ExpectedPath, [string[]]$Keys) {
    $expected = Normalize-CompilerPath $ExpectedPath
    $entries = @()
    foreach ($key in $Keys) {
        $entry = Get-CMakeCacheValue $CacheText $key
        if ($entry.Normalized -ne $expected) {
            throw "CMake compiler identity mismatch for ${key}: raw='$($entry.Raw)' normalized='$($entry.Normalized)' expected='$expected'"
        }
        $entries += $entry
    }
    return $entries
}

function Invoke-CompilerGateSelfTest {
    $expected = 'C:\LLVM19\bin\clang-cl.exe'
    $keys = @('CMAKE_C_COMPILER', 'CMAKE_CXX_COMPILER', 'CMAKE_ASM_COMPILER')
    $state = [pscustomobject]@{ Pass = 0; Fail = 0 }

    function Expect-Pass([string]$Name, [string]$Text) {
        try {
            $null = Assert-PinnedCompilerCache $Text $expected $keys
            Write-Host "PASS $Name"
            $state.Pass++
        } catch {
            Write-Host "FAIL $Name :: $($_.Exception.Message)"
            $state.Fail++
        }
    }
    function Expect-Reject([string]$Name, [string]$Text) {
        try {
            $null = Assert-PinnedCompilerCache $Text $expected $keys
            Write-Host "FAIL $Name :: unexpectedly accepted"
            $state.Fail++
        } catch {
            Write-Host "PASS $Name :: rejected"
            $state.Pass++
        }
    }

    Expect-Pass 'forward-slashes-string' @'
CMAKE_C_COMPILER:STRING=C:/LLVM19/bin/clang-cl.exe
CMAKE_CXX_COMPILER:STRING=C:/LLVM19/bin/clang-cl.exe
CMAKE_ASM_COMPILER:STRING=C:/LLVM19/bin/clang-cl.exe
'@
    Expect-Pass 'backslashes-filepath' @'
CMAKE_C_COMPILER:FILEPATH=C:\LLVM19\bin\clang-cl.exe
CMAKE_CXX_COMPILER:FILEPATH=C:\LLVM19\bin\clang-cl.exe
CMAKE_ASM_COMPILER:FILEPATH=C:\LLVM19\bin\clang-cl.exe
'@
    Expect-Pass 'outer-quotes-case-insensitive' @'
CMAKE_C_COMPILER:STRING="c:/llvm19/BIN/CLANG-CL.EXE"
CMAKE_CXX_COMPILER:STRING="c:/llvm19/BIN/CLANG-CL.EXE"
CMAKE_ASM_COMPILER:STRING="c:/llvm19/BIN/CLANG-CL.EXE"
'@
    Expect-Reject 'llvm20' @'
CMAKE_C_COMPILER:STRING=C:/LLVM20/bin/clang-cl.exe
CMAKE_CXX_COMPILER:STRING=C:/LLVM20/bin/clang-cl.exe
CMAKE_ASM_COMPILER:STRING=C:/LLVM20/bin/clang-cl.exe
'@
    Expect-Reject 'different-executable' @'
CMAKE_C_COMPILER:STRING=C:/LLVM19/bin/clang.exe
CMAKE_CXX_COMPILER:STRING=C:/LLVM19/bin/clang.exe
CMAKE_ASM_COMPILER:STRING=C:/LLVM19/bin/clang.exe
'@
    Expect-Reject 'missing-key' @'
CMAKE_C_COMPILER:STRING=C:/LLVM19/bin/clang-cl.exe
CMAKE_CXX_COMPILER:STRING=C:/LLVM19/bin/clang-cl.exe
'@
    Expect-Reject 'inconsistent-entries' @'
CMAKE_C_COMPILER:STRING=C:/LLVM19/bin/clang-cl.exe
CMAKE_CXX_COMPILER:STRING=C:/LLVM20/bin/clang-cl.exe
CMAKE_ASM_COMPILER:STRING=C:/LLVM19/bin/clang-cl.exe
'@
    Expect-Reject 'path-only-in-comment' @'
// CMAKE_C_COMPILER:STRING=C:/LLVM19/bin/clang-cl.exe
CMAKE_C_COMPILER:STRING=C:/LLVM20/bin/clang-cl.exe
CMAKE_CXX_COMPILER:STRING=C:/LLVM20/bin/clang-cl.exe
CMAKE_ASM_COMPILER:STRING=C:/LLVM20/bin/clang-cl.exe
'@

    Write-Host "COMPILER_GATE_FIXTURES pass=$($state.Pass) fail=$($state.Fail)"
    if ($state.Fail -ne 0) { throw "Compiler gate fixtures failed: $($state.Fail)" }
}

if ($CompilerGateSelfTest) {
    Invoke-CompilerGateSelfTest
    return
}

if (-not $BuildRoot) {
    $BuildRoot = Join-Path $SourceRoot "build-clean1"
}

$Clang = 'C:\LLVM19\bin\clang-cl.exe'
if (-not (Test-Path -LiteralPath $Clang)) {
    throw "Pinned compiler missing: $Clang"
}

foreach ($name in @('CPATH', 'CPLUS_INCLUDE_PATH', 'C_INCLUDE_PATH')) {
    [Environment]::SetEnvironmentVariable($name, $null, 'Process')
}
$pathParts = $env:PATH -split ';' | Where-Object {
    $_ -and ($_ -notmatch '(?i)\\msys64\\') -and ($_ -notmatch '(?i)\\mingw')
}
$env:PATH = (($pathParts | Select-Object -Unique) -join ';')

$bad = @()
foreach ($name in @('CPATH', 'CPLUS_INCLUDE_PATH', 'C_INCLUDE_PATH', 'INCLUDE', 'LIB', 'LIBPATH', 'PATH')) {
    $v = [Environment]::GetEnvironmentVariable($name, 'Process')
    if ($v -and $v -match '(?i)msys|mingw') { $bad += "$name=$v" }
}
if ($bad.Count -gt 0) {
    throw ("MinGW/MSYS contamination remains after sanitization:`n" + ($bad -join "`n"))
}

$clangVersion = (& $Clang --version | Out-String)
if ($LASTEXITCODE -ne 0 -or $clangVersion -notmatch 'clang version 19\.1\.1') {
    throw "Pinned clang-cl is not 19.1.1:`n$clangVersion"
}

$CMake = (Get-Command cmake.exe -ErrorAction Stop).Source
$Ninja = (Get-Command ninja.exe -ErrorAction Stop).Source
$CMakeVersion = (& $CMake --version | Out-String)
$NinjaVersion = (& $Ninja --version | Out-String)

@(
    "source_root=$SourceRoot"
    "build_root=$BuildRoot"
    "clang=$Clang"
    "cmake=$CMake"
    "ninja=$Ninja"
    "qt_root=$env:QT_ROOT_DIR"
    "clang_version=$($clangVersion.Trim())"
    "cmake_version=$($CMakeVersion.Trim())"
    "ninja_version=$($NinjaVersion.Trim())"
) | Out-File clean1_toolchain.txt -Encoding utf8

if (Test-Path -LiteralPath $BuildRoot) { Remove-Item -Recurse -Force $BuildRoot }

$cmakeArgs = @(
    '--fresh',
    '-S', $SourceRoot,
    '-B', $BuildRoot,
    '-G', 'Ninja',
    '-DCMAKE_BUILD_TYPE=Release',
    '-DENABLE_QT_GUI=ON',
    '-DENABLE_UPDATER=ON',
    '-DCMAKE_INTERPROCEDURAL_OPTIMIZATION_RELEASE=ON',
    "-DCMAKE_C_COMPILER=$Clang",
    "-DCMAKE_CXX_COMPILER=$Clang",
    "-DCMAKE_ASM_COMPILER=$Clang",
    "-DCMAKE_MAKE_PROGRAM=$Ninja"
)
if ($env:QT_ROOT_DIR) { $cmakeArgs += "-DCMAKE_PREFIX_PATH=$env:QT_ROOT_DIR" }

Write-Host "CONFIGURE: $CMake $($cmakeArgs -join ' ')"
& $CMake @cmakeArgs 2>&1 | Tee-Object clean1_cmake_configure.log
if ($LASTEXITCODE -ne 0) { throw "CMake configure failed: $LASTEXITCODE" }

$cache = Join-Path $BuildRoot 'CMakeCache.txt'
if (-not (Test-Path -LiteralPath $cache)) { throw 'CMakeCache.txt missing after configure' }
$cacheText = Get-Content -LiteralPath $cache -Raw
$compilerEntries = Assert-PinnedCompilerCache $cacheText $Clang @('CMAKE_C_COMPILER', 'CMAKE_CXX_COMPILER', 'CMAKE_ASM_COMPILER')
@(
    "expected_raw=$Clang"
    "expected_normalized=$(Normalize-CompilerPath $Clang)"
    $compilerEntries | ForEach-Object { "$($_.Key)_type=$($_.Type)`n$($_.Key)_raw=$($_.Raw)`n$($_.Key)_normalized=$($_.Normalized)" }
) | Out-File clean1_compiler_identity.txt -Encoding utf8

if ($cacheText -match '(?i)msys|mingw') { throw 'CMake cache contains MinGW/MSYS contamination' }

Write-Host 'BUILD'
$parallel = if ($env:NUMBER_OF_PROCESSORS) { $env:NUMBER_OF_PROCESSORS } else { '2' }
& $CMake --build $BuildRoot --config Release --parallel $parallel 2>&1 | Tee-Object clean1_build.log
if ($LASTEXITCODE -ne 0) { throw "CMake build failed: $LASTEXITCODE" }

$Exe = Get-ChildItem -LiteralPath $BuildRoot -Recurse -Filter 'shadPS4.exe' | Select-Object -First 1
if (-not $Exe) { throw 'shadPS4.exe not produced' }
$Recorder = Get-ChildItem -LiteralPath $BuildRoot -Recurse -Filter 'bb_blackbox_recorder.exe' | Select-Object -First 1
if (-not $Recorder) { throw 'bb_blackbox_recorder.exe not produced' }

Get-FileHash -LiteralPath $Exe.FullName -Algorithm SHA256 | Format-List | Out-File clean1_output_hashes.txt -Encoding utf8
Get-FileHash -LiteralPath $Recorder.FullName -Algorithm SHA256 | Format-List | Out-File clean1_output_hashes.txt -Append -Encoding utf8
if (Test-Path -LiteralPath (Join-Path $BuildRoot 'compile_commands.json')) {
    Copy-Item -LiteralPath (Join-Path $BuildRoot 'compile_commands.json') clean1_compile_commands.json -Force
}

Write-Host 'CLEAN1 Tier-B build completed'
Write-Host "shadPS4: $($Exe.FullName)"
Write-Host "recorder: $($Recorder.FullName)"
