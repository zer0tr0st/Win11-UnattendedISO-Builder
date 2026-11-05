#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Finds Win11_25H2_English_x64.iso in Downloads, asks the questions needed for an
  unattended install, generates autounattend.xml and builds a new bootable ISO.

.PARAMETER IsoPath
  Optional. Use a specific ISO instead of searching Downloads.

.PARAMETER XmlOnly
  Only generate autounattend.xml (saved to Downloads); do not rebuild the ISO.
  Handy if you'd rather copy the XML to the root of a USB stick made from the ISO.

.NOTES
  Rebuilding the ISO needs oscdimg.exe (Windows ADK -> "Deployment Tools").
  Needs roughly 20 GB free: ~8 GB temp copy + ~8 GB output ISO.
#>
[CmdletBinding()]
param(
    [string]$IsoPath,
    [switch]$XmlOnly
)

$ErrorActionPreference = 'Stop'

# ------------------------------------------------- fixed defaults (no prompts) ---
# Edit these values to change the defaults used for every build.
$FixedCulture      = 'en-US'                 # display language, keyboard, system locale, regional format
$FixedTimeZone     = 'Pacific Standard Time' # Windows ID for US Pacific (handles PST/PDT automatically)
$PreventBitLocker  = $false                  # $true = block automatic BitLocker device encryption
$EnableRdp         = $false                  # $true = enable Remote Desktop
$RemovePressAnyKey = $true                   # $true = no "Press any key to boot from CD/DVD" pause

# ----------------------------------------------------------------- helpers ---
function Read-Default {
    param([string]$Prompt, [string]$Default)
    $s = Read-Host "$Prompt [$Default]"
    if ([string]::IsNullOrWhiteSpace($s)) { return $Default }
    return $s.Trim()
}

function Read-YesNo {
    param([string]$Prompt, [bool]$Default = $true)
    $hint = if ($Default) { 'Y/n' } else { 'y/N' }
    while ($true) {
        $s = Read-Host "$Prompt ($hint)"
        if ([string]::IsNullOrWhiteSpace($s)) { return $Default }
        switch -regex ($s.Trim()) {
            '^(y|yes)$' { return $true }
            '^(n|no)$'  { return $false }
        }
    }
}

function Read-Culture {
    param([string]$Prompt, [string]$Default)
    while ($true) {
        $v = Read-Default $Prompt $Default
        try { [void][System.Globalization.CultureInfo]::GetCultureInfo($v); return $v }
        catch { Write-Warning "'$v' is not a valid culture name (examples: en-US, en-GB, de-DE)." }
    }
}

function Read-NewPassword {
    while ($true) {
        $p1 = Read-Host 'Password (leave blank for none)' -AsSecureString
        $p2 = Read-Host 'Confirm password' -AsSecureString
        $a = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($p1))
        $b = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($p2))
        if ($a -ceq $b) { return $a }
        Write-Warning 'Passwords did not match, try again.'
    }
}

function Esc { param([string]$s) return [System.Security.SecurityElement]::Escape($s) }

function Get-DownloadsFolder {
    try {
        $p = (New-Object -ComObject Shell.Application).NameSpace('shell:Downloads').Self.Path
        if ($p -and (Test-Path $p)) { return $p }
    } catch {}
    return (Join-Path $env:USERPROFILE 'Downloads')
}

