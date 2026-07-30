#requires -Version 5.1
<#
Purpose
Performs static analysis of copied PowerShell scripts. It does not execute them.

Searches for:

RDS service restarts
Drain-mode changes
WMI listener modifications
Unbounded loops
Asynchronous process/job execution
Reboots and shutdowns
#>
param(
    [Parameter(Mandatory)]
    [string]$ReviewFolder
)

if (-not (Test-Path -LiteralPath $ReviewFolder)) {
    throw "Review folder does not exist: $ReviewFolder"
}

$Patterns = @(
    "TermService",
    "UmRdpService",
    "SessionEnv",
    "Restart-Service",
    "Stop-Service",
    "Start-Service",
    "Get-Service",
    "sc.exe",
    "net stop",
    "net start",
    "change logon",
    "drain",
    "RDP-Tcp",
    "Win32_TSPermissionsSetting",
    "Win32_TSGeneralSetting",
    "Win32_TerminalServiceSetting",
    "SetAllowTSConnections",
    "fDenyTSConnections",
    "fLogonDisabled",
    "Set-ItemProperty",
    "Start-Process",
    "Invoke-Command",
    "Start-Job",
    "Wait-Job",
    "Wait-Process",
    "Stop-Process",
    "taskkill",
    "Restart-Computer",
    "shutdown",
    "while",
    "do {"
)

$Scripts = Get-ChildItem -LiteralPath $ReviewFolder `
    -Filter "*.ps1" -File -Recurse

foreach ($Script in $Scripts) {
    $Line = 0

    $NumberedFile = Join-Path `
        $ReviewFolder `
        "$($Script.BaseName)-Numbered.txt"

    Get-Content -LiteralPath $Script.FullName |
        ForEach-Object {
            $Line++
            "{0,4}: {1}" -f $Line, $_
        } |
        Out-File $NumberedFile `
            -Encoding UTF8 -Width 500
}

$Scripts |
    Select-String -Pattern $Patterns `
        -SimpleMatch -Context 8,8 |
    Out-File "$ReviewFolder\Script-Matches.txt" `
        -Encoding UTF8 -Width 500

$Scripts |
    ForEach-Object {
        [PSCustomObject]@{
            Name          = $_.Name
            FullName      = $_.FullName
            Length        = $_.Length
            CreationTime  = $_.CreationTime
            LastWriteTime = $_.LastWriteTime
            SHA256        = (
                Get-FileHash $_.FullName -Algorithm SHA256
            ).Hash
        }
    } |
    Export-Csv "$ReviewFolder\Script-Inventory.csv" `
        -NoTypeInformation -Encoding UTF8

Write-Host "Static review files saved to: $ReviewFolder" `
    -ForegroundColor Green
