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

if (-not (Test-Path -LiteralPath $SourceContract -PathType Leaf)) { throw 'STOP_BRIDGE_SOURCE_CONTRACT_MISSING' }
$Text = [IO.File]::ReadAllText($SourceContract)
$Text = Replace-ExactlyOnce $Text "'bb-clean1-contract-v2'" "'bb-clean1-contract-v2-bridge'" 'STOP_BRIDGE_WORKDIR_CARDINALITY'
$Text = Replace-ExactlyOnce $Text "'20260907.297.1'" "'20260913.307.1'" 'STOP_BRIDGE_IMAGE_CARDINALITY'
$Text = Replace-ExactlyOnce $Text "'17.14.37614.0'" "'17.14.37628.2'" 'STOP_BRIDGE_VS_CARDINALITY'
$Text = Replace-ExactlyOnce $Text "'7.6.5'" "'7.6.6'" 'STOP_BRIDGE_POWERSHELL_CARDINALITY'

[IO.File]::WriteAllText($OutputContract, $Text, [Text.UTF8Encoding]::new($false))
$Tokens = $null
$ParseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile($OutputContract, [ref]$Tokens, [ref]$ParseErrors) | Out-Null
if ($ParseErrors.Count -ne 0) { throw "STOP_BRIDGE_CONTRACT_PARSE $($ParseErrors[0].Message)" }
$EffectiveHash = (Get-FileHash -LiteralPath $OutputContract -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Host "CLEAN1_V2_BRIDGE_EFFECTIVE_CONTRACT_SHA256=$EffectiveHash"
