#requires -Version 5.1

$CsvPath = "C:\Temp\RDS-Task-History\All-TaskScheduler-History.csv"

# Add task instance GUIDs here, without braces if preferred.
$InstanceIDs = @(
    "00000000-0000-0000-0000-000000000001",
    "00000000-0000-0000-0000-000000000002"
)

$Output = "C:\Temp\RDS-Task-History\Task-Instance-History.csv"

$Csv = Import-Csv $CsvPath

$Regex = (
    $InstanceIDs |
        ForEach-Object { [regex]::Escape($_) }
) -join "|"

$Results = $Csv |
    Where-Object {
        $_.Message -match $Regex -or
        $_.EventXML -match $Regex
    } |
    Sort-Object ComputerName, {
        [datetime]$_.TimeCreated
    }

$Results |
    Export-Csv $Output -NoTypeInformation -Encoding UTF8

$Results |
    Select-Object ComputerName, TimeCreated, EventID, Message |
    Format-Table -Wrap

Write-Host "Saved to: $Output" -ForegroundColor Green
