$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$BaselineSha = "03d62ad22438344f1dcd38c5b5e44f660b564b92"
$Ready4Sha = "0b709de7e6c588b76786d8b648d5f669563c0bf45df5ec44a63db56f869e795f"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$Diag = Join-Path $env:RUNNER_TEMP "bbx-diagnostics"
New-Item -ItemType Directory -Path $Diag -Force | Out-Null

function Save-Diag([string]$Name, [string]$Text) {
    $Text | Set-Content -LiteralPath (Join-Path $Diag $Name) -Encoding utf8
}

try {
    $parts = @(
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
        foreach ($p in $parts) {
            if (-not (Test-Path -LiteralPath $p)) { throw "Missing transport chunk: $p" }
        }
        $b64 = ($parts | ForEach-Object { (Get-Content -LiteralPath $_ -Raw).Trim() }) -join ""
    } finally {
        Pop-Location
    }

    if ($b64.Length -ne 122832) {
        throw "SOURCE_READY4 base64 length mismatch: $($b64.Length), expected 122832"
    }

    $zip = Join-Path $env:RUNNER_TEMP "SOURCE_READY4.zip"
    [IO.File]::WriteAllBytes($zip, [Convert]::FromBase64String($b64))
    $zipHash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    Save-Diag "ready4-sha256.txt" $zipHash
    if ($zipHash -ne $Ready4Sha) {
        throw "SOURCE_READY4 SHA256 mismatch: $zipHash"
    }
    Write-Host "READY4_TRANSPORT_PASS=$zipHash"

    $pkgBase = Join-Path $env:RUNNER_TEMP "ready4-package"
    if (Test-Path $pkgBase) { Remove-Item -Recurse -Force $pkgBase }
    Expand-Archive -LiteralPath $zip -DestinationPath $pkgBase
    $apply = Get-ChildItem -LiteralPath $pkgBase -Recurse -Filter APPLY_CLEAN1_SOURCE_READY.ps1 | Select-Object -First 1
    if (-not $apply) { throw "APPLY_CLEAN1_SOURCE_READY.ps1 not found in verified READY4 package" }
    $pkgRoot = $apply.Directory.Parent.FullName

    $src = Join-Path $env:RUNNER_TEMP "bb-clean1-source"
    if (Test-Path $src) { Remove-Item -Recurse -Force $src }
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
    if ($LASTEXITCODE -ne 0) { throw "APPLY_CLEAN1_SOURCE_READY failed: $LASTEXITCODE" }

    Push-Location $src
    try {
        & ".\ci\INSTALL_LLVM_CLEAN1.ps1"
        if ($LASTEXITCODE -ne 0) { throw "LLVM installer failed: $LASTEXITCODE" }

        & ".\ci\VERIFY_EXACT_PARENT_REPLAY.ps1"
        if ($LASTEXITCODE -ne 0) { throw "Exact parent replay failed: $LASTEXITCODE" }

        python tools/bb_blackbox/decode.py --self-test
        if ($LASTEXITCODE -ne 0) { throw "decoder self-test failed" }
        python ci/test_verify_clean1.py
        if ($LASTEXITCODE -ne 0) { throw "semantic regression gate failed" }
        python ci/verify_clean1.py
        if ($LASTEXITCODE -ne 0) { throw "semantic gate failed" }

        & ".\ci\BUILD_TIERB_CLEAN1.ps1"
        if ($LASTEXITCODE -ne 0) { throw "Tier-B Windows build failed: $LASTEXITCODE" }
    } finally {
        Pop-Location
    }

    $runtime = Join-Path $env:RUNNER_TEMP "runtime-clean1"
    if (Test-Path $runtime) { Remove-Item -Recurse -Force $runtime }
    New-Item -ItemType Directory -Path $runtime | Out-Null

    $shad = Get-ChildItem -LiteralPath (Join-Path $src "build") -Recurse -Filter shadPS4.exe | Select-Object -First 1
    $rec = Get-ChildItem -LiteralPath (Join-Path $src "build") -Recurse -Filter bb_blackbox_recorder.exe | Select-Object -First 1
    if (-not $shad) { throw "shadPS4.exe not found after build" }
    if (-not $rec) { throw "bb_blackbox_recorder.exe not found after build" }
    Copy-Item -LiteralPath $shad.FullName -Destination (Join-Path $runtime "shadPS4.exe")
    Copy-Item -LiteralPath $rec.FullName -Destination (Join-Path $runtime "bb_blackbox_recorder.exe")

    Get-ChildItem -LiteralPath (Join-Path $src "build") -Recurse -Filter *.pdb -ErrorAction SilentlyContinue | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $runtime -Force
    }

    $qtConf = Join-Path $src "dist\qt.conf"
    if (Test-Path $qtConf) { Copy-Item -LiteralPath $qtConf -Destination (Join-Path $runtime "qt.conf") }
    New-Item -ItemType Directory -Path (Join-Path $runtime "qtplugins") -Force | Out-Null
    $windeployqt = Get-Command windeployqt -ErrorAction Stop
    & $windeployqt.Source --plugindir (Join-Path $runtime "qtplugins") --no-compiler-runtime --no-system-d3d-compiler --no-system-dxc-compiler --dir $runtime (Join-Path $runtime "shadPS4.exe")
    if ($LASTEXITCODE -ne 0) { throw "windeployqt failed: $LASTEXITCODE" }

    Copy-Item -LiteralPath (Join-Path $src "tools\bb_blackbox\decode.py") -Destination (Join-Path $runtime "decode.py")
    Copy-Item -LiteralPath (Join-Path $src "tools\bb_blackbox\run_blackbox.cmd") -Destination (Join-Path $runtime "run_blackbox.cmd")
    @'
