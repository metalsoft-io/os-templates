#!/usr/bin/env bash
# create-golden-template.sh: package a golden image and create a MetalSoft golden image OS template.
#
# Runs steps 1-6 of "Registering a golden image OS template": checks the image, packages it, uploads it
# (optional), writes the template directory from the built-in Linux or Windows example, checks it with
# `metalcloud-cli os-template list-directory` and creates it with `create-from-directory`.
#
# Needs: bash, metalcloud-cli configured for your controller (METALCLOUD_ENDPOINT and METALCLOUD_API_KEY),
# xorriso (to package), zstd (for zstd images), qemu-img (only to convert qcow2/VMDK/VHDX), scp (only with
# --upload), curl (only to check the uploaded URL). Works on Linux and macOS.

set -euo pipefail

VERSION="1.0"
MC_CLI="${MC_CLI:-metalcloud-cli}"   # the CLI command; override it to add global flags

usage() {
    cat <<'EOF'
Usage: create-golden-template.sh [options]

Run it in a terminal without options and it asks for everything it needs, checks each answer, shows a
summary and asks before changing anything. Any option you give is used instead of asking.

Image (one of):
  --image FILE          the golden image: .raw/.img, .raw.zst/.img.zst, or .qcow2/.vmdk/.vhdx (converted to raw)
  --image-url URL       an image ISO (or .img) that's already packaged and hosted; skips steps 1-3

Template:
  --os linux|windows    which built-in example to use (cloud-init or Cloudbase-Init)
  --label LABEL         template label, unique on the controller (lowercase letters, digits, hyphens)
  --name NAME           template name (default: the label)
  --description TEXT    template description
  --os-name NAME        os.name (default: linux-golden-image or windows-golden-image);
                        never exactly windows, rhel or redhat
  --os-version VERSION  os.version (default: 1.0)
  --boot-iso-url URL    the boot ISO (default: https://repo.metalsoft.io/.iso/boot-golden-image.iso)

First-boot files (rendered for each server, with the variables described in the guide):
  --user-data FILE      your own user-data instead of the built-in example's
  --meta-data FILE      your own meta-data instead of the built-in example's
  --network-config FILE your own network-config instead of the built-in example's
                        Any you don't give comes from the example. Asked when you run it without options.

Packaging and upload (with --image):
  --url-base URL        where the packaged file will be served from, e.g. https://repo.example.com/images;
                        the image URL is <url-base>/<file name>
  --upload DEST         copy the packaged file with scp to DEST (user@host:/path) before creating the template
  --no-upload           don't ask about uploading; you upload the file yourself
  --package iso|img     iso (default): an ISO labeled OSIMAGE, works with any BMC that mounts two images;
                        img: the image file itself named .img, padded if zstd; tested on Dell iDRAC only
  --compress            compress a raw image with zstd before packaging (recommended for large images)
  --no-compress         don't compress, and don't ask
  --work-dir DIR        where packaged files go (default: ./golden-work)

Other:
  --templates-dir DIR   where the template directory is written (default: ./golden-templates)
  --check-only          only check the image (step 1) and exit
  --dry-run             do everything except creating the template on the controller
  --no-prompt           never ask: fail if something required is missing (for scripts and CI)
  --interactive         ask even when input isn't a terminal
  --yes                 don't ask for confirmation before making changes
  --version             print the script's version
  -h, --help            show this help

Examples:
  create-golden-template.sh
  create-golden-template.sh --os linux --label rocky-9-golden-v1 --image rocky-9.raw.zst \
      --url-base https://repo.example.com/images --upload me@repo.example.com:/var/www/images
  create-golden-template.sh --no-prompt --os windows --label ws2025-golden-v1 --os-version 2025 \
      --image-url https://repo.example.com/images/ws2025-golden-v1.raw.zst.iso

Give every new image version a new file name and a new label: downloads are reused by file name, and the
URL is never checked for a newer file.
EOF
}

log()  { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '    WARNING: %s\n' "$*" >&2; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required${2:+ ($2)}"; }
file_size() { wc -c < "$1" | tr -d ' '; }

# --------------------------------------------------------------------------------------------------------
# Arguments
# --------------------------------------------------------------------------------------------------------

OS_FAMILY="" LABEL="" NAME="" DESCRIPTION="" OS_NAME="" OS_VERSION="" BOOT_ISO_URL=""
IMAGE="" IMAGE_URL="" URL_BASE="" UPLOAD="" NO_UPLOAD=0 PACKAGE="" COMPRESS="" SOURCE="" ANSWER=""
WORK_DIR="./golden-work" TEMPLATES_DIR="./golden-templates" TEMPLATES_DIR_SET=0 CHECK_ONLY=0 DRY_RUN=0
NO_PROMPT=0 INTERACTIVE=0 ASSUME_YES=0
USER_DATA_FILE="" META_DATA_FILE="" NETWORK_CONFIG_FILE="" FILES_CHOICE=""
DEFAULT_BOOT_ISO_URL="https://repo.metalsoft.io/.iso/boot-golden-image.iso"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --compress|--no-compress|--no-upload|--check-only|--dry-run|--no-prompt|--interactive|--yes|--version|-h|--help) ;;
        --*) [[ $# -ge 2 && "${2:0:2}" != "--" ]] || die "$1 needs a value" ;;
    esac
    case "$1" in
        --os) OS_FAMILY="$2"; shift 2 ;;
        --label) LABEL="$2"; shift 2 ;;
        --name) NAME="$2"; shift 2 ;;
        --description) DESCRIPTION="$2"; shift 2 ;;
        --os-name) OS_NAME="$2"; shift 2 ;;
        --os-version) OS_VERSION="$2"; shift 2 ;;
        --boot-iso-url) BOOT_ISO_URL="$2"; shift 2 ;;
        --user-data) USER_DATA_FILE="$2"; shift 2 ;;
        --meta-data) META_DATA_FILE="$2"; shift 2 ;;
        --network-config) NETWORK_CONFIG_FILE="$2"; shift 2 ;;
        --image) IMAGE="$2"; shift 2 ;;
        --image-url) IMAGE_URL="$2"; shift 2 ;;
        --url-base) URL_BASE="$2"; shift 2 ;;
        --upload) UPLOAD="$2"; shift 2 ;;
        --no-upload) NO_UPLOAD=1; shift ;;
        --package) PACKAGE="$2"; shift 2 ;;
        --compress) COMPRESS=1; shift ;;
        --no-compress) COMPRESS=0; shift ;;
        --work-dir) WORK_DIR="$2"; shift 2 ;;
        --templates-dir) TEMPLATES_DIR="$2"; TEMPLATES_DIR_SET=1; shift 2 ;;
        --check-only) CHECK_ONLY=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --no-prompt) NO_PROMPT=1; shift ;;
        --interactive) INTERACTIVE=1; shift ;;
        --yes) ASSUME_YES=1; shift ;;
        --version) echo "create-golden-template.sh $VERSION"; exit 0 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown option: $1" ;;
    esac
