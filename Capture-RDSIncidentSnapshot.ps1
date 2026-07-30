<#requires -Version 5.1

Purpose
Captures volatile evidence from an unhealthy broker before rebooting it.

It collects:

Services
Processes and command lines
Handle/thread counts
Scheduled-task states
TCP connection summary
Memory and CPU counters
Current RDP sessions
Recent RDS events
This is read-only, but confirm operational authorization before running during an incident.

#>
param(
    [Parameter(Mandatory)]
    [string]$ComputerName,

    [string]$OutputRoot = "C:\Temp"
)

$Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$OutputFolder = Join-Path `
    $OutputRoot `
    "$ComputerName-RDS-Snapshot-$Timestamp"

New-Item -Path $OutputFolder -ItemType Directory -Force |
    Out-Null

Write-Host "Capturing snapshot from $ComputerName..." `
    -ForegroundColor Cyan

$Snapshot = Invoke-Command -ComputerName $ComputerName `
    -ErrorAction Stop -ScriptBlock {

    $Services = Get-Service `
        TermService,
        UmRdpService,
        SessionEnv,
        Tssdis,
        RDMS `
        -ErrorAction SilentlyContinue |
        Select-Object Name, DisplayName, Status, StartType

    $Processes = Get-CimInstance Win32_Process |
        Select-Object Name,
                      ProcessId,
                      ParentProcessId,
                      CreationDate,
                      HandleCount,
                      ThreadCount,
                      WorkingSetSize,
                      CommandLine

    $RelevantProcesses = $Processes |
        Where-Object {
            $_.Name -in @(
                "powershell.exe",
                "pwsh.exe",
                "wmic.exe",
                "svchost.exe"
            )
        }

    $Tasks = Get-ScheduledTask |
        Where-Object {
            $_.TaskName -in @(
                "ConnectedUserHealthCheck",
                "RDDrainingCheckerV666",
                "RDDrainingCheckerV777"
            )
        } |
        ForEach-Object {
            $Info = $_ | Get-ScheduledTaskInfo

            [PSCustomObject]@{
                TaskPath       = $_.TaskPath
                TaskName       = $_.TaskName
                State          = $_.State
                LastRunTime    = $Info.LastRunTime
                LastTaskResult = $Info.LastTaskResult
                NextRunTime    = $Info.NextRunTime
            }
        }

    $TCPState = Get-NetTCPConnection -ErrorAction SilentlyContinue |
        Group-Object State |
        Select-Object Name, Count

    $Counters = Get-Counter @(
        '\Memory\Available MBytes',
        '\Memory\% Committed Bytes In Use',
        '\Memory\Pool Nonpaged Bytes',
        '\Memory\Pool Paged Bytes',
        '\System\Processor Queue Length',
        '\TCPv4\Connections Established'
    ) -ErrorAction SilentlyContinue

    $Sessions = (& qwinsta 2>&1) -join "`r`n"

    $RecentRDS = @()

    foreach ($Log in @(
        "Microsoft-Windows-TerminalServices-RemoteConnectionManager/Operational",
        "Microsoft-Windows-TerminalServices-RemoteConnectionManager/Admin",
        "Microsoft-Windows-TerminalServices-SessionBroker/Operational",
        "Microsoft-Windows-TerminalServices-SessionBroker/Admin"
    )) {
        try {
            $RecentRDS += Get-WinEvent -FilterHashtable @{
                LogName   = $Log
                StartTime = (Get-Date).AddMinutes(-30)
            }
        }
        catch {}
    }

    [PSCustomObject]@{
        ComputerName = $env:COMPUTERNAME
        CaptureTime  = Get-Date
        Services     = $Services
        Processes    = $RelevantProcesses
        Tasks        = $Tasks
        TCPState     = $TCPState
        Counters     = $Counters.CounterSamples
        Sessions     = $Sessions
        Events       = $RecentRDS
    }
}

$Snapshot.Services |
    Export-Csv "$OutputFolder\Services.csv" `
        -NoTypeInformation -Encoding UTF8

$Snapshot.Processes |
    Export-Csv "$OutputFolder\Processes.csv" `
        -NoTypeInformation -Encoding UTF8

$Snapshot.Tasks |
    Export-Csv "$OutputFolder\Tasks.csv" `
        -NoTypeInformation -Encoding UTF8

$Snapshot.TCPState |
    Export-Csv "$OutputFolder\TCP-State.csv" `
        -NoTypeInformation -Encoding UTF8

$Snapshot.Counters |
    Select-Object Path, CookedValue, Timestamp |
    Export-Csv "$OutputFolder\Performance-Counters.csv" `
        -NoTypeInformation -Encoding UTF8

$Snapshot.Sessions |
    Out-File "$OutputFolder\RDP-Sessions.txt" `
        -Encoding UTF8

$Snapshot.Events |
    ForEach-Object {
        [PSCustomObject]@{
            TimeCreated = $_.TimeCreated
            LogName     = $_.LogName
            Provider    = $_.ProviderName
            EventID     = $_.Id
            Level       = $_.LevelDisplayName
            RecordID    = $_.RecordId
            Message     = $_.Message
            EventXML    = $_.ToXml()
        }
    } |
    Export-Csv "$OutputFolder\Recent-RDS-Events.csv" `
        -NoTypeInformation -Encoding UTF8

Write-Host "Snapshot saved to: $OutputFolder" `
    -ForegroundColor Green
