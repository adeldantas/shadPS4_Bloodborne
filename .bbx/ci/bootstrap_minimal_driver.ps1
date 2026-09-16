$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$baseScript = Join-Path $PSScriptRoot 'bootstrap_minimal.ps1'
$effectiveScript = Join-Path $PSScriptRoot 'bootstrap_minimal_effective.ps1'

if (-not (Test-Path -LiteralPath $baseScript)) {
    throw "Missing minimal bootstrap: $baseScript"
}

$source = Get-Content -LiteralPath $baseScript -Raw
$anchor = '    if (Test-Path -LiteralPath $Src) { Remove-Item -LiteralPath $Src -Recurse -Force }'
$anchorCount = ([regex]::Matches($source, [regex]::Escape($anchor))).Count
if ($anchorCount -ne 1) {
    throw "PATCHFIX1 injection anchor expected exactly once; found $anchorCount"
}

$patchfixBlock = @'
    # Restore the CI-exact PATCHFIX1 integration patch before source reconstruction.
    # READY4 itself remains immutable and is verified above; only its extracted working copy is updated.
    $PatchfixSha = '9e998761b9aefdf7649f001a0ffaf875755733cf4b3885d63a8aec349fd34efa'
    $PatchPart01Sha = '7b6b725fd55f495f4391d431b0a4622cceb99aab7e055b42af9b5da67cff0711'
    $part01Pieces = @(
        '.bbx/patchfix1/part01a.b64',
        '.bbx/patchfix1/part01b.b64',
        '.bbx/patchfix1/part01c.b64',
        '.bbx/patchfix1/part01d1.b64',
        '.bbx/patchfix1/part01d2.b64'
    )

    Push-Location $RepoRoot
    try {
        foreach ($piece in $part01Pieces) {
            if (-not (Test-Path -LiteralPath $piece)) {
                throw "Missing PATCHFIX1 part01 piece: $piece"
            }
        }
        $part01 = ($part01Pieces | ForEach-Object { (Get-Content -LiteralPath $_ -Raw).Trim() }) -join ''
        if ($part01.Length -ne 8000) {
            throw "PATCHFIX1 part01 length mismatch: $($part01.Length)"
        }
        $part01Path = Join-Path $env:RUNNER_TEMP 'patchfix1-part01.b64'
        [IO.File]::WriteAllText($part01Path, $part01, [Text.Encoding]::ASCII)
        $part01Hash = (Get-FileHash -LiteralPath $part01Path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($part01Hash -ne $PatchPart01Sha) {
            throw "PATCHFIX1 part01 SHA256 mismatch: $part01Hash"
        }

        $rest = @(
            '.bbx/patchfix1/part02.b64',
            '.bbx/patchfix1/part03.b64',
            '.bbx/patchfix1/part04.b64'
        )
        foreach ($piece in $rest) {
            if (-not (Test-Path -LiteralPath $piece)) {
                throw "Missing PATCHFIX1 transport chunk: $piece"
            }
        }
        $patchB64 = $part01 + (($rest | ForEach-Object { (Get-Content -LiteralPath $_ -Raw).Trim() }) -join '')
    }
    finally {
        Pop-Location
    }

    if ($patchB64.Length -ne 30252) {
        throw "PATCHFIX1 base64 length mismatch: $($patchB64.Length)"
    }

    $integrationPatch = Join-Path $verifiedRoot 'integration\BLACKBOX_V1_CI_CLEAN1_CORE_SAFE.patch'
    if (-not (Test-Path -LiteralPath (Split-Path -Parent $integrationPatch))) {
        throw "PATCHFIX1 integration directory missing: $(Split-Path -Parent $integrationPatch)"
    }
    [IO.File]::WriteAllBytes($integrationPatch, [Convert]::FromBase64String($patchB64))
    $patchHash = (Get-FileHash -LiteralPath $integrationPatch -Algorithm SHA256).Hash.ToLowerInvariant()
    Save-Diag 'patchfix1-sha256.txt' $patchHash
    if ($patchHash -ne $PatchfixSha) {
        throw "PATCHFIX1 SHA256 mismatch: $patchHash"
    }
'@

$effective = $source.Replace($anchor, $patchfixBlock.TrimEnd() + "`r`n`r`n" + $anchor)
[IO.File]::WriteAllText($effectiveScript, $effective, [Text.UTF8Encoding]::new($false))

$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($effectiveScript, [ref]$tokens, [ref]$errors) | Out-Null
if ($errors.Count -ne 0) {
    $text = ($errors | ForEach-Object { $_.ToString() }) -join "`n"
    throw "Effective minimal bootstrap syntax validation failed:`n$text"
}

try {
    & $effectiveScript
}
finally {
    Remove-Item -LiteralPath $effectiveScript -Force -ErrorAction SilentlyContinue
}