done

# --------------------------------------------------------------------------------------------------------
# Step 1: check the image
# --------------------------------------------------------------------------------------------------------

magic_of() { head -c 4 "$1" | od -An -tx1 | tr -d ' \n'; }

# GPT partition type GUIDs as stored on disk (first three fields little-endian)
GUID_ESP="28732ac11ff8d211ba4b00a0c93ec93b"
GUID_WIN_RECOVERY="a4bb94ded106404da16abfd50179d6ac"
GUID_LINUX_SWAP="6dfd5706aba4c44384e50933c84b4f4f"

le() {  # le FILE OFFSET BYTES: unsigned little-endian integer at OFFSET
    local hex b
    hex="$(od -An -tx1 -j "$2" -N "$3" "$1" | tr -d ' \n')"
    local out=""
    for ((b = ${#hex} - 2; b >= 0; b -= 2)); do out="${out}${hex:$b:2}"; done
    printf '%d' "$((16#${out:-0}))"
}

check_gpt() {  # check_gpt FILE: FILE holds at least the first MiB of the raw disk image
    local f="$1" sig entries_lba count esize i off type first
    sig="$(dd if="$f" bs=1 skip=512 count=8 2>/dev/null | tr -d '\000' || true)"
    [[ "$sig" == "EFI PART" ]] ||
        die "no GPT partition table (expected at byte 512): the image must be a whole UEFI disk, not a partition"
    entries_lba="$(le "$f" 584 8)"
    count="$(le "$f" 592 4)"
    esize="$(le "$f" 596 4)"
    local esp=0 last_first=-1 last_type="" parts=0
    for ((i = 0; i < count; i++)); do
        off=$((entries_lba * 512 + i * esize))
        type="$(od -An -tx1 -j "$off" -N 16 "$f" | tr -d ' \n')"
        [[ -z "$type" || "$type" == 00000000000000000000000000000000 ]] && continue
        parts=$((parts + 1))
        first="$(le "$f" $((off + 32)) 8)"
        [[ "$type" == "$GUID_ESP" ]] && esp=1
        if (( first > last_first )); then last_first=$first; last_type=$type; fi
    done
    info "GPT with $parts partitions"
    [[ $esp -eq 1 ]] || die "no EFI system partition: the firmware couldn't boot the disk"
    info "EFI system partition found"
    case "$last_type" in
        "$GUID_WIN_RECOVERY") die "the last partition is a Windows recovery partition: C: must be last so it can grow" ;;
        "$GUID_LINUX_SWAP") die "the last partition is swap: the root partition must be last so it can grow" ;;
    esac
    info "last partition on the disk isn't recovery or swap (root/C: last, as required)"
}

FORMAT=""
check_image() {
    local f="$1" magic head
    log "Step 1: checking $f"
    magic="$(magic_of "$f")"
    head="$(mktemp)"
    case "$magic" in
        28b52ffd)
            need zstd "for zstd images"
            FORMAT="raw-zst"
            info "format: zstd-compressed raw"
            zstd -dc -- "$f" 2>/dev/null | head -c 1048576 > "$head" || true
            local dsize
            dsize="$(zstd -lv -- "$f" 2>/dev/null | sed -n 's/.*Decompressed Size: *\([^(]*\).*/\1/p' | head -1 | sed 's/ *$//')"
            [[ -n "$dsize" ]] && info "uncompressed size: $dsize (must fit on the smallest disk it can land on)"
            ;;
        514649fb) FORMAT="qcow2"; info "format: qcow2 (converted to raw before packaging)"; rm -f "$head"; return ;;
        *)
            FORMAT="raw"
            info "format: raw, $(( $(file_size "$f") / 1048576 )) MiB (must fit on the smallest disk it can land on)"
            head -c 1048576 "$f" > "$head"
            ;;
    esac
    check_gpt "$head"
    rm -f "$head"
}

# --------------------------------------------------------------------------------------------------------
# Inputs: options first, then questions for anything missing (in a terminal, or with --interactive)
# --------------------------------------------------------------------------------------------------------

PROMPT=0
if [[ $NO_PROMPT -eq 0 && ( $INTERACTIVE -eq 1 || -t 0 ) ]]; then PROMPT=1; fi

ask() {  # ask VAR "Question" [default]: sets VAR from the answer, or from the default when the answer is empty
    local __var="$1" __q="$2" __def="${3:-}" __ans=""
    if [[ -n "$__def" ]]; then printf '%s [%s]: ' "$__q" "$__def" >&2; else printf '%s: ' "$__q" >&2; fi
    IFS= read -r __ans || [[ -n "$__ans" ]] || die "no answer (end of input)"
    printf -v "$__var" '%s' "${__ans:-$__def}"
}

ask_until() {  # ask_until VAR "Question" DEFAULT CHECK: asks again until CHECK accepts the answer
    local __msg
    while true; do
        ask "$1" "$2" "$3"
        if __msg="$("$4" "${!1}")"; then return 0; fi
        printf '    %s\n' "$__msg" >&2
    done
}

check() {  # check VALUE CHECK OPTION: stops with CHECK's message when VALUE is invalid
    local msg
    msg="$("$2" "$1")" || die "$3: $msg"
}

