#requires -Version 5.1
<#

Event ID	Meaning
100	Task started
101	Task failed
102	Task finished
107	Time/event trigger fired
129	Task process created
140	Task updated
200	Action started
201	Action completed
202/203	Action failure
322	New run ignored because an instance is already running

#>

$Servers = @(
    "Broker01",
    "Broker02",
    "Broker03"
)

$StartTime = [datetime]"2026-01-01 00:00:00"
$EndTime   = [datetime]"2026-01-01 23:59:59"

$OutputFolder = "C:\Temp\RDS-Task-History"
New-Item -Path $OutputFolder -ItemType Directory -Force |
    Out-Null

$AllEvents = foreach ($Server in $Servers) {
    Write-Host "Collecting Task Scheduler history from $Server..." `
        -ForegroundColor Cyan

    try {
        Invoke-Command -ComputerName $Server `
            -ArgumentList $StartTime, $EndTime `
            -ErrorAction Stop -ScriptBlock {

            param($StartTime, $EndTime)

            Get-WinEvent -FilterHashtable @{
                LogName   = "Microsoft-Windows-TaskScheduler/Operational"
                StartTime = $StartTime
                EndTime   = $EndTime
            } -ErrorAction Stop |
                ForEach-Object {
                    [PSCustomObject]@{
                        ComputerName = $env:COMPUTERNAME
                        TimeCreated  = $_.TimeCreated
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
            "Unable to read Task Scheduler history on {0}: {1}" -f
            $Server, $_.Exception.Message
        )
    }
}

$AllEvents |
    Sort-Object ComputerName, TimeCreated, RecordID |
    Export-Csv "$OutputFolder\All-TaskScheduler-History.csv" `
        -NoTypeInformation -Encoding UTF8

$RelevantTerms = (
    "ConnectedUser|RDDraining|RDS|RemoteApps|" +
    "TermService|UmRdpService|RDP-Tcp|" +
    "PowerShell|WMIC"
)

$AllEvents |
    Where-Object {
        $_.Message -match $RelevantTerms -or
        $_.EventXML -match $RelevantTerms
    } |
    Sort-Object ComputerName, TimeCreated |
    Export-Csv "$OutputFolder\Relevant-TaskScheduler-History.csv" `
        -NoTypeInformation -Encoding UTF8

Write-Host "Saved to: $OutputFolder" -ForegroundColor Green
