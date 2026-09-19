$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$BaselineSha = "03d62ad22438344f1dcd38c5b5e44f660b564b92"
$Ready4Sha = "0b709de7e6c588b76786d8b648d5f669563c0bf45df5ec44a63db56f869e795f"
$PatchfixSha = "9e998761b9aefdf7649f001a0ffaf875755733cf4b3885d63a8aec349fd34efa"
$PatchPart01Sha = "7b6b725fd55f495f4391d431b0a4622cceb99aab7e055b42af9b5da67cff0711"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$Diag = Join-Path $env:RUNNER_TEMP "bbx-patchfix2-diagnostics"
$src = $null
$pkgRoot = $null
New-Item -ItemType Directory -Path $Diag -Force | Out-Null

function Save-Diag([string]$Name, [string]$Text) {
    $Text | Set-Content -LiteralPath (Join-Path $Diag $Name) -Encoding utf8
}

function Copy-IfExists([string]$Path, [string]$DestinationName = "") {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    if ([string]::IsNullOrWhiteSpace($DestinationName)) {
        $DestinationName = Split-Path -Leaf $Path
    }
    Copy-Item -LiteralPath $Path -Destination (Join-Path $Diag $DestinationName) -Recurse -Force
}

function Capture-SourceDiagnostics([string]$SourceRoot) {
    if (-not $SourceRoot -or -not (Test-Path -LiteralPath $SourceRoot)) { return }
    try { git -C $SourceRoot status --short | Set-Content -LiteralPath (Join-Path $Diag "git-status.txt") -Encoding utf8 } catch {}
    try { git -C $SourceRoot diff --binary | Set-Content -LiteralPath (Join-Path $Diag "tracked-source-diff.patch") -Encoding utf8 } catch {}

    foreach ($name in @(
        "clean1_static_audit.json",
        "clean1_decoder_selftest.json",
        "clean1_gate_tests.txt",
        "clean1_exact_parent_replay.txt",
        "clean1_full_source_diff.patch",
        "clean1_source_status.txt",
        "clean1_toolchain.txt",
        "clean1_llvm_identity.txt",
        "clean1_clang_version.txt",
        "clean1_cmake_configure.log",
        "clean1_build.log",
        "clean1_output_hashes.txt"
    )) {
        Copy-IfExists (Join-Path $SourceRoot $name)
    }

    Copy-IfExists (Join-Path $SourceRoot "ci\evidence") "ci-evidence"
    Copy-IfExists (Join-Path $SourceRoot "build-clean1\CMakeCache.txt") "CMakeCache.txt"
    Copy-IfExists (Join-Path $SourceRoot "build-clean1\CMakeFiles\CMakeError.log") "CMakeError.log"
    Copy-IfExists (Join-Path $SourceRoot "build-clean1\CMakeFiles\CMakeOutput.log") "CMakeOutput.log"
}

