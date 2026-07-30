#requires -Version 5.1

$Servers = @(
    "Broker01",
    "Broker02",
    "Broker03"
)

$TaskNames = @(
    "ConnectedUserHealthCheck",
    "RDDrainingCheckerV666",
    "RDDrainingCheckerV777"
)

$ScriptPaths = @(
    "C:\Scripts\ConnectedUserHealth.ps1",
    "C:\Scripts\SH2BRConnectionChecker.ps1"
)

$LogPaths = @(
    "C:\Temp\RestartLog.txt",
    "C:\Temp\ConnectedUsersHealthCheck.txt",
    "C:\Temp\ConnectedUsersTimeStamp.txt"
)

$OutputRoot = "C:\Temp\RDS-Evidence-$(Get-Date -Format yyyyMMdd-HHmmss)"
New-Item -Path $OutputRoot -ItemType Directory -Force |
    Out-Null

foreach ($Server in $Servers) {
    Write-Host "Preserving evidence from $Server..." `
        -ForegroundColor Cyan

    $ServerFolder = Join-Path $OutputRoot $Server
    New-Item -Path $ServerFolder -ItemType Directory -Force |
        Out-Null

    # Export task XML.
    foreach ($TaskName in $TaskNames) {
        try {
            $Task = Get-ScheduledTask -CimSession $Server |
                Where-Object TaskName -eq $TaskName |
                Select-Object -First 1

            if ($null -ne $Task) {
                $SafeName = $TaskName -replace '[\\/:*?"<>|]', "_"

                Export-ScheduledTask `
                    -CimSession $Server `
                    -TaskName $Task.TaskName `
                    -TaskPath $Task.TaskPath |
                    Out-File "$ServerFolder\$SafeName.xml" `
                        -Encoding UTF8
            }
        }
        catch {
            Write-Warning (
                "Unable to export {0} from {1}: {2}" -f
                $TaskName, $Server, $_.Exception.Message
            )
        }
    }

    # Copy scripts and logs through PowerShell remoting.
    $Session = $null

    try {
        $Session = New-PSSession -ComputerName $Server `
            -ErrorAction Stop

        foreach ($RemotePath in ($ScriptPaths + $LogPaths)) {
            $Exists = Invoke-Command -Session $Session `
                -ArgumentList $RemotePath -ScriptBlock {
                param($RemotePath)
                Test-Path -LiteralPath $RemotePath
            }

            if (-not $Exists) {
                continue
            }

            $FileName = Split-Path $RemotePath -Leaf
            $SafePath = $RemotePath -replace '[:\\]', "_"
            $Destination = Join-Path `
                $ServerFolder `
                "$SafePath-$FileName"

            Copy-Item -FromSession $Session `
                -Path $RemotePath `
                -Destination $Destination `
                -Force
        }

        $Metadata = Invoke-Command -Session $Session `
            -ArgumentList (,$ScriptPaths) -ScriptBlock {

            param($ScriptPaths)

            foreach ($Path in $ScriptPaths) {
                if (Test-Path -LiteralPath $Path) {
                    $Item = Get-Item -LiteralPath $Path

                    [PSCustomObject]@{
                        ComputerName  = $env:COMPUTERNAME
                        Path          = $Path
                        Length        = $Item.Length
                        CreationTime  = $Item.CreationTime
                        LastWriteTime = $Item.LastWriteTime
                        SHA256        = (
                            Get-FileHash -LiteralPath $Path `
                                -Algorithm SHA256
                        ).Hash
                    }
                }
            }
        }

        $Metadata |
            Export-Csv "$ServerFolder\Script-Metadata.csv" `
                -NoTypeInformation -Encoding UTF8
    }
    catch {
        Write-Warning (
            "Unable to copy evidence from {0}: {1}" -f
            $Server, $_.Exception.Message
        )
    }
    finally {
        if ($null -ne $Session) {
            Remove-PSSession $Session `
                -ErrorAction SilentlyContinue
        }
    }
}

# Hash every preserved file.
Get-ChildItem $OutputRoot -File -Recurse |
    ForEach-Object {
        [PSCustomObject]@{
            RelativePath = $_.FullName.Substring($OutputRoot.Length)
            Length       = $_.Length
            LastWriteTime = $_.LastWriteTime
            SHA256       = (
                Get-FileHash $_.FullName -Algorithm SHA256
            ).Hash
        }
    } |
    Export-Csv "$OutputRoot\Evidence-File-Hashes.csv" `
        -NoTypeInformation -Encoding UTF8

Write-Host "Evidence saved to: $OutputRoot" `
    -ForegroundColor Green
