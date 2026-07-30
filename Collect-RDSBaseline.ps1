<#Purpose
Collects RDS events across a historical period and creates:

Complete RDS timeline
Hourly authentication/redirection summary
First and last timestamps per event type
261/262 listener-pair analysis
Recurring warning/error summay
This was the most useful script for proving that the 261/262 pattern was abnormal and identifying when each broker became unhealthy. #>

#requires -Version 5.1

<#
.SYNOPSIS
    Collects a historical RDS event baseline from Connection Brokers.

.DESCRIPTION
    Produces hourly connection summaries, listener-pair analysis,
    warnings/errors, and a detailed RDS timeline.

    Run from an elevated PowerShell session with access to the remote
    event logs.

.NOTES
    All timestamps are collected as rendered by the remote server.
    EventXML SystemTime values are UTC.
#>

# ======================== CONFIGURATION ========================

$Brokers = @(
    "Broker01",
    "Broker02",
    "Broker03"
)

$IncidentTime = [datetime]"2026-01-01 15:00:00"
$StartTime    = $IncidentTime.AddHours(-48)
$EndTime      = $IncidentTime.AddHours(2)

$OutputFolder = "C:\Temp\RDS-Baseline-$($IncidentTime.ToString('yyyyMMdd'))"

# ===============================================================

New-Item -Path $OutputFolder -ItemType Directory -Force |
    Out-Null

$RDSLogs = @(
    "Microsoft-Windows-TerminalServices-SessionBroker/Admin",
    "Microsoft-Windows-TerminalServices-SessionBroker/Operational",
    "Microsoft-Windows-TerminalServices-SessionBroker-Client/Operational",
    "Microsoft-Windows-TerminalServices-RemoteConnectionManager/Admin",
    "Microsoft-Windows-TerminalServices-RemoteConnectionManager/Operational",
    "Microsoft-Windows-TerminalServices-LocalSessionManager/Operational",
    "Microsoft-Windows-RemoteDesktopServices-RdpCoreTS/Operational"
)

$AllEvents = @()
$CollectionErrors = @()

