param(
    [Parameter(Mandatory=$true)][string]$WorkflowHead
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Baseline = '03d62ad22438344f1dcd38c5b5e44f660b564b92'
$BaselineTree = 'a71d05341ad927c1c3fb7ff56b04a2b52aa2beb1'
$HarnessSha = '184e040de310f54024866adc6d5aa540d495a5fa'
$HarnessTree = '07f00408ff3d39a8205f0d3e84a63b3d82ecc750'
$ReadyZipSha = '0b709de7e6c588b76786d8b648d5f669563c0bf45df5ec44a63db56f869e795f'
$FixZipSha = '13144512830870296d297ebbe194dd8a2d30d9c8eb57358654b67392a7824308'
$ParentSha = '92ee02584cae06cc4feace76dcbfdaadcca225e3a005b1038246850fa154c485'
$IntegrationSha = '9e998761b9aefdf7649f001a0ffaf875755733cf4b3885d63a8aec349fd34efa'
$ApplySha = '010afb53115ad3e550d0bec21d697a857742245c491919b1dc1ac82fb0010466'
$InstallerSha = '9d597669e641cc7d163dd39db798142f39346b33b38620a971aae637df0f6705'
$AuditorSha = 'cb258fe7fa82f480779c856a4f97def6447c1a7ce132797a4f16537cb329f46a'
$DecoderSha = '8ffba834187630f16e34d82ae37ed06546ddc25eed0d87e7e8e48a2aa5089147'
$LauncherPsSha = 'eaaec92a072abbda4119edae6880667ef3cbd43d48fa784c805c555fb1b2d0ae'
$LauncherCmdSha = '22752522a5c39813ceb66d4099a716cbf226b17e0bf4e03b29d898b995e53530'
$FixtureSha = 'cb10f6f78e7a17b53cec907e11850f31443be7bd8917e1e40e7bb72f4ea348b7'

$Harness = (Resolve-Path $env:GITHUB_WORKSPACE).Path
$Inputs = Join-Path $env:RUNNER_TEMP 'bb-clean1-inputs'
$Work = Join-Path $env:RUNNER_TEMP 'bb-clean1-contract-v1'
if (Test-Path -LiteralPath $Work) { throw 'STOP_WORKSPACE_NOT_FRESH' }
New-Item -ItemType Directory -Path $Work | Out-Null
$Diag = New-Item -ItemType Directory -Path (Join-Path $Work 'diagnostics')
$Diag = $Diag.FullName
$Src = Join-Path $Work 'source'
$Build = Join-Path $Work 'build-clean1'
$Runtime = Join-Path $Work 'runtime'
$Reopened = Join-Path $Work 'reopened'
$Smoke = Join-Path $Work 'smoke'
$Zip = Join-Path $Work 'BB_CLEAN1_WIN64_QT.zip'
$ReadyZip = Join-Path $Inputs 'BB_BLACKBOX_V1_CI_CLEAN1_SOURCE_READY4_2026-09-15.zip'
$FixZip = Join-Path $Inputs 'BB_BLACKBOX_V1_CI_CLEAN1_SOURCE_READY4_PATCHFIX1_2026-09-15.zip'
$Clang = 'C:\LLVM19\bin\clang-cl.exe'
$CMake = 'C:\Program Files\CMake\bin\cmake.exe'
$Ninja = (Get-Command ninja.exe -ErrorAction Stop).Source
$Python = (Get-Command python.exe -ErrorAction Stop).Source
$Qt = (Resolve-Path $env:QT_ROOT_DIR).Path
$DeployQt = Join-Path $Qt 'bin\windeployqt.exe'

$Stage = 'S0'
$SourceState = 'NOT_RUN'
$BuildState = 'NOT_RUN'
$PackageState = 'NOT_RUN'
$SmokeState = 'NOT_RUN'
$FirstFailure = ''

function Get-Sha256([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Assert-Hash([string]$Path, [string]$Expected, [string]$Code) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Code missing=$Path" }
    $Actual = Get-Sha256 $Path
    if ($Actual -ne $Expected) { throw "$Code expected=$Expected actual=$Actual path=$Path" }
}
function Write-Diag([string]$Name, [object]$Value) { $Value | Out-File -LiteralPath (Join-Path $Diag $Name) -Encoding utf8 }
function Check-Native([string]$Code) { if ($LASTEXITCODE -ne 0) { throw "$Code exit=$LASTEXITCODE" } }
function Normalize-WindowsPath([string]$Value) { return $Value.Trim().Trim('"').Replace('/','\').TrimEnd('\').ToLowerInvariant() }
function Get-CacheEntry([string[]]$Lines, [string]$Key) {
    $Entries = @($Lines | Where-Object { $_ -match ('^' + [regex]::Escape($Key) + ':[^=]+=') })
    if ($Entries.Count -ne 1) { throw "STOP_S3_CACHE_KEY $Key count=$($Entries.Count)" }
    return $Entries[0].Substring($Entries[0].IndexOf('=') + 1).Trim().Trim('"')
}
function Verify-Manifest([string]$Root, [string]$ManifestName, [int]$ExpectedCount) {
    $ManifestPath = Join-Path $Root $ManifestName
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { throw 'STOP_MANIFEST_MISSING_FILE' }
    $Rows = @(Get-Content -LiteralPath $ManifestPath | Where-Object { $_.Length -gt 0 })
    if ($Rows.Count -ne $ExpectedCount) { throw "STOP_MANIFEST_COUNT expected=$ExpectedCount actual=$($Rows.Count)" }
    $Seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($Row in $Rows) {
        if ($Row -notmatch '^([0-9a-f]{64})  (.+)$') { throw "STOP_MANIFEST_SYNTAX row=$Row" }
        $Expected = $Matches[1]; $Rel = $Matches[2]
        if ([IO.Path]::IsPathRooted($Rel) -or $Rel.Contains(':') -or $Rel.Contains('\') -or ($Rel.Split('/') -contains '..') -or $Rel -eq $ManifestName -or -not $Seen.Add($Rel)) { throw "STOP_MANIFEST_PATH rel=$Rel" }
        $File = Join-Path $Root $Rel
        if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { throw "STOP_MANIFEST_MISSING rel=$Rel" }
        if ((Get-Sha256 $File) -ne $Expected) { throw "STOP_MANIFEST_HASH rel=$Rel" }
    }
    $Actual = @(Get-ChildItem -LiteralPath $Root -Recurse -File | ForEach-Object { [IO.Path]::GetRelativePath($Root,$_.FullName).Replace('\','/') } | Where-Object { $_ -ne $ManifestName })
    if ($Actual.Count -ne $Seen.Count) { throw "STOP_MANIFEST_FILESET listed=$($Seen.Count) actual=$($Actual.Count)" }
    foreach ($Rel in $Actual) { if (-not $Seen.Contains($Rel)) { throw "STOP_MANIFEST_EXTRA_FILE rel=$Rel" } }
}
function Copy-NoConflict([string]$Source, [string]$DestinationDir) {
    $Dest = Join-Path $DestinationDir ([IO.Path]::GetFileName($Source))
    if (Test-Path -LiteralPath $Dest) {
        if ((Get-Sha256 $Dest) -ne (Get-Sha256 $Source)) { throw "STOP_S5_COPY_CONFLICT file=$([IO.Path]::GetFileName($Source))" }
    } else { Copy-Item -LiteralPath $Source -Destination $Dest }
}

try {
    $Stage = 'S0'
    Write-Host '=== S0 environment / harness ==='
    if ($env:ImageVersion -ne '20260907.297.1') { throw "STOP_ENVIRONMENT_IDENTITY ImageVersion=$env:ImageVersion" }
    $HarnessHead = (git -C $Harness rev-parse HEAD).Trim(); Check-Native 'STOP_S0_HARNESS_HEAD'
    $ActualHarnessTree = (git -C $Harness rev-parse 'HEAD^{tree}').Trim(); Check-Native 'STOP_S0_HARNESS_TREE'
    if ($HarnessHead -ne $HarnessSha -or $ActualHarnessTree -ne $HarnessTree) { throw 'STOP_CI_CONTRACT_MISMATCH harness identity' }
    Write-Diag 'identity.txt' @("workflow_head=$WorkflowHead","harness_commit=$HarnessHead","harness_tree=$ActualHarnessTree","baseline=$Baseline","image_version=$env:ImageVersion","run_id=$env:GITHUB_RUN_ID","run_attempt=$env:GITHUB_RUN_ATTEMPT","job=$env:GITHUB_JOB","server=$env:GITHUB_SERVER_URL","repository=$env:GITHUB_REPOSITORY")

    $VsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    $VsVersion = (& $VsWhere -latest -products * -property installationVersion | Out-String).Trim(); Check-Native 'STOP_S0_VSWHERE'
    if ($VsVersion -ne '17.14.37614.0') { throw "STOP_ENVIRONMENT_IDENTITY VS=$VsVersion" }
    if ($env:VCToolsVersion.TrimEnd('\') -ne '14.44.35207') { throw "STOP_ENVIRONMENT_IDENTITY VCToolsVersion=$env:VCToolsVersion" }
    if ($env:WindowsSDKVersion.TrimEnd('\') -ne '10.0.26100.0') { throw "STOP_ENVIRONMENT_IDENTITY WindowsSDKVersion=$env:WindowsSDKVersion" }
    if ($PSVersionTable.PSVersion.ToString() -ne '7.6.5') { throw "STOP_ENVIRONMENT_IDENTITY PowerShell=$($PSVersionTable.PSVersion)" }
    if (-not (Test-Path -LiteralPath $CMake)) { throw 'STOP_ENVIRONMENT_IDENTITY CMake missing' }
    $CMakeVersion = (& $CMake --version | Select-Object -First 1); Check-Native 'STOP_S0_CMAKE_VERSION'
    if ($CMakeVersion -ne 'cmake version 3.31.6') { throw "STOP_ENVIRONMENT_IDENTITY $CMakeVersion" }
    $NinjaVersion = (& $Ninja --version | Out-String).Trim(); Check-Native 'STOP_S0_NINJA_VERSION'
    if ($NinjaVersion -ne '1.13.2') { throw "STOP_ENVIRONMENT_IDENTITY Ninja=$NinjaVersion" }
    $PyIdentity = & $Python -c 'import sys,struct;print("%d.%d.%d"%sys.version_info[:3]);print(struct.calcsize("P")*8)'; Check-Native 'STOP_S0_PYTHON_VERSION'
    if ($PyIdentity[0].Trim() -ne '3.12.10' -or $PyIdentity[1].Trim() -ne '64') { throw "STOP_ENVIRONMENT_IDENTITY Python=$($PyIdentity -join '/')" }
    $QtVersion = (& (Join-Path $Qt 'bin\qmake.exe') -query QT_VERSION | Out-String).Trim(); Check-Native 'STOP_S0_QT_VERSION'
    if ($QtVersion -ne '6.9.3') { throw "STOP_ENVIRONMENT_IDENTITY Qt=$QtVersion" }
    Write-Diag 'toolchain-preflight.txt' @("vs=$VsVersion","vctools=$env:VCToolsVersion","sdk=$env:WindowsSDKVersion","powershell=$($PSVersionTable.PSVersion)","cmake=$CMakeVersion","ninja=$NinjaVersion","ninja_sha256=$(Get-Sha256 $Ninja)","python=$($PyIdentity -join '/')","python_sha256=$(Get-Sha256 $Python)","qt=$QtVersion","qt_root=$Qt")

    foreach ($Name in @('CPATH','CPLUS_INCLUDE_PATH','C_INCLUDE_PATH')) { [Environment]::SetEnvironmentVariable($Name,$null,'Process') }
    $env:PATH = (($env:PATH -split ';' | Where-Object { $_ -and ($_ -notmatch '(?i)msys') -and ($_ -notmatch '(?i)mingw') } | Select-Object -Unique) -join ';')
    foreach ($Name in @('INCLUDE','LIB','LIBPATH','EXTERNAL_INCLUDE')) { $Value = [Environment]::GetEnvironmentVariable($Name,'Process'); if ($Value -and $Value -match '(?i)msys|mingw') { throw "STOP_ENV_CONTAMINATION variable=$Name" } }

    $HarnessArchive = Join-Path $Work 'harness-inputs.zip'; $HarnessInputs = Join-Path $Work 'harness-inputs'
    git -C $Harness archive --format=zip "--output=$HarnessArchive" $HarnessSha -- .bbx/ci/run_blackbox_patchfix3.ps1 .bbx/ci/run_blackbox_patchfix3.cmd .bbx/ci/bootstrap_minimal.ps1; Check-Native 'STOP_S0_HARNESS_EXPORT'
    Expand-Archive -LiteralPath $HarnessArchive -DestinationPath $HarnessInputs
    Assert-Hash (Join-Path $HarnessInputs '.bbx\ci\run_blackbox_patchfix3.ps1') $LauncherPsSha 'STOP_S0_LAUNCHER_PS_HASH'
    Assert-Hash (Join-Path $HarnessInputs '.bbx\ci\run_blackbox_patchfix3.cmd') $LauncherCmdSha 'STOP_S0_LAUNCHER_CMD_HASH'

    $Stage = 'S1'
    Write-Host '=== S1 authenticate / reconstruct ==='
    Assert-Hash $ReadyZip $ReadyZipSha 'STOP_INPUT_READY4_HASH'; Assert-Hash $FixZip $FixZipSha 'STOP_INPUT_PATCHFIX1_HASH'
    Expand-Archive -LiteralPath $ReadyZip -DestinationPath (Join-Path $Work 'ready4'); Expand-Archive -LiteralPath $FixZip -DestinationPath (Join-Path $Work 'patchfix1')
    $RootName = 'BB_BLACKBOX_V1_CI_CLEAN1_SOURCE_READY4_2026-09-15'; $Pkg = Join-Path (Join-Path $Work 'ready4') $RootName; $Fix = Join-Path (Join-Path $Work 'patchfix1') $RootName
    Verify-Manifest $Pkg 'SHA256SUMS.txt' 35; Verify-Manifest $Fix 'SHA256SUMS.txt' 35
    $Parent = Join-Path $Pkg 'evidence\accepted_parent\INTEGRATED_R3_SAVEFIX_S1.patch'; $Integration = Join-Path $Pkg 'integration\BLACKBOX_V1_CI_CLEAN1_CORE_SAFE.patch'
    Assert-Hash $Parent $ParentSha 'STOP_S1_PARENT_HASH'; Assert-Hash (Join-Path $Pkg 'ci\APPLY_CLEAN1_SOURCE_READY.ps1') $ApplySha 'STOP_S1_APPLY_HASH'; Assert-Hash (Join-Path $Pkg 'ci\INSTALL_LLVM_CLEAN1.ps1') $InstallerSha 'STOP_S1_INSTALLER_HASH'; Assert-Hash (Join-Path $Pkg 'ci\verify_clean1.py') $AuditorSha 'STOP_S1_AUDITOR_HASH'; Assert-Hash (Join-Path $Pkg 'overlay\tools\bb_blackbox\decode.py') $DecoderSha 'STOP_S1_DECODER_HASH'; Assert-Hash (Join-Path $Fix 'integration\BLACKBOX_V1_CI_CLEAN1_CORE_SAFE.patch') $IntegrationSha 'STOP_S1_PATCHFIX1_HASH'
    Copy-Item -LiteralPath (Join-Path $Fix 'integration\BLACKBOX_V1_CI_CLEAN1_CORE_SAFE.patch') -Destination $Integration -Force; Assert-Hash $Integration $IntegrationSha 'STOP_S1_EFFECTIVE_INTEGRATION_HASH'
    Write-Diag 'inputs.txt' @("ready4_sha256=$(Get-Sha256 $ReadyZip)","patchfix1_zip_sha256=$(Get-Sha256 $FixZip)","parent_sha256=$(Get-Sha256 $Parent)","integration_sha256=$(Get-Sha256 $Integration)")

    git -C $Harness cat-file -e "$Baseline^{commit}"; Check-Native 'STOP_S1_BASELINE_COMMIT'
    $ActualBaselineTree = (git -C $Harness rev-parse "$Baseline^{tree}").Trim(); Check-Native 'STOP_S1_BASELINE_TREE'; if ($ActualBaselineTree -ne $BaselineTree) { throw "STOP_S1_BASELINE_TREE expected=$BaselineTree actual=$ActualBaselineTree" }
    git -C $Harness config --local core.autocrlf true; Check-Native 'STOP_S1_GIT_AUTOCRLF'; git -C $Harness config --local core.eol crlf; Check-Native 'STOP_S1_GIT_EOL'
    git -C $Harness worktree add --detach $Src $Baseline; Check-Native 'STOP_S1_WORKTREE'
    git -C $Src submodule sync --recursive 2>&1 | Tee-Object (Join-Path $Diag 'submodule-sync.log'); Check-Native 'STOP_S1_SUBMODULE_SYNC'
    git -C $Src submodule update --init --recursive 2>&1 | Tee-Object (Join-Path $Diag 'submodule-update.log'); Check-Native 'STOP_S1_SUBMODULE_UPDATE'
    $SubStatus = @(git -C $Src submodule status --recursive); Check-Native 'STOP_S1_SUBMODULE_STATUS'; $SubStatus | Set-Content -LiteralPath (Join-Path $Diag 'submodules.txt') -Encoding utf8; foreach ($Line in $SubStatus) { if ($Line -notmatch '^ ') { throw "STOP_S1_SUBMODULE_IDENTITY line=$Line" } }
    & (Join-Path $Pkg 'ci\APPLY_CLEAN1_SOURCE_READY.ps1') -RepoRoot $Src -ParentPatch $Parent *>&1 | Tee-Object (Join-Path $Diag 'apply.log'); if (-not $?) { throw 'STOP_S1_APPLY' }

    $Stage = 'S2'
    Write-Host '=== S2 source gates ==='
    Push-Location $Src; try { & '.\ci\VERIFY_EXACT_PARENT_REPLAY.ps1' *>&1 | Tee-Object (Join-Path $Diag 'exact-parent-replay.log'); if (-not $?) { throw 'STOP_S2_PARENT_REPLAY' } } finally { Pop-Location }
    $AuditPath = Join-Path $Src 'clean1_static_audit.json'; if (-not (Test-Path -LiteralPath $AuditPath)) { throw 'STOP_S2_AUDIT_MISSING' }; $Audit = Get-Content -LiteralPath $AuditPath -Raw | ConvertFrom-Json; if ($Audit.pass -ne $true) { throw 'STOP_S2_AUDIT_FAIL' }; Copy-Item -LiteralPath $AuditPath -Destination (Join-Path $Diag 'clean1_static_audit.json')
    foreach ($EvidenceName in @('clean1_full_source_diff.patch','clean1_source_status.txt','clean1_exact_parent_replay.txt')) { $EvidencePath = Join-Path $Src $EvidenceName; if (-not (Test-Path -LiteralPath $EvidencePath)) { throw "STOP_S2_EVIDENCE_MISSING $EvidenceName" }; Copy-Item -LiteralPath $EvidencePath -Destination (Join-Path $Diag $EvidenceName) }
    git -C $Src status --porcelain=v1 | Set-Content -LiteralPath (Join-Path $Diag 'source-status.txt') -Encoding utf8; git -C $Src diff --binary $Baseline -- . | Set-Content -LiteralPath (Join-Path $Diag 'source-diff-live.patch') -Encoding utf8
    $SourcePaths = [string[]]@(Get-ChildItem $Src -Recurse -Force -File | Where-Object { $_.FullName -notmatch '[/\\]\.git([/\\]|$)' } | ForEach-Object { [IO.Path]::GetRelativePath($Src,$_.FullName).Replace('\','/') }); [Array]::Sort($SourcePaths,[StringComparer]::Ordinal); $SourcePaths | ForEach-Object { "$(Get-Sha256 (Join-Path $Src $_))  $_" } | Set-Content -LiteralPath (Join-Path $Diag 'SOURCE_SHA256SUMS.txt') -Encoding utf8
    $SourceState = 'YES'

    $Stage = 'S3'
    Write-Host '=== S3 LLVM / configure ==='
    Push-Location $Src; try { & '.\ci\INSTALL_LLVM_CLEAN1.ps1' -InstallRoot 'C:\LLVM19' *>&1 | Tee-Object (Join-Path $Diag 'llvm-install.log'); if (-not $?) { throw 'STOP_S3_LLVM_INSTALL' } } finally { Pop-Location }
    if (-not (Test-Path -LiteralPath $Clang -PathType Leaf)) { throw 'STOP_S3_CLANG_MISSING' }; $ClangVersion = (& $Clang --version | Out-String); Check-Native 'STOP_S3_CLANG_VERSION'; if ($ClangVersion -notmatch 'clang version 19\.1\.1(?:\s|$)') { throw 'STOP_S3_CLANG_VERSION_IDENTITY' }; Write-Diag 'toolchain-post-llvm.txt' @("clang=$Clang","clang_sha256=$(Get-Sha256 $Clang)",$ClangVersion.Trim())
    $ConfigureArgs = @('--fresh','-S',$Src,'-B',$Build,'-G','Ninja','-DCMAKE_BUILD_TYPE=Release','-DENABLE_QT_GUI=ON','-DENABLE_UPDATER=ON','-DCMAKE_INTERPROCEDURAL_OPTIMIZATION_RELEASE=ON',"-DCMAKE_C_COMPILER=$Clang","-DCMAKE_CXX_COMPILER=$Clang","-DCMAKE_ASM_COMPILER=$Clang","-DCMAKE_MAKE_PROGRAM=$Ninja","-DCMAKE_PREFIX_PATH=$Qt")
    & $CMake @ConfigureArgs 2>&1 | Tee-Object (Join-Path $Diag 'configure.log'); Check-Native 'STOP_S3_CONFIGURE'
    $Cache = Join-Path $Build 'CMakeCache.txt'; if (-not (Test-Path -LiteralPath $Cache)) { throw 'STOP_S3_CACHE_MISSING' }; $CacheLines = Get-Content -LiteralPath $Cache; $CompilerIdentity = @()
    foreach ($Key in @('CMAKE_C_COMPILER','CMAKE_CXX_COMPILER','CMAKE_ASM_COMPILER')) { $Raw = Get-CacheEntry $CacheLines $Key; $Normalized = Normalize-WindowsPath $Raw; if ($Normalized -ne $Clang.ToLowerInvariant()) { throw "STOP_S3_COMPILER $Key raw=$Raw normalized=$Normalized" }; if (-not (Test-Path -LiteralPath $Raw -PathType Leaf)) { throw "STOP_S3_COMPILER_MISSING $Key" }; $V = & $Raw --version; Check-Native "STOP_S3_COMPILER_EXEC $Key"; if (($V -join "`n") -notmatch 'clang version 19\.1\.1(?:\s|$)') { throw "STOP_S3_COMPILER_VERSION $Key" }; $CompilerIdentity += "$Key=$Raw normalized=$Normalized" }
    $CompilerIdentity | Set-Content -LiteralPath (Join-Path $Diag 'compiler-identity.txt') -Encoding utf8
    if ((Get-CacheEntry $CacheLines 'CMAKE_GENERATOR') -ne 'Ninja') { throw 'STOP_S3_GENERATOR' }; if ((Get-CacheEntry $CacheLines 'CMAKE_BUILD_TYPE') -ne 'Release') { throw 'STOP_S3_BUILD_TYPE' }; if ((Normalize-WindowsPath (Get-CacheEntry $CacheLines 'CMAKE_HOME_DIRECTORY')) -ne (Normalize-WindowsPath $Src)) { throw 'STOP_S3_HOME_DIRECTORY' }; if ((Normalize-WindowsPath (Get-CacheEntry $CacheLines 'CMAKE_MAKE_PROGRAM')) -ne (Normalize-WindowsPath $Ninja)) { throw 'STOP_S3_NINJA_CACHE' }; foreach ($Key in @('ENABLE_QT_GUI','ENABLE_UPDATER','CMAKE_INTERPROCEDURAL_OPTIMIZATION_RELEASE')) { if ((Get-CacheEntry $CacheLines $Key) -ne 'ON') { throw "STOP_S3_OPTION $Key" } }
    Copy-Item -LiteralPath $Cache -Destination (Join-Path $Diag 'CMakeCache.txt'); foreach ($Rel in @('CMakeFiles\CMakeConfigureLog.yaml','build.ninja')) { $P = Join-Path $Build $Rel; if (Test-Path -LiteralPath $P) { Copy-Item -LiteralPath $P -Destination (Join-Path $Diag ([IO.Path]::GetFileName($P))) } }

    $Stage = 'S4'
    Write-Host '=== S4 build ==='
    & $CMake --build $Build --config Release --parallel 2 2>&1 | Tee-Object (Join-Path $Diag 'build.log'); Check-Native 'STOP_S4_BUILD'
    $ShadFiles = @(Get-ChildItem $Build -Recurse -File -Filter 'shadPS4.exe'); $RecorderFiles = @(Get-ChildItem $Build -Recurse -File -Filter 'bb_blackbox_recorder.exe'); if ($ShadFiles.Count -ne 1 -or $RecorderFiles.Count -ne 1) { throw "STOP_S4_OUTPUT_CARDINALITY shad=$($ShadFiles.Count) recorder=$($RecorderFiles.Count)" }; $Shad = $ShadFiles[0]; $Recorder = $RecorderFiles[0]; $Dumpbin = (Get-Command dumpbin.exe -ErrorAction Stop).Source
    foreach ($Exe in @($Shad,$Recorder)) { & $Dumpbin /headers $Exe.FullName 2>&1 | Tee-Object (Join-Path $Diag ("headers-" + $Exe.Name + '.txt')); Check-Native 'STOP_S4_DUMPBIN_HEADERS' }
    Write-Diag 'built-binaries.txt' @("shadPS4_sha256=$(Get-Sha256 $Shad.FullName)","recorder_sha256=$(Get-Sha256 $Recorder.FullName)"); $BuildState = 'YES'

    $Stage = 'S5'
    Write-Host '=== S5 package ==='
    New-Item -ItemType Directory -Path $Runtime | Out-Null; Copy-Item -LiteralPath $Shad.FullName -Destination (Join-Path $Runtime 'shadPS4.exe'); Copy-Item -LiteralPath $Recorder.FullName -Destination (Join-Path $Runtime 'bb_blackbox_recorder.exe')
    foreach ($Dir in @($Shad.Directory.FullName,$Recorder.Directory.FullName) | Select-Object -Unique) { foreach ($File in Get-ChildItem -LiteralPath $Dir -File | Where-Object { $_.Extension -in '.dll','.pdb' }) { Copy-NoConflict $File.FullName $Runtime } }
    $QtConf = Join-Path $Src 'dist\qt.conf'; if (-not (Test-Path -LiteralPath $QtConf -PathType Leaf)) { throw 'STOP_S5_QT_CONF' }; Copy-Item -LiteralPath $QtConf -Destination (Join-Path $Runtime 'qt.conf'); if ((Get-Content -LiteralPath $QtConf -Raw) -notmatch '(?im)^\s*Plugins\s*=\s*qtplugins\s*$') { throw 'STOP_LAYOUT qt.conf plugins' }
    & $DeployQt --release --plugindir (Join-Path $Runtime 'qtplugins') --dir $Runtime (Join-Path $Runtime 'shadPS4.exe') 2>&1 | Tee-Object (Join-Path $Diag 'windeployqt.log'); Check-Native 'STOP_S5_WINDEPLOYQT'
    $Crt = Join-Path $env:VCToolsRedistDir 'x64\Microsoft.VC143.CRT'; if ($env:VCToolsRedistDir.TrimEnd('\') -notlike '*\14.44.35112' -or -not (Test-Path -LiteralPath $Crt)) { throw "STOP_S5_CRT_IDENTITY root=$env:VCToolsRedistDir" }; foreach ($File in Get-ChildItem -LiteralPath $Crt -File -Filter '*.dll') { Copy-NoConflict $File.FullName $Runtime }
    $PythonRoot = Split-Path -Parent $Python; foreach ($Rel in @('python.exe','python312.dll','DLLs','Lib')) { if (-not (Test-Path -LiteralPath (Join-Path $PythonRoot $Rel))) { throw "STOP_S5_PYTHON_LAYOUT missing=$Rel" } }; Copy-Item -LiteralPath $PythonRoot -Destination (Join-Path $Runtime 'python') -Recurse
    $Tools = New-Item -ItemType Directory -Path (Join-Path $Runtime 'tools\bb_blackbox'); Copy-Item -LiteralPath (Join-Path $Src 'tools\bb_blackbox\decode.py') -Destination (Join-Path $Tools.FullName 'decode.py'); Copy-Item -LiteralPath (Join-Path $HarnessInputs '.bbx\ci\run_blackbox_patchfix3.ps1') -Destination (Join-Path $Tools.FullName 'run_blackbox.ps1'); Copy-Item -LiteralPath (Join-Path $HarnessInputs '.bbx\ci\run_blackbox_patchfix3.cmd') -Destination (Join-Path $Tools.FullName 'run_blackbox.cmd')
    $RootWrapper = "@echo off`r`nsetlocal`r`ncd /d `"%~dp0`"`r`ncall `"%~dp0tools\bb_blackbox\run_blackbox.cmd`" `"%~dp0shadPS4.exe`"`r`nexit /b %ERRORLEVEL%`r`n"; [IO.File]::WriteAllText((Join-Path $Runtime 'RUN_BLACKBOX.cmd'),$RootWrapper,[Text.ASCIIEncoding]::new())
    @('CAPTURE_VALIDATED=NO','CAPTURE_READINESS=NOT_READY','RUNTIME_TEST_ALLOWED=false') | Set-Content -LiteralPath (Join-Path $Runtime 'CAPTURE-READINESS.txt') -Encoding ascii
    $RuntimeEvidence = New-Item -ItemType Directory -Path (Join-Path $Runtime 'evidence'); Copy-Item -LiteralPath $Parent -Destination (Join-Path $RuntimeEvidence.FullName 'INTEGRATED_R3_SAVEFIX_S1.patch'); Copy-Item -LiteralPath $Integration -Destination (Join-Path $RuntimeEvidence.FullName 'BLACKBOX_V1_CI_CLEAN1_CORE_SAFE.patch'); Copy-Item -LiteralPath (Join-Path $Pkg 'SHA256SUMS.txt') -Destination (Join-Path $RuntimeEvidence.FullName 'READY4-SHA256SUMS.txt'); Copy-Item -LiteralPath (Join-Path $Fix 'SHA256SUMS.txt') -Destination (Join-Path $RuntimeEvidence.FullName 'PATCHFIX1-SHA256SUMS.txt'); foreach ($File in Get-ChildItem -LiteralPath $Diag -File) { Copy-Item -LiteralPath $File.FullName -Destination $RuntimeEvidence.FullName }
    $Required = @('shadPS4.exe','bb_blackbox_recorder.exe','RUN_BLACKBOX.cmd','qt.conf','tools\bb_blackbox\decode.py','tools\bb_blackbox\run_blackbox.cmd','tools\bb_blackbox\run_blackbox.ps1','Qt6Core.dll','Qt6Gui.dll','Qt6Widgets.dll','Qt6Network.dll','Qt6Multimedia.dll','avcodec-61.dll','avformat-61.dll','avutil-59.dll','swresample-5.dll','swscale-8.dll','qtplugins\platforms\qwindows.dll','qtplugins\multimedia\ffmpegmediaplugin.dll','CAPTURE-READINESS.txt'); foreach ($Rel in $Required) { if (-not (Test-Path -LiteralPath (Join-Path $Runtime $Rel) -PathType Leaf)) { throw "STOP_DEPENDENCY required=$Rel" } }
    $PeFiles = @(Get-ChildItem -LiteralPath $Runtime -Recurse -File | Where-Object { $_.Extension -in '.exe','.dll' }); $MissingImports = [Collections.Generic.List[string]]::new()
    foreach ($Pe in $PeFiles) { $SafeName = ($Pe.Name -replace '[^A-Za-z0-9_.-]','_'); $Deps = @(& $Dumpbin /dependents $Pe.FullName 2>&1); Check-Native "STOP_DEPENDENCY_DUMPBIN $($Pe.Name)"; $Deps | Set-Content -LiteralPath (Join-Path $Diag ("dependents-" + $SafeName + '.txt')) -Encoding utf8; & $Dumpbin /headers $Pe.FullName 2>&1 | Set-Content -LiteralPath (Join-Path $Diag ("headers-package-" + $SafeName + '.txt')) -Encoding utf8; Check-Native "STOP_HEADERS_DUMPBIN $($Pe.Name)"; foreach ($Line in $Deps) { if ($Line -match '^\s+([A-Za-z0-9._-]+\.dll)\s*$') { $Dll = $Matches[1]; $InPackage = @(Get-ChildItem -LiteralPath $Runtime -Recurse -File -Filter $Dll).Count -gt 0; $IsApiSet = $Dll -match '^(?i)(api-ms-win-|ext-ms-win-)'; $IsSystem = Test-Path -LiteralPath (Join-Path $env:WINDIR "System32\$Dll"); $IsVulkanPrereq = $Dll -ieq 'vulkan-1.dll'; if (-not ($InPackage -or $IsApiSet -or $IsSystem -or $IsVulkanPrereq)) { $MissingImports.Add("$($Pe.Name):$Dll") } } } }
    if ($MissingImports.Count -gt 0) { $MissingImports | Set-Content (Join-Path $Diag 'missing-imports.txt'); throw 'STOP_DEPENDENCY unresolved imports' }

    $Stage = 'S6'
    Write-Host '=== S6 manifest / zip / reopen ==='
    $Manifest = Join-Path $Runtime 'SHA256SUMS-CLEAN1-RUNTIME.txt'; $RelativePaths = [string[]]@(Get-ChildItem $Runtime -Recurse -File | ForEach-Object { [IO.Path]::GetRelativePath($Runtime,$_.FullName).Replace('\','/') } | Where-Object { $_ -ne 'SHA256SUMS-CLEAN1-RUNTIME.txt' }); [Array]::Sort($RelativePaths,[StringComparer]::Ordinal); $ManifestLines = @($RelativePaths | ForEach-Object { "$(Get-Sha256 (Join-Path $Runtime $_))  $_" }); [IO.File]::WriteAllLines($Manifest,$ManifestLines,[Text.UTF8Encoding]::new($false)); Compress-Archive -Path (Join-Path $Runtime '*') -DestinationPath $Zip -CompressionLevel Optimal; Expand-Archive -LiteralPath $Zip -DestinationPath $Reopened; Verify-Manifest $Reopened 'SHA256SUMS-CLEAN1-RUNTIME.txt' $ManifestLines.Count
    foreach ($Rel in $Required) { if (-not (Test-Path -LiteralPath (Join-Path $Reopened $Rel) -PathType Leaf)) { throw "STOP_S6_REQUIRED_REOPEN rel=$Rel" } }; if ((Get-Sha256 (Join-Path $Reopened 'shadPS4.exe')) -ne (Get-Sha256 $Shad.FullName)) { throw 'STOP_S6_SHAD_HASH' }; if ((Get-Sha256 (Join-Path $Reopened 'bb_blackbox_recorder.exe')) -ne (Get-Sha256 $Recorder.FullName)) { throw 'STOP_S6_RECORDER_HASH' }; $ZipHashBeforeSmoke = Get-Sha256 $Zip; $PackageState = 'YES'

    $Stage = 'S7'
    Write-Host '=== S7 synthetic smoke ==='
    New-Item -ItemType Directory -Path $Smoke | Out-Null; $ProducerCpp = Join-Path $Smoke 'synthetic_producer.cpp'
    $Fixture = @'
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
'@
    $Fixture = $Fixture.Replace("`r`n","`n").TrimEnd("`n") + "`n"; [IO.File]::WriteAllText($ProducerCpp,$Fixture,[Text.UTF8Encoding]::new($false)); Assert-Hash $ProducerCpp $FixtureSha 'STOP_S7_FIXTURE_IDENTITY'; $ProducerExe = Join-Path $Smoke 'synthetic_producer.exe'
    Push-Location $Smoke; try { & $Clang /nologo /std:c++20 /EHsc /O2 /DNOMINMAX /DWIN32_LEAN_AND_MEAN "/I$Src\src" $ProducerCpp (Join-Path $Src 'src\common\bb_blackbox\recorder.cpp') "/Fe:$ProducerExe" 2>&1 | Tee-Object (Join-Path $Diag 'synthetic-build.log'); Check-Native 'STOP_S7_SYNTHETIC_BUILD'; & (Join-Path $Reopened 'tools\bb_blackbox\run_blackbox.cmd') $ProducerExe 2>&1 | Tee-Object (Join-Path $Diag 'synthetic-launcher.log'); Check-Native 'STOP_S7_LAUNCHER' } finally { Pop-Location }
    $Captures = @(Get-ChildItem $Smoke -Directory -Filter 'BB_BLACKBOX_*'); if ($Captures.Count -ne 1) { throw "STOP_S7_CAPTURE_CARDINALITY count=$($Captures.Count)" }; $Capture = $Captures[0].FullName; $PackPython = Join-Path $Reopened 'python\python.exe'
    & $PackPython -B -I -c 'import sys,struct;from pathlib import Path;assert sys.version_info[:3]==(3,12,10);assert struct.calcsize("P")==8;assert Path(sys.prefix).resolve()==Path(sys.argv[1]).resolve();print("PACKAGED_PYTHON=PASS")' (Join-Path $Reopened 'python') 2>&1 | Tee-Object (Join-Path $Diag 'packaged-python.log'); Check-Native 'STOP_S7_PACKAGED_PYTHON'
    & $PackPython -B -I (Join-Path $Reopened 'tools\bb_blackbox\decode.py') $Capture | Set-Content -LiteralPath (Join-Path $Diag 'synthetic-decode.json'); Check-Native 'STOP_S7_DECODE'
    & $PackPython -B -I -c 'import importlib.util,sys;from pathlib import Path;s=importlib.util.spec_from_file_location("bbd",sys.argv[1]);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);c,p=m.collect_capture_chunks(Path(sys.argv[2]));v=[e["arg0"] for x in c for e in x["events"] if e["event_id"]==251];assert len(v)==3000 and sorted(v)==list(range(3000)),(len(v),len(set(v)));print("EXACT_HEARTBEATS=PASS")' (Join-Path $Reopened 'tools\bb_blackbox\decode.py') $Capture 2>&1 | Tee-Object (Join-Path $Diag 'heartbeats.log'); Check-Native 'STOP_S7_HEARTBEATS'
    $Status = Get-Content -LiteralPath (Join-Path $Capture 'capture_status.json') -Raw | ConvertFrom-Json; if ($Status.complete -ne $true -or $Status.producer_seen -ne $true -or $Status.producer_exited -ne $true -or $Status.terminal_reason -ne 'normal_exit' -or [int64]$Status.event_loss_total -ne 0) { throw 'STOP_S7_CAPTURE_STATUS' }
    $Decoded = Get-Content -LiteralPath (Join-Path $Diag 'synthetic-decode.json') -Raw | ConvertFrom-Json; if ($Decoded.capture_complete -ne $true -or $Decoded.event_loss_free -ne $true -or $Decoded.capture_loss_free -ne $true -or $Decoded.retention.retention_complete -ne $true -or [int64]$Decoded.valid_chunks -le 0 -or [int64]$Decoded.known_guest_frame_count -ne 0) { throw 'STOP_S7_DECODE_INTEGRITY' }
    Copy-Item -LiteralPath $ProducerCpp -Destination (Join-Path $Diag 'synthetic_producer.cpp'); Copy-Item -LiteralPath $ProducerExe -Destination (Join-Path $Diag 'synthetic_producer.exe'); Get-ChildItem -LiteralPath $Capture -File | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $Diag }; $SmokeState = 'YES'

    $Stage = 'S8'
    Write-Host '=== S8 close / deliver ==='
    if ((Get-Sha256 $Zip) -ne $ZipHashBeforeSmoke) { throw 'STOP_S8_ZIP_CHANGED_AFTER_SMOKE' }; $ZipHashBeforeSmoke | Set-Content -LiteralPath (Join-Path $Diag 'runtime-zip-sha256.txt') -Encoding ascii; Write-Diag 'final-success.txt' 'CONTRACT_V1_S0_S8=PASS'
}
catch {
    $FirstFailure = $_.Exception.Message
    Write-Error "CLEAN1 CONTRACT STOP stage=$Stage error=$FirstFailure"
    throw
}
finally {
    $StateLines = @("SOURCE_VALIDATED=$SourceState","WINDOWS_BUILD_PASS=$BuildState","PACKAGE_PASS=$PackageState","SMOKE_PASS=$SmokeState",'CAPTURE_VALIDATED=NO','CAPTURE_READINESS=NOT_READY','RUNTIME_TEST_ALLOWED=false',"FINAL_STAGE=$Stage","FIRST_FAILURE=$FirstFailure")
    $StateLines | Set-Content -LiteralPath (Join-Path $Diag 'FINAL-STATES.txt') -Encoding utf8
    if (Test-Path -LiteralPath $Zip) { "RUNTIME_ZIP_SHA256=$(Get-Sha256 $Zip)" | Add-Content -LiteralPath (Join-Path $Diag 'FINAL-STATES.txt') -Encoding utf8 }
}
