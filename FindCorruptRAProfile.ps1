$Share    = '\\RemoteAppFS\RA_Profiles' ##Change to relevant
$Username = 'JoeBloggs'  ##JoeBlogs chnage to relevant username#

Get-ChildItem -Path $Share -Filter '*.vhdx' -File -Recurse -ErrorAction SilentlyContinue |
ForEach-Object {
    $file = $_

    try {
        $acl = Get-Acl -LiteralPath $file.FullName -ErrorAction Stop

        $matches = $acl.Access | Where-Object {
            $_.IdentityReference.Value -match "(^|\\)$([regex]::Escape($Username))$"
        }

        foreach ($entry in $matches) {
            [PSCustomObject]@{
                VHDXPath        = $file.FullName
                Username        = $entry.IdentityReference
                Rights          = $entry.FileSystemRights
                AccessType      = $entry.AccessControlType
                Inherited       = $entry.IsInherited
            }
        }
    }
    catch {
        Write-Warning "Could not inspect $($file.FullName): $($_.Exception.Message)"
    }
} | Format-Table -AutoSize