foreach ($Broker in $Brokers) {
    Write-Host "Collecting from $Broker..." -ForegroundColor Cyan

    try {
        $Results = Invoke-Command -ComputerName $Broker `
            -ArgumentList $StartTime, $EndTime, $RDSLogs `
            -ErrorAction Stop -ScriptBlock {

            param($StartTime, $EndTime, $RDSLogs)

            $Events = @()

            foreach ($Log in $RDSLogs) {
                try {
                    $Events += Get-WinEvent -FilterHashtable @{
                        LogName   = $Log
                        StartTime = $StartTime
                        EndTime   = $EndTime
                    } -ErrorAction Stop
                }
                catch {}
            }

            foreach ($Log in @("System", "Application")) {
                try {
                    $Events += Get-WinEvent -FilterHashtable @{
                        LogName   = $Log
                        StartTime = $StartTime
                        EndTime   = $EndTime
                        Level     = 1, 2, 3
                    } -ErrorAction Stop
                }
                catch {}
            }

            # Include important informational service/restart events.
            try {
                $Events += Get-WinEvent -FilterHashtable @{
                    LogName   = "System"
                    StartTime = $StartTime
                    EndTime   = $EndTime
                    Id        = @(
                        41, 1074, 1076,
                        6005, 6006, 6008,
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

        $AllEvents += $Results

        Write-Host "Collected $($Results.Count) events." `
            -ForegroundColor Green
    }
    catch {
        $CollectionErrors += [PSCustomObject]@{
            ComputerName = $Broker
            Time         = Get-Date
            Error        = $_.Exception.Message
        }

        Write-Warning (
            "Unable to collect from {0}: {1}" -f
            $Broker, $_.Exception.Message
        )
    }
}

$AllEvents |
    Sort-Object ComputerName, TimeCreated, RecordID |
    Export-Csv "$OutputFolder\01-All-Events.csv" `
        -NoTypeInformation -Encoding UTF8

$CollectionErrors |
    Export-Csv "$OutputFolder\Collection-Errors.csv" `
        -NoTypeInformation -Encoding UTF8

# Classify events and assign hourly buckets.
$ClassifiedEvents = $AllEvents | ForEach-Object {
    $Period =
        if ($_.TimeCreated -lt $IncidentTime) {
            "Pre-Incident"
        }
        elseif ($_.TimeCreated -lt $IncidentTime.AddHours(1)) {
            "Incident"
        }
        else {
            "Post-Recovery"
        }

    $Hour = Get-Date $_.TimeCreated `
        -Minute 0 -Second 0 -Millisecond 0

    [PSCustomObject]@{
        ComputerName = $_.ComputerName
        TimeCreated  = $_.TimeCreated
        Hour         = $Hour
        Period       = $Period
        LogName      = $_.LogName
        Provider     = $_.Provider
        EventID      = [int]$_.EventID
        Level        = $_.Level
        RecordID     = $_.RecordID
        Message      = $_.Message
        EventXML     = $_.EventXML
    }
}

$ImportantEventIDs = @(
    21, 22, 24, 25, 36, 41, 42, 54,
    258, 261, 262,
    776, 787, 800, 801, 802, 818, 819,
    832, 866, 1016, 1149,
    1281, 1296, 1301, 1306, 1307,
    1792, 2080, 2304, 2305, 2306, 20498
)

$RDSTimeline = $ClassifiedEvents |
    Where-Object {
        $_.EventID -in $ImportantEventIDs -and
        (
            $_.LogName -like "*TerminalServices*" -or
            $_.LogName -like "*RemoteDesktopServices*"
        )
    } |
    Sort-Object ComputerName, TimeCreated

$RDSTimeline |
    Export-Csv "$OutputFolder\02-RDS-Timeline.csv" `
        -NoTypeInformation -Encoding UTF8

function Get-EventStatistics {
    param(
        [object[]]$Events,
        [int]$EventID
    )

    $Matches = @(
        $Events |
            Where-Object EventID -eq $EventID |
            Sort-Object TimeCreated
    )

    if ($Matches.Count -gt 0) {
        return [PSCustomObject]@{
            Count     = $Matches.Count
            FirstTime = $Matches[0].TimeCreated
            LastTime  = $Matches[-1].TimeCreated
        }
    }

    return [PSCustomObject]@{
        Count     = 0
        FirstTime = $null
        LastTime  = $null
    }
}

# Hourly connection/redirection summary.
$HourlySummary = foreach ($Broker in $Brokers) {
    $BrokerEvents = @(
        $ClassifiedEvents |
            Where-Object ComputerName -eq $Broker
    )

    $Hours = $BrokerEvents.Hour | Sort-Object -Unique

    foreach ($Hour in $Hours) {
        $HourEvents = @(
            $BrokerEvents |
                Where-Object Hour -eq $Hour
        )

        $E261  = Get-EventStatistics $HourEvents 261
        $E262  = Get-EventStatistics $HourEvents 262
        $E1149 = Get-EventStatistics $HourEvents 1149
        $E800  = Get-EventStatistics $HourEvents 800
        $E801  = Get-EventStatistics $HourEvents 801
        $E818  = Get-EventStatistics $HourEvents 818
        $E819  = Get-EventStatistics $HourEvents 819
        $E1016 = Get-EventStatistics $HourEvents 1016
        $E1301 = Get-EventStatistics $HourEvents 1301
        $E1306 = Get-EventStatistics $HourEvents 1306
        $E1307 = Get-EventStatistics $HourEvents 1307

        [PSCustomObject]@{
            ComputerName = $Broker
            Hour         = $Hour
            Period       = ($HourEvents | Select-Object -First 1).Period

            Event261_Connections = $E261.Count
            Event261_FirstTime   = $E261.FirstTime
            Event261_LastTime    = $E261.LastTime

            Event262_StopListening = $E262.Count
            Event262_FirstTime      = $E262.FirstTime
            Event262_LastTime       = $E262.LastTime

            Event1149_AuthSuccess = $E1149.Count
            Event1149_FirstTime   = $E1149.FirstTime
            Event1149_LastTime    = $E1149.LastTime

            Event800_BrokerRequests = $E800.Count
            Event800_FirstTime      = $E800.FirstTime
            Event800_LastTime       = $E800.LastTime

            Event801_BrokerProcessed = $E801.Count
            Event801_FirstTime       = $E801.FirstTime
            Event801_LastTime        = $E801.LastTime

            Event1301_RedirectRequests = $E1301.Count
            Event1301_FirstTime        = $E1301.FirstTime
            Event1301_LastTime         = $E1301.LastTime

            Event1306_RedirectFailed = $E1306.Count
            Event1306_FirstTime      = $E1306.FirstTime
            Event1306_LastTime       = $E1306.LastTime

            Event1307_RedirectSuccess = $E1307.Count
            Event1307_FirstTime       = $E1307.FirstTime
            Event1307_LastTime        = $E1307.LastTime

            Event818_EndpointLogon = $E818.Count
            Event818_FirstTime     = $E818.FirstTime
            Event818_LastTime      = $E818.LastTime

            Event819_EndpointTimeout = $E819.Count
            Event819_FirstTime       = $E819.FirstTime
            Event819_LastTime        = $E819.LastTime

            Event1016_UnauthorizedRPC = $E1016.Count
            Event1016_FirstTime       = $E1016.FirstTime
            Event1016_LastTime        = $E1016.LastTime

            AuthenticationPercent =
                if ($E261.Count -gt 0) {
                    [math]::Round(
                        ($E1149.Count / $E261.Count) * 100, 2
                    )
                }
                else {
                    $null
                }

            RedirectionSuccessPercent =
                if ($E1301.Count -gt 0) {
                    [math]::Round(
                        ($E1307.Count / $E1301.Count) * 100, 2
                    )
                }
                else {
                    $null
                }
        }
    }
}

$HourlySummary |
    Sort-Object Hour, ComputerName |
    Export-Csv "$OutputFolder\03-Hourly-Connection-Summary.csv" `
        -NoTypeInformation -Encoding UTF8

# Warnings and errors.
$WarningsAndErrors = $ClassifiedEvents |
    Where-Object {
        $_.Level -in @("Critical", "Error", "Warning")
    }

$WarningsAndErrors |
    Sort-Object ComputerName, TimeCreated |
    Export-Csv "$OutputFolder\04-All-Warnings-And-Errors.csv" `
        -NoTypeInformation -Encoding UTF8

$WarningsAndErrors |
    Group-Object ComputerName, Provider, EventID, Level |
    ForEach-Object {
        $Ordered = $_.Group | Sort-Object TimeCreated
        $First = $Ordered | Select-Object -First 1
        $Last  = $Ordered | Select-Object -Last 1

        [PSCustomObject]@{
            ComputerName   = $First.ComputerName
            Provider       = $First.Provider
            EventID        = $First.EventID
            Level          = $First.Level
            Count          = $_.Count
            FirstSeen      = $First.TimeCreated
            LastSeen       = $Last.TimeCreated
            ExampleMessage = $First.Message
        }
    } |
    Sort-Object ComputerName,
        @{ Expression = "Count"; Descending = $true } |
    Export-Csv "$OutputFolder\05-Recurring-Warning-Error-Summary.csv" `
        -NoTypeInformation -Encoding UTF8

# Listener 261/262 pair analysis.
$PairDetails = foreach ($Broker in $Brokers) {
    $Events = @(
        $ClassifiedEvents |
            Where-Object {
                $_.ComputerName -eq $Broker -and
                $_.EventID -in 261, 262
            } |
            Sort-Object TimeCreated, RecordID
    )

    for ($Index = 0; $Index -lt $Events.Count; $Index++) {
        if ($Events[$Index].EventID -ne 261) {
            continue
        }

        $Current = $Events[$Index]
        $Next =
            if (($Index + 1) -lt $Events.Count) {
                $Events[$Index + 1]
            }
            else {
                $null
            }

        $IsPair = (
            $null -ne $Next -and
            $Next.EventID -eq 262
        )

        [PSCustomObject]@{
            ComputerName = $Broker
            TimeCreated  = $Current.TimeCreated
            Hour         = $Current.Hour
            Period       = $Current.Period
            FollowedBy262 = $IsPair
            MillisecondsTo262 =
                if ($IsPair) {
                    [math]::Round(
                        ($Next.TimeCreated -
                         $Current.TimeCreated).TotalMilliseconds,
                        4
                    )
                }
                else {
                    $null
                }
        }
    }
}

$PairDetails |
    Export-Csv "$OutputFolder\06-Listener-261-262-Pairs.csv" `
        -NoTypeInformation -Encoding UTF8

$PairDetails |
    Group-Object ComputerName, Hour |
    ForEach-Object {
        $First = $_.Group | Select-Object -First 1
        $Pairs = @($_.Group | Where-Object FollowedBy262)

        [PSCustomObject]@{
            ComputerName      = $First.ComputerName
            Hour              = $First.Hour
            Period            = $First.Period
            Event261Count     = $_.Count
            Immediate262Pairs = $Pairs.Count
            AverageMillisecondsTo262 =
                if ($Pairs.Count -gt 0) {
                    [math]::Round(
                        ($Pairs |
                            Measure-Object MillisecondsTo262 -Average
                        ).Average,
                        4
                    )
                }
                else {
                    $null
                }
        }
    } |
    Sort-Object Hour, ComputerName |
    Export-Csv "$OutputFolder\07-Hourly-261-262-Summary.csv" `
        -NoTypeInformation -Encoding UTF8

Write-Host "Results saved to: $OutputFolder" -ForegroundColor Green
