#!/usr/bin/env bash
#
# stickyshift — drop ISOs in a folder, pick a USB stick, let the script do the rest.
#
# Built on top of Ventoy (https://www.ventoy.net): stickyshift is a friendly wrapper
# that installs/updates Ventoy and fills the stick. Ventoy does the booting.
#
#   * finds removable/USB disks only (refuses your system disk)
#   * installs / updates Ventoy (or keeps an existing install)
#   * copies the ISOs you pick, checks free space, retries, verifies
#   * logs everything to ./logs/ and survives per-file failures
#
# Repo: https://github.com/aminepa8/stickyshift
#
# Linux only. Needs: bash 4+, lsblk, findmnt, sha256sum, df, mount (root for disk ops)
# Optional: rsync (progress + resume), curl (auto-download Ventoy)
#
set -uo pipefail

readonly VERSION="1.0.0"
readonly PROG="stickyshift"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORIG_ARGS=("$@")

# ---------------------------------------------------------------- defaults --
CMD="run"
ISO_DIR="$SCRIPT_DIR/isos"
DEVICE=""
DEVICE_FROM_FLAG=0
TARGET_DIR=""
VENTOY_DIR=""
RESERVE_MB=0
GPT=0
LABEL=""
DRY_RUN=0
ASSUME_YES=0
VERIFY=0
ANY_DISK=0
SELECT_ALL=0
FORCE_UPDATE=0
FORCE_REINSTALL=0
LOG_DIR="$SCRIPT_DIR/logs"
LOG_FILE=""
MNT=""
MOUNTED_BY_US=0
ISO_NAMES=()
ISO_SIZES=()
SELECTED=()
COPIED=()
SKIPPED=()
FAILED=()

# ------------------------------------------------------------------ colors --
if [[ -t 1 ]]; then
  C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[36m'; C_D=$'\e[2m'; C_0=$'\e[0m'
else
  C_R=""; C_G=""; C_Y=""; C_B=""; C_D=""; C_0=""
fi

banner() {
  cat <<'EOF'
███████╗████████╗██╗ ██████╗██╗  ██╗██╗   ██╗███████╗██╗  ██╗██╗███████╗████████╗
██╔════╝╚══██╔══╝██║██╔════╝██║ ██╔╝╚██╗ ██╔╝██╔════╝██║  ██║██║██╔════╝╚══██╔══╝
███████╗   ██║   ██║██║     █████╔╝  ╚████╔╝ ███████╗███████║██║█████╗     ██║
╚════██║   ██║   ██║██║     ██╔═██╗   ╚██╔╝  ╚════██║██╔══██║██║██╔══╝     ██║
███████║   ██║   ██║╚██████╗██║  ██╗   ██║   ███████║██║  ██║██║██║        ██║
╚══════╝   ╚═╝   ╚═╝ ╚═════╝╚═╝  ╚═╝   ╚═╝   ╚══════╝╚═╝  ╚═╝╚═╝╚═╝        ╚═╝
   ⇧⇧⇧⇧⇧  press shift five times. get a rescue kit.  ·  powered by Ventoy
EOF
}

# ----------------------------------------------------------------- logging --
init_log() {
  mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR="/tmp"
  LOG_FILE="$LOG_DIR/${PROG}-$(date +%Y%m%d-%H%M%S).log"
  if ! : >"$LOG_FILE" 2>/dev/null; then
    LOG_FILE="/tmp/${PROG}-$$.log"
    : >"$LOG_FILE"
  fi
  {
    echo "# $PROG $VERSION  started $(date '+%F %T')"
    echo "# host: $(uname -srm)  user: $(id -un)  args: ${ORIG_ARGS[*]:-}"
  } >>"$LOG_FILE"
}

log() {
  local lvl="$1"; shift
  local msg="$*"
  if [[ -n $LOG_FILE ]]; then
    printf '%s [%-5s] %s\n' "$(date '+%F %T')" "$lvl" "$msg" >>"$LOG_FILE"
  fi
  case "$lvl" in
    INFO)  printf '%s[*]%s %s\n' "$C_B" "$C_0" "$msg" ;;
    OK)    printf '%s[+]%s %s\n' "$C_G" "$C_0" "$msg" ;;
    WARN)  printf '%s[!]%s %s\n' "$C_Y" "$C_0" "$msg" >&2 ;;
    ERROR) printf '%s[x]%s %s\n' "$C_R" "$C_0" "$msg" >&2 ;;
    DRY)   printf '%s[dry]%s %s\n' "$C_D" "$C_0" "$msg" ;;
    *)     : ;;   # DEBUG -> file only
  esac
}

