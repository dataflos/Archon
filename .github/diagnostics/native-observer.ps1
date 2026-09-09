param(
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [Parameter(Mandatory = $true)][string]$StopMarker,
    [Parameter(Mandatory = $true)][string]$PidPath
)

$ErrorActionPreference = 'Stop'
$processNames = @('bun', 'git', 'tar', 'bash', 'node')
$watch = [System.Diagnostics.Stopwatch]::StartNew()
$writer = $null
$traceSources = @("archon-start-$PID", "archon-stop-$PID")

function Drain-ProcessEvents {
    foreach ($source in $traceSources) {
        foreach ($queued in @(Get-Event -SourceIdentifier $source -ErrorAction SilentlyContinue)) {
            $native = $queued.SourceEventArgs.NewEvent
            $isStop = $source -eq $traceSources[1]
            $entry = @{
                kind = if ($isStop) { 'native_process_stop' } else { 'native_process_start' }
                pid = $native.ProcessID
                parentPid = $native.ParentProcessID
                name = $native.ProcessName
                eventFileTime = [string]$native.TIME_CREATED
                generatedUtc = [DateTime]::FromFileTimeUtc([long]$native.TIME_CREATED).ToString('o')
            }
            if ($isStop) { $entry.exitStatus = $native.ExitStatus }
            Write-Observation $entry
            Remove-Event -EventIdentifier $queued.EventIdentifier -ErrorAction Stop
        }
    }
}

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
    # Native event timestamps are independent of when this queue is drained.
    # Include cmd.exe for the known-exit control after the measured suite.
    $filter = (($processNames + 'cmd') | ForEach-Object { "ProcessName='$_.exe'" }) -join ' OR '
    Register-CimIndicationEvent -Namespace root/cimv2 -Query "SELECT * FROM Win32_ProcessStartTrace WHERE $filter" -SourceIdentifier $traceSources[0] | Out-Null
    Register-CimIndicationEvent -Namespace root/cimv2 -Query "SELECT * FROM Win32_ProcessStopTrace WHERE $filter" -SourceIdentifier $traceSources[1] | Out-Null
    [System.IO.File]::WriteAllText($PidPath, [string]$PID)
    Write-Observation @{ kind = 'observer_started'; sampleIntervalMs = 1000; names = $processNames }

    while (-not [System.IO.File]::Exists($StopMarker)) {
        $sampleStart = $watch.ElapsedMilliseconds
        Drain-ProcessEvents
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
                if ($observedProcess.ProcessName -eq 'tar') {
                    foreach ($thread in $observedProcess.Threads) {
                        try {
                            $state = $thread.ThreadState
                            $reason = if ($state -eq [System.Diagnostics.ThreadState]::Wait) { [string]$thread.WaitReason } else { $null }
                            Write-Observation @{
                                kind = 'tar_thread'
                                pid = $observedProcess.Id
                                startedUtc = $observedProcess.StartTime.ToUniversalTime().ToString('o')
                                threadId = $thread.Id
                                state = [string]$state
                                waitReason = $reason
                                cpuSeconds = $thread.TotalProcessorTime.TotalSeconds
                            }
                        }
                        catch { Write-ObserverError 'tar_thread_sample' $_ $observedProcess.Id }
                        finally { $thread.Dispose() }
                    }
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
        $observerProcess = [System.Diagnostics.Process]::GetCurrentProcess()
        try {
            Write-Observation @{
                kind = 'sample_completed'
                durationMs = $sampleDuration
                observerCpuSeconds = $observerProcess.TotalProcessorTime.TotalSeconds
                observerWorkingSetBytes = $observerProcess.WorkingSet64
                observerPrivateMemoryBytes = $observerProcess.PrivateMemorySize64
            }
        }
        finally { $observerProcess.Dispose() }
        $remaining = 1000 - $sampleDuration
        if ($remaining -gt 0) { Start-Sleep -Milliseconds $remaining }
    }
    # Allow queued provider events to arrive; this is a bounded evidence drain,
    # not proof that every native termination event has been delivered.
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        Drain-ProcessEvents
        Start-Sleep -Milliseconds 100
    }
    Drain-ProcessEvents
    Write-Observation @{ kind = 'observer_stopped'; reason = 'stop_marker' }
}
catch {
    if ($null -ne $writer) { Write-ObserverError 'observer_fatal' $_ }
    [Console]::Error.WriteLine("Native observer failed: $($_.Exception.Message)")
    exit 1
}
finally {
    foreach ($source in $traceSources) {
        if (Get-EventSubscriber -SourceIdentifier $source -ErrorAction SilentlyContinue) {
            Unregister-Event -SourceIdentifier $source
        }
    }
    if ($null -ne $writer) { $writer.Dispose() }
}
