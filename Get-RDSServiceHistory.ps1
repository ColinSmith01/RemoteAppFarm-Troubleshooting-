<#
Purpose
Collects historical start/stop/failure events for:

TermService
UmRdpService
SessionEnv
Tssdis
RDMS
This was critical for proving that the health-check task stopped dependent RDS services and that the restart sequence failed to complete.


#>


#requires -Version 5.1

$Servers = @(
    "Broker01",
    "Broker02",
    "Broker03"
)

$StartTime = [datetime]"2026-01-01 00:00:00"
$EndTime   = [datetime]"2026-01-01 23:59:59"

$Output = "C:\Temp\RDS-Service-State-History.csv"

$Results = foreach ($Server in $Servers) {
    Write-Host "Collecting service history from $Server..." `
        -ForegroundColor Cyan

    try {
        Invoke-Command -ComputerName $Server `
            -ArgumentList $StartTime, $EndTime `
            -ErrorAction Stop -ScriptBlock {

            param($StartTime, $EndTime)

            Get-WinEvent -FilterHashtable @{
                LogName   = "System"
                StartTime = $StartTime
                EndTime   = $EndTime
                Id        = @(
                    7000, 7001, 7009, 7011,
                    7022, 7023, 7024,
                    7031, 7034, 7035, 7036,
                    7040, 7045
                )
            } -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.Message -match
                        "Remote Desktop|TermService|UmRdpService|" +
                        "SessionEnv|Tssdis|RDMS|Connection Broker"
                } |
                ForEach-Object {
                    [PSCustomObject]@{
                        ComputerName = $env:COMPUTERNAME
                        TimeCreated  = $_.TimeCreated
                        EventID      = $_.Id
                        Provider     = $_.ProviderName
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
            "Failed to collect from {0}: {1}" -f
            $Server, $_.Exception.Message
        )
    }
}

$Results |
    Sort-Object ComputerName, TimeCreated |
    Export-Csv $Output -NoTypeInformation -Encoding UTF8

Write-Host "Saved to: $Output" -ForegroundColor Green
