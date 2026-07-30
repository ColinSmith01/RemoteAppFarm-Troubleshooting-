#requires -Version 5.1
<#Collects narrow event windows around known failure times and compares failed brokers with a healthy control.

Use this after the baseline identifies the approximate transition time. #>

$OutputFolder = "C:\Temp\RDS-Transition-Investigation"
New-Item -Path $OutputFolder -ItemType Directory -Force |
    Out-Null

# Customize these windows.
$Windows = @(
    [PSCustomObject]@{
        Computer = "Broker01"
        Name     = "Broker02-Control"
        Start    = [datetime]"2026-01-01 11:55:00"
        End      = [datetime]"2026-01-01 12:15:00"
    },
    [PSCustomObject]@{
        Computer = "Broker02"
        Name     = "Broker02-Failure"
        Start    = [datetime]"2026-01-01 11:55:00"
        End      = [datetime]"2026-01-01 12:15:00"
    },
    [PSCustomObject]@{
        Computer = "Broker01"
        Name     = "Broker03-Control"
        Start    = [datetime]"2026-01-01 13:20:00"
        End      = [datetime]"2026-01-01 13:45:00"
    },
    [PSCustomObject]@{
        Computer = "Broker03"
        Name     = "Broker03-Failure"
        Start    = [datetime]"2026-01-01 13:20:00"
        End      = [datetime]"2026-01-01 13:45:00"
    }
)

$RDSLogs = @(
    "Microsoft-Windows-TerminalServices-SessionBroker/Admin",
    "Microsoft-Windows-TerminalServices-SessionBroker/Operational",
    "Microsoft-Windows-TerminalServices-SessionBroker-Client/Operational",
    "Microsoft-Windows-TerminalServices-RemoteConnectionManager/Admin",
    "Microsoft-Windows-TerminalServices-RemoteConnectionManager/Operational",
    "Microsoft-Windows-TerminalServices-LocalSessionManager/Operational",
    "Microsoft-Windows-RemoteDesktopServices-RdpCoreTS/Operational"
)

$Results = foreach ($Window in $Windows) {
    Write-Host "Collecting $($Window.Name)..." -ForegroundColor Cyan

    try {
        Invoke-Command -ComputerName $Window.Computer `
            -ArgumentList $Window.Start,
                          $Window.End,
                          $RDSLogs,
                          $Window.Name `
            -ErrorAction Stop -ScriptBlock {

            param($Start, $End, $RDSLogs, $WindowName)

            $Events = @()

            foreach ($Log in $RDSLogs) {
                try {
                    $Events += Get-WinEvent -FilterHashtable @{
                        LogName   = $Log
                        StartTime = $Start
                        EndTime   = $End
                    } -ErrorAction Stop
                }
                catch {}
            }

            foreach ($Log in @("System", "Application")) {
                try {
                    $Events += Get-WinEvent -FilterHashtable @{
                        LogName   = $Log
                        StartTime = $Start
                        EndTime   = $End
                        Level     = 1, 2, 3
                    } -ErrorAction Stop
                }
                catch {}
            }

            try {
                $Events += Get-WinEvent -FilterHashtable @{
                    LogName   = "System"
                    StartTime = $Start
                    EndTime   = $End
                    Id        = @(
                        7000, 7001, 7009, 7011,
                        7022, 7023, 7024,
                        7031, 7034, 7035, 7036
                    )
                } -ErrorAction Stop
            }
            catch {}

            $Events |
                Sort-Object TimeCreated, RecordId -Unique |
                ForEach-Object {
                    [PSCustomObject]@{
                        ComputerName = $env:COMPUTERNAME
                        Window       = $WindowName
                        TimeCreated  = $_.TimeCreated
                        LogName      = $_.LogName
                        Provider     = $_.ProviderName
                        EventID      = $_.Id
                        Level        = $_.LevelDisplayName
                        RecordID     = $_.RecordId
                        Message      = $_.Message
                        EventXML     = $_.ToXml()
                    }
                }
        }
    }
    catch {
        Write-Warning (
            "Collection failed for {0}: {1}" -f
            $Window.Computer, $_.Exception.Message
        )
    }
}

$Results |
    Sort-Object Window, ComputerName, TimeCreated, RecordID |
    Export-Csv "$OutputFolder\01-All-Transition-Events.csv" `
        -NoTypeInformation -Encoding UTF8

$Results |
    Where-Object EventID -ne 1016 |
    Sort-Object Window, ComputerName, TimeCreated, RecordID |
    Export-Csv "$OutputFolder\02-Transitions-Without-1016.csv" `
        -NoTypeInformation -Encoding UTF8

$KeyEventIDs = @(
    258, 261, 262,
    776, 787,
    800, 801, 802, 818, 819,
    866, 1016, 1149,
    1281, 1296, 1301, 1306, 1307,
    2004, 2019, 2020,
    20498, 2304, 2305, 2306,
    1000, 1001, 1002,
    4227, 4231,
    7009, 7011, 7022, 7031, 7034, 7036
)

$Results |
    Where-Object {
        $_.EventID -in $KeyEventIDs -or
        $_.Provider -match
            "Resource-Exhaustion|Application Hang|Windows Error Reporting"
    } |
    Sort-Object Window, ComputerName, TimeCreated |
    Export-Csv "$OutputFolder\03-Key-Transition-Events.csv" `
        -NoTypeInformation -Encoding UTF8

Write-Host "Saved to: $OutputFolder" -ForegroundColor Green