# Public generic (install-only) keys from Microsoft. They select the edition during
# setup but do NOT activate Windows; an existing digital license on the hardware
# will activate automatically once online.
$GenericKeys = @{
    'Windows 11 Home'                 = 'YTMG3-N6DKC-DKB77-7M9GH-8HVX7'
    'Windows 11 Home N'               = '4CPRK-NM3K3-X6XXQ-RXX86-WXCHW'
    'Windows 11 Home Single Language' = 'BT79Q-G7N6G-PGBYW-4YWX6-6F4BT'
    'Windows 11 Pro'                  = 'VK7JG-NPHTM-C97JM-9MPGT-3V66T'
    'Windows 11 Pro N'                = '2B87N-8KFHP-DKV6R-Y2C8J-PKCKT'
    'Windows 11 Pro for Workstations' = 'DXG7C-N36C4-C4HTG-X4T3X-2YV77'
    'Windows 11 Pro Education'        = '8PTT6-RNW4C-6V7J2-C2D3X-MHBPB'
    'Windows 11 Education'            = 'YNMGQ-8RYV3-4PGQ3-C8XTP-7CFBY'
    'Windows 11 Education N'          = '84NGF-MHBT6-FXBX8-QWJK7-DRR8H'
    'Windows 11 Enterprise'           = 'NPPR9-FWDCX-D2C8J-H872K-2YT43'
}

# -------------------------------------------------------------- find the ISO ---
$downloads = Get-DownloadsFolder
if (-not $IsoPath) {
    # All ISOs in Downloads, newest first; skip ones this script generated earlier
    $isos = @(Get-ChildItem -LiteralPath $downloads -Filter *.iso -File -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -notlike '*_Unattended.iso' } |
              Sort-Object LastWriteTime -Descending)
    # Prefer Windows-looking names (hides e.g. Ubuntu ISOs); fall back to everything
    $winIsos = @($isos | Where-Object { $_.Name -match 'win' })
    if ($winIsos.Count -gt 0) { $isos = $winIsos }

    if ($isos.Count -eq 0) { throw "No .iso files found in '$downloads'. Re-run with -IsoPath <path>." }

    if ($isos.Count -eq 1) {
        $IsoPath = $isos[0].FullName
    }
    else {
        Write-Host "`nMultiple ISO files found in Downloads:" -ForegroundColor Cyan
        $def = 1
        for ($i = 0; $i -lt $isos.Count; $i++) {
            Write-Host ("  [{0}] {1}  ({2:N1} GB, {3:yyyy-MM-dd})" -f ($i + 1), $isos[$i].Name, ($isos[$i].Length / 1GB), $isos[$i].LastWriteTime)
            if ($isos[$i].Name -eq 'Win11_25H2_English_x64.iso') { $def = $i + 1 }
        }
        while ($true) {
            $n = 0
            if ([int]::TryParse((Read-Default 'Select ISO number' $def), [ref]$n) -and $n -ge 1 -and $n -le $isos.Count) { break }
            Write-Warning 'Invalid choice.'
        }
        $IsoPath = $isos[$n - 1].FullName
    }
}
if (-not (Test-Path -LiteralPath $IsoPath)) {
    throw "ISO not found: '$IsoPath'."
}
Write-Host "`nUsing ISO: $IsoPath" -ForegroundColor Green

$oscdimg = $null
if (-not $XmlOnly) {
    $cmd = Get-Command oscdimg.exe -ErrorAction SilentlyContinue
    if ($cmd) { $oscdimg = $cmd.Source }
    else {
        $adk = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe'
        if (Test-Path $adk) { $oscdimg = $adk }
    }
    if (-not $oscdimg) {
        Write-Warning 'oscdimg.exe not found (install Windows ADK -> Deployment Tools).'
        Write-Warning 'Continuing in XML-only mode: the answer file will be saved to Downloads.'
        $XmlOnly = $true
    }
}