die() {
  log ERROR "$*"
  [[ -n $LOG_FILE ]] && echo "    log: $LOG_FILE" >&2
  exit 1
}

have() { command -v "$1" >/dev/null 2>&1; }

# Run a short command, capture its output into the log, honour --dry-run.
run_cmd() {
  log DEBUG "exec: $*"
  if ((DRY_RUN)); then log DRY "$*"; return 0; fi
  local out rc
  out=$("$@" 2>&1); rc=$?
  [[ -n $out ]] && printf '%s\n' "$out" >>"$LOG_FILE"
  if ((rc != 0)); then
    log ERROR "command failed (rc=$rc): $*"
    [[ -n $out ]] && log ERROR "last output: ${out##*$'\n'}"
  fi
  return $rc
}

# ----------------------------------------------------------------- cleanup --
cleanup() {
  local rc=$?
  if ((MOUNTED_BY_US)) && [[ -n $MNT ]] && mountpoint -q "$MNT" 2>/dev/null; then
    sync
    umount "$MNT" 2>/dev/null && log DEBUG "unmounted $MNT" || log WARN "could not unmount $MNT — unmount it manually before unplugging"
    rmdir "$MNT" 2>/dev/null || true
  fi
  # give the log back to the invoking user if we ran through sudo
  if [[ -n ${SUDO_USER:-} && -n $LOG_FILE && -e $LOG_FILE ]]; then
    chown "$SUDO_USER" "$LOG_FILE" "$LOG_DIR" 2>/dev/null || true
  fi
  [[ -n $LOG_FILE ]] && log DEBUG "exit code $rc"
}
on_signal() { log WARN "interrupted — cleaning up"; exit 130; }
trap cleanup EXIT
trap on_signal INT TERM

# ----------------------------------------------------------------- helpers --
human() {
  awk -v b="${1:-0}" 'BEGIN{n=split("B KiB MiB GiB TiB",u," "); i=1; while(b>=1024&&i<n){b/=1024;i++} printf "%.1f %s", b, u[i]}'
}

part_path() {
  local dev="$1" n="$2"
  if [[ $dev =~ [0-9]$ ]]; then echo "${dev}p${n}"; else echo "${dev}${n}"; fi
}

confirm() {
  ((ASSUME_YES)) && return 0
  [[ -t 0 ]] || die "Need interactive confirmation but stdin is not a terminal (use --yes)."
  local a
  read -rp "$1 [y/N] " a
  [[ $a =~ ^[Yy]$ ]]
}

need_root() {
  if ((EUID != 0)); then
    have sudo || die "Root is required for disk operations and 'sudo' is not installed."
    echo "Root is needed for disk operations — re-running with sudo..."
    exec sudo -E bash "$0" "${ORIG_ARGS[@]}"
  fi
}

# ------------------------------------------------------------ device logic --
list_candidates() {   # prints: /dev/x|size|model|transport
  local d tran rmv size model
  while read -r d; do
    [[ -n $d ]] || continue
    tran=$(lsblk -dnro TRAN "$d" 2>/dev/null | head -1)
    rmv=$(lsblk -dnro RM "$d" 2>/dev/null | head -1)
    if ((ANY_DISK)) || [[ $tran == usb || $rmv == 1 ]]; then
      size=$(lsblk -dno SIZE "$d" 2>/dev/null | head -1 | xargs)
      model=$(lsblk -dno MODEL "$d" 2>/dev/null | head -1 | xargs)
      printf '%s|%s|%s|%s\n' "$d" "$size" "${model:-unknown}" "${tran:-?}"
    fi
  done < <(lsblk -dnpro NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}')
}

is_system_disk() {
  local mp
  while read -r mp; do
    case "$mp" in
      /|/boot|/boot/efi|/home|/usr|/var|/opt|\[SWAP\]) return 0 ;;
    esac
  done < <(lsblk -nro MOUNTPOINT "$1" 2>/dev/null)
  return 1
}

validate_device() {
  local dev="$1" type tran rmv size
  [[ -b $dev ]] || die "$dev is not a block device."
  type=$(lsblk -dnro TYPE "$dev" 2>/dev/null | head -1)
  [[ $type == disk ]] || die "$dev is a '$type', not a whole disk (use /dev/sdX, not /dev/sdX1)."
  is_system_disk "$dev" && die "$dev holds a system mount point (/, /boot, /home, swap...). Refusing."
  tran=$(lsblk -dnro TRAN "$dev" | head -1)
  rmv=$(lsblk -dnro RM "$dev" | head -1)
  if ((!ANY_DISK)) && [[ $tran != usb && $rmv != 1 ]]; then
    die "$dev is not a USB/removable disk. If you are 100% sure, add --any-disk."
  fi
  size=$(lsblk -bdno SIZE "$dev" | head -1)
  if ((size > 256 * 1024 * 1024 * 1024)); then
    log WARN "$dev is $(human "$size") — that is large for a USB stick. Double-check it."
  fi
}

