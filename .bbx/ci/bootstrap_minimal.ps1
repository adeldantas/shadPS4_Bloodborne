$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$BaselineSha = '03d62ad22438344f1dcd38c5b5e44f660b564b92'
$BaselineTree = 'a71d05341ad927c1c3fb7ff56b04a2b52aa2beb1'
$Ready4Sha = '0b709de7e6c588b76786d8b648d5f669563c0bf45df5ec44a63db56f869e795f'
$ParentSha256 = '92ee02584cae06cc4feace76dcbfdaadcca225e3a005b1038246850fa154c485'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Diag = Join-Path $env:RUNNER_TEMP 'bbx-minimal-diagnostics'
$Src = Join-Path $env:RUNNER_TEMP 'bb-clean1-minimal-source'
$Runtime = Join-Path $env:RUNNER_TEMP 'bb-clean1-minimal-runtime'
$Reopened = Join-Path $env:RUNNER_TEMP 'bb-clean1-minimal-reopened'
$ZipOut = Join-Path $env:RUNNER_TEMP 'BLACKBOX_V1_CI_CLEAN1_MINIMAL_WIN64_QT.zip'

New-Item -ItemType Directory -Path $Diag -Force | Out-Null

function Save-Diag([string]$Name, [string]$Text) {
    $Text | Set-Content -LiteralPath (Join-Path $Diag $Name) -Encoding utf8
}

function Require-ExitCode([string]$Stage) {
    if ($LASTEXITCODE -ne 0) {
        throw "$Stage failed with exit code $LASTEXITCODE"
    }
}

function Get-CMakeCacheValue([string]$CacheText, [string]$Key) {
    $pattern = '(?m)^' + [regex]::Escape($Key) + ':[^=\r\n]+=(?<value>[^\r\n]*)$'
    $matches = [regex]::Matches($CacheText, $pattern)
    if ($matches.Count -ne 1) {
        throw "CMake cache key $Key expected exactly once; found $($matches.Count)"
    }
    return $matches[0].Groups['value'].Value.Trim().Trim([char]34)
}