# --------------------------------------------- mount ISO & read edition list ---
$work = $null
$mounted = $false
try {
    Write-Host 'Mounting ISO and reading editions...'
    $img = Mount-DiskImage -ImagePath $IsoPath -PassThru
    $mounted = $true
    $vol = $img | Get-Volume
    $drive = "$($vol.DriveLetter):"
    $wim = Join-Path $drive 'sources\install.wim'
    if (-not (Test-Path $wim)) { $wim = Join-Path $drive 'sources\install.esd' }
    if (-not (Test-Path $wim)) { throw 'No install.wim / install.esd found in the ISO.' }
    $editions = Get-WindowsImage -ImagePath $wim

    Write-Host "`n=== EDITION ===" -ForegroundColor Cyan
    $editions | ForEach-Object { Write-Host ("  [{0}] {1}" -f $_.ImageIndex, $_.ImageName) }
    $defIdx = ($editions | Where-Object ImageName -eq 'Windows 11 Pro' | Select-Object -First 1).ImageIndex
    if (-not $defIdx) { $defIdx = $editions[0].ImageIndex }
    while ($true) {
        $idx = [int](Read-Default 'Edition index to install' $defIdx)
        $chosen = $editions | Where-Object ImageIndex -eq $idx
        if ($chosen) { break }
        Write-Warning 'Invalid index.'
    }
    $editionName = $chosen.ImageName

    # ------------------------------------------------------------ questions ---
    Write-Host "`n=== PRODUCT KEY ===" -ForegroundColor Cyan
    $key = Read-Host "Product key (blank = use generic key for '$editionName'; activate later)"
    $key = $key.Trim()
    $keyLookup = $editionName -replace '^Windows 10', 'Windows 11'   # the generic keys are shared
    if (-not $key -and $GenericKeys.ContainsKey($keyLookup)) { $key = $GenericKeys[$keyLookup] }

    # Language, region and time zone are fixed (see "fixed defaults" at the top of the script).
    $uiLang   = $FixedCulture
    $inputLoc = $FixedCulture
    $sysLoc   = $FixedCulture
    $userLoc  = $FixedCulture
    $tz       = $FixedTimeZone

    Write-Host "`n=== COMPUTER ===" -ForegroundColor Cyan
    while ($true) {
        $pcName = Read-Default "Computer name (* = random)" '*'
        if ($pcName -eq '*' -or ($pcName -match '^[A-Za-z0-9-]{1,15}$' -and $pcName -notmatch '^\d+$')) { break }
        Write-Warning 'Max 15 chars, letters/digits/hyphen only, not all digits.'
    }

    Write-Host "`n=== DISK ===" -ForegroundColor Cyan
    Write-Host '  [1] Automatic - wipe the disk and create the partitions for you'
    Write-Host '  [2] Manual    - Setup shows the disk screen so you create/choose partitions yourself'
    while ($true) {
        $diskChoice = Read-Default 'Disk configuration' '1'
        if ($diskChoice -in '1', '2') { break }
        Write-Warning 'Enter 1 or 2.'
    }
    $diskManual = ($diskChoice -eq '2')
    $uefi = $true
    $diskId = 0
    if (-not $diskManual) {
        Write-Warning 'Automatic mode WIPES the selected disk with NO confirmation when booted.'
        $uefi = (Read-Default 'Firmware mode: UEFI (GPT) or BIOS (MBR)' 'UEFI') -match '^u'
        $diskId = [int](Read-Default 'Target disk number' '0')
    }

    Write-Host "`n=== USER ACCOUNT ===" -ForegroundColor Cyan
    $localAcct = Read-YesNo 'Create a local admin account and skip the Microsoft-account screen?' $true
    $userName = $null; $userPass = ''; $autoLogon = $false
    $extraUsers = @()
    if ($localAcct) {
        while ($true) {
            $userName = Read-Default 'Username' 'Admin'
            if ($userName -match '^[^\\/\[\]:;|=,+*?<>"@]{1,20}$') { break }
            Write-Warning 'Invalid username.'
        }
        $userPass  = Read-NewPassword
        $autoLogon = Read-YesNo 'Auto-logon once after install?' $true

        # ---- additional users ----
        while (Read-YesNo 'Add another user account?' $false) {
            $taken = @($userName) + @($extraUsers | ForEach-Object { $_.Name })
            while ($true) {
                $n = (Read-Host 'Username').Trim()
                if ($n -notmatch '^[^\\/\[\]:;|=,+*?<>"@]{1,20}$') { Write-Warning 'Invalid username.'; continue }
                if ($taken -contains $n -or $n -in 'Administrator', 'Guest', 'DefaultAccount') {
                    Write-Warning 'That name is already in use or reserved.'; continue
                }
                break
            }
            $isAdmin = Read-YesNo "Make '$n' an administrator? (No = standard user)" $false
            $p = Read-NewPassword
            $extraUsers += [pscustomobject]@{
                Name  = $n
                Pass  = $p
                Group = $(if ($isAdmin) { 'Administrators' } else { 'Users' })
            }
        }
    }

    Write-Host "`n=== EXTRAS ===" -ForegroundColor Cyan
    $bypassHw   = Read-YesNo 'Bypass TPM / Secure Boot / RAM / CPU requirement checks?' $false
    $noEncrypt  = $PreventBitLocker
    $enableRdp  = $EnableRdp

    $driverSrc = $null
    if (-not $XmlOnly) {
        Write-Host "`n=== EXTRA DRIVERS (e.g. Wi-Fi) ===" -ForegroundColor Cyan
        Write-Host '  Point to a folder of EXTRACTED drivers (containing .inf files, subfolders are fine).'
        Write-Host '  Tip: from a working PC, export its drivers with:  Export-WindowsDriver -Online -Destination C:\Drivers'
        while ($true) {
            $d = (Read-Host 'Driver folder (blank = none)').Trim().Trim('"')
            if (-not $d) { break }
            if (-not (Test-Path -LiteralPath $d -PathType Container)) { Write-Warning 'Folder not found.'; continue }
            $infCount = @(Get-ChildItem -LiteralPath $d -Recurse -Filter *.inf -ErrorAction SilentlyContinue).Count
            if ($infCount -eq 0) { Write-Warning 'No .inf files found. Extract installer .exe/.zip packages first.'; continue }
            $driverSrc = (Resolve-Path -LiteralPath $d).Path
            Write-Host "  Found $infCount .inf file(s)."
            break
        }
    }

    $noPrompt = $RemovePressAnyKey

    # ------------------------------------------------------------- summary ---
    Write-Host "`n=== SUMMARY ===" -ForegroundColor Yellow
    Write-Host "  Edition      : $editionName (index $idx)"
    Write-Host "  Locale       : UI $uiLang | keyboard $inputLoc | system $sysLoc | format $userLoc"
    Write-Host "  Time zone    : $tz"
    Write-Host "  Computer     : $pcName"
    if ($diskManual) {
        Write-Host '  Disk         : MANUAL - Setup will show the disk/partition screen'
    } else {
        Write-Host ("  Disk         : AUTOMATIC - disk #{0} WILL BE WIPED, {1}" -f $diskId, $(if ($uefi) { 'UEFI/GPT' } else { 'BIOS/MBR' }))
    }
    Write-Host ("  Account      : {0}" -f $(if ($localAcct) { "$userName (admin), autologon=$autoLogon" } else { 'Microsoft account at first sign-in' }))
    foreach ($u in $extraUsers) {
        Write-Host ("  Extra user   : {0} ({1})" -f $u.Name, $(if ($u.Group -eq 'Administrators') { 'admin' } else { 'standard' }))
    }
    Write-Host ("  Drivers      : {0}" -f $(if ($driverSrc) { $driverSrc } else { 'none' }))
    Write-Host "  HW bypass    : $bypassHw | No BitLocker: $noEncrypt | RDP: $enableRdp"
    $confirm = Read-Host "`nType BUILD to continue"
    if ($confirm -cne 'BUILD') { Write-Host 'Cancelled.'; return }

    # ------------------------------------------------------ build the XML ---
    $ns = 'xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"'
    $comp = 'processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"'

    # windowsPE: optional hardware-check bypass
    $peRun = ''
    if ($bypassHw) {
        $names = 'BypassTPMCheck','BypassSecureBootCheck','BypassRAMCheck','BypassCPUCheck','BypassStorageCheck'
        $i = 0
        $cmds = foreach ($n in $names) {
            $i++
            "<RunSynchronousCommand wcm:action=`"add`"><Order>$i</Order><Path>reg add HKLM\SYSTEM\Setup\LabConfig /v $n /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>"
        }
        $peRun = "<RunSynchronous>$($cmds -join '')</RunSynchronous>"
    }

    # windowsPE: disk layout
    if ($uefi) {
        $disk = @"
<Disk wcm:action="add">
  <DiskID>$diskId</DiskID>
  <WillWipeDisk>true</WillWipeDisk>
  <CreatePartitions>
    <CreatePartition wcm:action="add"><Order>1</Order><Type>EFI</Type><Size>300</Size></CreatePartition>
    <CreatePartition wcm:action="add"><Order>2</Order><Type>MSR</Type><Size>16</Size></CreatePartition>
    <CreatePartition wcm:action="add"><Order>3</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>
  </CreatePartitions>
  <ModifyPartitions>
    <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>FAT32</Format><Label>System</Label></ModifyPartition>
    <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>2</PartitionID></ModifyPartition>
    <ModifyPartition wcm:action="add"><Order>3</Order><PartitionID>3</PartitionID><Format>NTFS</Format><Label>Windows</Label><Letter>C</Letter></ModifyPartition>
  </ModifyPartitions>
</Disk>
"@
        $installPart = 3
    } else {
        $disk = @"
<Disk wcm:action="add">
  <DiskID>$diskId</DiskID>
  <WillWipeDisk>true</WillWipeDisk>
  <CreatePartitions>
    <CreatePartition wcm:action="add"><Order>1</Order><Type>Primary</Type><Size>100</Size></CreatePartition>
    <CreatePartition wcm:action="add"><Order>2</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>
  </CreatePartitions>
  <ModifyPartitions>
    <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Active>true</Active><Format>NTFS</Format><Label>System Reserved</Label></ModifyPartition>
    <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>2</PartitionID><Format>NTFS</Format><Label>Windows</Label><Letter>C</Letter></ModifyPartition>
  </ModifyPartitions>
</Disk>
"@
        $installPart = 2
    }

    if ($diskManual) {
        # No DiskConfiguration and no InstallTo: Setup shows the "Where do you want to install Windows?" screen.
        $diskCfgXml  = ''
        $installToXml = '<WillShowUI>Always</WillShowUI>'
    } else {
        $diskCfgXml  = "<DiskConfiguration>$disk</DiskConfiguration>"
        $installToXml = "<InstallTo><DiskID>$diskId</DiskID><PartitionID>$installPart</PartitionID></InstallTo>"
    }

    $keyXml = ''
    if ($key) { $keyXml = "<ProductKey><Key>$(Esc $key)</Key><WillShowUI>OnError</WillShowUI></ProductKey>" }

    # specialize: commands
    $spec = @()
    if ($noEncrypt) { $spec += 'reg add HKLM\SYSTEM\CurrentControlSet\Control\BitLocker /v PreventDeviceEncryption /t REG_DWORD /d 1 /f' }
    if ($localAcct) { $spec += 'reg add HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE /v BypassNRO /t REG_DWORD /d 1 /f' }
    $specComp = ''
    if ($spec.Count -gt 0) {
        $o = 0
        $c = foreach ($s in $spec) { $o++; "<RunSynchronousCommand wcm:action=`"add`"><Order>$o</Order><Path>$s</Path></RunSynchronousCommand>" }
        $specComp = "<component name=`"Microsoft-Windows-Deployment`" $comp $ns><RunSynchronous>$($c -join '')</RunSynchronous></component>"
    }

    # oobeSystem: account, autologon, first-logon commands
    $acctXml = ''; $logonXml = ''
    if ($localAcct) {
        $pw = "<Password><Value>$(Esc $userPass)</Value><PlainText>true</PlainText></Password>"
        $allUsers = @([pscustomobject]@{ Name = $userName; Pass = $userPass; Group = 'Administrators' }) + $extraUsers
        $accts = foreach ($u in $allUsers) {
            "<LocalAccount wcm:action=`"add`"><Name>$(Esc $u.Name)</Name><DisplayName>$(Esc $u.Name)</DisplayName><Group>$($u.Group)</Group><Password><Value>$(Esc $u.Pass)</Value><PlainText>true</PlainText></Password></LocalAccount>"
        }
        $acctXml = "<UserAccounts><LocalAccounts>$($accts -join '')</LocalAccounts></UserAccounts>"
        if ($autoLogon) {
            $logonXml = "<AutoLogon><Enabled>true</Enabled><LogonCount>1</LogonCount><Username>$(Esc $userName)</Username>$pw</AutoLogon>"
        }
    }
    $flc = ''
    if ($enableRdp) {
        $flc = @"
<FirstLogonCommands>
  <SynchronousCommand wcm:action="add"><Order>1</Order><CommandLine>reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server" /v fDenyTSConnections /t REG_DWORD /d 0 /f</CommandLine></SynchronousCommand>
  <SynchronousCommand wcm:action="add"><Order>2</Order><CommandLine>netsh advfirewall firewall set rule group="remote desktop" new enable=Yes</CommandLine></SynchronousCommand>
</FirstLogonCommands>
"@
    }
    $hideOnline = if ($localAcct) { 'true' } else { 'false' }

    $xml = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">

  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE" $comp $ns>
      <SetupUILanguage><UILanguage>$uiLang</UILanguage></SetupUILanguage>
      <InputLocale>$inputLoc</InputLocale>
      <SystemLocale>$sysLoc</SystemLocale>
      <UILanguage>$uiLang</UILanguage>
      <UserLocale>$userLoc</UserLocale>
    </component>
    <component name="Microsoft-Windows-Setup" $comp $ns>
      $peRun
      $diskCfgXml
      <ImageInstall>
        <OSImage>
          <InstallFrom>
            <MetaData wcm:action="add"><Key>/IMAGE/INDEX</Key><Value>$idx</Value></MetaData>
          </InstallFrom>
          $installToXml
        </OSImage>
      </ImageInstall>
      <UserData>
        <AcceptEula>true</AcceptEula>
        $keyXml
      </UserData>
    </component>
  </settings>

  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" $comp $ns>
      <ComputerName>$(Esc $pcName)</ComputerName>
      <TimeZone>$(Esc $tz)</TimeZone>
    </component>
    $specComp
  </settings>

  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" $comp $ns>
      <InputLocale>$inputLoc</InputLocale>
      <SystemLocale>$sysLoc</SystemLocale>
      <UILanguage>$uiLang</UILanguage>
      <UserLocale>$userLoc</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" $comp $ns>
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>$hideOnline</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
      $acctXml
      $logonXml
      $flc
    </component>
  </settings>

</unattend>
"@

    # Validate it is well-formed before going any further
    $null = [xml]$xml

    $xmlOut = Join-Path $downloads 'autounattend.xml'
    [IO.File]::WriteAllText($xmlOut, $xml, (New-Object Text.UTF8Encoding($false)))
    Write-Host "`nSaved answer file: $xmlOut" -ForegroundColor Green

    if ($XmlOnly) {
        Write-Host 'XML-only mode: copy autounattend.xml to the ROOT of a USB stick made from the ISO (or any separate USB stick).'
        return
    }

    # ----------------------------------------------- copy ISO, add XML, rebuild ---
    $work = Join-Path $env:TEMP ("Win11Unattend_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $work | Out-Null
    Write-Host "Copying ISO contents to $work (a few minutes)..."
    if (-not (Test-Path "$drive\sources")) { throw "ISO drive '$drive' is not readable." }
    Copy-Item -Path "$drive\*" -Destination $work -Recurse -Force -ErrorAction Stop
    Get-ChildItem $work -Recurse -Force | ForEach-Object { $_.Attributes = $_.Attributes -band (-bnot [IO.FileAttributes]::ReadOnly) }

    $label = $vol.FileSystemLabel
    if ([string]::IsNullOrWhiteSpace($label)) { $label = 'WIN11_UNATTENDED' }
    if ($label.Length -gt 32) { $label = $label.Substring(0, 32) }

    Dismount-DiskImage -ImagePath $IsoPath | Out-Null
    $mounted = $false

    [IO.File]::WriteAllText((Join-Path $work 'autounattend.xml'), $xml, (New-Object Text.UTF8Encoding($false)))

    if ($driverSrc) {
        $wimWork = Join-Path $work 'sources\install.wim'
        if (-not (Test-Path -LiteralPath $wimWork)) {
            Write-Warning 'This ISO uses install.esd, which cannot be mounted for driver injection. Drivers were NOT added.'
        }
        else {
            $mnt = Join-Path $env:TEMP ('WimMount_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            New-Item -ItemType Directory -Path $mnt | Out-Null
            $committed = $false
            try {
                Write-Host "Mounting image index $idx to inject drivers (this takes a few minutes)..."
                Mount-WindowsImage -ImagePath $wimWork -Index $idx -Path $mnt | Out-Null
                Write-Host 'Injecting drivers...'
                $added = Add-WindowsDriver -Path $mnt -Driver $driverSrc -Recurse
                Write-Host "Injected $(@($added).Count) driver package(s):" -ForegroundColor Green
                $added | ForEach-Object { Write-Host ("  {0}  ({1}, {2})" -f $_.OriginalFileName.Split('\')[-1], $_.ProviderName, $_.ClassName) }
                Write-Host 'Saving image (this takes a few minutes)...'
                Dismount-WindowsImage -Path $mnt -Save | Out-Null
                $committed = $true
            }
            finally {
                if (-not $committed) { Dismount-WindowsImage -Path $mnt -Discard -ErrorAction SilentlyContinue | Out-Null }
                Remove-Item $mnt -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    $etfs = Join-Path $work 'boot\etfsboot.com'
    $efi = Join-Path $work 'efi\microsoft\boot\efisys.bin'
    if ($noPrompt -and (Test-Path (Join-Path $work 'efi\microsoft\boot\efisys_noprompt.bin'))) {
        $efi = Join-Path $work 'efi\microsoft\boot\efisys_noprompt.bin'
    }
    if (-not (Test-Path $etfs) -or -not (Test-Path $efi)) { throw 'Boot files missing from ISO copy.' }

    $outIso = Join-Path $downloads ([IO.Path]::GetFileNameWithoutExtension($IsoPath) + '_Unattended.iso')
    if (Test-Path $outIso) { Remove-Item $outIso -Force }

    Write-Host "Building $outIso ..."
    $args = @(
        '-m', '-o', '-u2', '-udfver102',
        "-bootdata:2#p0,e,b$etfs#pEF,e,b$efi",
        "-l$label",
        $work, $outIso
    )
    & $oscdimg @args
    if ($LASTEXITCODE -ne 0) { throw "oscdimg failed (exit $LASTEXITCODE)." }

    Write-Host "`nDone! Unattended ISO: $outIso" -ForegroundColor Green
    Write-Warning 'Booting this ISO will WIPE the target disk without asking. Use it in a VM first.'
    Write-Warning 'The ISO contains your password in plain text. Do not share it.'
    if ($noPrompt) {
        Write-Warning 'The "press any key" pause is removed: detach/eject the ISO after the first reboot, or Setup may start over.'
    }
}
finally {
    if ($mounted) { Dismount-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue | Out-Null }
    if ($work -and (Test-Path $work)) { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue }
}
