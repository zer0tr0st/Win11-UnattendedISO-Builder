# New-UnattendedWin11Iso.ps1

A PowerShell script that turns a stock Windows 11 ISO into an **unattended-install ISO**. It finds your ISO in the Downloads folder, asks a short set of questions, generates an `autounattend.xml` answer file, optionally injects drivers (for example Wi-Fi), and rebuilds a bootable ISO you can use in a VM or write to a USB drive.

> **WARNING:** In *Automatic* disk mode the resulting ISO **wipes the target disk without asking for confirmation** as soon as it boots. Test in a virtual machine first, and never leave the ISO attached to a machine you don't want erased.

---

## Requirements

| Requirement | Details |
|---|---|
| **Operating system** | Windows 10 or 11 (64-bit) to run the script |
| **PowerShell** | Windows PowerShell 5.1 or PowerShell 7, **run as Administrator** (needed for DISM/driver injection) |
| **Windows ADK** | **Deployment Tools** feature, which provides `oscdimg.exe` (see below). Required to rebuild the ISO |
| **Source ISO** | A Windows 11 ISO in your Downloads folder (default name `Win11_25H2_English_x64.iso`) |
| **Free disk space** | About 20 GB (temp copy of the ISO contents plus the output ISO) |

### Windows ADK (required)

The script uses `oscdimg.exe` from the **Windows Assessment and Deployment Kit (ADK)** to build a bootable ISO. Without it, the script can only produce the `autounattend.xml` file (it falls back to XML-only mode automatically).

- **Download page (official, always current):** <https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install>
- **Direct download, Windows ADK 10.1.26100.9457 (September 2026):** <https://go.microsoft.com/fwlink/?linkid=2289980>
  Supports Windows 11 versions 26H2, 25H2 and 24H2 and earlier.

**Install steps**

1. Run the downloaded `adksetup.exe`.
2. Choose **Install the Windows Assessment and Deployment Kit to this computer**.
3. On the feature list, tick **only "Deployment Tools"** and untick everything else.
4. Finish the install. The Windows PE add-on is **not** needed.

The script looks for `oscdimg.exe` on your `PATH` and in the default ADK location:

```
C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe
```

> **Version note:** Microsoft publishes a separate ADK (10.1.28000.x) for Windows 11 **26H1** only. Use the 10.1.26100.x ADK above for 25H2/24H2 ISOs. Microsoft updates this page periodically, so if the direct link ever stops working, use the download page.

---

## Quick start

1. Install the Windows ADK (above).
2. Put your Windows 11 ISO in your **Downloads** folder.
3. Open **PowerShell as Administrator** and run:

   ```powershell
   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
   cd C:\path\to\script
   .\New-UnattendedWin11Iso.ps1
   ```

4. Answer the prompts, review the summary, and type `BUILD` to continue.
5. When it finishes, you'll find the new ISO in Downloads:

   ```
   <original ISO name>_Unattended.iso
   ```

   The generated `autounattend.xml` is also saved to Downloads.

### Parameters

| Parameter | Description |
|---|---|
| `-IsoPath <path>` | Use a specific ISO (any folder) instead of searching Downloads |
| `-XmlOnly` | Only generate `autounattend.xml`. Skips the ISO rebuild and driver injection. Handy for copying the XML to the root of a USB stick you made yourself |

---

## What the script does

1. Locates ISOs in Downloads. If there is more than one, it shows a numbered menu (newest first) so you can choose.
2. Mounts the ISO and reads the available Windows editions from `install.wim`.
3. Asks the questions below and shows a summary.
4. Generates `autounattend.xml` and copies it to the root of the ISO contents.
5. If you provided drivers, injects them into the selected edition with DISM.
6. Rebuilds a bootable BIOS and UEFI ISO with `oscdimg.exe` and cleans up temp files.

### Questions asked

| Prompt | Notes |
|---|---|
| **ISO selection** | Only shown when several ISOs are found in Downloads |
| **Edition** | Chosen from the editions inside the ISO |
| **Product key** | Leave blank to use Microsoft's public generic key for the edition (installs but doesn't activate; an existing digital license activates automatically once online) |
| **Computer name** | `*` generates a random name |
| **Disk configuration** | *Automatic* or *Manual* (see below) |
| **Local account** | Create a local admin account and skip the Microsoft-account screen, with username, password and optional one-time auto-logon |
| **Additional users** | Add as many extra local users as you like, each as administrator or standard user |
| **Hardware check bypass** | Optionally bypass TPM, Secure Boot, RAM, CPU and storage checks |
| **Driver folder** | Optional folder of extracted drivers (for example Wi-Fi) to inject into the image |