function Normalize-WindowsPath([string]$Value) {
    return $Value.Replace('/', '\').TrimEnd('\').ToLowerInvariant()
}

try {
    $checkout = (git -C $RepoRoot rev-parse HEAD).Trim()
    Require-ExitCode 'candidate HEAD read'

    $candidate = $checkout
    if ($env:GITHUB_EVENT_PATH -and (Test-Path -LiteralPath $env:GITHUB_EVENT_PATH)) {
        $event = Get-Content -LiteralPath $env:GITHUB_EVENT_PATH -Raw | ConvertFrom-Json
        if (($event.PSObject.Properties.Name -contains 'pull_request') -and $event.pull_request -and $event.pull_request.head.sha) {
            $candidate = [string]$event.pull_request.head.sha
        }
    }
    Save-Diag 'candidate-identity.txt' "event=$env:GITHUB_EVENT_NAME`ncheckout=$checkout`ncandidate=$candidate"
    if ($checkout -ne $candidate) {
        throw "Candidate checkout mismatch: checkout=$checkout candidate=$candidate"
    }

    $tree = (git -C $RepoRoot rev-parse "$BaselineSha`^{tree}").Trim()
    Require-ExitCode 'baseline tree read'
    if ($tree -ne $BaselineTree) {
        throw "Frozen baseline tree mismatch: $tree"
    }
    Save-Diag 'baseline.txt' "commit=$BaselineSha`ntree=$tree"

    $parts = @(
        '.bbx/package/ready4.b64.part01',
        '.bbx/package/ready4.b64.part02',
        '.bbx/package/ready4.b64.part03',
        '.bbx/package/ready4.b64.part04',
        '.bbx/package/ready4.b64.part05',
        '.bbx/package/ready4.b64.part06',
        '.bbx/package/ready4.b64.part07a',
        '.bbx/package/ready4.b64.part07b',
        '.bbx/package/ready4.b64.part08',
        '.bbx/package/ready4.b64.part09',
        '.bbx/package/ready4.b64.part10a',
        '.bbx/package/ready4.b64.part10b',
        '.bbx/package/ready4.b64.part11a',
        '.bbx/package/ready4.b64.part11b',
        '.bbx/package/ready4.b64.part12a',
        '.bbx/package/ready4.b64.part12b',
        '.bbx/package/ready4.b64.part13'
    )

    Push-Location $RepoRoot
    try {
        foreach ($part in $parts) {
            if (-not (Test-Path -LiteralPath $part)) {
                throw "Missing READY4 transport chunk: $part"
            }
        }
        $b64 = ($parts | ForEach-Object { (Get-Content -LiteralPath $_ -Raw).Trim() }) -join ''
    }
    finally {
        Pop-Location
    }

    if ($b64.Length -ne 122832) {
        throw "SOURCE_READY4 base64 length mismatch: $($b64.Length)"
    }

    $ready4Zip = Join-Path $env:RUNNER_TEMP 'SOURCE_READY4.zip'
    [IO.File]::WriteAllBytes($ready4Zip, [Convert]::FromBase64String($b64))
    $ready4Hash = (Get-FileHash -LiteralPath $ready4Zip -Algorithm SHA256).Hash.ToLowerInvariant()
    Save-Diag 'ready4-sha256.txt' $ready4Hash
    if ($ready4Hash -ne $Ready4Sha) {
        throw "SOURCE_READY4 SHA256 mismatch: $ready4Hash"
    }

    $packageRoot = Join-Path $env:RUNNER_TEMP 'ready4-minimal-package'
    if (Test-Path -LiteralPath $packageRoot) { Remove-Item -LiteralPath $packageRoot -Recurse -Force }
    Expand-Archive -LiteralPath $ready4Zip -DestinationPath $packageRoot

    $apply = Get-ChildItem -LiteralPath $packageRoot -Recurse -Filter 'APPLY_CLEAN1_SOURCE_READY.ps1' | Select-Object -First 1
    if (-not $apply) { throw 'APPLY_CLEAN1_SOURCE_READY.ps1 not found in verified READY4 package' }
    $verifiedRoot = $apply.Directory.Parent.FullName

    $parentPatch = Get-ChildItem -LiteralPath $verifiedRoot -Recurse -Filter 'INTEGRATED_R3_SAVEFIX_S1.patch' | Select-Object -First 1
    if (-not $parentPatch) { throw 'INTEGRATED_R3_SAVEFIX_S1.patch missing from READY4 package' }
    $parentHash = (Get-FileHash -LiteralPath $parentPatch.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    Save-Diag 'parent-sha256.txt' $parentHash
    if ($parentHash -ne $ParentSha256) {
        throw "Parent R3-SAVEFIX-S1 SHA256 mismatch: $parentHash"
    }

    if (Test-Path -LiteralPath $Src) { Remove-Item -LiteralPath $Src -Recurse -Force }
    git -C $RepoRoot worktree add --detach $Src $BaselineSha
    Require-ExitCode 'frozen baseline worktree creation'

    $srcHead = (git -C $Src rev-parse HEAD).Trim()
    Require-ExitCode 'source HEAD read'
    if ($srcHead -ne $BaselineSha) { throw "Source worktree baseline mismatch: $srcHead" }

    git -C $Src submodule sync --recursive
    Require-ExitCode 'submodule sync'
    git -C $Src submodule update --init --recursive
    Require-ExitCode 'submodule update'

    & $apply.FullName -RepoRoot $Src
    Require-ExitCode 'CLEAN1 source application'

    Push-Location $Src
    try {
        & '.\ci\VERIFY_EXACT_PARENT_REPLAY.ps1'
        Require-ExitCode 'exact parent replay verification'

        python tools/bb_blackbox/decode.py --self-test
        Require-ExitCode 'decoder self-test'
        python ci/test_verify_clean1.py
        Require-ExitCode 'CLEAN1 semantic regression tests'
        python ci/verify_clean1.py
        Require-ExitCode 'CLEAN1 semantic verification'

        git status --short | Out-File (Join-Path $Diag 'source-status-after-apply.txt') -Encoding utf8
        git diff --stat | Out-File (Join-Path $Diag 'source-diff-stat.txt') -Encoding utf8

        & '.\ci\INSTALL_LLVM_CLEAN1.ps1'
        Require-ExitCode 'LLVM 19.1.1 installation'
    }
    finally {
        Pop-Location
    }

    $Clang = 'C:\LLVM19\bin\clang-cl.exe'
    if (-not (Test-Path -LiteralPath $Clang)) {
        throw "Pinned compiler missing: $Clang"
    }

    foreach ($name in @('CPATH', 'CPLUS_INCLUDE_PATH', 'C_INCLUDE_PATH')) {
        [Environment]::SetEnvironmentVariable($name, $null, 'Process')
    }
    $env:PATH = (($env:PATH -split ';' | Where-Object {
        $_ -and ($_ -notmatch '(?i)\\msys64\\') -and ($_ -notmatch '(?i)\\mingw')
    } | Select-Object -Unique) -join ';')

    $clangVersion = (& $Clang --version | Out-String)
    Require-ExitCode 'clang-cl version query'
    if ($clangVersion -notmatch 'clang version 19\.1\.1') {
        throw "Pinned clang-cl is not 19.1.1:`n$clangVersion"
    }

    $CMake = (Get-Command cmake.exe -ErrorAction Stop).Source
    $Ninja = (Get-Command ninja.exe -ErrorAction Stop).Source
    $cmakeVersion = (& $CMake --version | Out-String).Trim()
    Require-ExitCode 'CMake version query'
    $ninjaVersion = (& $Ninja --version | Out-String).Trim()
    Require-ExitCode 'Ninja version query'
    Save-Diag 'toolchain.txt' "clang=$Clang`n$($clangVersion.Trim())`ncmake=$CMake`n$cmakeVersion`nninja=$Ninja`n$ninjaVersion`nqt=$env:QT_ROOT_DIR"

    $buildRoot = Join-Path $Src 'build-clean1-minimal'
    if (Test-Path -LiteralPath $buildRoot) { Remove-Item -LiteralPath $buildRoot -Recurse -Force }

    $cmakeArgs = @(
        '--fresh',
        '-S', $Src,
        '-B', $buildRoot,
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
    if ($env:QT_ROOT_DIR) {
        $cmakeArgs += "-DCMAKE_PREFIX_PATH=$env:QT_ROOT_DIR"
    }

    & $CMake @cmakeArgs 2>&1 | Tee-Object (Join-Path $Diag 'cmake-configure.log')
    Require-ExitCode 'CMake configure'

    $cachePath = Join-Path $buildRoot 'CMakeCache.txt'
    if (-not (Test-Path -LiteralPath $cachePath)) { throw 'CMakeCache.txt missing after configure' }
    $cacheText = Get-Content -LiteralPath $cachePath -Raw

    $expectedCompiler = Normalize-WindowsPath $Clang
    $identityLines = @("expected=$expectedCompiler")
    foreach ($key in @('CMAKE_C_COMPILER', 'CMAKE_CXX_COMPILER', 'CMAKE_ASM_COMPILER')) {
        $raw = Get-CMakeCacheValue $cacheText $key
        $normalized = Normalize-WindowsPath $raw
        $identityLines += "$key=$raw"
        $identityLines += "${key}_normalized=$normalized"
        if ($normalized -ne $expectedCompiler) {
            throw "Compiler identity mismatch for ${key}: raw='$raw' normalized='$normalized' expected='$expectedCompiler'"
        }
        $reported = (& $raw --version | Out-String)
        Require-ExitCode "$key version query"
        if ($reported -notmatch 'clang version 19\.1\.1') {
            throw "$key does not resolve to clang 19.1.1"
        }
    }
    $identityLines | Set-Content -LiteralPath (Join-Path $Diag 'compiler-identity.txt') -Encoding utf8

    $parallel = if ($env:NUMBER_OF_PROCESSORS) { $env:NUMBER_OF_PROCESSORS } else { '2' }
    & $CMake --build $buildRoot --config Release --parallel $parallel 2>&1 | Tee-Object (Join-Path $Diag 'build.log')
    Require-ExitCode 'Windows CLEAN1 build'

    $shad = Get-ChildItem -LiteralPath $buildRoot -Recurse -Filter 'shadPS4.exe' | Select-Object -First 1
    $recorder = Get-ChildItem -LiteralPath $buildRoot -Recurse -Filter 'bb_blackbox_recorder.exe' | Select-Object -First 1
    if (-not $shad) { throw 'shadPS4.exe not produced' }
    if (-not $recorder) { throw 'bb_blackbox_recorder.exe not produced' }

    Save-Diag 'built-binaries.txt' "shadPS4=$($shad.FullName)`nshadPS4_sha256=$((Get-FileHash $shad.FullName -Algorithm SHA256).Hash.ToLowerInvariant())`nrecorder=$($recorder.FullName)`nrecorder_sha256=$((Get-FileHash $recorder.FullName -Algorithm SHA256).Hash.ToLowerInvariant())"

    foreach ($path in @($Runtime, $Reopened)) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
    }
    New-Item -ItemType Directory -Path $Runtime -Force | Out-Null

    Copy-Item -LiteralPath $shad.FullName -Destination (Join-Path $Runtime 'shadPS4.exe')
    Copy-Item -LiteralPath $recorder.FullName -Destination (Join-Path $Runtime 'bb_blackbox_recorder.exe')

    foreach ($dir in @($shad.Directory.FullName, $recorder.Directory.FullName) | Select-Object -Unique) {
        Get-ChildItem -LiteralPath $dir -Filter '*.dll' -File -ErrorAction SilentlyContinue | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $Runtime -Force
        }
        Get-ChildItem -LiteralPath $dir -Filter '*.pdb' -File -ErrorAction SilentlyContinue | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $Runtime -Force
        }
    }

    $qtConf = Join-Path $Src 'dist\qt.conf'
    if (Test-Path -LiteralPath $qtConf) {
        Copy-Item -LiteralPath $qtConf -Destination (Join-Path $Runtime 'qt.conf')
    }

    $windeployqt = (Get-Command windeployqt.exe -ErrorAction Stop).Source
    $pluginDir = Join-Path $Runtime 'qtplugins'
    New-Item -ItemType Directory -Path $pluginDir -Force | Out-Null
    & $windeployqt --release --plugindir $pluginDir --dir $Runtime (Join-Path $Runtime 'shadPS4.exe') 2>&1 | Tee-Object (Join-Path $Diag 'windeployqt.log')
    Require-ExitCode 'windeployqt'

    $toolsDir = Join-Path $Runtime 'tools\bb_blackbox'
    New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $Src 'tools\bb_blackbox\decode.py') -Destination (Join-Path $toolsDir 'decode.py')
    Copy-Item -LiteralPath (Join-Path $RepoRoot '.bbx\ci\run_blackbox_patchfix3.ps1') -Destination (Join-Path $toolsDir 'run_blackbox.ps1')
    Copy-Item -LiteralPath (Join-Path $RepoRoot '.bbx\ci\run_blackbox_patchfix3.cmd') -Destination (Join-Path $toolsDir 'run_blackbox.cmd')

    @'