valid_os()      { [[ "$1" == linux || "$1" == windows ]] || { echo "answer linux or windows"; return 1; }; }
valid_label()   { [[ "$1" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] ||
                      { echo "use lowercase letters, digits and hyphens, starting and ending with a letter or digit"; return 1; }; }
valid_os_name() {
    [[ -n "$1" ]] || { echo "os.name can't be empty"; return 1; }
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
        windows|rhel|redhat) echo "os.name must not be exactly '$1': the image builder would rebuild the boot ISO as an installer ISO"; return 1 ;;
    esac
}
valid_package() { [[ "$1" == iso || "$1" == img ]] || { echo "answer iso or img"; return 1; }; }
valid_url()     { [[ "$1" =~ ^https?://[^[:space:]]+$ ]] || { echo "give an http:// or https:// URL"; return 1; }; }
valid_image_url() {
    valid_url "$1" || return 1
    local file; file="$(basename "${1%%\?*}" | tr '[:upper:]' '[:lower:]')"
    [[ "$file" == *.iso || "$file" == *.img ]] ||
        { echo "the file name must end in .iso or .img (got '$(basename "${1%%\?*}")'): BMCs mount only those"; return 1; }
}
valid_source()  {
    if [[ "$1" =~ ^https?:// ]]; then valid_image_url "$1"; return; fi
    [[ -f "$1" ]] || { echo "no such file: $1"; return 1; }
}
valid_text()    { [[ -n "$1" ]] || { echo "this can't be empty"; return 1; }; }
valid_yes_no()  { [[ "$1" =~ ^([yY]([eE][sS])?|[nN][oO]?)$ ]] || { echo "answer y or n"; return 1; }; }
valid_upload()  { [[ -z "$1" || "$1" == *:* ]] || { echo "give user@host:/path (or leave it empty)"; return 1; }; }
valid_files_choice() { [[ "$1" =~ ^(e|example|o|own)$ ]] || { echo "answer example or own"; return 1; }; }
valid_file()    { [[ -f "${1/#\~/$HOME}" && -r "${1/#\~/$HOME}" ]] || { echo "no such file: $1"; return 1; }; }
valid_file_or_example() { [[ "$1" == example ]] || valid_file "$1"; }

[[ -z "$IMAGE" || -z "$IMAGE_URL" ]] || die "give --image or --image-url, not both"

# The controller: metalcloud-cli needs an endpoint and an API key, and must match the controller's version.
# Any call to the controller makes it check them; listing templates changes nothing.
read -r -a MC <<< "$MC_CLI"
CONTROLLER=""
setup_help() {
    info "Set the controller and your API key (from the controller UI: your user menu, API credentials):"
    info "  export METALCLOUD_ENDPOINT=https://<controller>"
    info "  export METALCLOUD_API_KEY=<API key>"
    info "or put endpoint: and api_key: in metalcloud.yaml in the current folder, ~/.metalcloud/ or /etc/metalcloud/."
}
controller_problem() {  # controller_problem MESSAGE [help]: a dry run only warns
    [[ "${2:-}" == help ]] && setup_help
    if [[ $DRY_RUN -eq 1 ]]; then
        warn "$1. A dry run doesn't need the controller; the real run would stop here."
    else
        die "$1"
    fi
}
check_controller() {
    local ver ctl_version out line
    need "${MC[0]}" "metalcloud-cli, configured with METALCLOUD_ENDPOINT and METALCLOUD_API_KEY"
    log "Checking the controller"
    # "version" shows the endpoint metalcloud-cli uses (from the environment or its configuration file), the
    # controller's version, and a "User ID" line only when the API key works
    ver="$("${MC[@]}" version 2>&1 || true)"
    if grep -q '^Metalsoft Endpoint:' <<< "$ver"; then
        CONTROLLER="$(sed -n 's/^Metalsoft Endpoint: *//p' <<< "$ver" | head -1)"
        [[ -n "$CONTROLLER" ]] || { controller_problem "metalcloud-cli has no API endpoint" help; return 0; }
        ctl_version="$(sed -n 's/^Metalsoft Endpoint Version: *//p' <<< "$ver" | head -1)"
        info "endpoint: $CONTROLLER${ctl_version:+ (version $ctl_version)}"
        grep -q '^User ID:' <<< "$ver" ||
            { controller_problem "metalcloud-cli has no API key, or $CONTROLLER doesn't accept it" help; return 0; }
        info "API key accepted"
    fi
    # A real call: metalcloud-cli also refuses to work with a controller version it doesn't support
    if out="$("${MC[@]}" os-template list -f json 2>&1 >/dev/null)"; then
        info "metalcloud-cli $(sed -n 's/^CLI Version: *//p' <<< "$ver" | head -1) works with this controller"
        return 0
    fi
    line="$(printf '%s\n' "$out" | grep -m1 '^Error: ' || true)"
    [[ -n "$line" ]] || line="$(printf '%s\n' "$out" | grep -v '^Returned ' | grep -m1 . || true)"
    line="${line#Error: }"
    case "$line" in
        "API endpoint is required"*) controller_problem "metalcloud-cli has no API endpoint" help ;;
        "API key is required"*) controller_problem "metalcloud-cli has no API key" help ;;
        "invalid API endpoint URL"*) controller_problem "metalcloud-cli's endpoint isn't a valid URL ($line)" help ;;
        *"invalid version"*|*"incompatible version"*)
            controller_problem "metalcloud-cli doesn't support the controller's version ($line): install the CLI release that matches the controller" ;;
        *) controller_problem "metalcloud-cli can't use the controller: $line" ;;
    esac
}
[[ $CHECK_ONLY -eq 1 ]] || check_controller

if [[ $CHECK_ONLY -eq 0 ]]; then
    [[ -n "$OS_FAMILY" || $PROMPT -eq 0 ]] ||
        ask_until OS_FAMILY "Operating system of the image (linux or windows)" linux valid_os
    [[ -n "$OS_FAMILY" ]] || die "give --os linux|windows"
    check "$OS_FAMILY" valid_os "--os"
fi

if [[ -z "$IMAGE" && -z "$IMAGE_URL" ]]; then
    [[ $PROMPT -eq 1 ]] || { usage >&2; die "give --image or --image-url"; }
    ask_until SOURCE "Golden image: a local file, or the URL of an image that's already packaged and hosted" "" valid_source
    if [[ "$SOURCE" =~ ^https?:// ]]; then IMAGE_URL="$SOURCE"; else IMAGE="$SOURCE"; fi
fi
[[ -z "$IMAGE" || -f "$IMAGE" ]] || die "image not found: $IMAGE"
[[ -z "$IMAGE_URL" ]] || check "$IMAGE_URL" valid_image_url "--image-url"
[[ $CHECK_ONLY -eq 0 || -n "$IMAGE" ]] || die "--check-only needs a local image (--image)"

# Step 1 for a local image: checked now, so a bad image stops the script before any more questions
if [[ -n "$IMAGE" ]]; then
    case "$(printf '%s' "$IMAGE" | tr '[:upper:]' '[:lower:]')" in
        *.vmdk|*.vhdx|*.vhd) FORMAT="convert"; log "Step 1: $IMAGE is converted to raw and checked before packaging" ;;
        *) check_image "$IMAGE" ;;
    esac
    if [[ $CHECK_ONLY -eq 1 ]]; then
        [[ "$FORMAT" == raw || "$FORMAT" == raw-zst ]] ||
            die "convert the image to raw first (qemu-img convert -O raw), then check it"
        log "Image check passed"
        info "Not checked here: drivers, cloud-init/Cloudbase-Init setup and sysprep (see step 1 of the guide)"
        exit 0
    fi
    if [[ "$FORMAT" == raw || "$FORMAT" == raw-zst ]]; then
        case "$(basename "$IMAGE")" in
            *.raw|*.img|*.raw.zst|*.img.zst) ;;
            *) die "the image file must be named *.raw, *.img, *.raw.zst or *.img.zst (got $(basename "$IMAGE")): the boot ISO looks for those names" ;;
        esac
    fi
    [[ $PROMPT -eq 1 ]] && log "Packaging and upload"
    [[ -n "$PACKAGE" || $PROMPT -eq 0 ]] ||
        ask_until PACKAGE "Package as iso (works with any BMC) or img (mounted directly, Dell iDRAC only)" iso valid_package
    PACKAGE="${PACKAGE:-iso}"
    check "$PACKAGE" valid_package "--package"
    if [[ -z "$COMPRESS" ]]; then
        COMPRESS=0
        if [[ $PROMPT -eq 1 && "$FORMAT" != raw-zst ]]; then
            ask_until ANSWER "Compress the image with zstd first? (smaller upload, faster deploys)" y valid_yes_no
            [[ "$ANSWER" =~ ^[yY] ]] && COMPRESS=1
        fi
    fi
    [[ -n "$URL_BASE" || $PROMPT -eq 0 ]] ||
        ask_until URL_BASE "URL of the web folder the packaged file will be served from (e.g. https://repo.example.com/images)" "" valid_url
    [[ -n "$URL_BASE" ]] || die "--image needs --url-base (where the packaged file will be served from)"
    check "$URL_BASE" valid_url "--url-base"
    if [[ -z "$UPLOAD" && $NO_UPLOAD -eq 0 && $PROMPT -eq 1 ]]; then
        ask_until UPLOAD "Copy it there with scp? Destination as user@host:/path, or empty to upload it yourself" "" valid_upload
    fi