@echo off
setlocal
cd /d "%~dp0"
call run_blackbox.cmd "%~dp0shadPS4.exe"
'@ | Set-Content -LiteralPath (Join-Path $runtime "RUN_BLACKBOX.cmd") -Encoding ascii

    $required = @("shadPS4.exe", "bb_blackbox_recorder.exe", "decode.py", "RUN_BLACKBOX.cmd")
    foreach ($name in $required) {
        if (-not (Test-Path -LiteralPath (Join-Path $runtime $name))) { throw "Missing runtime file: $name" }
    }
    $qwindows = Get-ChildItem -LiteralPath $runtime -Recurse -Filter qwindows.dll -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $qwindows) { throw "qwindows.dll missing after windeployqt" }

    $evidence = Join-Path $runtime "evidence"
    New-Item -ItemType Directory -Path $evidence -Force | Out-Null
    if (Test-Path (Join-Path $src "ci\evidence")) {
        Copy-Item -Path (Join-Path $src "ci\evidence\*") -Destination $evidence -Recurse -Force
    }
    Copy-Item -LiteralPath $zip -Destination (Join-Path $evidence "SOURCE_READY4_INPUT.zip")

    $manifest = Get-ChildItem -LiteralPath $runtime -Recurse -File | Sort-Object FullName | ForEach-Object {
        $rel = $_.FullName.Substring($runtime.Length + 1).Replace('\','/')
        $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        "$hash  $rel"
    }
    $manifest | Set-Content -LiteralPath (Join-Path $runtime "SHA256SUMS.txt") -Encoding ascii

    $zipOut = Join-Path $env:RUNNER_TEMP "BLACKBOX_V1_CI_CLEAN1_WIN64_QT.zip"
    if (Test-Path $zipOut) { Remove-Item -Force $zipOut }
    Compress-Archive -Path (Join-Path $runtime "*") -DestinationPath $zipOut -CompressionLevel Optimal
    $outHash = (Get-FileHash -LiteralPath $zipOut -Algorithm SHA256).Hash.ToLowerInvariant()
    Save-Diag "runtime-zip-sha256.txt" $outHash
    Save-Diag "result.txt" "BUILD_PASS`nREADY4_SHA256=$zipHash`nRUNTIME_ZIP_SHA256=$outHash"
    Write-Host "BLACKBOX_BUILD_PASS runtime_zip_sha256=$outHash"

    "RUNTIME_ZIP=$zipOut" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
    "SRC_ROOT=$src" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
}
catch {
    Save-Diag "failure.txt" ($_ | Out-String)
    if ($src -and (Test-Path $src)) {
        try { git -C $src status --short | Set-Content -LiteralPath (Join-Path $Diag "git-status.txt") -Encoding utf8 } catch {}
        try { git -C $src diff --binary | Set-Content -LiteralPath (Join-Path $Diag "source-diff.patch") -Encoding utf8 } catch {}
        try {
            if (Test-Path (Join-Path $src "ci\evidence")) {
                Copy-Item -LiteralPath (Join-Path $src "ci\evidence") -Destination (Join-Path $Diag "ci-evidence") -Recurse -Force
            }
        } catch {}
    }
    throw
}
