$ErrorActionPreference = 'Stop'
$provider = 'Microsoft-Windows-Kernel-Process'
$providerId = [guid]'22fb2cd6-0e7b-422b-a0c7-2fad1fd0e716'
$scratch = Join-Path $env:RUNNER_TEMP 'archon-native-etw'
$exportDir = Join-Path $scratch 'export'
New-Item -ItemType Directory -Path $exportDir -ErrorAction Stop | Out-Null
$etl = Join-Path $scratch 'process.etl'
$session = 'ArchonProcess-' + [guid]::NewGuid().ToString('N')
$metadata = Get-WinEvent -ListProvider $provider -ErrorAction Stop
if ($metadata.Id -ne $providerId) { throw 'Unexpected process provider identity.' }
if (-not @($metadata.Keywords | Where-Object Value -EQ 16).Count) { throw 'Process keyword is absent from provider metadata.' }
@{
    name = $metadata.Name
    id = [string]$metadata.Id
    keywords = @($metadata.Keywords | Select-Object Name, Value)
    events = @($metadata.Events | Where-Object Id -In 1, 2 | Select-Object Id, Version, Template)
} | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $exportDir 'provider.json')

function Record-Control([string]$Name) {
    $child = [System.Diagnostics.Process]::new()
    try {
        $child.StartInfo.FileName = 'cmd.exe'
        $child.StartInfo.UseShellExecute = $false
        $child.StartInfo.CreateNoWindow = $true
        foreach ($argument in @('/d', '/c', 'exit 23')) { $child.StartInfo.ArgumentList.Add($argument) }
        $before = [DateTime]::UtcNow.ToString('o')
        if (-not $child.Start()) { throw 'Known-exit control failed to start.' }
        $child.WaitForExit()
        $after = [DateTime]::UtcNow.ToString('o')
        @{
            pid = $child.Id
            parentPid = $PID
            beforeUtc = $before
            afterUtc = $after
            createUtc = $child.StartTime.ToUniversalTime().ToString('o')
            exitUtc = $child.ExitTime.ToUniversalTime().ToString('o')
            createFileTime = [string]$child.StartTime.ToUniversalTime().ToFileTimeUtc()
            exitFileTime = [string]$child.ExitTime.ToUniversalTime().ToFileTimeUtc()
            exitCode = $child.ExitCode
        } | ConvertTo-Json -Compress | Set-Content (Join-Path $exportDir "control-$Name.json")
        if ($child.ExitCode -ne 23) { throw 'Known-exit control returned an unexpected status.' }
    }
    finally { $child.Dispose() }
}

& logman create trace $session -p ($providerId.ToString('B')) 0x10 4 -ct perf -o $etl -ets
if ($LASTEXITCODE -ne 0) { throw 'Native process ETW capture failed to start.' }
$suiteExit = 1
try {
    Record-Control 'before'
    # No fixture warmup or JavaScript preload precedes this normal parallel suite.
    & bun run test
    $suiteExit = $LASTEXITCODE
    Record-Control 'after'
}
finally {
    & logman stop $session -ets
    if ($LASTEXITCODE -ne 0) { throw 'Native process ETW capture failed to stop.' }
}

# ETL consumption happens after the workload. Never upload the raw trace: provider
# versions may include fields outside this deliberately small export contract.
$records = [System.Collections.Generic.List[object]]::new()
$selected = [System.Collections.Generic.HashSet[string]]::new()
$names = @('bun.exe', 'bash.exe', 'tar.exe', 'git.exe', 'node.exe', 'cmd.exe', 'pwsh.exe')
Get-WinEvent -Path $etl -Oldest -ErrorAction Stop | ForEach-Object {
    $event = $_
    if ($event.ProviderId -ne $providerId -or $event.Id -notin 1, 2) { return }
    [xml]$xml = $event.ToXml()
    $fields = @{}
    foreach ($field in $xml.Event.EventData.Data) { $fields[$field.GetAttribute('Name')] = $field.InnerText }
    $required = if ($event.Id -eq 1) { @('ProcessID', 'CreateTime', 'ParentProcessID') } else { @('ProcessID', 'CreateTime', 'ExitTime', 'ExitCode') }
    foreach ($field in $required) {
        if ([string]::IsNullOrEmpty($fields[$field])) { throw "Required native process field is absent: $field" }
    }
    $name = if ($fields['ImageName']) { [IO.Path]::GetFileName($fields['ImageName']).ToLowerInvariant() } else { $null }
    $key = $fields['ProcessID'] + '|' + $fields['CreateTime']
    if ($names -contains $name) { $null = $selected.Add($key) }
    $records.Add(@{
        eventId = $event.Id
        version = $event.Version
        headerUtc = $xml.Event.System.TimeCreated.GetAttribute('SystemTime')
        pid = $fields['ProcessID']
        parentPid = $fields['ParentProcessID']
        createTime = $fields['CreateTime']
        exitTime = $fields['ExitTime']
        exitCode = $fields['ExitCode']
        name = $name
    })
}
$writer = [IO.StreamWriter]::new((Join-Path $exportDir 'process-events.jsonl'), $false, [Text.UTF8Encoding]::new($false))
try {
    foreach ($record in $records) {
        if ($selected.Contains($record.pid + '|' + $record.createTime)) {
            $writer.WriteLine(($record | ConvertTo-Json -Compress))
        }
    }
}
finally { $writer.Dispose() }
@{
    etlBytes = (Get-Item $etl).Length
    observedStartStopEvents = $records.Count
    selectedIncarnations = $selected.Count
    readbackUtc = [DateTime]::UtcNow.ToString('o')
    lossStatisticsVerified = $false
    suiteExitCode = $suiteExit
} | ConvertTo-Json -Compress | Set-Content (Join-Path $exportDir 'capture.json')
exit $suiteExit
