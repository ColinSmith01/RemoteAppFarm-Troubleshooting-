#requires -RunAsAdministrator

$ServiceName = 'IAS'
$LogFile     = 'C:\ProgramData\NPS-Watchdog.log'

# Observe the service for this long before deciding it is stuck.
$ObservationCount   = 5
$ObservationSeconds = 30

function Write-Log {
    param([string]$Message)

    $Timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -LiteralPath $LogFile -Value "$Timestamp - $Message"
}

function Get-NpsService {
    Get-CimInstance -ClassName Win32_Service `
        -Filter "Name='$ServiceName'" `
        -ErrorAction Stop
}

try {
    Write-Log 'Starting NPS watchdog.'

    $InitialService = Get-NpsService

    Write-Log "Initial state: $($InitialService.State); PID: $($InitialService.ProcessId); CheckPoint: $($InitialService.CheckPoint)."

    if ($InitialService.State -ne 'Start Pending') {
        Write-Log 'NPS is not Start Pending. No action required.'
        exit 0
    }

    $ExpectedPid        = [int]$InitialService.ProcessId
    $InitialCheckPoint  = [uint32]$InitialService.CheckPoint

    # Reject dangerous or invalid PIDs.
    if ($ExpectedPid -le 4) {
        throw "Refusing to terminate invalid or protected PID $ExpectedPid."
    }

    if ($ExpectedPid -eq $PID) {
        throw "Refusing to terminate the watchdog's own PID."
    }

    # Confirm that NPS remains Start Pending, with the same PID and
    # without checkpoint progress.
    for ($Attempt = 1; $Attempt -le $ObservationCount; $Attempt++) {
        Start-Sleep -Seconds $ObservationSeconds

        $CurrentService = Get-NpsService

        Write-Log "Observation $Attempt/$ObservationCount`: State=$($CurrentService.State); PID=$($CurrentService.ProcessId); CheckPoint=$($CurrentService.CheckPoint)."

        if ($CurrentService.State -ne 'Start Pending') {
            Write-Log "NPS is no longer Start Pending. Current state: $($CurrentService.State). No process will be terminated."
            exit 0
        }

        if ([int]$CurrentService.ProcessId -ne $ExpectedPid) {
            throw 'The NPS PID changed during observation. Refusing to terminate it.'
        }

        if ([uint32]$CurrentService.CheckPoint -ne $InitialCheckPoint) {
            Write-Log 'The service checkpoint changed, indicating startup progress. No process will be terminated.'
            exit 0
        }
    }

    # Revalidate the service immediately before terminating anything.
    $CurrentService = Get-NpsService

    if (
        $CurrentService.State -ne 'Start Pending' -or
        [int]$CurrentService.ProcessId -ne $ExpectedPid
    ) {
        throw 'NPS state or PID changed during final validation. No process will be terminated.'
    }

    # Make sure the PID still exists.
    $NpsProcess = Get-CimInstance -ClassName Win32_Process `
        -Filter "ProcessId=$ExpectedPid" `
        -ErrorAction Stop

    if (-not $NpsProcess) {
        throw "PID $ExpectedPid no longer exists."
    }

    # A Windows service should normally run in Session 0.
    if ([int]$NpsProcess.SessionId -ne 0) {
        throw "PID $ExpectedPid is running in Session $($NpsProcess.SessionId), not Session 0. Refusing to terminate it."
    }

    # Fail closed if any other service shares this PID.
    $ServicesInProcess = @(
        Get-CimInstance -ClassName Win32_Service `
            -Filter "ProcessId=$ExpectedPid" `
            -ErrorAction Stop
    )

    $ServiceNames = $ServicesInProcess.Name -join ', '

    Write-Log "Services associated with PID $ExpectedPid`: $ServiceNames."

    if ($ServicesInProcess.Count -ne 1) {
        throw "PID $ExpectedPid hosts multiple services ($ServiceNames). Refusing to terminate it."
    }

    if ($ServicesInProcess[0].Name -ne $ServiceName) {
        throw "PID $ExpectedPid is not exclusively associated with NPS. Refusing to terminate it."
    }

    # One last validation immediately before taskkill.
    $FinalService = Get-NpsService

    if (
        $FinalService.State -ne 'Start Pending' -or
        [int]$FinalService.ProcessId -ne $ExpectedPid
    ) {
        throw 'Final validation failed. No process will be terminated.'
    }

    Write-Log "All safety checks passed. Terminating NPS PID $ExpectedPid."

    # Specify both the PID and the service filter. Do not use /T,
    # because that would also terminate child processes.
    $TaskkillOutput = & "$env:SystemRoot\System32\taskkill.exe" `
        /PID $ExpectedPid `
        /FI "SERVICES eq $ServiceName" `
        /F 2>&1

    $TaskkillExitCode = $LASTEXITCODE
    Write-Log "taskkill output: $($TaskkillOutput -join ' ')"

    if ($TaskkillExitCode -ne 0) {
        throw "taskkill failed with exit code $TaskkillExitCode."
    }

    # Wait for SCM to notice that the process ended.
    $Deadline = (Get-Date).AddMinutes(2)

    do {
        Start-Sleep -Seconds 3
        $CurrentService = Get-NpsService

        Write-Log "State after taskkill: $($CurrentService.State)."

        if ($CurrentService.State -eq 'Running') {
            Write-Log 'NPS recovered automatically and is running.'
            exit 0
        }
    }
    until (
        $CurrentService.State -eq 'Stopped' -or
        (Get-Date) -ge $Deadline
    )

    if ($CurrentService.State -ne 'Stopped') {
        throw "NPS did not reach Stopped state. Current state: $($CurrentService.State)."
    }

    Write-Log 'Starting NPS.'
    Start-Service -Name $ServiceName -ErrorAction Stop

    $ServiceController = Get-Service -Name $ServiceName

    $ServiceController.WaitForStatus(
        [System.ServiceProcess.ServiceControllerStatus]::Running,
        [TimeSpan]::FromMinutes(2)
    )

    Write-Log 'NPS restarted successfully and is running.'
    exit 0
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    exit 1
}
