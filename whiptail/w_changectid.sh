#!/bin/bash
# Script to change the ID of a Proxmox LXC container or VM using backup and restore
# Uses whiptail to select the current guest and new ID
# Robust error handling, logging, and disk space checks

LOG_FILE="/var/log/change_ct_id.log"
VERBOSE=0
KEEP_ORIGINAL=0

# Parse --verbose and --keep-original flags
for arg in "$@"; do
    if [ "$arg" = "--verbose" ]; then
        VERBOSE=1
        shift
    elif [ "$arg" = "--keep-original" ]; then
        KEEP_ORIGINAL=1
        shift
    fi
done

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" | tee -a "$LOG_FILE"
}

debug_log() {
    if [ "$VERBOSE" -eq 1 ]; then
        echo "[DEBUG] $*" | tee -a "$LOG_FILE"
    fi
}

# Check for whiptail
if ! command -v whiptail >/dev/null 2>&1; then
    log "Error: whiptail not found. Please install it with 'apt install whiptail'."
    exit 2
fi

# Check for root
if [ "$(id -u)" -ne 0 ]; then
    log "Error: This script must be run as root."
    exit 1
fi

# Check for Proxmox tools
for tool in pct vzdump pvesm qm; do
    if ! command -v $tool >/dev/null 2>&1; then
        log "Error: Proxmox tool '$tool' not found. Is this a Proxmox system?"
        exit 2
    fi
done

# Get containers and VMs for menu
CONTAINERS=$(pct list | tail -n +2 | awk '{print "CT:"$1 " ["$2"] "$3}')
VMS=$(qm list | tail -n +2 | awk '{print "VM:"$1 " ["$2"] "$3}')
ALL_GUESTS=$(echo -e "$CONTAINERS\n$VMS" | grep -v '^$')
if [ -z "$ALL_GUESTS" ]; then
    log "Error: No containers or VMs found on this system."
    exit 1
fi
MENU_OPTIONS=()
while read -r line; do
    TYPE_ID=$(echo "$line" | awk '{print $1}')
    DESC=$(echo "$line" | cut -d' ' -f2-)
    MENU_OPTIONS+=("$TYPE_ID" "$DESC")
done <<< "$ALL_GUESTS"

SELECTED=$(whiptail --title "Select Container or Virtual Machine" --menu "Choose a container or virtual machine to change its ID:" 20 70 15 "${MENU_OPTIONS[@]}" 3>&1 1>&2 2>&3)
if [ $? -ne 0 ]; then
    log "Menu cancelled."
    exit 1
fi
log "Selected: $SELECTED"

# Detect type and ID
if [[ "$SELECTED" =~ ^CT:([0-9]+)$ ]]; then
    GUEST_TYPE="ct"
    CURRENT_ID="${BASH_REMATCH[1]}"
elif [[ "$SELECTED" =~ ^VM:([0-9]+)$ ]]; then
    GUEST_TYPE="vm"
    CURRENT_ID="${BASH_REMATCH[1]}"
else
    log "Error: Could not parse selection."
    exit 1
fi

# Prompt for new ID
NEW_ID=$(whiptail --title "Enter New ID" --inputbox "Enter the new ID for $GUEST_TYPE $CURRENT_ID:" 10 40 3>&1 1>&2 2>&3)
if [ $? -ne 0 ]; then
    log "Input cancelled."
    exit 1
fi
if [ -z "$NEW_ID" ] || ! [[ "$NEW_ID" =~ ^[0-9]+$ ]]; then
    log "Error: New ID must be a positive integer."
    exit 1
fi

# Check if new ID exists
if [ "$GUEST_TYPE" = "ct" ]; then
    if pct status "$NEW_ID" >/dev/null 2>&1; then
        log "Error: Container with ID $NEW_ID already exists."
        exit 1
    fi
    CONFIG_FILE="/etc/pve/lxc/$CURRENT_ID.conf"
    if [ ! -f "$CONFIG_FILE" ]; then
        log "Error: Configuration file $CONFIG_FILE not found."
        exit 2
    fi
    STORAGE=$(grep '^rootfs:' "$CONFIG_FILE" | awk -F: '{print $2}' | awk '{print $1}')