fi

if [[ $PROMPT -eq 1 ]]; then log "Template"; fi
[[ -n "$LABEL" || $PROMPT -eq 0 ]] ||
    ask_until LABEL "Template label, unique on the controller (e.g. rocky-9-golden-v1)" "" valid_label
[[ -n "$LABEL" ]] || die "give --label"
check "$LABEL" valid_label "--label"

[[ -n "$NAME" || $PROMPT -eq 0 ]] || ask_until NAME "Template name" "$LABEL" valid_text
NAME="${NAME:-$LABEL}"

if [[ "$OS_FAMILY" == windows ]]; then
    CRED_USER="Administrator"
    DEFAULT_DESCRIPTION="Writes a sysprepped Windows disk image to the local disk; Cloudbase-Init configures it on first boot"
else
    CRED_USER="root"
    DEFAULT_DESCRIPTION="Writes a Linux disk image to the local disk; cloud-init configures it on first boot"
fi
[[ -n "$DESCRIPTION" || $PROMPT -eq 0 ]] || ask_until DESCRIPTION "Description" "$DEFAULT_DESCRIPTION" valid_text
DESCRIPTION="${DESCRIPTION:-$DEFAULT_DESCRIPTION}"

[[ -n "$OS_NAME" || $PROMPT -eq 0 ]] ||
    ask_until OS_NAME "os.name (never exactly windows, rhel or redhat)" "${OS_FAMILY}-golden-image" valid_os_name
OS_NAME="${OS_NAME:-${OS_FAMILY}-golden-image}"
check "$OS_NAME" valid_os_name "--os-name"

[[ -n "$OS_VERSION" || $PROMPT -eq 0 ]] || ask_until OS_VERSION "os.version" "1.0" valid_text
OS_VERSION="${OS_VERSION:-1.0}"

[[ -n "$BOOT_ISO_URL" || $PROMPT -eq 0 ]] ||
    ask_until BOOT_ISO_URL "Boot ISO URL" "$DEFAULT_BOOT_ISO_URL" valid_url
BOOT_ISO_URL="${BOOT_ISO_URL:-$DEFAULT_BOOT_ISO_URL}"
check "$BOOT_ISO_URL" valid_url "--boot-iso-url"

# First-boot files: the built-in example, or the user's own (rendered as templates for each server either way)
if [[ -z "$USER_DATA_FILE$META_DATA_FILE$NETWORK_CONFIG_FILE" && $PROMPT -eq 1 ]]; then
    log "First-boot files"
    ask_until FILES_CHOICE "user-data, meta-data and network-config: the built-in $OS_FAMILY example, or your own? (example/own)" example valid_files_choice
    if [[ "$FILES_CHOICE" == o* ]]; then
        info "Give each file's path; leave one empty to use the example's."
        ask_until USER_DATA_FILE "user-data file" example valid_file_or_example
        ask_until META_DATA_FILE "meta-data file" example valid_file_or_example
        ask_until NETWORK_CONFIG_FILE "network-config file" example valid_file_or_example
        [[ "$USER_DATA_FILE" == example ]] && USER_DATA_FILE=""
        [[ "$META_DATA_FILE" == example ]] && META_DATA_FILE=""
        [[ "$NETWORK_CONFIG_FILE" == example ]] && NETWORK_CONFIG_FILE=""
    fi
fi
USER_DATA_FILE="${USER_DATA_FILE/#\~/$HOME}" META_DATA_FILE="${META_DATA_FILE/#\~/$HOME}"
NETWORK_CONFIG_FILE="${NETWORK_CONFIG_FILE/#\~/$HOME}"
[[ -z "$USER_DATA_FILE" ]] || check "$USER_DATA_FILE" valid_file "--user-data"
[[ -z "$META_DATA_FILE" ]] || check "$META_DATA_FILE" valid_file "--meta-data"
[[ -z "$NETWORK_CONFIG_FILE" ]] || check "$NETWORK_CONFIG_FILE" valid_file "--network-config"
first_line() { local l; l="$(tr -d '\r' < "$1" | grep -m1 -v '^[[:space:]]*$' || true)"; printf '%s' "${l#$'\xef\xbb\xbf'}"; }
if [[ -n "$USER_DATA_FILE" ]]; then
    case "$OS_FAMILY:$(first_line "$USER_DATA_FILE")" in
        linux:'#'*|linux:'{'*|linux:Content-Type:*) ;;
        windows:'#'*|windows:'{'*|windows:'rem cmd'*|windows:'<'*|windows:Content-Type:*) ;;
        linux:*) warn "$USER_DATA_FILE doesn't start with a header such as #cloud-config or #!: cloud-init would ignore it" ;;
        *) warn "$USER_DATA_FILE doesn't start with a header such as #ps1_sysnative or #cloud-config: Cloudbase-Init would ignore it" ;;
    esac
fi
files_desc() {  # files_desc: which first-boot files are the user's and which come from the example
    local d="" f v
    for f in user-data meta-data network-config; do
        case "$f" in user-data) v="$USER_DATA_FILE" ;; meta-data) v="$META_DATA_FILE" ;; *) v="$NETWORK_CONFIG_FILE" ;; esac
        d+="${d:+, }$f ${v:-from the $OS_FAMILY example}"
    done
    printf '%s' "$d"
}

