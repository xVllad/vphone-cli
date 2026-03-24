#!/bin/zsh
# clone_independent.sh — Clone a VM instance with a new identity.
#
# Unlike clone_instance.sh (which copies machineIdentifier as-is), this script
# clears the machineIdentifier in config.plist so vphone-cli generates a brand-new
# ECID/UDID on first boot.  Both the source and the clone can run simultaneously.
#
# Usage:
#   zsh scripts/clone_independent.sh <source> <destination>
#
# Examples:
#   zsh scripts/clone_independent.sh iphone_01 iphone_02
#   zsh scripts/clone_independent.sh vm iphone_backup

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

die()  { echo "[-] $*" >&2; exit 1; }
info() { echo "[*] $*"; }
ok()   { echo "[+] $*"; }

# ─── Usage ───────────────────────────────────────────────────────
usage() {
  cat <<'EOF'
Usage: clone_independent.sh <source> <destination>

  <source>       Existing VM directory (e.g. iphone_01 or vm)
  <destination>  New VM directory to create (e.g. iphone_02)

Both paths are relative to the project root unless absolute.

Notes:
  - The clone gets a FRESH machineIdentifier (new ECID/UDID) generated on first boot.
  - Source and clone can run simultaneously — they have distinct identities.
  - The large iPhone*_Restore IPSW folder is NOT copied (not needed for booting).
    Copy it manually if you want to be able to re-restore the clone.
EOF
  exit 1
}

