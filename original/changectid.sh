#!/bin/bash
# Script to change the CT ID of a Proxmox LXC container using backup and restore
# Uses the container's storage for backup, checks disk space before backup and restore
# Skips stop if container is already stopped, dynamically finds or creates backup
# Usage: ./change_ct_id.sh <current_ct_id> <new_ct_id>

# Initialize logging
LOG_FILE="/var/log/change_ct_id.log"
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" | tee -a "$LOG_FILE"
}

# Check if exactly 2 arguments are provided
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <current_ct_id> <new_ct_id>"
    log "Error: Invalid arguments"
    exit 1
fi

# Define variables
CURRENT_CT_ID="$1"
NEW_CT_ID="$2"

# Validate that both arguments are positive integers
if ! [[ "$CURRENT_CT_ID" =~ ^[0-9]+$ ]] || ! [[ "$NEW_CT_ID" =~ ^[0-9]+$ ]]; then
    echo "Error: Both CT IDs must be positive integers."
    log "Error: Invalid CT ID format"
    exit 1
fi

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run as root."
    log "Error: Not running as root"
    exit 1
fi

# Check if Proxmox tools are available
if ! command -v pct >/dev/null 2>&1 || ! command -v vzdump >/dev/null 2>&1 || ! command -v pvesm >/dev/null 2>&1; then
    echo "Error: Proxmox tools (pct, vzdump, or pvesm) not found. Is this a Proxmox system?"
    log "Error: Missing Proxmox tools"
    exit 2
fi

# Check if the current CT ID exists
if ! pct status "$CURRENT_CT_ID" >/dev/null 2>&1; then
    echo "Error: Container with ID $CURRENT_CT_ID does not exist."
    log "Error: CT $CURRENT_CT_ID not found"
    exit 1
fi

# Check if the new CT ID is already in use
if pct status "$NEW_CT_ID" >/dev/null 2>&1; then
    echo "Error: Container with ID $NEW_CT_ID already exists."
    log "Error: CT $NEW_CT_ID already exists"
    exit 1
fi

# Detect container storage from configuration
CONFIG_FILE="/etc/pve/lxc/$CURRENT_CT_ID.conf"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Configuration file $CONFIG_FILE not found."
    log "Error: Config file $CONFIG_FILE missing"
    exit 2
fi

# Extract storage from rootfs line
CONTAINER_STORAGE=$(grep '^rootfs:' "$CONFIG_FILE" | awk -F: '{print $2}' | awk '{print $1}')
if [ -z "$CONTAINER_STORAGE" ]; then
    echo "Error: Could not detect container storage from $CONFIG_FILE."
    log "Error: Failed to detect storage from $CONFIG_FILE"
    exit 2
fi

# Verify container storage exists
if ! pvesm status | grep -q "^$CONTAINER_STORAGE"; then
    echo "Error: Container storage '$CONTAINER_STORAGE' not found."
    log "Error: Storage $CONTAINER_STORAGE not found"
    exit 2
fi
echo "Detected container storage: $CONTAINER_STORAGE"
log "Detected container storage: $CONTAINER_STORAGE"

# Function to check available disk space (in bytes)
check_disk_space() {
    local storage="$1"
    local required_space="$2"
    local storage_path=$(pvesm status | grep "^$storage" | awk '{print $7}')
    if [ -z "$storage_path" ]; then
        echo "Error: Could not determine path for storage '$storage'."
        log "Error: Failed to get path for storage $storage"
        exit 2
    fi
    local available_space=$(df --block-size=1 --output=avail "$storage_path" | tail -n 1)
    if [ "$available_space" -lt "$required_space" ]; then
        echo "Error: Insufficient disk space on $storage_path."
        echo "Required: $((required_space / 1024 / 1024)) MB, Available: $((available_space / 1024 / 1024)) MB"
        log "Error: Insufficient space on $storage_path (Required: $required_space bytes, Available: $available_space bytes)"
        exit 2
    fi
    echo "Sufficient disk space on $storage_path: $((available_space / 1024 / 1024)) MB available"
    log "Sufficient space on $storage_path: $available_space bytes available"
}

# Estimate container size (try actual usage first, then config, then default)
CONTAINER_DISK=$(pvesm list "$CONTAINER_STORAGE" | grep "lxc/$CURRENT_CT_ID/" | awk '{print $2}' | head -n 1)
if [ -n "$CONTAINER_DISK" ]; then
    REQUIRED_SPACE=$CONTAINER_DISK
    log "Estimated container size from pvesm: $((REQUIRED_SPACE / 1024 / 1024)) MB"
else
    CONTAINER_SIZE=$(grep '^rootfs:' "$CONFIG_FILE" | grep -oP 'size=\K[^,]+' | head -n 1)
    if [ -n "$CONTAINER_SIZE" ]; then
        case "$CONTAINER_SIZE" in
            *G) REQUIRED_SPACE=$(echo "$CONTAINER_SIZE" | tr -d 'G'); REQUIRED_SPACE=$((REQUIRED_SPACE * 1024 * 1024 * 1024)) ;;
            *M) REQUIRED_SPACE=$(echo "$CONTAINER_SIZE" | tr -d 'M'); REQUIRED_SPACE=$((REQUIRED_SPACE * 1024 * 1024)) ;;
            *K) REQUIRED_SPACE=$(echo "$CONTAINER_SIZE" | tr -d 'K'); REQUIRED_SPACE=$((REQUIRED_SPACE * 1024)) ;;
            *) REQUIRED_SPACE=$((CONTAINER_SIZE * 1024 * 1024 * 1024)) ;;
        esac
        log "Estimated container size from config: $((REQUIRED_SPACE / 1024 / 1024)) MB"
    else
        REQUIRED_SPACE=$((10 * 1024 * 1024 * 1024)) # Default 10GB
        log "Warning: No size detected, using default 10GB"
    fi
