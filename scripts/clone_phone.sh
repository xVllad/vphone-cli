#!/bin/zsh
# clone_independent.sh — Clone a VM instance with a new identity.
#
# Unlike clone_instance.sh (which copies machineIdentifier as-is), this script
# clears the machineIdentifier in config.plist so vphone-cli generates a brand-new
# ECID/UDID on first boot.  Both the source and the clone can run simultaneously.
# The clone's directory name is also set as the VM name in config.plist.
#
# Usage:
#   zsh scripts/clone_independent.sh <source> <destination> [--count N]
#
# Examples:
#   zsh scripts/clone_independent.sh iphone_01 iphone_02
#   zsh scripts/clone_independent.sh iphone_01 iphone --count 5
#     → creates iphone_1, iphone_2, iphone_3, iphone_4, iphone_5

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

die()  { echo "[-] $*" >&2; exit 1; }
info() { echo "[*] $*"; }
ok()   { echo "[+] $*"; }

# ─── Usage ───────────────────────────────────────────────────────
usage() {
  cat <<'EOF'
Usage: clone_independent.sh <source> <destination> [--count N]

  <source>       Existing VM directory (e.g. iphone_01 or vm)
  <destination>  New VM directory to create (e.g. iphone_02)
                 With --count, used as a base name: iphone_1, iphone_2, ...

Options:
  --count N   Number of clones to create (default: 1)

Both paths are relative to the project root unless absolute.

Notes:
  - Each clone gets a FRESH machineIdentifier (new ECID/UDID) generated on first boot.
  - The clone's directory name is set as the VM name in config.plist.
  - Source and clones can run simultaneously — they have distinct identities.
  - The large iPhone*_Restore IPSW folder is NOT copied (not needed for booting).
    Copy it manually if you want to be able to re-restore the clone.
EOF
  exit 1
}