# The template directory is written on this computer: asked before it's created, unless --templates-dir chose it
abs_dir() { local d="${1/#\~/$HOME}"; [[ "$d" == /* ]] || d="$PWD/${d#./}"; printf '%s' "$d"; }
REL_DIR="golden/$OS_FAMILY/$LABEL"
DIR_CONFIRMED=0
[[ $TEMPLATES_DIR_SET -eq 1 || $ASSUME_YES -eq 1 || $PROMPT -eq 0 ]] && DIR_CONFIRMED=1
while true; do
    TEMPLATES_DIR="${TEMPLATES_DIR/#\~/$HOME}"
    TDIR="$TEMPLATES_DIR/$REL_DIR"
    if [[ -e "$TDIR" ]]; then
        [[ $PROMPT -eq 1 ]] || die "$TDIR already exists; remove it or use another --label or --templates-dir"
        info "$(abs_dir "$TDIR") already exists: choose another folder (or stop with Ctrl+C and use another label)"
        ask_until TEMPLATES_DIR "Folder to write the template directory in" "" valid_text
        DIR_CONFIRMED=1
        continue
    fi
    [[ $DIR_CONFIRMED -eq 1 ]] && break
    info "The template files are written on this computer, in $(abs_dir "$TDIR")"
    ask_until ANSWER "Create that directory? (n to choose another folder)" y valid_yes_no
    [[ "$ANSWER" =~ ^[yY] ]] && break
    ask_until TEMPLATES_DIR "Folder to write the template directory in" "" valid_text
    DIR_CONFIRMED=1
done

# Summary, the same run as one command, and the confirmation
log "Summary"
info "template:      $NAME ($LABEL), private"
info "description:   $DESCRIPTION"
info "os:            name $OS_NAME, version $OS_VERSION, login $CRED_USER with a generated password"
info "first boot:    $(files_desc)"
if [[ -n "$IMAGE" ]]; then
    info "image:         $IMAGE ($FORMAT)"
    info "packaging:     $PACKAGE$([[ $COMPRESS -eq 1 ]] && echo ", compressed with zstd first")"
    info "served from:   ${URL_BASE%/}/"
    info "upload:        ${UPLOAD:-you upload it yourself}"
else
    info "image URL:     $IMAGE_URL"
fi
info "boot ISO:      $BOOT_ISO_URL"
info "template dir:  $(abs_dir "$TDIR")"
if [[ $DRY_RUN -eq 1 ]]; then
    info "controller:    not changed (dry run)"
else
    info "controller:    ${CONTROLLER:-${METALCLOUD_ENDPOINT:-the one in the metalcloud-cli configuration}}"
fi

cmd=(create-golden-template.sh --no-prompt --os "$OS_FAMILY" --label "$LABEL" --name "$NAME" --description "$DESCRIPTION"
     --os-name "$OS_NAME" --os-version "$OS_VERSION" --boot-iso-url "$BOOT_ISO_URL")
[[ -z "$USER_DATA_FILE" ]] || cmd+=(--user-data "$USER_DATA_FILE")
[[ -z "$META_DATA_FILE" ]] || cmd+=(--meta-data "$META_DATA_FILE")
[[ -z "$NETWORK_CONFIG_FILE" ]] || cmd+=(--network-config "$NETWORK_CONFIG_FILE")
if [[ -n "$IMAGE" ]]; then
    cmd+=(--image "$IMAGE" --package "$PACKAGE" --url-base "$URL_BASE")
    if [[ $COMPRESS -eq 1 ]]; then cmd+=(--compress); else cmd+=(--no-compress); fi
    if [[ -n "$UPLOAD" ]]; then cmd+=(--upload "$UPLOAD"); else cmd+=(--no-upload); fi
    [[ "$WORK_DIR" == ./golden-work ]] || cmd+=(--work-dir "$WORK_DIR")
else
    cmd+=(--image-url "$IMAGE_URL")
fi
[[ "$TEMPLATES_DIR" == ./golden-templates ]] || cmd+=(--templates-dir "$TEMPLATES_DIR")
[[ $DRY_RUN -eq 0 ]] || cmd+=(--dry-run)
printf '\n    The same run as one command:\n    '; printf '%q ' "${cmd[@]}"; printf '\n'

if [[ $PROMPT -eq 1 && $ASSUME_YES -eq 0 ]]; then
    printf '\n' >&2
    ask_until ANSWER "Go ahead?" y valid_yes_no
    [[ "$ANSWER" =~ ^[yY] ]] || { log "Stopped; nothing was changed."; exit 0; }
fi

# qcow2/VMDK/VHDX: converted only now, since it writes a whole raw disk
if [[ "$FORMAT" == qcow2 || "$FORMAT" == convert ]]; then
    need qemu-img "to convert the image to raw"
    mkdir -p "$WORK_DIR"
    raw="$WORK_DIR/$(basename "${IMAGE%.*}").raw"
    log "Converting $IMAGE to raw: $raw"
    qemu-img convert -O raw "$IMAGE" "$raw"
    IMAGE="$raw"
    check_image "$IMAGE"
fi

# --------------------------------------------------------------------------------------------------------
# Step 2: package
# --------------------------------------------------------------------------------------------------------

pad_zstd() {  # append a zstd skippable frame so the file size is a multiple of 512 bytes
    local f="$1" size pad payload
    size="$(file_size "$f")"
    pad=$(( (512 - size % 512) % 512 ))
    [[ $pad -eq 0 ]] && return
    (( pad < 8 )) && pad=$((pad + 512))
    payload=$((pad - 8))
    {
        printf '\x50\x2a\x4d\x18'
        printf "\\x$(printf %02x $((payload & 255)))\\x$(printf %02x $(((payload >> 8) & 255)))\\x00\\x00"
        head -c "$payload" /dev/zero
    } >> "$f"
}

if [[ -n "$IMAGE" ]]; then
    mkdir -p "$WORK_DIR"
    if [[ $COMPRESS -eq 1 && "$FORMAT" == raw ]]; then
        need zstd "to compress the image"
        log "Compressing with zstd (this takes a while for large images)"
        zstd -T0 -10 -q -f -o "$WORK_DIR/$(basename "$IMAGE").zst" -- "$IMAGE"
        IMAGE="$WORK_DIR/$(basename "$IMAGE").zst"
        FORMAT="raw-zst"
    fi
    base="$(basename "$IMAGE")"
    case "$base" in
        *.raw|*.img|*.raw.zst|*.img.zst) ;;
        *) die "the image file must be named *.raw, *.img, *.raw.zst or *.img.zst (got $base): the boot ISO looks for those names" ;;
    esac
    log "Step 2: packaging ($PACKAGE)"
    if [[ "$PACKAGE" == iso ]]; then
        need xorriso "to build the image ISO"
        PACKAGED="$WORK_DIR/$base.iso"
        rm -f "$PACKAGED"
        if ! xout="$(xorriso -as mkisofs -quiet -iso-level 3 -V OSIMAGE -R -J -joliet-long -graft-points \
                -o "$PACKAGED" "/$base=$IMAGE" 2>&1)"; then
            printf '%s\n' "$xout" >&2
            die "xorriso couldn't build the image ISO"
        fi
        info "ISO labeled OSIMAGE with one file, $base"
    else
        warn "--package img mounts the image directly; it worked on Dell iDRAC and failed on a Lenovo XCC"
        PACKAGED="$WORK_DIR/${base%.img}.img"
        [[ "$base" == *.img ]] && PACKAGED="$WORK_DIR/$base"
        [[ "$(cd "$(dirname "$IMAGE")" && pwd)/$(basename "$IMAGE")" != "$(cd "$WORK_DIR" && pwd)/$(basename "$PACKAGED")" ]] &&
            cp -- "$IMAGE" "$PACKAGED"
        [[ "$FORMAT" == raw-zst ]] && pad_zstd "$PACKAGED"
        info "$(basename "$PACKAGED"): $(file_size "$PACKAGED") bytes, a multiple of 512"
    fi
    info "packaged file: $PACKAGED ($(( $(file_size "$PACKAGED") / 1048576 )) MiB)"
    IMAGE_URL="${URL_BASE%/}/$(basename "$PACKAGED")"

    # ----------------------------------------------------------------------------------------------------
    # Step 3: upload
    # ----------------------------------------------------------------------------------------------------
    if [[ -n "$UPLOAD" ]]; then
        need scp "for --upload"
        log "Step 3: uploading to $UPLOAD"
        scp -- "$PACKAGED" "$UPLOAD"
        if command -v curl >/dev/null 2>&1; then
            remote_size="$(curl -sfIL "$IMAGE_URL" | tr -d '\r' | awk 'tolower($1)=="content-length:"{s=$2} END{print s}' || true)"
            if [[ "$remote_size" == "$(file_size "$PACKAGED")" ]]; then
                info "$IMAGE_URL answers with the right size"
            else
                warn "$IMAGE_URL didn't answer with the uploaded file's size (got '${remote_size:-nothing}'); check --url-base"
            fi
        fi
    else
        log "Step 3: upload $PACKAGED so it's served at $IMAGE_URL"
        info "Finish the upload before you deploy: downloads are reused by file name, so a partial or replaced"
        info "file can keep deploying until its cached copy expires."
    fi
    info "The URL must be reachable from the component that downloads it (the global controller by default,"
    info "or the site controller if it builds images), with a trusted certificate if it's HTTPS."
fi

# --------------------------------------------------------------------------------------------------------
# Step 4: write the template directory
# --------------------------------------------------------------------------------------------------------

yaml_quote() { local v="${1//\\/\\\\}"; v="${v//\"/\\\"}"; printf '"%s"' "$v"; }

log "Step 4: writing $TDIR"
[[ ! -e "$TDIR" ]] || die "$TDIR already exists; remove it or use another --label"
mkdir -p "$TDIR"
IMAGE_FILE_NAME="$(basename "${IMAGE_URL%%\?*}")"
BOOT_FILE_NAME="$(basename "${BOOT_ISO_URL%%\?*}")"

cat > "$TDIR/template.yaml" <<EOF
template:
  name: $(yaml_quote "$NAME")
  label: $LABEL
  description: $(yaml_quote "$DESCRIPTION")
  visibility: private
  device:
    architecture: x86_64
    bootmode: uefi
    type: server
  imagebuild:
    required: true
  install:
    drivetype: local_drive
    method: oob
    readymethod: wait_for_power_off
  os:
    name: $(yaml_quote "$OS_NAME")
    version: $(yaml_quote "$OS_VERSION")
    credential:
      username: $CRED_USER
      passwordtype: generated
  tags:
    - golden-image
    - $OS_FAMILY
templateassets:
  # Virtual media 1: MetalSoft's boot ISO (volume label CIDATA). The files below are added to it per server.
  - file:
      name: $BOOT_FILE_NAME
      path: /$BOOT_FILE_NAME
      mimetype: application/octet-stream
      url: $BOOT_ISO_URL
      templatingengine: false
    usage: build_source_image
  # Virtual media 2: the golden image. Give every image version a new file name.
  - file:
      name: $IMAGE_FILE_NAME
      path: /$IMAGE_FILE_NAME
      mimetype: application/octet-stream
      url: $IMAGE_URL
      templatingengine: false
    usage: secondary_image
  - file:
      name: user-data
      path: /user-data
      mimetype: text/plain
      templatingengine: true
    usage: build_component
  - file:
      name: meta-data
      path: /meta-data
      mimetype: text/plain
      templatingengine: true
    usage: build_component
  - file:
      name: network-config
      path: /network-config
      mimetype: text/plain
      templatingengine: true
    usage: build_component
EOF

write_linux_user_data() {
    cat <<'__EOF_LINUX_USER_DATA__'
#cloud-config
{#- First boot of the golden image. cloud-init reads this from the CIDATA boot ISO, which stays attached. -#}
{%- set si = serverInstance or {} %}
{%- set password = si.osCredentials.initialPasswordEncrypted if si.osCredentials else '' %}
{%- set keys = [] %}
{%- for key in (userSSHKeys or []) %}{% if key %}{% set keys = (keys.push(key), keys) %}{% endif %}{% endfor %}
{%- if managementSSHKey %}{% set keys = (keys.push(managementSSHKey), keys) %}{% endif %}
{%- set bonds = [] %}
{%- for interface in ((network.interfaces if network else []) or []) %}{% if interface.interfaceType == 'bond' %}{% set bonds = (bonds.push(interface), bonds) %}{% endif %}{% endfor %}

preserve_hostname: false
hostname: {{ (si.hostname or si.label or 'localhost') | dump | safe }}
{%- if si.provisionInstanceDnsRecords and si.fqdn %}
fqdn: {{ si.fqdn | dump | safe }}
prefer_fqdn_over_hostname: true
{%- else %}
prefer_fqdn_over_hostname: false
{%- endif %}
manage_etc_hosts: true
timezone: UTC

# Keep the image's default user (ubuntu, rocky, debian, cloud-user, ...) with the SSH keys.
# disable_root: false also puts the keys in root's authorized_keys.
users:
  - default
disable_root: false
{%- if keys | length %}
ssh_authorized_keys:
{%- for key in keys %}
  - {{ key | dump | safe }}
{%- endfor %}
{%- endif %}

{%- if password %}

# root gets the password MetalSoft generated for this server (needs cloud-init 22.3 or later)
chpasswd:
  expire: false
  users:
    - name: root
      password: {{ password | dump | safe }}
      type: text
{%- endif %}

# Grow the root partition and filesystem to the size of the disk
growpart:
  mode: auto
  devices: ["/"]
resize_rootfs: true

package_update: false
package_upgrade: false

runcmd:
  # Provisioning is one-shot. Without this, a distro whose cloud-init still runs after the
  # CIDATA ISO is removed may treat the server as a new instance and rewrite its network config.
  - [touch, /etc/cloud/cloud-init.disabled]
{#-
  Where cloud-init writes NetworkManager files (RHEL 10, SLES 16 and others), cloud-init 26.2 and earlier
  leave lacp_rate and xmit_hash_policy out of the bond (fixed upstream in cloud-init PR 6936). Set them
  with nmcli; they take effect from the next boot. Elsewhere the file test is false and nothing runs.
  The values match the ones in network-config.
-#}
{%- for bond in bonds %}
  {%- set parameters = bond.parameters or {} %}
  {%- set mode = bond.bondMode or parameters.mode or '802.3ad' %}
  {%- if mode == '802.3ad' or mode == 'balance-xor' %}
  {%- set name = 'bond' ~ bond.typeInterfaceId %}
  {%- set options = 'mode=' ~ mode ~ ',miimon=' ~ (parameters.miiMonitorInterval or 100) ~ ((',lacp_rate=' ~ (parameters.lacpRate or 'fast')) if mode == '802.3ad' else '') ~ ',xmit_hash_policy=' ~ (parameters.transmitHashPolicy or 'layer3+4') %}
  - {{ ("if [ -f /etc/NetworkManager/system-connections/cloud-init-" ~ name ~ ".nmconnection ]; then nmcli connection modify 'cloud-init " ~ name ~ "' bond.options '" ~ options ~ "'; fi") | dump | safe }}
  {%- endif %}
{%- endfor %}

# MetalSoft's wait_for_power_off finishes the deployment when the server powers off
power_state:
  mode: poweroff
  delay: now
  message: MetalSoft provisioning complete
  timeout: 300
  condition: true
__EOF_LINUX_USER_DATA__
}

write_windows_user_data() {
    cat <<'__EOF_WINDOWS_USER_DATA__'
#ps1_sysnative
{#-
  First boot of the golden image. Cloudbase-Init's UserDataPlugin runs this once, reading it from the
  CIDATA boot ISO. Hostname (meta-data) and network (network-config) are applied by Cloudbase-Init itself.
-#}
{%- set si = serverInstance or {} %}
{%- set password = si.osCredentials.initialPasswordEncrypted if si.osCredentials else '' %}
{%- set keys = [] %}
{%- for key in (userSSHKeys or []) %}{% if key %}{% set keys = (keys.push(key), keys) %}{% endif %}{% endfor %}
{%- if managementSSHKey %}{% set keys = (keys.push(managementSSHKey), keys) %}{% endif %}
{%- set ntp = [] %}
{%- for server in ((siteConfig.NTPServers if siteConfig else []) or []) %}{% if server %}{% set ntp = (ntp.push(server), ntp) %}{% endif %}{% endfor %}
$ErrorActionPreference = 'Stop'

# The built-in Administrator account, found by its well-known SID (its name can be localized or renamed)
$admin = Get-LocalUser | Where-Object { $_.SID.Value -like 'S-1-5-*-500' }
{%- if password %}

# Administrator password: the one MetalSoft generated for this server
$password = ConvertTo-SecureString -String '{{ password | replace("'", "''") | safe }}' -AsPlainText -Force
Set-LocalUser -SID $admin.SID -Password $password -PasswordNeverExpires $true
Remove-Variable password
{%- endif %}
Enable-LocalUser -SID $admin.SID
{%- if keys | length %}

# SSH keys, only if OpenSSH Server is installed in the image
if (Get-Service -Name sshd -ErrorAction SilentlyContinue) {
    $keysFile = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
    New-Item -ItemType Directory -Force -Path (Split-Path $keysFile) | Out-Null
    $keys = @(
{%- for key in keys %}
        '{{ key | replace("'", "''") | safe }}'
{%- endfor %}
    )
    Set-Content -Path $keysFile -Value $keys -Encoding ascii
    # Administrators and SYSTEM only, as OpenSSH requires; SIDs so localized group names don't matter
    icacls.exe $keysFile /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' | Out-Null
    Set-Service -Name sshd -StartupType Automatic
}
{%- endif %}
{%- if ntp | length %}

# Time servers
Set-Service -Name W32Time -StartupType Automatic
Start-Service -Name W32Time
w32tm.exe /config /manualpeerlist:"{{ ntp | join(' ') }}" /syncfromflags:manual /update | Out-Null
{%- endif %}

# Grow C: to the end of the disk. ExtendVolumesPlugin does this too when it's enabled; repeating it is harmless.
$cPartition = Get-Partition -DriveLetter C
$cMax = (Get-PartitionSupportedSize -DriveLetter C).SizeMax
if ($cMax -gt ($cPartition.Size + 1MB)) {
    Resize-Partition -DriveLetter C -Size $cMax
}

# Power off once Cloudbase-Init has finished, so MetalSoft's wait_for_power_off completes.
# Provisioning is one-shot: Cloudbase-Init is also stopped from running on later boots.
$conf = Join-Path $env:ProgramFiles 'Cloudbase Solutions\Cloudbase-Init\conf\cloudbase-init.conf'
$confLines = @(if (Test-Path $conf) { Get-Content -Path $conf })
$scriptsSetting = $confLines | Select-String -Pattern '^\s*local_scripts_path\s*=\s*(.+?)\s*$' | Select-Object -First 1
$pluginsSetting = $confLines | Select-String -Pattern '^\s*plugins\s*=\s*(.+?)\s*$' | Select-Object -First 1
# The default plugin list (no plugins= line) includes LocalScriptsPlugin
$localScriptsRuns = $scriptsSetting -and ((-not $pluginsSetting) -or
    ($pluginsSetting.Matches[0].Groups[1].Value -match 'LocalScriptsPlugin'))
if ($localScriptsRuns) {
    # LocalScriptsPlugin runs after every other plugin, so a script left in its folder now
    # powers the server off at the very end of this boot
    $localScripts = $scriptsSetting.Matches[0].Groups[1].Value
    New-Item -ItemType Directory -Force -Path $localScripts | Out-Null
    @'
# Written by the MetalSoft user-data on first boot.
sc.exe config cloudbase-init start= disabled | Out-Null
shutdown.exe /s /t 15 /f /d p:4:1 /c "MetalSoft provisioning complete"
exit 0
'@ | Set-Content -Path (Join-Path $localScripts '99-metalsoft-poweroff.ps1') -Encoding ascii
} else {
    # No LocalScriptsPlugin in this image: power off two minutes after this script returns,
    # which leaves Cloudbase-Init time to finish its remaining plugins and save its state
    sc.exe config cloudbase-init start= disabled | Out-Null
    shutdown.exe /s /t 120 /f /d p:4:1 /c "MetalSoft provisioning complete"
}

exit 0
__EOF_WINDOWS_USER_DATA__
}

write_meta_data() {
    cat <<'__EOF_META_DATA__'
{%- set si = serverInstance or {} -%}
instance-id: {{ ('metalsoft-' ~ (si.label or 'instance')) | dump | safe }}
local-hostname: {{ (si.hostname or si.label or 'localhost') | dump | safe }}
__EOF_META_DATA__
}

write_network_config() {
    cat <<'__EOF_NETWORK_CONFIG__'
{#-
  NoCloud network-config, version 2. Read on first boot by cloud-init (Linux) and by
  Cloudbase-Init 1.1.5 or later (Windows). Interfaces are matched by MAC address and named
  phy<N>, bond<N> and <parent>.<vlan id>.
-#}
{%- set dns = [] %}
{%- for server in ((siteConfig.DNSServers if siteConfig else []) or []) %}{% if server %}{% set dns = (dns.push(server), dns) %}{% endif %}{% endfor %}
{%- set physicals = [] %}
{%- set bonds = [] %}
{%- set vlans = [] %}
{%- for interface in ((network.interfaces if network else []) or []) %}
  {%- if interface.interfaceType == 'physical' %}{% set physicals = (physicals.push(interface), physicals) %}
  {%- elif interface.interfaceType == 'bond' %}{% set bonds = (bonds.push(interface), bonds) %}
  {%- elif interface.interfaceType == 'vlan' and interface.links and interface.links | length %}{% set vlans = (vlans.push(interface), vlans) %}
  {%- endif %}
{%- endfor %}

{%- macro linkName(link) -%}
{{ 'bond' if link.interfaceType == 'bond' else 'phy' }}{{ link.id }}
{%- endmacro %}

{%- macro layer3(interface) %}
    {%- if interface.mtu %}
    mtu: {{ interface.mtu }}
    {%- endif %}
    {%- set ipv4 = interface.ipv4Addresses or [] %}
    {%- set ipv6 = interface.ipv6Addresses or [] %}
    {%- if ipv4 | length or ipv6 | length %}
    addresses:
      {%- for address in ipv4 %}
      - {{ address.cidr }}
      {%- endfor %}
      {%- for address in ipv6 %}
      - {{ address.cidr }}
      {%- endfor %}
    {%- if ipv4 | length and dns | length %}
    nameservers:
      addresses:
        {%- for server in dns %}
        - {{ server }}
        {%- endfor %}
    {%- endif %}
    {%- elif interface.dhcp4 %}
    dhcp4: true
    {%- endif %}
    {%- if interface.routes and interface.routes | length %}
    routes:
      {%- for route in interface.routes %}
      - to: {{ route.to }}
        via: {{ route.via }}
        {%- if route.metric %}
        metric: {{ route.metric }}
        {%- endif %}
      {%- endfor %}
    {%- endif %}
{%- endmacro -%}
version: 2
{%- if physicals | length %}
ethernets:
  {%- for interface in physicals %}
  phy{{ interface.typeInterfaceId }}:
    match:
      macaddress: {{ (interface.macAddress | lower) | dump | safe }}
    set-name: phy{{ interface.typeInterfaceId }}
    {{- layer3(interface) }}
  {%- endfor %}
{%- endif %}
{%- if bonds | length %}
bonds:
  {%- for bond in bonds %}
  {%- set parameters = bond.parameters or {} %}
  {%- set mode = bond.bondMode or parameters.mode or '802.3ad' %}
  bond{{ bond.typeInterfaceId }}:
    interfaces:
      {%- for member in (bond.members or []) %}
      - {{ linkName(member) }}
      {%- endfor %}
    parameters:
      mode: {{ mode }}
      {%- if mode == '802.3ad' %}
      lacp-rate: {{ parameters.lacpRate or 'fast' }}
      {%- endif %}
      {%- if mode == '802.3ad' or mode == 'balance-xor' %}
      transmit-hash-policy: {{ parameters.transmitHashPolicy or 'layer3+4' }}
      {%- endif %}
      mii-monitor-interval: {{ parameters.miiMonitorInterval or 100 }}
    {{- layer3(bond) }}
  {%- endfor %}
{%- endif %}
{%- if vlans | length %}
vlans:
  {%- for vlan in vlans %}
  {{ linkName(vlan.links[0]) }}.{{ vlan.vlanId }}:
    id: {{ vlan.vlanId }}
    link: {{ linkName(vlan.links[0]) }}
    {{- layer3(vlan) }}
  {%- endfor %}
{%- endif %}
__EOF_NETWORK_CONFIG__
}

copy_text() {  # copy_text SRC DEST: without a UTF-8 byte order mark and with LF line endings
    if [[ "$(head -c 3 "$1" | od -An -tx1 | tr -d ' \n')" == efbbbf ]]; then tail -c +4 "$1"; else cat "$1"; fi |
        sed $'s/\r$//' > "$2"
}
if [[ -n "$USER_DATA_FILE" ]]; then copy_text "$USER_DATA_FILE" "$TDIR/user-data"
elif [[ "$OS_FAMILY" == windows ]]; then write_windows_user_data > "$TDIR/user-data"
else write_linux_user_data > "$TDIR/user-data"; fi
if [[ -n "$META_DATA_FILE" ]]; then copy_text "$META_DATA_FILE" "$TDIR/meta-data"; else write_meta_data > "$TDIR/meta-data"; fi
if [[ -n "$NETWORK_CONFIG_FILE" ]]; then copy_text "$NETWORK_CONFIG_FILE" "$TDIR/network-config"
else write_network_config > "$TDIR/network-config"; fi
info "template.yaml, and $(files_desc)"
info "image: $IMAGE_URL"
info "boot ISO: $BOOT_ISO_URL"

# --------------------------------------------------------------------------------------------------------
# Steps 5 and 6: check offline, then create
# --------------------------------------------------------------------------------------------------------

# metalcloud-cli reads every file under --dir and stops at any folder it can't read, so it gets a temporary
# folder holding only this template, whatever else is in $TEMPLATES_DIR
CLI_DIR="$(mktemp -d)"
trap 'rm -rf "$CLI_DIR"' EXIT
mkdir -p "$CLI_DIR/$REL_DIR"
cp -- "$TDIR"/* "$CLI_DIR/$REL_DIR/"

log "Step 5: checking the template offline"
if ! listing="$("${MC[@]}" os-template list-directory --dir "$CLI_DIR" 2>&1)"; then
    printf '%s\n' "$listing" >&2
    die "metalcloud-cli os-template list-directory failed"
fi
grep -F -- "$LABEL" <<< "$listing" >/dev/null ||
    die "metalcloud-cli doesn't list $REL_DIR as a template; check $TDIR/template.yaml"
info "metalcloud-cli parses $REL_DIR"

if [[ $DRY_RUN -eq 1 ]]; then
    log "Dry run: not creating the template. To create it:"
    info "${MC_CLI} os-template create-from-directory $REL_DIR --dir $(printf '%q' "$TEMPLATES_DIR")"
    info "(metalcloud-cli reads every file under --dir: give it a folder that holds only template directories)"
    exit 0
fi

log "Step 6: creating the template"
"${MC[@]}" os-template create-from-directory "$REL_DIR" --dir "$CLI_DIR"
info "The template is created private. Test it on one server (step 7), then publish it (step 8)."
info "List its assets: ${MC_CLI} os-template get-assets <id>"