elif [ "$GUEST_TYPE" = "vm" ]; then
    if qm status "$NEW_ID" >/dev/null 2>&1; then
        log "Error: VM with ID $NEW_ID already exists."
        exit 1
    fi
    CONFIG_FILE="/etc/pve/qemu-server/$CURRENT_ID.conf"
    if [ ! -f "$CONFIG_FILE" ]; then
        log "Error: Configuration file $CONFIG_FILE not found."
        exit 2
    fi
    # Try all common disk types for storage detection
    STORAGE=""
    for disk_type in virtio scsi sata ide; do
        STORAGE=$(grep "^${disk_type}0:" "$CONFIG_FILE" | awk -F: '{print $2}' | awk '{print $1}')
        if [ -n "$STORAGE" ]; then
            break
        fi
    done
fi

if [ -z "$STORAGE" ]; then
    log "Error: Could not detect storage from $CONFIG_FILE."
    exit 2
fi
if ! pvesm status | grep -q "^$STORAGE"; then
    log "Error: Storage '$STORAGE' not found."
    exit 2
fi
log "Detected storage: $STORAGE"

# Disk space check function
check_disk_space() {
    local storage="$1"
    local required="$2"
    local storage_info=$(pvesm status | grep "^$storage ")
    local storage_type=$(echo "$storage_info" | awk '{print $2}')
    local storage_path=$(echo "$storage_info" | awk '{print $7}')

    if [ "$storage_type" = "dir" ] || [ "$storage_type" = "nfs" ] || [ "$storage_type" = "cifs" ]; then
        # Directory, NFS, or CIFS storage: use the path for df
        if [ -z "$storage_path" ] || [ ! -d "$storage_path" ]; then
            log "Warning: Could not determine a valid path for storage '$storage'. Skipping disk space check."
            return
        fi
        local available=$(df --block-size=1 --output=avail "$storage_path" | tail -n 1)
        if [ -z "$available" ] || ! [[ "$available" =~ ^[0-9]+$ ]]; then
            log "Warning: Could not determine available disk space for $storage_path. Skipping disk space check."
            return
        fi
        if [ "$available" -lt "$required" ]; then
            log "Error: Insufficient disk space on $storage_path. Required: $((required / 1024 / 1024)) MB, Available: $((available / 1024 / 1024)) MB"
            exit 2
        fi
        log "Sufficient disk space on $storage_path: $((available / 1024 / 1024)) MB available"
    elif [ "$storage_type" = "lvm" ] || [ "$storage_type" = "lvmthin" ]; then
        # LVM or LVM-Thin: use vgs for free space
        local vg=$(echo "$storage_info" | awk '{print $6}')
        if [ -z "$vg" ]; then
            log "Warning: Could not determine volume group for LVM storage '$storage'. Skipping disk space check."
            return
        fi
        local available=$(vgs --noheadings -o vg_free --units b "$vg" | awk '{print $1}' | tr -d 'B')
        if [ -z "$available" ] || ! [[ "$available" =~ ^[0-9]+$ ]]; then
            log "Warning: Could not determine available LVM space for $vg. Skipping disk space check."
            return
        fi
        if [ "$available" -lt "$required" ]; then
            log "Error: Insufficient LVM space in $vg. Required: $((required / 1024 / 1024)) MB, Available: $((available / 1024 / 1024)) MB"
            exit 2
        fi
        log "Sufficient LVM space in $vg: $((available / 1024 / 1024)) MB available"
    elif [ "$storage_type" = "zfspool" ]; then
        # ZFS: use zfs list for available space
        local pool=$(echo "$storage_info" | awk '{print $6}')
        if [ -z "$pool" ]; then
            log "Warning: Could not determine ZFS pool for storage '$storage'. Skipping disk space check."
            return
        fi
        local available=$(zfs get -Hp -o value available "$pool")
        if [ -z "$available" ] || ! [[ "$available" =~ ^[0-9]+$ ]]; then
            log "Warning: Could not determine available ZFS space for $pool. Skipping disk space check."
            return
        fi
        if [ "$available" -lt "$required" ]; then
            log "Error: Insufficient ZFS space in $pool. Required: $((required / 1024 / 1024)) MB, Available: $((available / 1024 / 1024)) MB"
            exit 2
        fi
        log "Sufficient ZFS space in $pool: $((available / 1024 / 1024)) MB available"
    else
        log "Warning: Storage type '$storage_type' not supported for disk space check. Skipping check."
    fi
}

