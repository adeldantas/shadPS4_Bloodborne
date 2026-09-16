param(
    [Parameter(Mandatory=$true)][string]$SourceContract,
    [Parameter(Mandatory=$true)][string]$OutputContract
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Replace-ExactlyOnce([string]$Text, [string]$Old, [string]$New, [string]$Code) {
    $Count = [regex]::Matches($Text, [regex]::Escape($Old)).Count
    if ($Count -ne 1) { throw "$Code count=$Count" }
    return $Text.Replace($Old, $New)
}

if (-not (Test-Path -LiteralPath $SourceContract -PathType Leaf)) { throw 'STOP_V3_SOURCE_CONTRACT_MISSING' }
$Text = [IO.File]::ReadAllText($SourceContract)
$WorkPattern = "bb-clean1-contract-v[12]"
$WorkMatches = [regex]::Matches($Text, $WorkPattern)
if ($WorkMatches.Count -ne 1) { throw "STOP_V3_WORKDIR_PATCH_CARDINALITY count=$($WorkMatches.Count)" }
$Text = [regex]::Replace($Text, $WorkPattern, 'bb-clean1-contract-v3', 1)

$AuditAnchor = @'
    $AuditPath = Join-Path $Src 'clean1_static_audit.json'; if (-not (Test-Path -LiteralPath $AuditPath)) { throw 'STOP_S2_AUDIT_MISSING' }; $Audit = Get-Content -LiteralPath $AuditPath -Raw | ConvertFrom-Json; if ($Audit.pass -ne $true) { throw 'STOP_S2_AUDIT_FAIL' }; Copy-Item -LiteralPath $AuditPath -Destination (Join-Path $Diag 'clean1_static_audit.json')
'@
$AuditAnchor = $AuditAnchor.TrimEnd("`r","`n")
$CaptureFixBlock = @'
    Write-Host '=== S2b capture-integrity delta ==='
    $CaptureFixSource = $env:BB_CLEAN1_V3_CAPTURE_FIX
    $CaptureAuditSource = $env:BB_CLEAN1_V3_CAPTURE_AUDIT
    if ([string]::IsNullOrWhiteSpace($CaptureFixSource) -or -not (Test-Path -LiteralPath $CaptureFixSource -PathType Leaf)) { throw 'STOP_V3_CAPTURE_FIX_MISSING' }
    if ([string]::IsNullOrWhiteSpace($CaptureAuditSource) -or -not (Test-Path -LiteralPath $CaptureAuditSource -PathType Leaf)) { throw 'STOP_V3_CAPTURE_AUDIT_MISSING' }
    Assert-Hash $CaptureFixSource '4fa2e0a52e285c5f51d4e10b9c7d13a156c3eabe75b4d00cc0cffde09ba0fc9c' 'STOP_V3_CAPTURE_FIX_HASH'
    Assert-Hash $CaptureAuditSource '0cd328d6d21a2895c51cd176a8140afd6c64c67502b082838b0abe849773a050' 'STOP_V3_CAPTURE_AUDIT_HASH'

    git -C $Src apply --check --whitespace=error-all -- $CaptureFixSource
    Check-Native 'STOP_V3_CAPTURE_FIX_APPLY_CHECK'
    git -C $Src apply --whitespace=error-all -- $CaptureFixSource
    Check-Native 'STOP_V3_CAPTURE_FIX_APPLY'

    $CaptureAuditOut = Join-Path $Src 'clean1_capture_fix_audit.json'
    & $Python -B $CaptureAuditSource --root $Src --output $CaptureAuditOut *>&1 | Tee-Object (Join-Path $Diag 'capture-fix-audit.log')
    if ($LASTEXITCODE -ne 0) { throw "STOP_V3_CAPTURE_AUDIT exit=$LASTEXITCODE" }
    if (-not (Test-Path -LiteralPath $CaptureAuditOut -PathType Leaf)) { throw 'STOP_V3_CAPTURE_AUDIT_OUTPUT_MISSING' }
    $CaptureAuditJson = Get-Content -LiteralPath $CaptureAuditOut -Raw | ConvertFrom-Json
    if ($CaptureAuditJson.pass -ne $true) { throw 'STOP_V3_CAPTURE_AUDIT_FAIL' }
    Copy-Item -LiteralPath $CaptureAuditOut -Destination (Join-Path $Diag 'clean1_capture_fix_audit.json')
    Copy-Item -LiteralPath $CaptureFixSource -Destination (Join-Path $Diag 'BB_CLEAN1_CAPTURE_FIX1.patch')
    Write-Diag 'capture-fix-identity.txt' @(
        "capture_fix_sha256=$(Get-Sha256 $CaptureFixSource)",
        "capture_audit_sha256=$(Get-Sha256 $CaptureAuditSource)",
        'capture_validated=NO',
        'capture_readiness=NOT_READY',
        'runtime_test_allowed=false'
    )
'@
$Text = Replace-ExactlyOnce $Text $AuditAnchor ($AuditAnchor + "`n" + $CaptureFixBlock.TrimEnd("`r","`n")) 'STOP_V3_CAPTURE_BLOCK_CARDINALITY'

[IO.File]::WriteAllText($OutputContract, $Text, [Text.UTF8Encoding]::new($false))
$Tokens = $null
$ParseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile($OutputContract, [ref]$Tokens, [ref]$ParseErrors) | Out-Null
if ($ParseErrors.Count -ne 0) { throw "STOP_V3_CONTRACT_PARSE $($ParseErrors[0].Message)" }
$EffectiveHash = (Get-FileHash -LiteralPath $OutputContract -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Host "CLEAN1_V3_EFFECTIVE_CONTRACT_SHA256=$EffectiveHash"
