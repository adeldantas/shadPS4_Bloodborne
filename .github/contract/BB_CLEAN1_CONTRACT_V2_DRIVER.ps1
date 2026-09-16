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

if (-not (Test-Path -LiteralPath $SourceContract -PathType Leaf)) { throw 'STOP_V2_SOURCE_CONTRACT_MISSING' }
$Text = [IO.File]::ReadAllText($SourceContract)

$OldWork = "'bb-clean1-contract-v1'"
$NewWork = "'bb-clean1-contract-v2'"
$Text = Replace-ExactlyOnce $Text $OldWork $NewWork 'STOP_V2_WORKDIR_PATCH_CARDINALITY'

$AuditAnchor = "    if (`$env:ImageVersion -ne '20260907.297.1') { throw \"STOP_ENVIRONMENT_IDENTITY ImageVersion=`$env:ImageVersion\" }"
$AuditBlock = @'
    $AuditVsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    $AuditVsVersion = (& $AuditVsWhere -latest -products * -property installationVersion | Out-String).Trim()
    $AuditCMakeVersion = (& $CMake --version | Select-Object -First 1)
    $AuditNinjaVersion = (& $Ninja --version | Out-String).Trim()
    $AuditPyIdentity = & $Python -c 'import sys,struct;print("%d.%d.%d"%sys.version_info[:3]);print(struct.calcsize("P")*8)'
    $AuditQtVersion = (& (Join-Path $Qt 'bin\qmake.exe') -query QT_VERSION | Out-String).Trim()
    $AuditLines = @(
        "image_version=$env:ImageVersion",
        "powershell=$($PSVersionTable.PSVersion)",
        "vs=$AuditVsVersion",
        "vctools=$($env:VCToolsVersion.TrimEnd('\'))",
        "sdk=$($env:WindowsSDKVersion.TrimEnd('\'))",
        "cmake=$AuditCMakeVersion",
        "ninja=$AuditNinjaVersion",
        "ninja_sha256=$(Get-Sha256 $Ninja)",
        "python=$($AuditPyIdentity -join '/')",
        "python_sha256=$(Get-Sha256 $Python)",
        "qt=$AuditQtVersion",
        "qt_root=$Qt"
    )
    Write-Diag 'runner-identity-audit.txt' $AuditLines
    foreach ($AuditLine in $AuditLines) { Write-Host "RUNNER_AUDIT $AuditLine" }
'@
$Text = Replace-ExactlyOnce $Text $AuditAnchor ($AuditBlock.TrimEnd("`r","`n") + "`n" + $AuditAnchor) 'STOP_V2_AUDIT_PATCH_CARDINALITY'

$OldQtGate = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('ICAgICRRdENvbmYgPSBKb2luLVBhdGggJFNyYyAnZGlzdFxxdC5jb25mJzsgaWYgKC1ub3QgKFRlc3QtUGF0aCAtTGl0ZXJhbFBhdGggJFF0Q29uZiAtUGF0aFR5cGUgTGVhZikpIHsgdGhyb3cgJ1NUT1BfUzVfUVRfQ09ORicgfTsgQ29weS1JdGVtIC1MaXRlcmFsUGF0aCAkUXRDb25mIC1EZXN0aW5hdGlvbiAoSm9pbi1QYXRoICRSdW50aW1lICdxdC5jb25mJyk7IGlmICgoR2V0LUNvbnRlbnQgLUxpdGVyYWxQYXRoICRRdENvbmYgLVJhdykgLW5vdG1hdGNoICcoP2ltKV5ccypQbHVnaW5zXHMqPVxzKnF0cGx1Z2luc1xzKiQnKSB7IHRocm93ICdTVE9QX0xBWU9VVCBxdC5jb25mIHBsdWdpbnMnIH0='))
$NewQtGate = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('ICAgICRRdENvbmYgPSBKb2luLVBhdGggJFNyYyAnZGlzdFxxdC5jb25mJwogICAgaWYgKC1ub3QgKFRlc3QtUGF0aCAtTGl0ZXJhbFBhdGggJFF0Q29uZiAtUGF0aFR5cGUgTGVhZikpIHsgdGhyb3cgJ1NUT1BfUzVfUVRfQ09ORicgfQogICAgJFJ1bnRpbWVRdENvbmYgPSBKb2luLVBhdGggJFJ1bnRpbWUgJ3F0LmNvbmYnCiAgICBDb3B5LUl0ZW0gLUxpdGVyYWxQYXRoICRRdENvbmYgLURlc3RpbmF0aW9uICRSdW50aW1lUXRDb25mCiAgICAkUXRDb25mVGV4dCA9IEdldC1Db250ZW50IC1MaXRlcmFsUGF0aCAkUnVudGltZVF0Q29uZiAtUmF3CiAgICBpZiAoJFF0Q29uZlRleHQgLW5vdG1hdGNoICcoP2ltKV5ccypcW1BhdGhzXF1ccyokJyAtb3IgJFF0Q29uZlRleHQgLW5vdG1hdGNoICcoP2ltKV5ccypwbHVnaW5zXHMqPVxzKiJcLi9xdHBsdWdpbnMiXHMqJCcpIHsgdGhyb3cgJ1NUT1BfTEFZT1VUIHF0LmNvbmYgc291cmNlJyB9CiAgICBbSU8uRmlsZV06OldyaXRlQWxsVGV4dCgkUnVudGltZVF0Q29uZiwgIltQYXRoc11gcmBuUGx1Z2lucyA9IHF0cGx1Z2luc2ByYG4iLCBbVGV4dC5VVEY4RW5jb2RpbmddOjpuZXcoJGZhbHNlKSkKICAgIGlmICgoR2V0LUNvbnRlbnQgLUxpdGVyYWxQYXRoICRSdW50aW1lUXRDb25mIC1SYXcpIC1ub3RtYXRjaCAnKD9pbSleXHMqUGx1Z2luc1xzKj1ccypxdHBsdWdpbnNccyokJykgeyB0aHJvdyAnU1RPUF9MQVlPVVQgcXQuY29uZiBwbHVnaW5zJyB9'))
$Text = Replace-ExactlyOnce $Text $OldQtGate $NewQtGate 'STOP_V2_QT_PATCH_CARDINALITY'