# ─── Parse args ──────────────────────────────────────────────────
[[ $# -ge 2 ]] || usage

SRC="$1"
DST_BASE="$2"
shift 2

COUNT=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --count)
      [[ $# -ge 2 ]] || die "--count requires a value"
      COUNT="$2"
      [[ "$COUNT" =~ ^[1-9][0-9]*$ ]] || die "Invalid --count: ${COUNT} (must be a positive integer)"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      die "Unknown option: $1  (run with --help for usage)"
      ;;
  esac
done

cd "$PROJECT_ROOT"
[[ "$SRC" == /* ]] || SRC="${PROJECT_ROOT}/${SRC}"
[[ "$DST_BASE" == /* ]] || DST_BASE="${PROJECT_ROOT}/${DST_BASE}"

# ─── Validate source ─────────────────────────────────────────────
[[ -d "$SRC" ]]            || die "Source does not exist: ${SRC}"
[[ -f "${SRC}/Disk.img" ]] || die "Source missing Disk.img: ${SRC}"

if command -v lsof >/dev/null 2>&1; then
  local_locks="$(lsof -t -- "${SRC}/Disk.img" "${SRC}/nvram.bin" 2>/dev/null | grep -v "^$$\$" || true)"
  [[ -z "$local_locks" ]] || die "Source VM is running (locked files in ${SRC}). Shut it down first."
fi

# ─── Detect APFS clone support ───────────────────────────────────
CP_FILE_FLAGS="-a"
CP_DIR_FLAGS="-a"
APFS_CLONE=0

if ! cp --version 2>/dev/null | grep -q GNU; then
  _apfs_src="${PROJECT_ROOT}/.vphone_apfs_src_$$"
  _apfs_dst="${PROJECT_ROOT}/.vphone_apfs_dst_$$"
  touch "$_apfs_src"
  if cp -c "$_apfs_src" "$_apfs_dst" 2>/dev/null; then
    CP_FILE_FLAGS="-ac"
    CP_DIR_FLAGS="-ac"
    APFS_CLONE=1
  fi
  rm -f "$_apfs_src" "$_apfs_dst" 2>/dev/null || true
fi

# ─── Pre-flight summary ──────────────────────────────────────────
SRC_NAME="${SRC:t}"
DISK_ACTUAL="$(du -sh "${SRC}/Disk.img" 2>/dev/null | cut -f1 || echo "?")"
DISK_BYTES="$(stat -f %z "${SRC}/Disk.img" 2>/dev/null || echo 0)"

RESTORE_DIRS=("${SRC}"/iPhone*_Restore(N))

echo ""
echo "  Source:  ${SRC_NAME}"
echo "  Clones:  ${COUNT}"
if (( COUNT == 1 )); then
  echo "  Name:    ${DST_BASE:t}"
else
  echo "  Names:   ${DST_BASE:t}_1  …  ${DST_BASE:t}_${COUNT}"
fi
echo "  Disk:    ${DISK_ACTUAL} actual  ($(( DISK_BYTES / 1024 / 1024 / 1024 ))G logical)"
if (( ${#RESTORE_DIRS[@]} > 0 )); then
  RESTORE_SIZE="$(du -sh "${RESTORE_DIRS[1]}" 2>/dev/null | cut -f1 || echo "?")"
  echo "  Skip:    ${RESTORE_DIRS[1]:t}/ (${RESTORE_SIZE} — not needed for boot)"
fi
if (( APFS_CLONE )); then
  echo "  Method:  APFS copy-on-write clone (fast)"
else
  echo "  Method:  rsync with progress"
fi
echo ""

# ─── Helpers ─────────────────────────────────────────────────────
copy_file() {
  local src_file="$1" dst_file="$2" label="${1:t}"
  [[ -e "$src_file" ]] || return 0
  info "Copying ${label}..."
  cp ${=CP_FILE_FLAGS} "$src_file" "$dst_file"
  ok "  ${label} done"
}

copy_dir() {
  local src_dir="$1" dst_dir="$2" label="${1:t}"
  [[ -d "$src_dir" ]] || return 0
  info "Copying ${label}/..."
  cp ${=CP_DIR_FLAGS} "$src_dir" "$dst_dir"
  ok "  ${label}/ done"
}

copy_disk() {
  local src_file="$1" dst_file="$2"
  info "Copying Disk.img  (${DISK_ACTUAL} data)..."

  if (( APFS_CLONE )); then
    cp -c "$src_file" "$dst_file" &
    local cp_pid=$!
    local spin=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏') i=0
    while kill -0 $cp_pid 2>/dev/null; do
      printf "\r  %s  APFS clone in progress..." "${spin[$(( i % ${#spin[@]} + 1 ))]}"
      sleep 0.1
      (( ++i )) || true
    done
    wait $cp_pid
    printf "\r  %-60s\n" "APFS clone done (copy-on-write, no data transferred)"
  else
    rsync -a --sparse --progress "$src_file" "$dst_file"
    echo ""
  fi

  ok "  Disk.img done"
}

# ─── Clone one instance ──────────────────────────────────────────
clone_one() {
  local dst="$1"
  local dst_name="${dst:t}"

  # Validate destination
  if [[ -d "$dst" ]]; then
    echo "[!] Destination already exists: ${dst_name}"
    echo -n "[?] Overwrite? [y/N] "
    read -r answer
    [[ "${answer:l}" == "y" ]] || die "Aborted."
    rm -rf "$dst"
  fi

  mkdir -p "$dst"

  copy_disk "${SRC}/Disk.img" "${dst}/Disk.img"

  # Boot-critical files
  copy_file "${SRC}/nvram.bin"                   "${dst}/nvram.bin"
  copy_file "${SRC}/SEPStorage"                  "${dst}/SEPStorage"
  copy_file "${SRC}/AVPBooter.vresearch1.bin"    "${dst}/AVPBooter.vresearch1.bin"
  copy_file "${SRC}/AVPSEPBooter.vresearch1.bin" "${dst}/AVPSEPBooter.vresearch1.bin"

  # CFW support files
  copy_dir  "${SRC}/shsh"          "${dst}/shsh"
  copy_dir  "${SRC}/cfw_input"     "${dst}/cfw_input"
  copy_dir  "${SRC}/cfw_jb_input"  "${dst}/cfw_jb_input"
  copy_dir  "${SRC}/Ramdisk"       "${dst}/Ramdisk"
  copy_dir  "${SRC}/ramdisk_input" "${dst}/ramdisk_input"

  # Anything else at root (skip restore folder, logs, setup_logs, identity files)
  for f in "${SRC}"/*; do
    fname="${f:t}"
    [[ -e "${dst}/${fname}" ]]              && continue
    [[ "$fname" == iPhone*_Restore ]]       && continue
    [[ "$fname" == *.log ]]                 && continue
    [[ "$fname" == setup_logs ]]            && continue
    # Identity files handled explicitly below
    [[ "$fname" == config.plist ]]          && continue
    [[ "$fname" == machineIdentifier.bin ]] && continue
    [[ "$fname" == udid-prediction.txt ]]   && continue
    if [[ -f "$f" ]]; then
      copy_file "$f" "${dst}/${fname}"
    elif [[ -d "$f" ]]; then
      copy_dir "$f" "${dst}/${fname}"
    fi
  done

  # ── New identity: clear machineIdentifier, set name in config.plist ──
  info "Generating new VM identity..."

  if [[ -f "${SRC}/config.plist" ]]; then
    python3 - "${SRC}/config.plist" "${dst}/config.plist" "$dst_name" <<'PYEOF'
import sys, plistlib

src_path, dst_path, vm_name = sys.argv[1], sys.argv[2], sys.argv[3]

with open(src_path, "rb") as f:
    manifest = plistlib.load(f)

# Clear machineIdentifier — vphone-cli generates a fresh ECID/UDID on first boot.
manifest["machineIdentifier"] = b""

# Reset MAC address — framework assigns a fresh one.
if "networkConfig" in manifest and "macAddress" in manifest["networkConfig"]:
    manifest["networkConfig"]["macAddress"] = ""

# Set the VM name to match the clone directory name.
manifest["name"] = vm_name

with open(dst_path, "wb") as f:
    plistlib.dump(manifest, f)

print(f"[+]   config.plist written (name={vm_name}, cleared machineIdentifier)")
PYEOF
  else
    # Source predates the manifest system — generate a fresh config.plist.
    info "Source has no config.plist — generating default manifest..."
    python3 "${SCRIPT_DIR}/vm_manifest.py" --vm-dir "${dst}"
    ok "  config.plist generated with defaults"
  fi

  # Remove legacy machineIdentifier.bin if present
  if [[ -f "${dst}/machineIdentifier.bin" ]]; then
    rm -f "${dst}/machineIdentifier.bin"
    ok "  machineIdentifier.bin removed"
  fi

  # Remove udid-prediction.txt — it belonged to the source's UDID
  if [[ -f "${dst}/udid-prediction.txt" ]]; then
    rm -f "${dst}/udid-prediction.txt"
    ok "  udid-prediction.txt removed (new UDID assigned on first boot)"
  fi

  ok "  New identity ready (name=${dst_name})"

  echo ""
  ok "Clone complete: ${dst_name}"
  echo "  To boot:        make boot VM_DIR=${dst_name}"
  echo "  CFW install:    make cfw_install VM_DIR=${dst_name}"
  echo ""
}

# ─── Run ─────────────────────────────────────────────────────────
if (( COUNT == 1 )); then
  clone_one "$DST_BASE"
else
  for i in $(seq 1 "$COUNT"); do
    echo "── Clone ${i}/${COUNT} ──────────────────────────────────────────────"
    clone_one "${DST_BASE}_${i}"
  done
  echo ""
  ok "All ${COUNT} clones complete."
  echo ""
fi
