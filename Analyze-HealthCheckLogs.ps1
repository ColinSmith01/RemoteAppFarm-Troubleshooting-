#requires -Version 5.1

param(
    [Parameter(Mandatory)]
    [string]$LogFolder
)

if (-not (Test-Path -LiteralPath $LogFolder)) {
    throw "Log folder does not exist: $LogFolder"
}

$OutputFolder = Join-Path $LogFolder "Analysis"
New-Item -Path $OutputFolder -ItemType Directory -Force |
    Out-Null

$RestartHistory = @()

foreach ($File in Get-ChildItem $LogFolder `
    -Filter "*-RestartLog.txt" -File) {

    $ComputerName = $File.Name -replace "-RestartLog.txt", ""
    $Lines = @(Get-Content -LiteralPath $File.FullName)

    for ($Index = 0; $Index -lt $Lines.Count; $Index++) {
        $Line = $Lines[$Index]

        if ($Line -match
            '^Service restarted at (?<Date>.+?) \(Within.*zero connected users was (?<ZeroCount>\d+)') {

            $NextLine =
                if (($Index + 1) -lt $Lines.Count) {
                    $Lines[$Index + 1]
                }
                else {
                    $null
                }

            $RestartHistory += [PSCustomObject]@{
                ComputerName = $ComputerName
                LineNumber   = $Index + 1
                RestartTimeText = $Matches.Date
                ZeroCount       = [int]$Matches.ZeroCount
                FollowedByRunningStatus = (
                    $NextLine -match
                    "TermService status is now Running"
                )
                NextLine = $NextLine
                SourceFile = $File.FullName
            }
        }
    }
}

$RestartHistory |
    Export-Csv "$OutputFolder\TermService-Restart-History.csv" `
        -NoTypeInformation -Encoding UTF8

$RestartHistory |
    Where-Object {
        -not $_.FollowedByRunningStatus
    } |
    Export-Csv "$OutputFolder\Incomplete-Restart-Attempts.csv" `
        -NoTypeInformation -Encoding UTF8

$RestartHistory |
    Group-Object ComputerName |
    ForEach-Object {
        [PSCustomObject]@{
            ComputerName = $_.Name
            TotalRestartAttempts = $_.Count
            IncompleteAttempts = @(
                $_.Group |
                    Where-Object {
                        -not $_.FollowedByRunningStatus
                    }
            ).Count
        }
    } |
    Export-Csv "$OutputFolder\Restart-Summary.csv" `
        -NoTypeInformation -Encoding UTF8

# Preserve hashes of the analyzed files.
Get-ChildItem $LogFolder -File |
    ForEach-Object {
        [PSCustomObject]@{
            Name          = $_.Name
            Length        = $_.Length
            LastWriteTime = $_.LastWriteTime
            SHA256        = (
                Get-FileHash $_.FullName -Algorithm SHA256
            ).Hash
        }
    } |
    Export-Csv "$OutputFolder\Source-File-Hashes.csv" `
        -NoTypeInformation -Encoding UTF8

Write-Host "Analysis saved to: $OutputFolder" `
    -ForegroundColor Green
