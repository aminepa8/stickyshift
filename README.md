```
███████╗████████╗██╗ ██████╗██╗  ██╗██╗   ██╗███████╗██╗  ██╗██╗███████╗████████╗
██╔════╝╚══██╔══╝██║██╔════╝██║ ██╔╝╚██╗ ██╔╝██╔════╝██║  ██║██║██╔════╝╚══██╔══╝
███████╗   ██║   ██║██║     █████╔╝  ╚████╔╝ ███████╗███████║██║█████╗     ██║
╚════██║   ██║   ██║██║     ██╔═██╗   ╚██╔╝  ╚════██║██╔══██║██║██╔══╝     ██║
███████║   ██║   ██║╚██████╗██║  ██╗   ██║   ███████║██║  ██║██║██║        ██║
╚══════╝   ╚═╝   ╚═╝ ╚═════╝╚═╝  ╚═╝   ╚═╝   ╚══════╝╚═╝  ╚═╝╚═╝╚═╝        ╚═╝
   ⇧⇧⇧⇧⇧  press shift five times. get a rescue kit.  ·  powered by Ventoy
```

[![Built on Ventoy](https://img.shields.io/badge/built%20on-Ventoy-blue)](https://www.ventoy.net)
![Shell](https://img.shields.io/badge/bash-4%2B-green)
![Platform](https://img.shields.io/badge/platform-Linux-orange)

> *Press Shift five times and Windows offers you Sticky Keys. Run this one and you get a rescue kit.*
>
> Drop your ISOs in a folder. Plug in a stick. Run one command.
> You never know when you'll need a rescue disk. Now you'll have two.

**stickyshift** is a small CLI that turns a USB stick into a multiboot rescue/install drive, with guard rails, logging and sane failure handling, plus a curated reference of what to put on it.

> 🧩 **Built on Ventoy.** stickyshift is only a friendly wrapper around [Ventoy](https://www.ventoy.net) ([source](https://github.com/ventoy/Ventoy)): Ventoy does the actual disk setup and booting, and stickyshift automates installing/updating it and loading your images. Ventoy is an independent open-source project by its own authors. All credit for the heavy lifting goes to them.

---

## ⚡ Quick start

```bash
git clone https://github.com/aminepa8/stickyshift.git && cd stickyshift
chmod +x stickyshift.sh

# 1. put everything you downloaded in ONE folder
mv ~/Downloads/*.iso isos/

# 2. run it (it asks for sudo itself)
./stickyshift.sh
```

What happens:

1. Scans `isos/` for `.iso .img .wim .vhd(x) .efi`
2. Lists **only USB/removable disks** → you pick the stick
3. Finds Ventoy (or downloads + checksum-verifies the latest release)
4. Installs Ventoy (typed confirmation first) or keeps/updates an existing install
5. Shows your images with sizes and the stick's free space → you pick which ones
6. Copies them to `/ISO` with retries, space checks and verification
7. Prints a summary and exits non-zero if anything failed

Do it twice, once per stick (`MEDIC` and `LAUNCHPAD`, see below), picking different images each time.

---

## 🛡️ Safety rails

| Guard | Behavior |
|-------|----------|
| USB-only listing | Non-USB / non-removable disks are hidden unless you pass `--any-disk` |
| System disk check | Refuses any disk with `/`, `/boot`, `/boot/efi`, `/home`, `/usr`, `/var`, `/opt` or swap mounted |
| Typed confirmation | Wiping requires typing the device name (`sdb`) |
| Size warning | Warns if the "stick" is over 256 GB |
| Dry run | `-n` prints every action and changes nothing |
| Partitions rejected | `/dev/sdb1` is refused; use `/dev/sdb` |

> ⚠️ Installing Ventoy **erases the whole stick**. Check the model and size before you type the name.

## 🧯 Failure handling and logging

- Every run writes `logs/stickyshift-YYYYMMDD-HHMMSS.log` (commands, output, decisions, timings).
- **Per-file isolation:** one bad ISO never aborts the batch. It is retried up to 3 times, then recorded as failed.
- **Space checks:** images that don't fit are skipped, not half-copied. Failed copies are removed.
- **Resumable:** re-running skips files already on the stick (same size, or same sha256 with `--verify`).
- **Source integrity:** if `name.iso.sha256` sits next to an image, it is checked first, and a mismatch skips that image.
- **Clean exit:** Ctrl+C or any error unmounts what the tool mounted. Exit code `0` = all good, `1` = failures, `2` = bad usage.

---

## 🔧 Usage

```text
./stickyshift.sh [command] [options]

commands:  run (default) | copy | list | fetch
```

| Option | Meaning |
|--------|---------|
| `-i, --iso-dir DIR` | Folder with your ISOs (default `./isos`) |
| `-d, --device DEV` | e.g. `/dev/sdb`, skips the menu |
| `-t, --target-dir DIR` | Copy into an already-mounted folder instead of a device |
| `-V, --ventoy-dir DIR` | Extracted Ventoy folder (has `Ventoy2Disk.sh`) |
| `-r, --reserve MB` | Leave free space at the end of the stick (fresh install) |
| `--gpt` | GPT instead of MBR (fresh install) |
| `--label NAME` | Data partition label |
| `--update` | Non-destructive Ventoy update |
| `--reinstall` | Wipe and reinstall even if Ventoy exists |
| `-a, --all` | Copy every image, no questions |
| `--verify` | sha256-compare source vs. copy |
| `-y, --yes` | Skip prompts (typed wipe check skipped only when `--device` is also given) |
| `-n, --dry-run` | Show what would happen |
| `--any-disk` | Allow non-USB disks (dangerous) |
| `--log-dir DIR` | Log location |

```bash
./stickyshift.sh list                                  # which sticks would be offered
./stickyshift.sh -i ~/Downloads/isos -r 4096           # keep 4 GiB free for tools
./stickyshift.sh -n -d /dev/sdb -a                     # dry run, no root needed
sudo ./stickyshift.sh copy -d /dev/sdb -a --verify     # refresh ISOs on a ready stick
./stickyshift.sh fetch                                 # just grab + verify Ventoy
```

**Optional sidecars in `isos/`:**

- `name.iso.sha256`: expected hash (first field is used)
- `ventoy.json`: copied to `<stick>/ventoy/ventoy.json` (see [`ventoy.json.example`](ventoy.json.example))

**Requirements:** Linux, bash 4+, `lsblk`, `sha256sum`, `df`, `find`. Optional: `rsync` (progress + resume), `curl` (auto-download Ventoy). The kernel needs exFAT support (5.7+) to mount the Ventoy data partition.

---

## 🧭 The two-stick strategy

| Stick | Role | Codename |
|-------|------|----------|
| **USB 1** | Rescue and repair | 🚑 `MEDIC` |
| **USB 2** | Live OS and installers | 🚀 `LAUNCHPAD` |

If one dies, or gets plugged into a machine you don't trust, the other is untouched. Put one in your bag; leave one at home.

### 🚑 `MEDIC`: rescue and repair

| Tool | ~Size | What it does | Link |
|------|-------|--------------|------|
| SystemRescue | ~1 GB | Linux rescue toolkit: GParted, chroot, fsck, network tools | [system-rescue.org](https://www.system-rescue.org/Download/) |
| Hiren's BootCD PE | ~3 GB | Windows PE: password resets, file recovery, partition tools | [hirensbootcd.org](https://www.hirensbootcd.org/download/) |
| Clonezilla | ~400 MB | Disk imaging and cloning | [clonezilla.org](https://clonezilla.org/downloads.php) |
| Rescuezilla | ~1.5 GB | Friendly GUI imaging, Clonezilla-based | [rescuezilla.com](https://rescuezilla.com/) |
| Memtest86+ | ~10 MB | Is it the RAM? Find out | [memtest.org](https://memtest.org/) |
| ShredOS | ~100 MB | Secure disk wiping (nwipe) | [GitHub](https://github.com/PartialVolume/shredos.x86_64) |
| Boot-Repair-Disk | ~1 GB | Fixes GRUB and broken dual-boots | [SourceForge](https://sourceforge.net/projects/boot-repair-cd/) |
| netboot.xyz | few MB | Network-boot menu for hundreds of OSes and tools | [netboot.xyz](https://netboot.xyz/) |

### 🚀 `LAUNCHPAD`: live and install

| OS | ~Size | Why | Link |
|----|-------|-----|------|
| Linux Mint | ~3 GB | Friendly live system, great hardware support | [linuxmint.com](https://linuxmint.com/download.php) |
| Ubuntu Desktop | ~6 GB | The widely supported default | [ubuntu.com](https://ubuntu.com/download/desktop) |
| Fedora Workstation | ~2 GB | Fresh kernel/drivers, a good second opinion | [fedoraproject.org](https://fedoraproject.org/workstation/download) |
| Debian Live | ~3 GB | Rock-solid and minimal | [debian.org](https://www.debian.org/CD/live/) |
| Windows 11 ISO | ~7 GB | Official reinstall media | [microsoft.com](https://www.microsoft.com/software-download/windows11) |
| Kali Linux *(opt.)* | ~4 GB | Pentesting and forensics | [kali.org](https://www.kali.org/get-kali/) |
| Parrot OS *(opt.)* | ~4 GB | Security/privacy flavored alternative | [parrotsec.org](https://parrotsec.org/download/) |

> 16 GB goes fast. Windows 11 alone eats almost half. The tool skips what doesn't fit and tells you.

---

## ⚙️ Ventoy tips

- **Secure Boot:** [docs](https://www.ventoy.net/en/doc_secure.html). Enroll the Ventoy key via MokManager on first boot instead of disabling Secure Boot everywhere. The tool installs with Secure Boot support enabled.
- **Persistence:** [docs](https://www.ventoy.net/en/plugin_persistence.html). Create a backing file with the script shipped in the Ventoy folder, then map it in `ventoy.json`:
  ```bash
  cd ventoy-*/ && sudo sh CreatePersistentImg.sh -s 4096 -l casper-rw   # then copy the .dat to the stick
  ```
- **Reserve space** (`-r`) for a tools/notes partition, set at install time.
- **Tails** doesn't play well with Ventoy; flash it to its own stick: [tails.net](https://tails.net/install/).
- Some images need GRUB2 or Memdisk mode: press `Ctrl+R` at the Ventoy menu.
- Verify checksums and refresh your ISOs every few months.

---

## ✅ Checklist

- [ ] ISOs in `isos/` (with `.sha256` sidecars if you have them)
- [ ] `./stickyshift.sh -n` dry run looks right
- [ ] Run for `MEDIC`, then again for `LAUNCHPAD`
- [ ] Test-boot both sticks on a real machine (BIOS **and** UEFI)
- [ ] Label them physically
- [ ] Keep the logs. Future you will thank you.

---

## 📝 Notes

- Linux only (it leans on `lsblk`, `findmnt`-style tooling and Ventoy's Linux installer). On Windows, use Ventoy2Disk.exe and copy files by hand.
- stickyshift is not affiliated with or endorsed by the Ventoy project; it just uses it. Respect each OS's license; this repo ships no ISOs.

<sub>Built for emergencies. Hopefully never needed. 🛟</sub>
