param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$TargetPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$target = (Resolve-Path -LiteralPath $TargetPath -ErrorAction Stop).Path
$recorder = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..\bb_blackbox_recorder.exe') -ErrorAction Stop).Path
$stamp = "{0}_{1}" -f $PID, ([DateTime]::UtcNow.ToString('yyyyMMddHHmmssfff'))
$mapping = "Local\BB_BLACKBOX_$stamp"
$outDir = Join-Path (Get-Location).Path "BB_BLACKBOX_$stamp"
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

$rec = $null
$producer = $null
$oldMapping = [Environment]::GetEnvironmentVariable('BB_BLACKBOX_MAPPING', 'Process')
try {
    $recArgs = @((('"' + $mapping + '"')), (('"' + $outDir + '"')))
    $rec = Start-Process -FilePath $recorder -ArgumentList $recArgs -PassThru -NoNewWindow
    $null = $rec.Handle
    $statusPath = Join-Path $outDir 'capture_status.json'
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while (-not (Test-Path -LiteralPath $statusPath)) {
        if ($rec.HasExited) { throw "Recorder exited before readiness with code $($rec.ExitCode)" }
        if ([DateTime]::UtcNow -ge $deadline) { throw 'Recorder readiness timeout' }
        Start-Sleep -Milliseconds 100
        $rec.Refresh()
    }

    [Environment]::SetEnvironmentVariable('BB_BLACKBOX_MAPPING', $mapping, 'Process')
    $producer = Start-Process -FilePath $target -PassThru -Wait -NoNewWindow
    $producerRc = $producer.ExitCode
    if ($null -eq $producerRc) { throw 'Producer exit code unavailable after process exit' }

    if (-not $rec.WaitForExit(15000)) {
        try { $rec.Kill() } catch {}
        throw 'Recorder completion timeout after producer exit'
    }
    $recRc = $rec.ExitCode
    if ($null -eq $recRc) { throw 'Recorder exit code unavailable after process exit' }
    if ($recRc -ne 0) { throw "Recorder exited with code $recRc" }

    $status = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
    if (-not $status.complete) { throw "Recorder status is incomplete: $($status.terminal_reason)" }
    Write-Host "Capture directory: $outDir"
    exit $producerRc
}
finally {
    [Environment]::SetEnvironmentVariable('BB_BLACKBOX_MAPPING', $oldMapping, 'Process')
    if ($rec -and -not $rec.HasExited) {
        try { $rec.Kill() } catch {}
    }
}
