<##requires -Version 5.1
Performs read-only live monitoring of:

Ping
TCP 3389
RDS service states
Relevant scheduled-task states
Recent 261/262/1149 events
TCP 3389 alone is not a sufficient health check. The known failure accepted TCP connections but rejected the RDP session immediately.

#>



$Servers = @(
    "Broker01",
    "Broker02",
    "Broker03"
)

$PollingSeconds = 30
$Output = "C:\Temp\RDS-LiveMonitor-$(Get-Date -Format yyyyMMdd-HHmmss).csv"

$Results = @()

Write-Host "Monitoring RDS brokers. Press Ctrl+C to stop." `
    -ForegroundColor Cyan

while ($true) {
    foreach ($Server in $Servers) {
        $Now = Get-Date

        $Ping = Test-Connection -ComputerName $Server `
            -Count 1 -Quiet

        $RDP = (
            Test-NetConnection -ComputerName $Server `
                -Port 3389 -WarningAction SilentlyContinue
        ).TcpTestSucceeded

        try {
            $State = Invoke-Command -ComputerName $Server `
                -ErrorAction Stop -ScriptBlock {

                $Services = Get-Service `
                    TermService,
                    UmRdpService,
                    SessionEnv,
                    Tssdis,
                    RDMS `
                    -ErrorAction SilentlyContinue

                function Get-ServiceState {
                    param($Name)

                    (
                        $Services |
                        Where-Object Name -eq $Name |
                        Select-Object -ExpandProperty Status
                    )
                }

                function Get-TaskState {
                    param($Name)

                    (
                        Get-ScheduledTask |
                        Where-Object TaskName -eq $Name |
                        Select-Object -First 1 `
                            -ExpandProperty State
                    )
                }

                $Start = (Get-Date).AddMinutes(-5)

                $RecentEvents = Get-WinEvent -FilterHashtable @{
                    LogName   = "Microsoft-Windows-TerminalServices-RemoteConnectionManager/Operational"
                    StartTime = $Start
                    Id        = 261, 262, 1149
                } -ErrorAction SilentlyContinue

                [PSCustomObject]@{
                    TermService  = Get-ServiceState "TermService"
                    UmRdpService = Get-ServiceState "UmRdpService"
                    SessionEnv   = Get-ServiceState "SessionEnv"
                    Tssdis       = Get-ServiceState "Tssdis"
                    RDMS         = Get-ServiceState "RDMS"

                    HealthTask = Get-TaskState "ConnectedUserHealthCheck"
                    V666       = Get-TaskState "RDDrainingCheckerV666"
                    V777       = Get-TaskState "RDDrainingCheckerV777"

                    Event261Last5Min = @(
                        $RecentEvents |
                            Where-Object Id -eq 261
                    ).Count

                    Event262Last5Min = @(
                        $RecentEvents |
                            Where-Object Id -eq 262
                    ).Count

                    Event1149Last5Min = @(
                        $RecentEvents |
                            Where-Object Id -eq 1149
                    ).Count
                }
            }

            $Record = [PSCustomObject]@{
                Time          = $Now
                ComputerName  = $Server
                Ping          = $Ping
                RDP3389       = $RDP
                TermService   = $State.TermService
                UmRdpService  = $State.UmRdpService
                SessionEnv    = $State.SessionEnv
                Tssdis        = $State.Tssdis
                RDMS          = $State.RDMS
                HealthTask    = $State.HealthTask
                V666          = $State.V666
                V777          = $State.V777
                Event261      = $State.Event261Last5Min
                Event262      = $State.Event262Last5Min
                Event1149     = $State.Event1149Last5Min
            }
        }
        catch {
            $Record = [PSCustomObject]@{
                Time          = $Now
                ComputerName  = $Server
                Ping          = $Ping
                RDP3389       = $RDP
                TermService   = "Unavailable"
                UmRdpService  = "Unavailable"
                SessionEnv    = "Unavailable"
                Tssdis        = "Unavailable"
                RDMS          = "Unavailable"
                HealthTask    = $null
                V666          = $null
                V777          = $null
                Event261      = $null
                Event262      = $null
                Event1149     = $null
            }
        }

        $Record |
            Export-Csv $Output -NoTypeInformation `
                -Encoding UTF8 -Append

        $Record | Format-Table -AutoSize
    }

    Start-Sleep -Seconds $PollingSeconds
}