# Estimate guest size
if [ "$GUEST_TYPE" = "ct" ]; then
    GUEST_DISK=$(pvesm list "$STORAGE" | grep "lxc/$CURRENT_ID/" | awk '{print $2}' | head -n 1)
    if [ -n "$GUEST_DISK" ]; then
        REQUIRED_SPACE=$GUEST_DISK
    else
        SIZE=$(grep '^rootfs:' "$CONFIG_FILE" | grep -oP 'size=\K[^,]+' | head -n 1)
        if [ -n "$SIZE" ]; then
            case "$SIZE" in
                *G) REQUIRED_SPACE=$(( $(echo "$SIZE" | tr -d 'G') * 1024 * 1024 * 1024 )) ;;
                *M) REQUIRED_SPACE=$(( $(echo "$SIZE" | tr -d 'M') * 1024 * 1024 )) ;;
                *K) REQUIRED_SPACE=$(( $(echo "$SIZE" | tr -d 'K') * 1024 )) ;;
                *) REQUIRED_SPACE=$(( SIZE * 1024 * 1024 * 1024 )) ;;
            esac
        else
            REQUIRED_SPACE=$((10 * 1024 * 1024 * 1024))
        fi
    fi
elif [ "$GUEST_TYPE" = "vm" ]; then
    REQUIRED_SPACE=0
    for disk in $(grep -E '^(virtio|scsi|sata|ide)[0-9]+:' "$CONFIG_FILE" | awk -F: '{print $2}' | awk '{print $1}'); do
        size=$(pvesm list "$disk" | grep "$CURRENT_ID" | awk '{print $2}' | head -n 1)
        if [ -n "$size" ]; then
            REQUIRED_SPACE=$((REQUIRED_SPACE + size))
        fi
    done
    if [ "$REQUIRED_SPACE" -eq 0 ]; then
        REQUIRED_SPACE=$((10 * 1024 * 1024 * 1024))
    fi
fi
REQUIRED_SPACE=$((REQUIRED_SPACE + (REQUIRED_SPACE / 5)))

check_disk_space "$STORAGE" "$REQUIRED_SPACE"

BACKUP_STORAGE="$STORAGE"
check_disk_space "$BACKUP_STORAGE" "$REQUIRED_SPACE"

# Stop guest
if [ "$GUEST_TYPE" = "ct" ]; then
    STATUS=$(pct status "$CURRENT_ID" 2>/dev/null)
    if echo "$STATUS" | grep -q "status: running"; then
        log "Stopping container $CURRENT_ID..."
        pct stop "$CURRENT_ID" || { log "Error: Failed to stop container $CURRENT_ID."; exit 2; }
        log "Stopped CT $CURRENT_ID"
    else
        log "Container $CURRENT_ID is already stopped (status: $STATUS)."
    fi
elif [ "$GUEST_TYPE" = "vm" ]; then
    STATUS=$(qm status "$CURRENT_ID" 2>/dev/null)
    if echo "$STATUS" | grep -q "status: running"; then
        log "Stopping VM $CURRENT_ID..."
        qm stop "$CURRENT_ID" || { log "Error: Failed to stop VM $CURRENT_ID."; exit 2; }
        log "Stopped VM $CURRENT_ID"
    else
        log "VM $CURRENT_ID is already stopped (status: $STATUS)."
    fi
fi

# Backup
log "Searching for existing backup for $GUEST_TYPE $CURRENT_ID..."
BACKUP_FILE=$(pvesm list "$BACKUP_STORAGE" | grep "vzdump-${GUEST_TYPE}-$CURRENT_ID-" | awk '{print $1}' | head -n 1)
if [ -n "$BACKUP_FILE" ]; then
    BACKUP_PATH=$(pvesm path "$BACKUP_FILE")
    if [ -f "$BACKUP_PATH" ]; then
        log "Found existing backup: $BACKUP_PATH"
    else
        BACKUP_FILE=""
    fi
