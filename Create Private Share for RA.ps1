<#
.SYNOPSIS
    Creates a hidden SMB share for an existing local folder.

.DESCRIPTION
    This script is designed to be run locally on each server.

    It:
      - Confirms that the local folder exists.
      - Grants an AD group Modify NTFS permission.
      - Creates a hidden SMB share.
      - Grants the AD group Change share permission.
      - Grants local Administrators Full share permission.
      - Removes Everyone from the share permissions.

    A share name ending with "$" is hidden from normal network browsing.

.NOTES
    Run from an elevated Windows PowerShell session.

    This script does not copy, synchronize, or replicate any files.
    Each server shares its own local folder.
#>

[CmdletBinding()]
param (
    # Existing local folder to share
    [Parameter()]
    [string]$Folder = 'C:\Path\To\Application\Data',

    # Include the trailing $ to make the share hidden
    [Parameter()]
    [string]$ShareName = 'application-data$',

    # AD group that should be allowed to use the share
    [Parameter()]
    [string]$UserGroup = 'EXAMPLE\App-RemoteApp-Users'
)

$ErrorActionPreference = 'Stop'

Write-Host "Configuring $env:COMPUTERNAME..." -ForegroundColor Cyan
Write-Host "Folder: $Folder"
Write-Host "Share:  $ShareName"
Write-Host "Group:  $UserGroup"

#region Administrative check

$CurrentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$Principal = [Security.Principal.WindowsPrincipal]::new($CurrentIdentity)

$IsAdministrator = $Principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

if (-not $IsAdministrator) {
    throw 'Run this script from PowerShell using Run as administrator.'
}

#endregion

#region Validation

if (-not (Test-Path -LiteralPath $Folder -PathType Container)) {
    throw "The local folder does not exist: $Folder"
}

if (-not $ShareName.EndsWith('$')) {
    Write-Warning "The share name does not end with '$'. It will not be a hidden share."
}

# Confirm that Windows can resolve the specified account/group.
try {
    $Account = [Security.Principal.NTAccount]::new($UserGroup)
    $null = $Account.Translate([Security.Principal.SecurityIdentifier])
}
catch {
    throw "Windows could not resolve the account '$UserGroup'. Verify the domain and group name."
}

#endregion

#region NTFS permissions

Write-Host 'Configuring NTFS permissions...' -ForegroundColor Cyan

# (OI) = Object inherit, applying to files
# (CI) = Container inherit, applying to subfolders
# M    = Modify
#
# /grant:r replaces the explicit grant for this principal but does not
# remove permissions belonging to other principals.
& icacls.exe $Folder /grant:r "${UserGroup}:(OI)(CI)M"

if ($LASTEXITCODE -ne 0) {
    throw "Failed to configure NTFS permissions on: $Folder"
}

#endregion

#region SMB share

$ExistingShare = Get-SmbShare `
    -Name $ShareName `
    -ErrorAction SilentlyContinue

if (-not $ExistingShare) {
    Write-Host 'Creating hidden SMB share...' -ForegroundColor Cyan

    New-SmbShare `
        -Name $ShareName `
        -Path $Folder `
        -Description 'Hidden application data share' `
        -ChangeAccess $UserGroup `
        -FullAccess 'BUILTIN\Administrators' |
        Out-Null

    Write-Host 'The share was created successfully.' -ForegroundColor Green
}
elseif ($ExistingShare.Path -ne $Folder) {
    throw @"
A share named '$ShareName' already exists, but it points to a different folder.

Existing path: $($ExistingShare.Path)
Requested path: $Folder

No changes were made to the existing share.
"@
}
else {
    Write-Host 'The share already exists and points to the correct folder.' `
        -ForegroundColor Yellow
}

#endregion

#region Share permissions

Write-Host 'Configuring share permissions...' -ForegroundColor Cyan

Grant-SmbShareAccess `
    -Name $ShareName `
    -AccountName $UserGroup `
    -AccessRight Change `
    -Force |
    Out-Null

Grant-SmbShareAccess `
    -Name $ShareName `
    -AccountName 'BUILTIN\Administrators' `
    -AccessRight Full `
    -Force |
    Out-Null

# Remove broad Everyone access if it exists.
$EveryoneEntries = Get-SmbShareAccess -Name $ShareName |
    Where-Object {
        $_.AccountName -in @(
            'Everyone',
            'BUILTIN\Everyone'
        )
    }

foreach ($Entry in $EveryoneEntries) {
    Revoke-SmbShareAccess `
        -Name $ShareName `
        -AccountName $Entry.AccountName `
        -Force
}

#endregion

#region Results

$UncPath = "\\$env:COMPUTERNAME\$ShareName"

Write-Host ''
Write-Host 'Configuration completed successfully.' -ForegroundColor Green
Write-Host "UNC path: $UncPath" -ForegroundColor Green

Write-Host ''
Write-Host 'Share details:' -ForegroundColor Cyan

Get-SmbShare -Name $ShareName |
    Format-List Name, Path, Description

Write-Host 'Share permissions:' -ForegroundColor Cyan

Get-SmbShareAccess -Name $ShareName |
    Format-Table AccountName, AccessControlType, AccessRight -AutoSize

#endregion




<# CLEANUP if needed run seperate

.\Remove-HiddenShare.ps1 `
    -Folder 'C:\Path\To\Application\Data' `
    -ShareName 'application-data$' `
    -UserGroup 'EXAMPLE\App-RemoteApp-Users'

    #>