### Fixed defaults (no prompts)

These are set in the "fixed defaults" block at the top of the script. Edit them there to change them.

| Setting | Default |
|---|---|
| Language, keyboard, system locale, regional format | `en-US` |
| Time zone | `Pacific Standard Time` (switches between PST and PDT automatically) |
| Prevent automatic BitLocker device encryption (`$PreventBitLocker`) | `$false` (Windows default behavior applies) |
| Enable Remote Desktop (`$EnableRdp`) | `$false` |
| Remove "Press any key to boot from CD/DVD" (`$RemovePressAnyKey`) | `$true` |

### Disk configuration modes

- **Automatic:** wipes the chosen disk (default disk 0) and creates partitions for you.
  - UEFI/GPT: 300 MB EFI, 16 MB MSR, and the rest as the Windows (C:) partition.
  - BIOS/MBR: 100 MB System Reserved, and the rest as the Windows (C:) partition.
- **Manual:** the disk layout is left out of the answer file, so Setup stops at the "Where do you want to install Windows?" screen. Everything else remains unattended.

---

## Adding drivers (e.g. Wi-Fi)

If you give the script a driver folder, it mounts the selected edition in `install.wim` and runs `Add-WindowsDriver -Recurse`. The drivers end up in the installed system's driver store, so Windows binds them automatically.

- The folder must contain **extracted** drivers (`.inf` files). Unpack vendor installers (`.exe`/`.zip`) first, for example with 7-Zip.
- Easiest source if the target is the same model as a working PC:
  ```powershell
  Export-WindowsDriver -Online -Destination C:\Drivers
  ```
- The script prints each injected driver package. If it reports **0**, nothing was added, so check your folder.
- Only the edition you select receives the drivers. Other editions in the ISO are untouched.
- Not supported for ISOs that ship `install.esd` instead of `install.wim`. The script warns and skips drivers in that case.
- Verify on the installed PC with: `pnputil /enum-drivers`

---

## Boot behavior and safety notes

- **Disk wipe:** Automatic mode erases the target disk with no confirmation. Use a VM for testing.
- **Press-any-key removed:** because the prompt is removed by default, an ISO left attached after Setup's first reboot can start the install over. **Detach or eject the ISO after the first reboot.** To keep the prompt, set `$RemovePressAnyKey = $false`.
- **Passwords are stored in plain text** in `autounattend.xml` and inside the ISO. Don't share the ISO or the XML.
- **Microsoft-account bypass:** the local-account flow relies on the `HideOnlineAccountScreens` setting and the `BypassNRO` registry value. Microsoft changes OOBE behavior between builds, so verify this on your target build.
- **Generic product keys** only select the edition. They do not activate Windows.

---

## Troubleshooting

| Problem | What to try |
|---|---|
| `oscdimg.exe not found` / script drops to XML-only mode | Install the ADK **Deployment Tools** feature (see Requirements) |
| "No .iso files found" | Put the ISO in Downloads, or pass `-IsoPath` |
| Copy step fails | Check free disk space on the drive that holds `%TEMP%`, and check whether antivirus is blocking the copy |
| Drivers: 0 packages injected | Make sure the folder holds extracted `.inf` drivers for Windows 11 x64 |
| Driver injection fails on an unsigned driver | Use a signed driver package |
| A build was interrupted and a mount is left over | `Dismount-WindowsImage -Path <WimMount_ folder in %TEMP%> -Discard`, or run `dism /Cleanup-Wim` |
| Setup restarts the install after the first reboot | Detach the ISO, or rebuild with `$RemovePressAnyKey = $false` |
| Manual mode doesn't show the disk screen | Rebuild and test in a VM; confirm you chose option `2` for disk configuration |

---

## Output files

| File | Location |
|---|---|
| `<source name>_Unattended.iso` | Downloads |
| `autounattend.xml` | Downloads |

Temporary files are created under `%TEMP%` and removed automatically when the script finishes.