fi
# Add 20% overhead for backup and restore
REQUIRED_SPACE=$((REQUIRED_SPACE + (REQUIRED_SPACE / 5)))

# Check disk space for backup
echo "Checking disk space for backup on $CONTAINER_STORAGE..."
check_disk_space "$CONTAINER_STORAGE" "$REQUIRED_SPACE"

# Check if the container is unprivileged
UNPRIVILEGED=""
if grep -q "unprivileged: 1" "$CONFIG_FILE"; then
    UNPRIVILEGED="--unprivileged"
    echo "Detected unprivileged container. Will use --unprivileged flag for restore."
    log "Detected unprivileged container"
fi

# Stop the container if running
echo "Checking container $CURRENT_CT_ID status..."
STATUS=$(pct status "$CURRENT_CT_ID" 2>/dev/null)
if echo "$STATUS" | grep -q "status: running"; then
    echo "Stopping container $CURRENT_CT_ID..."
    pct stop "$CURRENT_CT_ID" || {
        echo "Error: Failed to stop container $CURRENT_CT_ID."
        log "Error: Failed to stop CT $CURRENT_CT_ID"
        exit 2
    }
    log "Stopped CT $CURRENT_CT_ID"
else
    echo "Container $CURRENT_CT_ID is already stopped (status: $STATUS)."
    log "CT $CURRENT_CT_ID already stopped: $STATUS"
fi

# Check for existing backup or create a new one
echo "Searching for existing backup for CT $CURRENT_CT_ID..."
BACKUP_FILE=$(pvesm list "$CONTAINER_STORAGE" | grep "vzdump-lxc-$CURRENT_CT_ID-" | awk '{print $1}' | head -n 1)
if [ -n "$BACKUP_FILE" ]; then
    BACKUP_PATH=$(pvesm path "$BACKUP_FILE")
    if [ -f "$BACKUP_PATH" ]; then
        echo "Found existing backup: $BACKUP_PATH"
        log "Found existing backup: $BACKUP_PATH"
    else
        BACKUP_FILE=""
    fi
fi
if [ -z "$BACKUP_FILE" ]; then
    echo "No existing backup found. Creating new backup on $CONTAINER_STORAGE..."
    VZDUMP_OUTPUT=$(vzdump "$CURRENT_CT_ID" --compress zstd --storage "$CONTAINER_STORAGE" --mode snapshot 2>&1)
    VZDUMP_STATUS=$?
    if [ $VZDUMP_STATUS -ne 0 ]; then
        echo "Error: Backup failed for container $CURRENT_CT_ID."
        echo "$VZDUMP_OUTPUT"
        if echo "$VZDUMP_OUTPUT" | grep -q "Permission denied"; then
            echo "Hint: Check storage permissions for $CONTAINER_STORAGE."
        elif echo "$VZDUMP_OUTPUT" | grep -q "No space left"; then
            echo "Hint: Storage $CONTAINER_STORAGE may be full."
        fi
        log "Error: Backup failed for CT $CURRENT_CT_ID: $VZDUMP_OUTPUT"
        exit 2
    fi
    BACKUP_FILE=$(echo "$VZDUMP_OUTPUT" | grep -oP "creating vzdump archive '\K[^']+" | head -n 1)
    if [ -z "$BACKUP_FILE" ] || [ ! -f "$BACKUP_FILE" ]; then
        echo "Error: No backup file found after vzdump."
        log "Error: No backup file found after vzdump"
        exit 2
    fi
    echo "New backup created: $BACKUP_FILE"
    log "New backup created: $BACKUP_FILE"
fi

# Check disk space for restore
echo "Checking disk space for restore on $CONTAINER_STORAGE..."
check_disk_space "$CONTAINER_STORAGE" "$REQUIRED_SPACE"

# Delete the original container
echo "Deleting original container $CURRENT_CT_ID..."
pct destroy "$CURRENT_CT_ID" || {
    echo "Error: Failed to delete container $CURRENT_CT_ID."
    log "Error: Failed to delete CT $CURRENT_CT_ID"
    exit 2
}
log "Deleted CT $CURRENT_CT_ID"

# Restore the container with the new CT ID
echo "Restoring container as $NEW_CT_ID..."
pct restore "$NEW_CT_ID" "$BACKUP_FILE" --storage "$CONTAINER_STORAGE" $UNPRIVILEGED || {
    echo "Error: Failed to restore container as $NEW_CT_ID."
    log "Error: Failed to restore CT $NEW_CT_ID"
    exit 2
}
log "Restored CT $NEW_CT_ID"

# Start the new container
echo "Starting container $NEW_CT_ID..."
pct start "$NEW_CT_ID" || {
    echo "Error: Failed to start container $NEW_CT_ID."
    log "Error: Failed to start CT $NEW_CT_ID"
    exit 2
}
log "Started CT $NEW_CT_ID"

# Verify the container is running
if pct status "$NEW_CT_ID" | grep -q "status: running"; then
    echo "Success: Container ID changed from $CURRENT_CT_ID to $NEW_CT_ID and is running."
    log "Success: Changed CT $CURRENT_CT_ID to $NEW_CT_ID"
else
    echo "Warning: Container $NEW_CT_ID restored but not running. Check logs with 'journalctl -u pve*'."
    log "Warning: CT $NEW_CT_ID not running"
    exit 2
fi

# Optional cleanup (commented out)
# echo "Cleaning up backup file $BACKUP_FILE..."
# rm -f "$BACKUP_FILE"
# log "Cleaned up backup: $BACKUP_FILE"

exit 0