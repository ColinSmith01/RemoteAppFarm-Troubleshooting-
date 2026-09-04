<#
.SYNOPSIS
    Removes a hidden SMB share from the local server.

.DESCRIPTION
    This script is designed to be run locally on each server.

    By default, it:
      - Validates the existing share.
      - Removes the SMB share.
      - Does not delete the local folder.
      - Does not delete any files.
      - Does not remove NTFS permissions.

    Use -RemoveNtfsPermission to additionally remove the specified
    group's explicit NTFS grant.

.WARNING
    Removing the share disconnects users who currently have files open
    through that share.

    Only use -RemoveNtfsPermission if the group permission is no longer
    needed for any other purpose.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param (
    # Expected local folder
    [Parameter()]
    [string]$Folder = 'C:\Path\To\Application\Data',

    # Existing hidden share name
    [Parameter()]
    [string]$ShareName = 'application-data$',

    # AD group used by the installation script
    [Parameter()]
    [string]$UserGroup = 'EXAMPLE\App-RemoteApp-Users',

    # Optional: remove the group's explicit NTFS grant
    [Parameter()]
    [switch]$RemoveNtfsPermission
)

$ErrorActionPreference = 'Stop'

Write-Host "Decommissioning share on $env:COMPUTERNAME..." `
    -ForegroundColor Cyan

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

#region Locate and validate the share

$ExistingShare = Get-SmbShare `
    -Name $ShareName `
    -ErrorAction SilentlyContinue

if (-not $ExistingShare) {
    Write-Warning "The share '$ShareName' does not exist on $env:COMPUTERNAME."

    if ($RemoveNtfsPermission) {
        Write-Warning 'The NTFS permission check will still be performed.'
    }
}
elseif ($ExistingShare.Path -ne $Folder) {
    throw @"
The share '$ShareName' points to a different folder than expected.

Actual path:   $($ExistingShare.Path)
Expected path: $Folder

The share was not removed. Verify the parameters before trying again.
"@
}
else {
    $UncPath = "\\$env:COMPUTERNAME\$ShareName"

    Write-Host "Share found: $UncPath"
    Write-Host "Local path:  $($ExistingShare.Path)"

    # Show current SMB sessions/files associated with the share.
    $OpenFiles = Get-SmbOpenFile -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ShareRelativePath -or
            $_.Path -like "$Folder*"
        }

    if ($OpenFiles) {
        Write-Warning 'There may be files currently open through SMB.'
    }

    if ($PSCmdlet.ShouldProcess(
        $UncPath,
        'Remove the SMB share without deleting the local folder'
    )) {
        Remove-SmbShare `
            -Name $ShareName `
            -Force

        Write-Host "Removed SMB share: $UncPath" -ForegroundColor Green
    }
}

#endregion

#region Optional NTFS permission removal

if ($RemoveNtfsPermission) {
    if (-not (Test-Path -LiteralPath $Folder -PathType Container)) {
        Write-Warning "The folder does not exist, so NTFS permissions cannot be changed: $Folder"
    }
    elseif ($PSCmdlet.ShouldProcess(
        $Folder,
        "Remove the explicit NTFS grant for $UserGroup"
    )) {
        Write-Host "Removing the NTFS grant for $UserGroup..." `
            -ForegroundColor Cyan

        # /remove:g removes granted permissions for the named principal.
        # It does not delete the folder or files.
        & icacls.exe $Folder /remove:g $UserGroup

        if ($LASTEXITCODE -ne 0) {
            throw "Failed to remove the NTFS permission for: $UserGroup"
        }

        Write-Host 'The NTFS permission was removed.' -ForegroundColor Green
    }
}
else {
    Write-Host ''
    Write-Host 'The local folder and NTFS permissions were left unchanged.' `
        -ForegroundColor Yellow
}

#endregion

Write-Host ''
Write-Host 'Decommissioning operation completed.' -ForegroundColor Green
Write-Host "The folder was not deleted: $Folder"
