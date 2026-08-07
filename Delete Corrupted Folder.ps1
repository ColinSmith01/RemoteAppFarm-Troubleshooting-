$VhdxPath = '\\RemoteAppFS\RA_Profiles\12356.vhdx'   #JoeBloggs Corrupted folder is encrypted as 12356 from previous output paste this in 

Remove-Item -LiteralPath $VhdxPath -Force -Confirm