try {
    $readyParts = @(
        ".bbx/package/ready4.b64.part01",
        ".bbx/package/ready4.b64.part02",
        ".bbx/package/ready4.b64.part03",
        ".bbx/package/ready4.b64.part04",
        ".bbx/package/ready4.b64.part05",
        ".bbx/package/ready4.b64.part06",
        ".bbx/package/ready4.b64.part07a",
        ".bbx/package/ready4.b64.part07b",
        ".bbx/package/ready4.b64.part08",
        ".bbx/package/ready4.b64.part09",
        ".bbx/package/ready4.b64.part10a",
        ".bbx/package/ready4.b64.part10b",
        ".bbx/package/ready4.b64.part11a",
        ".bbx/package/ready4.b64.part11b",
        ".bbx/package/ready4.b64.part12a",
        ".bbx/package/ready4.b64.part12b",
        ".bbx/package/ready4.b64.part13"
    )
    Push-Location $RepoRoot
    try {
        foreach ($p in $readyParts) {
            if (-not (Test-Path -LiteralPath $p)) { throw "Missing READY4 transport chunk: $p" }
        }
        $readyB64 = ($readyParts | ForEach-Object { (Get-Content -LiteralPath $_ -Raw).Trim() }) -join ""
    } finally { Pop-Location }

    if ($readyB64.Length -ne 122832) { throw "READY4 base64 length mismatch: $($readyB64.Length)" }
    $readyZip = Join-Path $env:RUNNER_TEMP "SOURCE_READY4_ORIGINAL.zip"
    [IO.File]::WriteAllBytes($readyZip, [Convert]::FromBase64String($readyB64))
    $readyHash = (Get-FileHash -LiteralPath $readyZip -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($readyHash -ne $Ready4Sha) { throw "READY4 SHA256 mismatch: $readyHash" }
    Save-Diag "ready4-sha256.txt" $readyHash

    $pkgBase = Join-Path $env:RUNNER_TEMP "ready4-patchfix2-package"
    if (Test-Path -LiteralPath $pkgBase) { Remove-Item -Recurse -Force $pkgBase }
    Expand-Archive -LiteralPath $readyZip -DestinationPath $pkgBase
    $apply = Get-ChildItem -LiteralPath $pkgBase -Recurse -Filter APPLY_CLEAN1_SOURCE_READY.ps1 | Select-Object -First 1
    if (-not $apply) { throw "APPLY_CLEAN1_SOURCE_READY.ps1 missing from READY4" }
    $pkgRoot = $apply.Directory.Parent.FullName

    $part01Pieces = @(
        ".bbx/patchfix1/part01a.b64",
        ".bbx/patchfix1/part01b.b64",
        ".bbx/patchfix1/part01c.b64",
        ".bbx/patchfix1/part01d1.b64",
        ".bbx/patchfix1/part01d2.b64"
    )
    Push-Location $RepoRoot
    try {
        foreach ($p in $part01Pieces) {
            if (-not (Test-Path -LiteralPath $p)) { throw "Missing PATCHFIX1 part01 piece: $p" }
        }
        $part01 = ($part01Pieces | ForEach-Object { (Get-Content -LiteralPath $_ -Raw).Trim() }) -join ""
        if ($part01.Length -ne 8000) { throw "PATCHFIX1 part01 length mismatch: $($part01.Length)" }
        $part01Path = Join-Path $env:RUNNER_TEMP "patchfix1-part01.b64"
        [IO.File]::WriteAllText($part01Path, $part01, [Text.Encoding]::ASCII)
        $part01Hash = (Get-FileHash -LiteralPath $part01Path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($part01Hash -ne $PatchPart01Sha) { throw "PATCHFIX1 part01 SHA256 mismatch: $part01Hash" }

        $rest = @(".bbx/patchfix1/part02.b64", ".bbx/patchfix1/part03.b64", ".bbx/patchfix1/part04.b64")
        foreach ($p in $rest) {
            if (-not (Test-Path -LiteralPath $p)) { throw "Missing PATCHFIX1 transport chunk: $p" }
        }
        $patchB64 = $part01 + (($rest | ForEach-Object { (Get-Content -LiteralPath $_ -Raw).Trim() }) -join "")
    } finally { Pop-Location }

    if ($patchB64.Length -ne 30252) { throw "PATCHFIX1 base64 length mismatch: $($patchB64.Length)" }
    $patchPath = Join-Path $pkgRoot "integration\BLACKBOX_V1_CI_CLEAN1_CORE_SAFE.patch"
    [IO.File]::WriteAllBytes($patchPath, [Convert]::FromBase64String($patchB64))
    $patchHash = (Get-FileHash -LiteralPath $patchPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($patchHash -ne $PatchfixSha) { throw "PATCHFIX1 SHA256 mismatch: $patchHash" }
    Save-Diag "patchfix1-sha256.txt" $patchHash
    Write-Host "PATCHFIX1_TRANSPORT_PASS=$patchHash"

    $src = Join-Path $env:RUNNER_TEMP "bb-clean1-patchfix2-source"
    if (Test-Path -LiteralPath $src) { Remove-Item -Recurse -Force $src }
    git -C $RepoRoot worktree add --detach $src $BaselineSha
    if ($LASTEXITCODE -ne 0) { throw "git worktree add failed" }
    $head = (git -C $src rev-parse HEAD).Trim()
    if ($head -ne $BaselineSha) { throw "Frozen baseline mismatch: $head" }
    Save-Diag "baseline-head.txt" $head

    git -C $src submodule sync --recursive
    if ($LASTEXITCODE -ne 0) { throw "submodule sync failed" }
    git -C $src submodule update --init --recursive
    if ($LASTEXITCODE -ne 0) { throw "submodule update failed" }

    & (Join-Path $pkgRoot "ci\APPLY_CLEAN1_SOURCE_READY.ps1") -RepoRoot $src
    if ($LASTEXITCODE -ne 0) { throw "PATCHFIX1 source reconstruction failed: $LASTEXITCODE" }
    Save-Diag "apply-result.txt" "PATCHFIX1_APPLY_PASS"

    Push-Location $src
    try {
        & ".\ci\INSTALL_LLVM_CLEAN1.ps1"
        if ($LASTEXITCODE -ne 0) { throw "LLVM installer failed: $LASTEXITCODE" }

        & ".\ci\VERIFY_EXACT_PARENT_REPLAY.ps1"
        if ($LASTEXITCODE -ne 0) { throw "Exact parent replay failed: $LASTEXITCODE" }

        python tools/bb_blackbox/decode.py --self-test | Tee-Object clean1_decoder_selftest.json
        if ($LASTEXITCODE -ne 0) { throw "decoder self-test failed" }

        python ci/test_verify_clean1.py | Tee-Object clean1_gate_tests.txt
        if ($LASTEXITCODE -ne 0) { throw "semantic regression gate failed" }

        python ci/verify_clean1.py . --json clean1_static_audit.json
        if ($LASTEXITCODE -ne 0) { throw "semantic gate failed" }

        & ".\ci\BUILD_TIERB_CLEAN1.ps1" -SourceRoot $src -BuildRoot (Join-Path $src "build-clean1")
        if ($LASTEXITCODE -ne 0) { throw "Tier-B Windows build failed: $LASTEXITCODE" }
    } finally { Pop-Location }

    $buildRoot = Join-Path $src "build-clean1"
    $shad = Get-ChildItem -LiteralPath $buildRoot -Recurse -Filter shadPS4.exe | Select-Object -First 1
    $rec = Get-ChildItem -LiteralPath $buildRoot -Recurse -Filter bb_blackbox_recorder.exe | Select-Object -First 1
    if (-not $shad) { throw "shadPS4.exe not found after build" }
    if (-not $rec) { throw "bb_blackbox_recorder.exe not found after build" }

    $recProc = Start-Process -FilePath $rec.FullName -ArgumentList @() -Wait -PassThru -NoNewWindow
    if ($recProc.ExitCode -ne 2) { throw "bb_blackbox_recorder smoke returned $($recProc.ExitCode), expected 2" }
    Save-Diag "recorder-smoke.txt" "PASS exit_code=2"

    $runtime = Join-Path $env:RUNNER_TEMP "runtime-clean1-patchfix2"
    if (Test-Path -LiteralPath $runtime) { Remove-Item -Recurse -Force $runtime }
    New-Item -ItemType Directory -Path $runtime -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $runtime "tools\bb_blackbox") -Force | Out-Null

    Copy-Item -LiteralPath $shad.FullName -Destination (Join-Path $runtime "shadPS4.exe") -Force
    Copy-Item -LiteralPath $rec.FullName -Destination (Join-Path $runtime "bb_blackbox_recorder.exe") -Force

    $shadPdb = Get-ChildItem -LiteralPath $buildRoot -Recurse -Filter shadPS4.pdb -ErrorAction SilentlyContinue | Select-Object -First 1
    $recPdb = Get-ChildItem -LiteralPath $buildRoot -Recurse -Filter bb_blackbox_recorder.pdb -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($shadPdb) { Copy-Item -LiteralPath $shadPdb.FullName -Destination (Join-Path $runtime "shadPS4.pdb") -Force }
    if ($recPdb) { Copy-Item -LiteralPath $recPdb.FullName -Destination (Join-Path $runtime "bb_blackbox_recorder.pdb") -Force }

    $qtConf = Join-Path $src "dist\qt.conf"
    if (-not (Test-Path -LiteralPath $qtConf)) { throw "dist/qt.conf missing" }
    Copy-Item -LiteralPath $qtConf -Destination (Join-Path $runtime "qt.conf") -Force

    $windeployqt = (Get-Command windeployqt.exe -ErrorAction Stop).Source
    & $windeployqt --plugindir (Join-Path $runtime "qtplugins") `
        --no-compiler-runtime --no-system-d3d-compiler --no-system-dxc-compiler `
        --dir $runtime (Join-Path $runtime "shadPS4.exe")
    if ($LASTEXITCODE -ne 0) { throw "windeployqt failed: $LASTEXITCODE" }

    Copy-Item -LiteralPath (Join-Path $src "tools\bb_blackbox\run_blackbox.cmd") -Destination (Join-Path $runtime "tools\bb_blackbox\run_blackbox.cmd") -Force
    Copy-Item -LiteralPath (Join-Path $src "tools\bb_blackbox\decode.py") -Destination (Join-Path $runtime "tools\bb_blackbox\decode.py") -Force

    @(
        '@echo off',
        'pushd "%~dp0"',
        'call "tools\bb_blackbox\run_blackbox.cmd" "%~dp0shadPS4.exe"',
        'set "BB_RC=%ERRORLEVEL%"',
        'popd',
        'exit /b %BB_RC%'
    ) | Set-Content -LiteralPath (Join-Path $runtime "RUN_BLACKBOX.cmd") -Encoding ascii

    foreach ($required in @(
        "shadPS4.exe",
        "bb_blackbox_recorder.exe",
        "qt.conf",
        "Qt6Core.dll",
        "Qt6Gui.dll",
        "Qt6Widgets.dll",
        "Qt6Multimedia.dll",
        "Qt6Network.dll",
        "avcodec-61.dll",
        "avformat-61.dll",
        "avutil-59.dll",
        "swresample-5.dll",
        "swscale-8.dll",
        "qtplugins\platforms\qwindows.dll",
        "qtplugins\multimedia\ffmpegmediaplugin.dll",
        "tools\bb_blackbox\run_blackbox.cmd",
        "tools\bb_blackbox\decode.py",
        "RUN_BLACKBOX.cmd"
    )) {
        if (-not (Test-Path -LiteralPath (Join-Path $runtime $required))) {
            throw "Runnable package missing required file: $required"
        }
    }

    $dumpbin = (Get-Command dumpbin.exe -ErrorAction Stop).Source
    & $dumpbin /dependents (Join-Path $runtime "shadPS4.exe") 2>&1 | Set-Content -LiteralPath (Join-Path $Diag "shadPS4-dependents.txt") -Encoding utf8
    if ($LASTEXITCODE -ne 0) { throw "dumpbin /dependents shadPS4.exe failed: $LASTEXITCODE" }
    & $dumpbin /dependents (Join-Path $runtime "bb_blackbox_recorder.exe") 2>&1 | Set-Content -LiteralPath (Join-Path $Diag "recorder-dependents.txt") -Encoding utf8
    if ($LASTEXITCODE -ne 0) { throw "dumpbin /dependents recorder failed: $LASTEXITCODE" }

    $evidence = Join-Path $runtime "evidence"
    New-Item -ItemType Directory -Path $evidence -Force | Out-Null
    if (Test-Path -LiteralPath (Join-Path $src "ci\evidence")) {
        Copy-Item -Path (Join-Path $src "ci\evidence\*") -Destination $evidence -Recurse -Force
    }
    Copy-Item -LiteralPath $patchPath -Destination (Join-Path $evidence "BLACKBOX_V1_CI_CLEAN1_CORE_SAFE_PATCHFIX1.patch") -Force
    foreach ($pair in @(
        @{Src="clean1_toolchain.txt"; Dst="BUILD-TOOLCHAIN-CLEAN1.txt"},
        @{Src="clean1_exact_parent_replay.txt"; Dst="EXACT-PARENT-REPLAY.txt"},
        @{Src="clean1_static_audit.json"; Dst="STATIC-AUDIT-CLEAN1.json"},
        @{Src="clean1_decoder_selftest.json"; Dst="DECODER-SELFTEST-CLEAN1.json"}
    )) {
        $p = Join-Path $src $pair.Src
        if (-not (Test-Path -LiteralPath $p)) { throw "Required evidence missing after build: $($pair.Src)" }
        Copy-Item -LiteralPath $p -Destination (Join-Path $runtime $pair.Dst) -Force
    }

    $manifest = Get-ChildItem -LiteralPath $runtime -Recurse -File | Sort-Object FullName | ForEach-Object {
        $rel = [IO.Path]::GetRelativePath($runtime, $_.FullName).Replace('\','/')
        $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        "$hash  $rel"
    }
    $manifestPath = Join-Path $runtime "SHA256SUMS-CLEAN1-RUNTIME.txt"
    $manifest | Set-Content -LiteralPath $manifestPath -Encoding ascii

    $zipOut = Join-Path $env:RUNNER_TEMP "BLACKBOX_V1_CI_CLEAN1_PATCHFIX2_WIN64_QT.zip"
    if (Test-Path -LiteralPath $zipOut) { Remove-Item -Force $zipOut }
    Compress-Archive -Path (Join-Path $runtime "*") -DestinationPath $zipOut -CompressionLevel Optimal
    $outHash = (Get-FileHash -LiteralPath $zipOut -Algorithm SHA256).Hash.ToLowerInvariant()
    Save-Diag "runtime-zip-sha256.txt" $outHash
    Save-Diag "result.txt" "BUILD_PASS`nPATCHFIX1_SHA256=$patchHash`nRUNTIME_ZIP_SHA256=$outHash"

    Capture-SourceDiagnostics $src

    "RUNTIME_ZIP=$zipOut" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
    "SRC_ROOT=$src" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
    "PATCHFIX1_SHA256=$patchHash" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
    Write-Host "BLACKBOX_PATCHFIX2_BUILD_PASS runtime_zip_sha256=$outHash"
}
catch {
    Save-Diag "failure.txt" ($_ | Out-String)
    Capture-SourceDiagnostics $src
    throw
}
