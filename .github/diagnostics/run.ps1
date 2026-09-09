$ErrorActionPreference = 'Stop'
$logDir = Join-Path $env:RUNNER_TEMP 'archon-class-operations'
New-Item -ItemType Directory -Path $logDir -ErrorAction Stop | Out-Null
$stopPath = Join-Path $logDir 'observer.stop'
$observerScript = Join-Path $PSScriptRoot 'native-observer.ps1'
$observer = Start-Process pwsh -ArgumentList @('-NoProfile', '-File', ('"' + $observerScript + '"'), '-OutputPath', ('"' + (Join-Path $logDir 'native.jsonl') + '"'), '-StopMarker', ('"' + $stopPath + '"'), '-PidPath', ('"' + (Join-Path $logDir 'observer.pid') + '"')) -PassThru -RedirectStandardError (Join-Path $logDir 'observer.stderr')
$exitCode = 1
try {
    $readyDeadline = [DateTime]::UtcNow.AddSeconds(5)
    $pidFile = Join-Path $logDir 'observer.pid'
    while (-not (Test-Path $pidFile) -and -not $observer.HasExited -and [DateTime]::UtcNow -lt $readyDeadline) { Start-Sleep -Milliseconds 50 }
    if (-not (Test-Path $pidFile)) { throw 'Native observer did not start; inspect observer.stderr.' }
    $env:ARCHON_DIAG_LOG_DIR = $logDir
    # Run the normal parallel suite first; no focused fixture warmup precedes it.
    & bun run test
    $exitCode = $LASTEXITCODE
}
finally {
    [IO.File]::WriteAllText($stopPath, 'stop')
    if (-not $observer.WaitForExit(10000)) {
        Stop-Process -Id $observer.Id
        $observer.WaitForExit()
        Write-Warning 'Observer exceeded its shutdown wait; exact observer PID terminated.'
    }
    if ($observer.ExitCode -ne 0) { Write-Warning "Observer failed with exit code $($observer.ExitCode); inspect artifacts." }
}
exit $exitCode