choose_device() {
  if [[ -n $DEVICE ]]; then validate_device "$DEVICE"; return; fi
  local cands=() line i
  mapfile -t cands < <(list_candidates)
  ((${#cands[@]})) || die "No USB/removable disks found. Plug one in (or check 'lsblk')."
  [[ -t 0 ]] || die "Several steps need a choice but stdin is not a terminal. Pass --device /dev/sdX."
  echo
  echo "USB / removable disks:"
  for i in "${!cands[@]}"; do
    IFS='|' read -r d s m t <<<"${cands[i]}"
    printf '  %d) %-14s %8s  %-28s [%s]\n' "$((i + 1))" "$d" "$s" "$m" "$t"
  done
  local n
  while :; do
    read -rp "Select disk [1-${#cands[@]}] or q: " n
    [[ $n == q ]] && { log INFO "aborted by user"; exit 0; }
    if [[ $n =~ ^[0-9]+$ ]] && ((n >= 1 && n <= ${#cands[@]})); then
      DEVICE="${cands[n - 1]%%|*}"
      break
    fi
    echo "Invalid choice."
  done
  validate_device "$DEVICE"
}

has_ventoy() {
  local p1 p2
  p1=$(part_path "$1" 1); p2=$(part_path "$1" 2)
  [[ -b $p1 && -b $p2 ]] || return 1
  [[ $(lsblk -nro LABEL "$p2" 2>/dev/null | head -1) == VTOYEFI ]]
}

unmount_all() {
  local name mp
  while read -r name mp; do
    [[ -n $mp ]] || continue
    mp=$(printf '%b' "$mp")
    log INFO "unmounting $name ($mp)"
    run_cmd umount "$name" || die "Could not unmount $name. Close anything using it and retry."
  done < <(lsblk -nrpo NAME,MOUNTPOINT "$1" 2>/dev/null)
}

confirm_wipe() {
  local dev="$1" model size want
  model=$(lsblk -dno MODEL "$dev" | head -1 | xargs)
  size=$(lsblk -dno SIZE "$dev" | head -1 | xargs)
  want=$(basename "$dev")
  echo
  echo "${C_R}!! ALL DATA ON THIS DISK WILL BE DESTROYED !!${C_0}"
  echo "   device : $dev"
  echo "   model  : ${model:-unknown}"
  echo "   size   : $size"
  lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$dev" 2>/dev/null | sed 's/^/   /'
  echo
  if ((DRY_RUN)); then log DRY "would ask for typed confirmation of '$want'"; return 0; fi
  if ((ASSUME_YES && DEVICE_FROM_FLAG)); then
    log WARN "--yes with explicit --device: skipping typed confirmation for $dev"
    return 0
  fi
  [[ -t 0 ]] || die "Wipe confirmation needs a terminal (or --yes together with --device)."
  local typed
  read -rp "Type '$want' to confirm: " typed
  [[ $typed == "$want" ]] || die "Confirmation did not match. Nothing was changed."
}

# ------------------------------------------------------------------ ventoy --
find_ventoy_dir() {
  [[ -n $VENTOY_DIR ]] && return
  local cand
  for cand in "$ISO_DIR"/ventoy-*/ "$SCRIPT_DIR"/ventoy-*/ "$SCRIPT_DIR"/.cache/ventoy-*/ ./ventoy-*/; do
    if [[ -f ${cand}Ventoy2Disk.sh ]]; then VENTOY_DIR="${cand%/}"; return; fi
  done
}

fetch_ventoy() {
  have curl || die "curl is required to download Ventoy. Install it, or download manually and pass --ventoy-dir."
  local cache="$SCRIPT_DIR/.cache" api tag ver name base expected actual
  mkdir -p "$cache" || die "Cannot create $cache"
  api="https://api.github.com/repos/ventoy/Ventoy/releases/latest"
  log INFO "querying latest Ventoy release..."
  tag=$(curl -fsSL --retry 3 --max-time 30 "$api" 2>>"$LOG_FILE" | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')
  [[ -n $tag ]] || die "Could not determine the latest Ventoy version (network/rate limit?). Download from https://github.com/ventoy/Ventoy/releases and use --ventoy-dir."
  ver="${tag#v}"
  name="ventoy-${ver}-linux.tar.gz"
  base="https://github.com/ventoy/Ventoy/releases/download/${tag}"
  if [[ ! -f $cache/$name ]]; then
    log INFO "downloading $name"
    curl -fL --retry 3 -o "$cache/$name" "$base/$name" 2>>"$LOG_FILE" || { rm -f "$cache/$name"; die "Download failed: $base/$name"; }
  fi
  if curl -fsSL --retry 3 --max-time 30 -o "$cache/sha256.txt" "$base/sha256.txt" 2>>"$LOG_FILE"; then
    expected=$(grep -F "$name" "$cache/sha256.txt" | awk '{print $1}' | head -1)
    actual=$(sha256sum "$cache/$name" | awk '{print $1}')
    if [[ -n $expected && $expected == "$actual" ]]; then
      log OK "Ventoy checksum OK"
    elif [[ -n $expected ]]; then
      rm -f "$cache/$name"
      die "Ventoy checksum MISMATCH — deleted the download. Try again."
    else
      log WARN "No checksum entry for $name in sha256.txt — verify manually."
      confirm "Continue without checksum verification?" || die "Aborted."
    fi
  else
    log WARN "Could not fetch sha256.txt — download is unverified."
    confirm "Continue without checksum verification?" || die "Aborted."
  fi
  tar -xzf "$cache/$name" -C "$cache" || die "Could not extract $name"
  VENTOY_DIR="$cache/ventoy-${ver}"
  [[ -f $VENTOY_DIR/Ventoy2Disk.sh ]] || die "Ventoy2Disk.sh not found in $VENTOY_DIR"
  log OK "Ventoy ready at $VENTOY_DIR"
}

ensure_ventoy() {
  find_ventoy_dir
  if [[ -z $VENTOY_DIR ]]; then
    log WARN "Ventoy not found next to the ISOs or the script."
    if confirm "Download the latest Ventoy release now?"; then
      ((DRY_RUN)) && { log DRY "fetch latest Ventoy to $SCRIPT_DIR/.cache"; VENTOY_DIR="$SCRIPT_DIR/.cache/ventoy-<latest>"; return; }
      fetch_ventoy
    else
      die "Ventoy is required. Use --ventoy-dir PATH or run '$PROG fetch'."
    fi
  fi
  [[ -f $VENTOY_DIR/Ventoy2Disk.sh ]] || ((DRY_RUN)) || die "$VENTOY_DIR/Ventoy2Disk.sh not found."
  log INFO "using Ventoy from $VENTOY_DIR"
}

wait_for_block() {
  local p="$1" t=0
  while [[ ! -b $p ]]; do
    ((t++ >= 20)) && return 1
    sleep 1
    have udevadm && udevadm settle 2>/dev/null
    have partprobe && partprobe "$DEVICE" 2>/dev/null
  done
  return 0
}

run_ventoy2disk() {  # mode: -I (install, wipes) or -u (update, keeps data)
  local mode="$1" args=()
  args=("$mode")
  if [[ $mode == -I ]]; then
    args+=(-s)
    ((GPT)) && args+=(-g)
    ((RESERVE_MB > 0)) && args+=(-r "$RESERVE_MB")
    [[ -n $LABEL ]] && args+=(-L "$LABEL")
  fi
  args+=("$DEVICE")
  log INFO "Ventoy2Disk ${args[*]}"
  if ((DRY_RUN)); then
    log DRY "(cd $VENTOY_DIR && printf 'y\\ny\\n' | bash ./Ventoy2Disk.sh ${args[*]})"
    return 0
  fi
  local rc
  ( cd "$VENTOY_DIR" && printf 'y\ny\n' | bash ./Ventoy2Disk.sh "${args[@]}" ) 2>&1 | tee -a "$LOG_FILE"
  rc=${PIPESTATUS[0]}
  ((rc == 0)) || die "Ventoy2Disk failed (rc=$rc). The stick may be damaged, write-protected, or in use. See $LOG_FILE"
  have udevadm && udevadm settle 2>/dev/null
  sleep 2
  have partprobe && partprobe "$DEVICE" 2>/dev/null
  has_ventoy "$DEVICE" || { sleep 3; has_ventoy "$DEVICE"; } || die "Install finished but Ventoy partitions were not detected on $DEVICE."
  log OK "Ventoy installed/updated on $DEVICE"
}

prepare_device() {   # decides install / update / keep
  local do_install="$1" choice="k"
  if has_ventoy "$DEVICE"; then
    log INFO "$DEVICE already has Ventoy."
    if ((FORCE_REINSTALL)); then choice="r"
    elif ((FORCE_UPDATE)); then choice="u"
    elif ((do_install && !ASSUME_YES)) && [[ -t 0 ]]; then
      read -rp "[k]eep as-is and copy ISOs / [u]pdate Ventoy (keeps data) / [r]einstall (WIPES)? [k/u/r] " choice
      choice="${choice:-k}"
    fi
  else
    ((do_install)) || die "$DEVICE has no Ventoy install. Run '$PROG run' first (copy-only mode can't install)."
    choice="r"
  fi

  case "$choice" in
    k|K) log INFO "keeping existing Ventoy install" ;;
    u|U) ensure_ventoy; unmount_all "$DEVICE"; run_ventoy2disk -u ;;
    r|R) ensure_ventoy; confirm_wipe "$DEVICE"; unmount_all "$DEVICE"; run_ventoy2disk -I ;;
    *)   die "Unknown choice '$choice'." ;;
  esac
}

mount_data_partition() {
  local p1 mp
  p1=$(part_path "$DEVICE" 1)
  if ((DRY_RUN)); then MNT="(dry-run)"; return; fi
  wait_for_block "$p1" || die "Data partition $p1 never appeared."
  mp=$(lsblk -nro MOUNTPOINT "$p1" | head -1)
  if [[ -n $mp ]]; then
    MNT=$(printf '%b' "$mp")
    log INFO "$p1 already mounted at $MNT"
  else
    MNT=$(mktemp -d /tmp/stickyshift.XXXXXX) || die "mktemp failed"
    mount "$p1" "$MNT" 2>>"$LOG_FILE" || { rmdir "$MNT"; MNT=""; die "Could not mount $p1 (exFAT support in kernel? see log)."; }
    MOUNTED_BY_US=1
    log INFO "mounted $p1 at $MNT"
  fi
  check_writable "$MNT"
}

check_writable() {
  local probe="$1/.vk_write_test.$$"
  if ! { : >"$probe"; } 2>/dev/null; then
    die "$1 is not writable (read-only mount or write-protected stick)."
  fi
  rm -f "$probe"
}

# --------------------------------------------------------------- ISO logic --
scan_isos() {
  [[ -d $ISO_DIR ]] || {
    mkdir -p "$ISO_DIR" 2>/dev/null
    die "ISO folder '$ISO_DIR' did not exist — created it. Put your ISOs in there and run again."
  }
  local line
  ISO_NAMES=(); ISO_SIZES=()
  while IFS='|' read -r sz nm; do
    [[ -n $nm ]] || continue
    ISO_SIZES+=("$sz"); ISO_NAMES+=("$nm")
  done < <(find "$ISO_DIR" -maxdepth 1 -type f \( -iname '*.iso' -o -iname '*.img' -o -iname '*.wim' -o -iname '*.vhd' -o -iname '*.vhdx' -o -iname '*.efi' \) -printf '%s|%f\n' | sort -f -t'|' -k2)
  ((${#ISO_NAMES[@]})) || die "No .iso/.img/.wim/.vhd(x)/.efi files found in $ISO_DIR"
  log INFO "found ${#ISO_NAMES[@]} image(s) in $ISO_DIR"
}

free_bytes() {
  local dir="$1" dsz
  if ((DRY_RUN)) || [[ ! -d $dir ]]; then
    if [[ -n $DEVICE && -b $DEVICE ]]; then
      dsz=$(lsblk -bdno SIZE "$DEVICE" | head -1)
      echo $((dsz - RESERVE_MB * 1024 * 1024 - 33 * 1024 * 1024))
    else
      echo 0
    fi
    return
  fi
  df -B1 --output=avail "$dir" 2>/dev/null | tail -1 | tr -d ' '
}

select_isos() {
  local free="$1" i
  SELECTED=()
  if ((SELECT_ALL)); then SELECTED=("${ISO_NAMES[@]}"); return; fi
  [[ -t 0 ]] || die "No terminal to ask on. Pass --all to copy every image."
  echo
  echo "Images in $ISO_DIR   (free on stick: $(human "$free"))"
  for i in "${!ISO_NAMES[@]}"; do
    local flag=""
    [[ -f $ISO_DIR/${ISO_NAMES[i]}.sha256 ]] && flag=" ${C_D}(sha256 sidecar)${C_0}"
    printf '  %2d) %-50s %10s%s\n' "$((i + 1))" "${ISO_NAMES[i]}" "$(human "${ISO_SIZES[i]}")" "$flag"
  done
  local ans tok a b total idx
  declare -A pick
  while :; do
    pick=(); total=0
    read -rp "Pick (e.g. 1 3 5-7 | a=all | q=quit): " ans
    [[ $ans == q ]] && { log INFO "aborted by user"; exit 0; }
    local bad=0
    for tok in $ans; do
      if [[ $tok == a ]]; then
        for i in "${!ISO_NAMES[@]}"; do pick[$i]=1; done
      elif [[ $tok =~ ^([0-9]+)-([0-9]+)$ ]]; then
        a=${BASH_REMATCH[1]}; b=${BASH_REMATCH[2]}
        if ((a < 1 || b > ${#ISO_NAMES[@]} || a > b)); then bad=1; break; fi
        for ((i = a; i <= b; i++)); do pick[$((i - 1))]=1; done
      elif [[ $tok =~ ^[0-9]+$ ]] && ((tok >= 1 && tok <= ${#ISO_NAMES[@]})); then
        pick[$((tok - 1))]=1
      else
        bad=1; break
      fi
    done
    if ((bad || ${#pick[@]} == 0)); then echo "Invalid selection."; continue; fi
    for idx in "${!pick[@]}"; do total=$((total + ISO_SIZES[idx])); done
    if ((free > 0 && total > free)); then
      echo "${C_Y}Selection is $(human "$total") but only $(human "$free") is free. Pick less.${C_0}"
      continue
    fi
    echo "Selected ${#pick[@]} image(s), $(human "$total")."
    confirm "Copy them?" || continue
    for i in "${!ISO_NAMES[@]}"; do [[ -n ${pick[$i]:-} ]] && SELECTED+=("${ISO_NAMES[i]}"); done
    break
  done
}

check_source_sum() {   # verifies <file>.sha256 sidecar when present
  local f="$1" side="$1.sha256" want got
  [[ -f $side ]] || return 0
  want=$(awk '{print tolower($1); exit}' "$side")
  [[ $want =~ ^[0-9a-f]{64}$ ]] || { log WARN "unusable sidecar $side — ignoring"; return 0; }
  log INFO "checking source checksum: $(basename "$f")"
  got=$(sha256sum "$f" | awk '{print $1}')
  [[ $got == "$want" ]]
}

drop_caches() { sync; [[ -w /proc/sys/vm/drop_caches ]] && echo 3 >/proc/sys/vm/drop_caches 2>/dev/null; return 0; }

same_content() {   # size match, plus sha256 when --verify
  local a="$1" b="$2"
  [[ -f $b ]] || return 1
  [[ $(stat -c %s "$a") == "$(stat -c %s "$b")" ]] || return 1
  if ((VERIFY)); then
    drop_caches
    [[ $(sha256sum "$a" | awk '{print $1}') == "$(sha256sum "$b" | awk '{print $1}')" ]] || return 1
  fi
  return 0
}

copy_one() {
  local src="$1" dest_dir="$2" name dest attempt=1 max=3 rc
  name=$(basename "$src"); dest="$dest_dir/$name"
  while ((attempt <= max)); do
    log INFO "copying $name (attempt $attempt/$max)"
    if ((DRY_RUN)); then log DRY "copy $src -> $dest"; return 0; fi
    if have rsync; then
      rsync --partial --inplace --info=progress2 -- "$src" "$dest"; rc=$?
    else
      cp -- "$src" "$dest"; rc=$?
    fi
    if ((rc == 0)); then
      sync
      if same_content "$src" "$dest"; then return 0; fi
      log WARN "$name: verification failed after copy"
    else
      log WARN "$name: copy exited with rc=$rc"
    fi
    ((attempt++)); sleep 2
  done
  return 1
}

copy_isos() {
  local dest_dir="$1" name src size avail total=${#SELECTED[@]} n=0
  if ((DRY_RUN)); then :; else mkdir -p "$dest_dir" || die "Cannot create $dest_dir"; fi
  for name in "${SELECTED[@]}"; do
    ((n++))
    src="$ISO_DIR/$name"
    size=$(stat -c %s "$src" 2>/dev/null) || { log ERROR "cannot read $src"; FAILED+=("$name (unreadable)"); continue; }
    echo; log INFO "[$n/$total] $name ($(human "$size"))"

    if ! check_source_sum "$src"; then
      log ERROR "$name: source checksum MISMATCH — corrupt download? skipping"
      FAILED+=("$name (bad source checksum)"); continue
    fi

    if ((!DRY_RUN)) && same_content "$src" "$dest_dir/$name"; then
      log OK "$name already on the stick — skipped"
      SKIPPED+=("$name (already present)"); continue
    fi

    avail=$(free_bytes "$dest_dir")
    # an existing partial/older copy will be overwritten, so count it as free
    if [[ -f $dest_dir/$name ]]; then avail=$((avail + $(stat -c %s "$dest_dir/$name"))); fi
    if ((!DRY_RUN && avail > 0 && size > avail)); then
      log WARN "$name needs $(human "$size") but only $(human "$avail") is free — skipped"
      SKIPPED+=("$name (no space)"); continue
    fi

    if copy_one "$src" "$dest_dir"; then
      if ((DRY_RUN)); then log DRY "$name would be copied"; else log OK "$name copied"; fi
      COPIED+=("$name")
    else
      log ERROR "$name failed after retries"
      ((DRY_RUN)) || rm -f "$dest_dir/$name" 2>/dev/null
      FAILED+=("$name")
    fi
  done
}

copy_ventoy_json() {
  local src="$ISO_DIR/ventoy.json" dst_dir="$MNT/ventoy"
  [[ -f $src ]] || return 0
  log INFO "found ventoy.json — installing to the stick"
  if ((DRY_RUN)); then log DRY "cp $src $dst_dir/ventoy.json"; return 0; fi
  mkdir -p "$dst_dir" && cp -f -- "$src" "$dst_dir/ventoy.json" && log OK "ventoy.json installed" \
    || log WARN "could not copy ventoy.json"
}

summary() {
  echo
  echo "────────────────────────── summary ──────────────────────────"
  printf ' copied : %d\n skipped: %d\n failed : %d\n' "${#COPIED[@]}" "${#SKIPPED[@]}" "${#FAILED[@]}"
  local x
  for x in "${COPIED[@]}";  do echo "   ${C_G}+${C_0} $x"; done
  for x in "${SKIPPED[@]}"; do echo "   ${C_Y}~${C_0} $x"; done
  for x in "${FAILED[@]}";  do echo "   ${C_R}x${C_0} $x"; done
  echo " log    : $LOG_FILE"
  echo "──────────────────────────────────────────────────────────────"
  log INFO "summary: copied=${#COPIED[@]} skipped=${#SKIPPED[@]} failed=${#FAILED[@]}"
  if ((${#FAILED[@]})); then return 1; fi
  return 0
}

# ---------------------------------------------------------------- commands --
cmd_list() {
  local cands=() i d s m t
  mapfile -t cands < <(list_candidates)
  if ((${#cands[@]} == 0)); then echo "No USB/removable disks found."; return 0; fi
  printf '%-14s %9s  %-28s %s\n' DEVICE SIZE MODEL TRAN
  for i in "${!cands[@]}"; do
    IFS='|' read -r d s m t <<<"${cands[i]}"
    printf '%-14s %9s  %-28s %s\n' "$d" "$s" "$m" "$t"
  done
}

cmd_fetch() { fetch_ventoy; echo "$VENTOY_DIR"; }

cmd_run() {   # $1 = 1 (install if needed) | 0 (copy only)
  local do_install="$1" free dest_dir
  scan_isos

  if [[ -n $TARGET_DIR ]]; then
    [[ -d $TARGET_DIR ]] || die "--target-dir '$TARGET_DIR' is not a directory."
    check_writable "$TARGET_DIR"
    MNT="$TARGET_DIR"
    log INFO "copy-only mode into directory $MNT"
  else
    choose_device
    log INFO "target disk: $DEVICE"
    prepare_device "$do_install"
    mount_data_partition
  fi

  free=$(free_bytes "$MNT")
  select_isos "$free"
  ((${#SELECTED[@]})) || die "Nothing selected."

  dest_dir="$MNT/ISO"
  copy_isos "$dest_dir"
  copy_ventoy_json
  ((DRY_RUN)) || sync
  summary
}

usage() {
  banner
  cat <<EOF

  $PROG $VERSION — put ISOs in a folder, pick a stick, done. (uses Ventoy)

USAGE
  sudo ./$PROG.sh [command] [options]

COMMANDS
  run      (default) install/update Ventoy if needed, then copy the images
  copy     copy images only; the stick must already have Ventoy
  list     show USB/removable disks that would be offered
  fetch    download + verify the latest Ventoy into ./.cache

OPTIONS
  -i, --iso-dir DIR     folder with your ISOs            (default: ./isos)
  -d, --device DEV      e.g. /dev/sdb; skips the disk menu
  -t, --target-dir DIR  copy into an already-mounted dir instead of a device
  -V, --ventoy-dir DIR  extracted Ventoy folder (has Ventoy2Disk.sh)
  -r, --reserve MB      leave MB free at the end of the stick (fresh install only)
      --gpt             use GPT instead of MBR (fresh install only)
      --label NAME      data partition label            (default: Ventoy)
      --update          non-destructive Ventoy update if already installed
      --reinstall       wipe and reinstall even if Ventoy is present
  -a, --all             copy every image, don't ask
      --verify          sha256-compare source and copy (slower, safer)
      --any-disk        allow non-USB disks   (dangerous; you were warned)
  -y, --yes             no prompts (typed wipe check is skipped only if --device is given)
  -n, --dry-run         print what would happen, change nothing
      --log-dir DIR     where to write logs              (default: ./logs)
  -h, --help            this text
  -v, --version

EXAMPLES
  sudo ./$PROG.sh                                  # fully interactive
  sudo ./$PROG.sh -i ~/Downloads/isos -r 4096      # keep 4 GiB free for tools
  sudo ./$PROG.sh copy -d /dev/sdb --all --verify  # refresh ISOs on a ready stick
  ./$PROG.sh -n -d /dev/sdb --all                  # dry run, no root needed

SIDECARS (optional, in the ISO folder)
  <image>.sha256   expected hash; a mismatch skips that image
  ventoy.json      copied to <stick>/ventoy/ventoy.json
EOF
}

# -------------------------------------------------------------------- main --
parse_args() {
  if (($# > 0)) && [[ $1 != -* ]]; then CMD="$1"; shift; fi
  while (($#)); do
    case "$1" in
      -i|--iso-dir)     [[ $# -ge 2 ]] || die "$1 needs a value"; ISO_DIR="$2"; shift 2 ;;
      -d|--device)      [[ $# -ge 2 ]] || die "$1 needs a value"; DEVICE="$2"; DEVICE_FROM_FLAG=1; shift 2 ;;
      -t|--target-dir)  [[ $# -ge 2 ]] || die "$1 needs a value"; TARGET_DIR="$2"; shift 2 ;;
      -V|--ventoy-dir)  [[ $# -ge 2 ]] || die "$1 needs a value"; VENTOY_DIR="$2"; shift 2 ;;
      -r|--reserve)     [[ $# -ge 2 && $2 =~ ^[0-9]+$ ]] || die "$1 needs a number (MB)"; RESERVE_MB="$2"; shift 2 ;;
      --label)          [[ $# -ge 2 ]] || die "$1 needs a value"; LABEL="$2"; shift 2 ;;
      --log-dir)        [[ $# -ge 2 ]] || die "$1 needs a value"; LOG_DIR="$2"; shift 2 ;;
      --gpt)            GPT=1; shift ;;
      --update)         FORCE_UPDATE=1; shift ;;
      --reinstall)      FORCE_REINSTALL=1; shift ;;
      -a|--all)         SELECT_ALL=1; shift ;;
      --verify)         VERIFY=1; shift ;;
      --any-disk)       ANY_DISK=1; shift ;;
      -y|--yes)         ASSUME_YES=1; shift ;;
      -n|--dry-run)     DRY_RUN=1; shift ;;
      -h|--help)        usage; exit 0 ;;
      -v|--version)     echo "$PROG $VERSION"; exit 0 ;;
      *)                echo "Unknown option: $1 (try --help)" >&2; exit 2 ;;
    esac
  done
}

main() {
  parse_args "$@"
  case "$CMD" in
    help) usage; exit 0 ;;
    run|copy|list|fetch) ;;
    *) echo "Unknown command: $CMD (try --help)" >&2; exit 2 ;;
  esac

  if ((BASH_VERSINFO[0] < 4)); then echo "bash 4+ required." >&2; exit 2; fi
  [[ $(uname -s) == Linux ]] || { echo "Linux only." >&2; exit 2; }
  for t in lsblk sha256sum df stat find awk; do have "$t" || { echo "Missing required tool: $t" >&2; exit 2; }; done

  # root is needed whenever we touch a real device for real
  if [[ $CMD == run || $CMD == copy ]] && [[ -z $TARGET_DIR ]] && ((!DRY_RUN)); then need_root; fi

  init_log
  banner
  log INFO "$PROG $VERSION | cmd=$CMD dry_run=$DRY_RUN verify=$VERIFY"

  case "$CMD" in
    list)  cmd_list ;;
    fetch) cmd_fetch ;;
    run)   cmd_run 1 ;;
    copy)  cmd_run 0 ;;
  esac
}

main "$@"