@echo off
setlocal
cd /d "%~dp0"
call "%~dp0tools\bb_blackbox\run_blackbox.cmd" "%~dp0shadPS4.exe"
exit /b %ERRORLEVEL%
'@ | Set-Content -LiteralPath (Join-Path $Runtime 'RUN_BLACKBOX.cmd') -Encoding ascii

    @(
        'CAPTURE_READINESS=NOT_READY',
        'RUNTIME_TEST_ALLOWED=false',
        'unresolved=submit identity collision; query lifecycle/final collection; CONTROL query inactivity; frame/present semantics; nested GPU duration semantics'
    ) | Set-Content -LiteralPath (Join-Path $Runtime 'CAPTURE-READINESS.txt') -Encoding ascii

    $evidenceDir = Join-Path $Runtime 'evidence'
    New-Item -ItemType Directory -Path $evidenceDir -Force | Out-Null
    if (Test-Path -LiteralPath (Join-Path $Src 'ci\evidence')) {
        Copy-Item -Path (Join-Path $Src 'ci\evidence\*') -Destination $evidenceDir -Recurse -Force
    }
    Copy-Item -LiteralPath $ready4Zip -Destination (Join-Path $evidenceDir 'SOURCE_READY4_INPUT.zip')
    Copy-Item -LiteralPath (Join-Path $Diag 'compiler-identity.txt') -Destination (Join-Path $evidenceDir 'compiler-identity.txt')
    Copy-Item -LiteralPath (Join-Path $Diag 'parent-sha256.txt') -Destination (Join-Path $evidenceDir 'parent-sha256.txt')

    $required = @(
        'shadPS4.exe',
        'bb_blackbox_recorder.exe',
        'RUN_BLACKBOX.cmd',
        'tools\bb_blackbox\decode.py',
        'tools\bb_blackbox\run_blackbox.cmd',
        'tools\bb_blackbox\run_blackbox.ps1',
        'CAPTURE-READINESS.txt'
    )
    foreach ($name in $required) {
        if (-not (Test-Path -LiteralPath (Join-Path $Runtime $name))) {
            throw "Missing runtime file: $name"
        }
    }
    if (-not (Get-ChildItem -LiteralPath $Runtime -Recurse -Filter 'qwindows.dll' -ErrorAction SilentlyContinue | Select-Object -First 1)) {
        throw 'qwindows.dll missing after windeployqt'
    }

    $manifestPath = Join-Path $Runtime 'SHA256SUMS-CLEAN1-RUNTIME.txt'
    Get-ChildItem -LiteralPath $Runtime -Recurse -File |
        Where-Object { $_.FullName -ne $manifestPath } |
        Sort-Object FullName |
        ForEach-Object {
            $relative = [IO.Path]::GetRelativePath($Runtime, $_.FullName).Replace('\', '/')
            $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            "$hash  $relative"
        } | Set-Content -LiteralPath $manifestPath -Encoding ascii

    if (Test-Path -LiteralPath $ZipOut) { Remove-Item -LiteralPath $ZipOut -Force }
    Compress-Archive -Path (Join-Path $Runtime '*') -DestinationPath $ZipOut -CompressionLevel Optimal

    Expand-Archive -LiteralPath $ZipOut -DestinationPath $Reopened
    $reopenedManifest = Join-Path $Reopened 'SHA256SUMS-CLEAN1-RUNTIME.txt'
    if (-not (Test-Path -LiteralPath $reopenedManifest)) { throw 'Runtime SHA256 manifest missing after ZIP reopen' }
    foreach ($line in Get-Content -LiteralPath $reopenedManifest) {
        if ($line -notmatch '^([0-9a-f]{64})  (.+)$') { throw "Malformed runtime manifest line: $line" }
        $file = Join-Path $Reopened ($Matches[2].Replace('/', '\'))
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Manifest file missing after reopen: $($Matches[2])" }
        $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($hash -ne $Matches[1]) { throw "Manifest SHA256 mismatch after reopen: $($Matches[2])" }
    }
    Save-Diag 'package-reopen.txt' 'PACKAGE_REOPEN_MANIFEST=PASS'

    $smokeDir = Join-Path $env:RUNNER_TEMP 'bb-clean1-minimal-smoke'
    if (Test-Path -LiteralPath $smokeDir) { Remove-Item -LiteralPath $smokeDir -Recurse -Force }
    New-Item -ItemType Directory -Path $smokeDir -Force | Out-Null

    $producerCpp = Join-Path $smokeDir 'synthetic_producer.cpp'
    @'
#include "common/bb_blackbox/recorder.h"
#include "common/bb_blackbox/schema.h"
#include "common/bb_blackbox/sites.h"
int main() {
    namespace B = Common::Blackbox;
    auto& r = B::Recorder::Instance();
    if (!r.InitializeFromEnvironment()) return 20;
    for (unsigned long long i = 0; i < 3000; ++i) {
        if (r.Emit(B::EventId::Heartbeat, B::Site::Unknown, B::EventFlags::None, B::PayloadKind::None, i, 0, 0) == 0) return 21;
    }
    r.ShutdownProducer();
    return 0;
}
'@ | Set-Content -LiteralPath $producerCpp -Encoding ascii

    $producerExe = Join-Path $smokeDir 'synthetic_producer.exe'
    & $Clang /nologo /std:c++20 /EHsc /O2 /DNOMINMAX /DWIN32_LEAN_AND_MEAN "/I$Src\src" $producerCpp (Join-Path $Src 'src\common\bb_blackbox\recorder.cpp') "/Fe:$producerExe" 2>&1 | Tee-Object (Join-Path $Diag 'synthetic-build.log')
    Require-ExitCode 'synthetic producer build'

    Push-Location $smokeDir
    try {
        & (Join-Path $Reopened 'tools\bb_blackbox\run_blackbox.cmd') $producerExe 2>&1 | Tee-Object (Join-Path $Diag 'synthetic-launcher.log')
        Require-ExitCode 'synthetic launcher/recorder smoke'
    }
    finally {
        Pop-Location
    }

    $capture = Get-ChildItem -LiteralPath $smokeDir -Directory -Filter 'BB_BLACKBOX_*' |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    if (-not $capture) { throw 'Synthetic smoke produced no capture directory' }

    $decodedText = (python (Join-Path $Reopened 'tools\bb_blackbox\decode.py') $capture.FullName | Out-String)
    Require-ExitCode 'synthetic capture decode'
    $decodedText | Set-Content -LiteralPath (Join-Path $Diag 'synthetic-decode.json') -Encoding utf8
    $decoded = $decodedText | ConvertFrom-Json
    if (-not $decoded.capture_complete) { throw 'Synthetic capture is incomplete' }
    if ([int64]$decoded.event_count -lt 3000) { throw "Synthetic capture event_count too small: $($decoded.event_count)" }
    if (-not $decoded.event_loss_free) { throw 'Synthetic capture reports event loss' }
    Save-Diag 'smoke-pass.txt' "SMOKE_PASS=true`ndecoded_events=$($decoded.event_count)"

    $zipHash = (Get-FileHash -LiteralPath $ZipOut -Algorithm SHA256).Hash.ToLowerInvariant()
    Save-Diag 'runtime-zip-sha256.txt' $zipHash
    Save-Diag 'result.txt' @"
SOURCE_VALIDATED=PASS
WINDOWS_BUILD_PASS=PASS
PACKAGE_PASS=PASS
SMOKE_PASS=PASS
CAPTURE_READINESS=NOT_READY
CAPTURE_VALIDATED=NO
RUNTIME_TEST_ALLOWED=false
RUNTIME_ZIP_SHA256=$zipHash
"@

    "RUNTIME_ZIP=$ZipOut" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
    Write-Host "BLACKBOX_MINIMAL_PASS sha256=$zipHash capture_readiness=NOT_READY"
}
catch {
    Save-Diag 'failure.txt' ($_ | Out-String)
    if (Test-Path -LiteralPath $Src) {
        try { git -C $Src status --short | Set-Content -LiteralPath (Join-Path $Diag 'failure-source-status.txt') -Encoding utf8 } catch {}
        try {
            if (Test-Path -LiteralPath (Join-Path $Src 'ci\evidence')) {
                Copy-Item -LiteralPath (Join-Path $Src 'ci\evidence') -Destination (Join-Path $Diag 'ci-evidence') -Recurse -Force
            }
        } catch {}
    }
    throw
}
finally {
    if (Test-Path -LiteralPath $Src) {
        try { git -C $RepoRoot worktree remove --force $Src | Out-Null } catch {}
    }
    try { git -C $RepoRoot worktree prune | Out-Null } catch {}
}
