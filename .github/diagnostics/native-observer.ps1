param(
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [Parameter(Mandatory = $true)][string]$StopMarker,
    [Parameter(Mandatory = $true)][string]$PidPath
)

$ErrorActionPreference = 'Stop'
$processNames = @('bun', 'git', 'tar', 'bash', 'node')
$watch = [System.Diagnostics.Stopwatch]::StartNew()
$writer = $null

function Write-Observation([hashtable]$Value) {
    $Value.timestampUtc = [DateTime]::UtcNow.ToString('o')
    $Value.elapsedMs = $watch.ElapsedMilliseconds
    $Value.observerPid = $PID
    $writer.WriteLine(($Value | ConvertTo-Json -Depth 4 -Compress))
    $writer.Flush()
}

function Write-ObserverError([string]$Stage, $Failure, $ObservedPid = $null) {
    Write-Observation @{
        kind = 'observer_error'
        stage = $Stage
        observedPid = $ObservedPid
        errorType = $Failure.Exception.GetType().FullName
        message = $Failure.Exception.Message
    }
}

try {
    # CreateNew prevents accidentally overwriting another observer's evidence.
    $stream = [System.IO.File]::Open($OutputPath, 'CreateNew', 'Write', 'Read')
    $writer = [System.IO.StreamWriter]::new($stream, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($PidPath, [string]$PID)
    Write-Observation @{ kind = 'observer_started'; sampleIntervalMs = 1000; names = $processNames }

    while (-not [System.IO.File]::Exists($StopMarker)) {
        $sampleStart = $watch.ElapsedMilliseconds
        $processes = @()
        try {
            $processes = @(Get-Process | Where-Object { $processNames -contains $_.ProcessName })
        }
        catch { Write-ObserverError 'process_enumeration' $_ }

        foreach ($observedProcess in $processes) {
            try {
                Write-Observation @{
                    kind = 'process'
                    pid = $observedProcess.Id
                    name = $observedProcess.ProcessName
                    startedUtc = $observedProcess.StartTime.ToUniversalTime().ToString('o')
                    cpuSeconds = $observedProcess.TotalProcessorTime.TotalSeconds
                    workingSetBytes = $observedProcess.WorkingSet64
                    privateMemoryBytes = $observedProcess.PrivateMemorySize64
                }
            }
            catch { Write-ObserverError 'process_sample' $_ $observedProcess.Id }
            finally { $observedProcess.Dispose() }
        }

        # CIM class/property names are stable across localized Windows installations.
        foreach ($metric in @(
            @{ class = 'Win32_PerfFormattedData_PerfOS_Processor'; filter = "Name='_Total'"; property = 'PercentProcessorTime'; field = 'cpuPercent' },
            @{ class = 'Win32_PerfFormattedData_PerfOS_Memory'; filter = $null; property = 'AvailableMBytes'; field = 'availableMemoryMiB' },
            @{ class = 'Win32_PerfFormattedData_PerfDisk_PhysicalDisk'; filter = "Name='_Total'"; property = 'CurrentDiskQueueLength'; field = 'diskQueueLength' }
        )) {
            if ([System.IO.File]::Exists($StopMarker)) { break }
            try {
                $query = @{ ClassName = $metric.class; OperationTimeoutSec = 2; ErrorAction = 'Stop' }
                if ($metric.filter) { $query.Filter = $metric.filter }
                $rows = @(Get-CimInstance @query)
                if ($rows.Count -ne 1) { throw "Expected one counter row; received $($rows.Count)" }
                $value = $rows[0].($metric.property)
                if ($null -eq $value) { throw "Counter property is absent: $($metric.property)" }
                $entry = @{ kind = 'host'; metric = $metric.field; value = $value }
                Write-Observation $entry
            }
            catch { Write-ObserverError $metric.field $_ }
        }
        $sampleDuration = $watch.ElapsedMilliseconds - $sampleStart
        Write-Observation @{ kind = 'sample_completed'; durationMs = $sampleDuration }
        $remaining = 1000 - $sampleDuration
        if ($remaining -gt 0) { Start-Sleep -Milliseconds $remaining }
    }
    Write-Observation @{ kind = 'observer_stopped'; reason = 'stop_marker' }
}
catch {
    if ($null -ne $writer) { Write-ObserverError 'observer_fatal' $_ }
    [Console]::Error.WriteLine("Native observer failed: $($_.Exception.Message)")
    exit 1
}
finally {
    if ($null -ne $writer) { $writer.Dispose() }
}