$LauncherAnchor = '    Assert-Hash (Join-Path $HarnessInputs ''.bbx\ci\run_blackbox_patchfix3.cmd'') $LauncherCmdSha ''STOP_S0_LAUNCHER_CMD_HASH'''
$LauncherAmendment = @'
    $LauncherV2Source = $env:BB_CLEAN1_V2_LAUNCHER
    if ([string]::IsNullOrWhiteSpace($LauncherV2Source)) { throw 'STOP_V2_LAUNCHER_INPUT_MISSING' }
    Assert-Hash $LauncherV2Source '71d6d3f20ddf81881d0d3a9c7eb25dbd6ca783a16bfe319f0cf218d49ce15ac3' 'STOP_V2_LAUNCHER_SOURCE_HASH'
    $LauncherV2Dest = Join-Path $HarnessInputs '.bbx\ci\run_blackbox_patchfix3.ps1'
    Copy-Item -LiteralPath $LauncherV2Source -Destination $LauncherV2Dest -Force
    Assert-Hash $LauncherV2Dest '71d6d3f20ddf81881d0d3a9c7eb25dbd6ca783a16bfe319f0cf218d49ce15ac3' 'STOP_V2_LAUNCHER_EFFECTIVE_HASH'
    Write-Diag 'launcher-v2.txt' @('original_launcher_ps_sha256=eaaec92a072abbda4119edae6880667ef3cbd43d48fa784c805c555fb1b2d0ae','v2_launcher_ps_sha256=71d6d3f20ddf81881d0d3a9c7eb25dbd6ca783a16bfe319f0cf218d49ce15ac3','launcher_cmd_unchanged_sha256=22752522a5c39813ceb66d4099a716cbf226b17e0bf4e03b29d898b995e53530')
'@
$Text = Replace-ExactlyOnce $Text $LauncherAnchor ($LauncherAnchor + "`n" + $LauncherAmendment.TrimEnd("`r","`n")) 'STOP_V2_LAUNCHER_PATCH_CARDINALITY'

$StateAnchor = '    $StateLines = @('
$FailureEvidence = @'
    try {
        if (Test-Path -LiteralPath $Smoke -PathType Container) {
            $SmokeEvidence = Join-Path $Diag 'smoke-failure-evidence'
            New-Item -ItemType Directory -Path $SmokeEvidence -Force | Out-Null
            foreach ($File in Get-ChildItem -LiteralPath $Smoke -Recurse -File) {
                $Rel = [IO.Path]::GetRelativePath($Smoke,$File.FullName)
                $Dest = Join-Path $SmokeEvidence $Rel
                $DestDir = Split-Path -Parent $Dest
                if (-not (Test-Path -LiteralPath $DestDir -PathType Container)) { New-Item -ItemType Directory -Path $DestDir -Force | Out-Null }
                Copy-Item -LiteralPath $File.FullName -Destination $Dest -Force
            }
        }
    } catch {
        $_ | Out-String | Set-Content -LiteralPath (Join-Path $Diag 'smoke-failure-evidence-copy-error.txt') -Encoding utf8
    }
'@
$Text = Replace-ExactlyOnce $Text $StateAnchor ($FailureEvidence.TrimEnd("`r","`n") + "`n" + $StateAnchor) 'STOP_V2_DIAGNOSTICS_PATCH_CARDINALITY'

[IO.File]::WriteAllText($OutputContract, $Text, [Text.UTF8Encoding]::new($false))
$Tokens = $null
$ParseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile($OutputContract, [ref]$Tokens, [ref]$ParseErrors) | Out-Null
if ($ParseErrors.Count -ne 0) { throw "STOP_V2_CONTRACT_PARSE $($ParseErrors[0].Message)" }
$EffectiveHash = (Get-FileHash -LiteralPath $OutputContract -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Host "CLEAN1_V2_EFFECTIVE_CONTRACT_SHA256=$EffectiveHash"