# ─── Parse args ──────────────────────────────────────────────────
[[ $# -ge 2 ]] || usage

SRC="$1"
DST="$2"
shift 2

while [[ $# -gt 0 ]]; do
  case "$1" in
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
[[ "$DST" == /* ]] || DST="${PROJECT_ROOT}/${DST}"

# ─── Validate source ─────────────────────────────────────────────
[[ -d "$SRC" ]]            || die "Source does not exist: ${SRC}"
[[ -f "${SRC}/Disk.img" ]] || die "Source missing Disk.img: ${SRC}"

if command -v lsof >/dev/null 2>&1; then
  local_locks="$(lsof -t -- "${SRC}/Disk.img" "${SRC}/nvram.bin" 2>/dev/null | grep -v "^$$\$" || true)"
  [[ -z "$local_locks" ]] || die "Source VM is running (locked files in ${SRC}). Shut it down first."
fi

# ─── Validate destination ─────────────────────────────────────────
if [[ -d "$DST" ]]; then
  echo "[!] Destination already exists: ${DST}"
  echo -n "[?] Overwrite? [y/N] "
  read -r answer
  [[ "${answer:l}" == "y" ]] || die "Aborted."
  rm -rf "$DST"
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

# ─── Show plan ───────────────────────────────────────────────────
SRC_NAME="${SRC:t}"
DST_NAME="${DST:t}"

DISK_ACTUAL="$(du -sh "${SRC}/Disk.img" 2>/dev/null | cut -f1 || echo "?")"
DISK_BYTES="$(stat -f %z "${SRC}/Disk.img" 2>/dev/null || echo 0)"

echo ""
echo "  Source:      ${SRC_NAME}"
echo "  Destination: ${DST_NAME}"
echo "  Disk.img:    ${DISK_ACTUAL} actual data  ($(( DISK_BYTES / 1024 / 1024 / 1024 ))G logical)"
echo "  Identity:    NEW (fresh machineIdentifier generated on first boot)"

RESTORE_DIRS=("${SRC}"/iPhone*_Restore(N))
if (( ${#RESTORE_DIRS[@]} > 0 )); then
  RESTORE_SIZE="$(du -sh "${RESTORE_DIRS[1]}" 2>/dev/null | cut -f1 || echo "?")"
  echo "  Skipping:    ${RESTORE_DIRS[1]:t}/ (${RESTORE_SIZE} — not needed for boot)"
fi

if (( APFS_CLONE )); then
  echo "  Method:      APFS copy-on-write clone (fast)"
else
  echo "  Method:      rsync with progress"
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

# ─── Copy ────────────────────────────────────────────────────────
mkdir -p "$DST"

copy_disk "${SRC}/Disk.img" "${DST}/Disk.img"

# Boot-critical files
copy_file "${SRC}/nvram.bin"                   "${DST}/nvram.bin"
copy_file "${SRC}/SEPStorage"                  "${DST}/SEPStorage"
copy_file "${SRC}/AVPBooter.vresearch1.bin"    "${DST}/AVPBooter.vresearch1.bin"
copy_file "${SRC}/AVPSEPBooter.vresearch1.bin" "${DST}/AVPSEPBooter.vresearch1.bin"

# CFW support files
copy_dir  "${SRC}/shsh"          "${DST}/shsh"
copy_dir  "${SRC}/cfw_input"     "${DST}/cfw_input"
copy_dir  "${SRC}/cfw_jb_input"  "${DST}/cfw_jb_input"
copy_dir  "${SRC}/Ramdisk"       "${DST}/Ramdisk"
copy_dir  "${SRC}/ramdisk_input" "${DST}/ramdisk_input"

# Anything else at root (skip restore folder, logs, setup_logs, identity files)
for f in "${SRC}"/*; do
  fname="${f:t}"
  [[ -e "${DST}/${fname}" ]]              && continue
  [[ "$fname" == iPhone*_Restore ]]       && continue
  [[ "$fname" == *.log ]]                 && continue
  [[ "$fname" == setup_logs ]]            && continue
  # Identity files handled explicitly below
  [[ "$fname" == config.plist ]]          && continue
  [[ "$fname" == machineIdentifier.bin ]] && continue
  [[ "$fname" == udid-prediction.txt ]]   && continue
  if [[ -f "$f" ]]; then
    copy_file "$f" "${DST}/${fname}"
  elif [[ -d "$f" ]]; then
    copy_dir "$f" "${DST}/${fname}"
  fi
done

# ─── New identity: clear machineIdentifier in config.plist ───────
info "Generating new VM identity..."

if [[ -f "${SRC}/config.plist" ]]; then
  python3 - "${SRC}/config.plist" "${DST}/config.plist" <<'PYEOF'
import sys, plistlib

src_path, dst_path = sys.argv[1], sys.argv[2]

with open(src_path, "rb") as f:
    manifest = plistlib.load(f)

# Clear machineIdentifier — vphone-cli generates a fresh ECID/UDID on first boot.
manifest["machineIdentifier"] = b""

# Reset MAC address — framework assigns a fresh one.
if "networkConfig" in manifest and "macAddress" in manifest["networkConfig"]:
    manifest["networkConfig"]["macAddress"] = ""

with open(dst_path, "wb") as f:
    plistlib.dump(manifest, f)

print("[+]   config.plist written with cleared machineIdentifier")
PYEOF
else
  # Source predates the manifest system — generate a fresh config.plist.
  info "Source has no config.plist — generating default manifest..."
  python3 "${SCRIPT_DIR}/vm_manifest.py" --vm-dir "${DST}"
  ok "  config.plist generated with defaults"
fi

# Remove legacy machineIdentifier.bin if present
if [[ -f "${DST}/machineIdentifier.bin" ]]; then
  rm -f "${DST}/machineIdentifier.bin"
  ok "  machineIdentifier.bin removed"
fi

# Remove udid-prediction.txt — it belonged to the source's UDID
if [[ -f "${DST}/udid-prediction.txt" ]]; then
  rm -f "${DST}/udid-prediction.txt"
  ok "  udid-prediction.txt removed (new UDID assigned on first boot)"
fi

ok "  New identity ready"

# ─── Summary ─────────────────────────────────────────────────────
echo ""
ok "Clone complete: ${DST_NAME}"
echo ""
echo "  This instance has a NEW identity — it can run alongside ${SRC_NAME}."
echo ""
echo "  To boot:"
echo "    make boot VM_DIR=${DST_NAME}"
echo ""
echo "  CFW install:"
echo "    make cfw_install VM_DIR=${DST_NAME}"
echo ""