fi
if [ -z "$BACKUP_FILE" ]; then
    log "No existing backup found. Creating new backup on $BACKUP_STORAGE..."
    VZDUMP_OUTPUT=$(vzdump "$CURRENT_ID" --compress zstd --storage "$BACKUP_STORAGE" --mode snapshot 2>&1)
    VZDUMP_STATUS=$?
    if [ $VZDUMP_STATUS -ne 0 ]; then
        log "Error: Backup failed for $GUEST_TYPE $CURRENT_ID."
        log "$VZDUMP_OUTPUT"
        exit 2
    fi
    BACKUP_FILE=$(echo "$VZDUMP_OUTPUT" | grep -oP "creating vzdump archive '\K[^']+" | head -n 1)
    if [ -z "$BACKUP_FILE" ] || [ ! -f "$BACKUP_FILE" ]; then
        log "Error: No backup file found after vzdump."
        exit 2
    fi
    log "New backup created: $BACKUP_FILE"
fi

check_disk_space "$STORAGE" "$REQUIRED_SPACE"

# Restore
echo "Restoring $GUEST_TYPE as $NEW_ID..."
if [ "$GUEST_TYPE" = "ct" ]; then
    UNPRIVILEGED=""
    if grep -q "unprivileged: 1" "$CONFIG_FILE"; then
        UNPRIVILEGED="--unprivileged"
        log "Detected unprivileged container. Will use --unprivileged flag for restore."
    fi
    pct restore "$NEW_ID" "$BACKUP_FILE" --storage "$STORAGE" $UNPRIVILEGED || {
        log "Error: Failed to restore container as $NEW_ID. Old container $CURRENT_ID preserved."
        exit 2
    }
    log "Restored CT $NEW_ID"
    log "Starting container $NEW_ID..."
    pct start "$NEW_ID" || {
        log "Error: Failed to start container as $NEW_ID. Old container $CURRENT_ID preserved."
        exit 2
    }
    log "Started CT $NEW_ID"
    if pct status "$NEW_ID" | grep -q "status: running"; then
        log "Success: Container ID changed from $CURRENT_ID to $NEW_ID and is running."
    else
        log "Error: Container $NEW_ID restored but not running. Old container $CURRENT_ID preserved."
        log "Check logs with 'journalctl -u pve*'."
        exit 2
    fi
    if [ "$KEEP_ORIGINAL" -eq 0 ]; then
        log "Deleting original container $CURRENT_ID..."
        pct destroy "$CURRENT_ID" || {
            log "Warning: Failed to delete original container $CURRENT_ID. New container $NEW_ID is running."
            exit 2
        }
        log "Deleted CT $CURRENT_ID"
    else
        log "--keep-original flag set. Skipping deletion of original container $CURRENT_ID."
    fi
elif [ "$GUEST_TYPE" = "vm" ]; then
    qmrestore --storage "$STORAGE" "$BACKUP_FILE" "$NEW_ID" || {
        log "Error: Failed to restore VM as $NEW_ID. Old VM $CURRENT_ID preserved."
        exit 2
    }
    log "Restored VM $NEW_ID"
    log "Starting VM $NEW_ID..."
    qm start "$NEW_ID" || {
        log "Error: Failed to start VM as $NEW_ID. Old VM $CURRENT_ID preserved."
        exit 2
    }
    log "Started VM $NEW_ID"
    if qm status "$NEW_ID" | grep -q "status: running"; then
        log "Success: VM ID changed from $CURRENT_ID to $NEW_ID and is running."
    else
        log "Error: VM $NEW_ID restored but not running. Old VM $CURRENT_ID preserved."
        log "Check logs with 'journalctl -u pve*'."
        exit 2
    fi
    if [ "$KEEP_ORIGINAL" -eq 0 ]; then
        log "Deleting original VM $CURRENT_ID..."
        qm destroy "$CURRENT_ID" || {
            log "Warning: Failed to delete original VM $CURRENT_ID. New VM $NEW_ID is running."
            exit 2
        }
        log "Deleted VM $CURRENT_ID"
    else
        log "--keep-original flag set. Skipping deletion of original VM $CURRENT_ID."
    fi
fi

exit 0