#!/bin/bash
#
# Steam Animation Manager Daemon (Bash Version)
# Native systemd service for Steam Deck animation management
# Fixes all issues with the Python plugin approach
#

set -euo pipefail

# Global configuration
DAEMON_NAME="steam-animation-daemon"
VERSION="1.0.0"
CONFIG_FILE="${CONFIG_FILE:-/etc/steam-animation-manager/config.conf}"
PID_FILE="/run/user/$UID/steam-animation-daemon.pid"
LOG_FILE="/tmp/steam-animation-daemon.log"

# Use existing SDH-AnimationChanger plugin paths (actual folder name)
# DECKY_PLUGIN_RUNTIME_DIR = ~/homebrew/data/SDH-AnimationChanger/
ANIMATIONS_DIR="${HOME}/homebrew/data/SDH-AnimationChanger/animations"
DOWNLOADS_DIR="${HOME}/homebrew/data/SDH-AnimationChanger/downloads"
STEAM_OVERRIDE_DIR="${HOME}/.steam/root/config/uioverrides/movies"
CACHE_DIR="/tmp/steam-animation-cache"

# Animation files
BOOT_VIDEO="deck_startup.webm"
SUSPEND_VIDEO="steam_os_suspend.webm"
THROBBER_VIDEO="steam_os_suspend_from_throbber.webm"

# State variables
CURRENT_BOOT=""
CURRENT_SUSPEND=""
CURRENT_THROBBER=""
RANDOMIZE_MODE="disabled"
MAX_DURATION=5
STEAM_RUNNING=false
WAS_SUSPENDED=false

# Logging functions
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$1] $2" | tee -a "$LOG_FILE"
}

log_info() { log "INFO" "$1"; }
log_warn() { log "WARN" "$1"; }
log_error() { log "ERROR" "$1"; }
log_debug() { log "DEBUG" "$1"; }

# Signal handlers
cleanup() {
    log_info "Shutting down Steam Animation Daemon..."
    
    # Unmount any active animations
    unmount_all_animations
    
    # Remove PID file
    rm -f "$PID_FILE"
    
    exit 0
}

reload_config() {
    log_info "Reloading configuration..."
    load_config
    load_animations
}

# Setup signal handlers
trap cleanup SIGTERM SIGINT
trap reload_config SIGHUP

# Configuration management
create_default_config() {
    cat > "$CONFIG_FILE" << 'EOF'
# Steam Animation Manager Configuration

# Current animation selections (full paths or empty for default Steam animations)
# Examples:
# CURRENT_BOOT="/home/deck/homebrew/data/Animation Changer/downloads/some-animation.webm"
# CURRENT_BOOT="/home/deck/homebrew/data/Animation Changer/animations/set-name/deck_startup.webm"
CURRENT_BOOT=""
CURRENT_SUSPEND=""
CURRENT_THROBBER=""

# Randomization: disabled, per_boot, per_set
# per_boot: Randomly select from all downloaded animations for each boot
RANDOMIZE_MODE="disabled"

# Video processing (fixes stuck animations!)
MAX_DURATION=5          # Max animation duration in seconds (prevents stuck playback)
VIDEO_QUALITY=23        # FFmpeg CRF value (lower = better quality)
TARGET_WIDTH=1280       # Steam Deck width
TARGET_HEIGHT=720       # Steam Deck height

# Cache settings
MAX_CACHE_MB=500        # Maximum cache size in MB
CACHE_MAX_DAYS=30       # Remove cached files older than this

# Exclusions for randomization (filenames to skip)
# Example: SHUFFLE_EXCLUSIONS="annoying-sound.webm boring-animation.webm"
SHUFFLE_EXCLUSIONS=""   

# Debug mode
DEBUG_MODE=false

# NOTE: Downloaded animations (from plugin) are in:
# /home/deck/homebrew/data/SDH-AnimationChanger/downloads/
# Animation sets are in:
# /home/deck/homebrew/data/SDH-AnimationChanger/animations/
EOF
}

load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_info "Config file not found, creating default config"
        mkdir -p "$(dirname "$CONFIG_FILE")"
        create_default_config
    fi
    
    # Source the configuration
    source "$CONFIG_FILE"
    
    # Override with any provided values
    CURRENT_BOOT="${CURRENT_BOOT:-}"
    CURRENT_SUSPEND="${CURRENT_SUSPEND:-}"
    CURRENT_THROBBER="${CURRENT_THROBBER:-}"
    RANDOMIZE_MODE="${RANDOMIZE_MODE:-disabled}"
    MAX_DURATION="${MAX_DURATION:-5}"
    VIDEO_QUALITY="${VIDEO_QUALITY:-23}"
    TARGET_WIDTH="${TARGET_WIDTH:-1280}"
    TARGET_HEIGHT="${TARGET_HEIGHT:-720}"
    MAX_CACHE_MB="${MAX_CACHE_MB:-500}"
    CACHE_MAX_DAYS="${CACHE_MAX_DAYS:-30}"
    DEBUG_MODE="${DEBUG_MODE:-false}"
    
    log_info "Configuration loaded: randomize=$RANDOMIZE_MODE, max_duration=${MAX_DURATION}s"
}

# Directory setup
setup_directories() {
    log_info "Setting up directories..."
    
    mkdir -p "$ANIMATIONS_DIR"
    mkdir -p "$DOWNLOADS_DIR"  
    mkdir -p "$STEAM_OVERRIDE_DIR"
    mkdir -p "$CACHE_DIR"
    mkdir -p "$(dirname "$PID_FILE")"
    
    log_info "Directories created successfully"
}

# Steam process monitoring
is_steam_running() {
    pgrep -f "steam" >/dev/null 2>&1
}

monitor_steam_processes() {
    local was_running=$STEAM_RUNNING
    STEAM_RUNNING=$(is_steam_running && echo true || echo false)
    
    if [[ "$STEAM_RUNNING" == "true" && "$was_running" == "false" ]]; then
        log_info "Steam started - preparing boot animation"
        handle_steam_start
    elif [[ "$STEAM_RUNNING" == "false" && "$was_running" == "true" ]]; then
        log_info "Steam stopped - cleaning up"
        handle_steam_stop
    fi
}

handle_steam_start() {
    prepare_boot_animation
}

handle_steam_stop() {
    unmount_all_animations
}

# System event monitoring via journalctl
monitor_system_events() {
    if ! command -v journalctl >/dev/null 2>&1; then
        log_warn "journalctl not available - system event monitoring disabled"
        return
    fi
    
    log_debug "Starting system event monitoring"
    journalctl -f -u systemd-suspend.service -u systemd-hibernate.service --no-pager 2>/dev/null | while read -r line; do
        if [[ "$line" =~ (suspend|Suspending) ]]; then
            log_info "System suspend detected"
            WAS_SUSPENDED=true
            prepare_suspend_animation
        elif [[ "$line" =~ (resume|resumed) ]]; then
            log_info "System resume detected"
            if [[ "$WAS_SUSPENDED" == "true" ]]; then
                WAS_SUSPENDED=false
                prepare_boot_animation
            fi
        fi
    done &
}

# Animation discovery
load_animations() {
    log_info "Loading animations from directories..."
    
    local anim_count=0
    local dl_count=0
    
    # Count animations in traditional animation sets directory
    if [[ -d "$ANIMATIONS_DIR" ]]; then
        anim_count=$(find "$ANIMATIONS_DIR" -name "*.webm" | wc -l)
    fi
    
    # Count downloaded animations (from plugin downloads)
    if [[ -d "$DOWNLOADS_DIR" ]]; then
        dl_count=$(find "$DOWNLOADS_DIR" -name "*.webm" | wc -l)
    fi
    
    log_info "Found $anim_count animation files, $dl_count downloaded files"
    
    if [[ $dl_count -gt 0 ]]; then
        log_info "Downloaded animations will be used for boot animations"
    fi
}

# Video processing functions
optimize_video() {
    local input="$1"
    local output="$2"
    
    log_info "Optimizing video: $(basename "$input")"
    
    # Generate cache key based on file path and modification time
    local cache_key
    cache_key=$(echo "${input}$(stat -c %Y "$input" 2>/dev/null || echo 0)" | sha256sum | cut -c1-16)
    local cached_file="$CACHE_DIR/${cache_key}.webm"
    
    # Return cached version if exists
    if [[ -f "$cached_file" ]]; then
        log_debug "Using cached optimized video: $cached_file"
        cp "$cached_file" "$output"
        return 0
    fi
    
    # Process with ffmpeg
    if ! command -v ffmpeg >/dev/null 2>&1; then
        log_error "ffmpeg not found - copying original file"
        cp "$input" "$output"
        return 1
    fi
    
    # FFmpeg optimization for Steam Deck
    if ffmpeg -y \
        -i "$input" \
        -t "$MAX_DURATION" \
        -vf "scale=${TARGET_WIDTH}:${TARGET_HEIGHT}:force_original_aspect_ratio=decrease,pad=${TARGET_WIDTH}:${TARGET_HEIGHT}:-1:-1:black" \
        -c:v libvpx-vp9 \
        -crf "$VIDEO_QUALITY" \
        -speed 4 \
        -row-mt 1 \
        -tile-columns 2 \
        -c:a libopus \
        -b:a 64k \
        -f webm \
        "$output" 2>/dev/null; then
        
        # Cache the optimized version
        cp "$output" "$cached_file"
        log_info "Video optimized and cached: $(basename "$input")"
        return 0
    else
        log_warn "FFmpeg optimization failed, using original"
        cp "$input" "$output"
        return 1
    fi
}

# Animation mounting - try bind mount, fall back to symlink
mount_animation() {
    local source="$1"
    local target="$2"
    local anim_type="$3"
    
    log_debug "Applying $anim_type animation: $(basename "$source") -> $(basename "$target")"
    
    # Remove existing file/symlink/mount
    unmount_animation "$target"
    
    # Try bind mount first (requires special permissions)
    touch "$target" 2>/dev/null || true
    if mount --bind "$source" "$target" 2>/dev/null; then
        log_info "Bind mounted $anim_type animation: $(basename "$source")"
        return 0
    fi
    
    # Fall back to symlink (works without special permissions)
    rm -f "$target"
    if ln -sf "$source" "$target" 2>/dev/null; then
        log_info "Symlinked $anim_type animation: $(basename "$source")"
        return 0
    fi
    
    # Fall back to copying file (always works)
    if cp "$source" "$target" 2>/dev/null; then
        log_info "Copied $anim_type animation: $(basename "$source")"
        return 0
    fi
    
    log_error "Failed to apply $anim_type animation: $(basename "$source")"
    return 1
}

unmount_animation() {
    local target="$1"
    
    # Try to unmount if it's a mount point
    if mountpoint -q "$target" 2>/dev/null; then
        if umount "$target" 2>/dev/null; then
            log_debug "Unmounted: $(basename "$target")"
        fi
    fi
    
    # Remove file/symlink
    if [[ -e "$target" || -L "$target" ]]; then
        rm -f "$target"
        log_debug "Removed: $(basename "$target")"
    fi
}

unmount_all_animations() {
    log_debug "Unmounting all animations"
    
    unmount_animation "$STEAM_OVERRIDE_DIR/$BOOT_VIDEO"
    unmount_animation "$STEAM_OVERRIDE_DIR/$SUSPEND_VIDEO" 
    unmount_animation "$STEAM_OVERRIDE_DIR/$THROBBER_VIDEO"
}

# Animation selection and application
select_random_animation() {
    local anim_type="$1"
    
    # Find all animations of this type
    local candidates=()
    
    # Check downloads directory (where plugin downloads go) - these are individual files
    if [[ -d "$DOWNLOADS_DIR" ]]; then
        while IFS= read -r -d '' file; do
            local basename_file
            basename_file=$(basename "$file")
            # Skip if in exclusion list
            if [[ " $SHUFFLE_EXCLUSIONS " == *" $basename_file "* ]]; then
                continue
            fi
            
            # For downloads, all files are treated as boot animations by default
            # (the plugin downloads boot animations primarily)
            if [[ "$anim_type" == "boot" ]]; then
                candidates+=("$file")
            fi
        done < <(find "$DOWNLOADS_DIR" -name "*.webm" -print0 2>/dev/null || true)
    fi
    
    # Check animations directory (traditional sets)
    if [[ -d "$ANIMATIONS_DIR" ]]; then
        local pattern
        case "$anim_type" in
            "boot") pattern="*$BOOT_VIDEO" ;;
            "suspend") pattern="*$SUSPEND_VIDEO" ;;
            "throbber") pattern="*$THROBBER_VIDEO" ;;
            *) pattern="*.webm" ;;
        esac
        
        while IFS= read -r -d '' file; do
            local basename_file
            basename_file=$(basename "$file")
            # Skip if in exclusion list
            if [[ " $SHUFFLE_EXCLUSIONS " == *" $basename_file "* ]]; then
                continue
            fi
            candidates+=("$file")
        done < <(find "$ANIMATIONS_DIR" -name "$pattern" -print0 2>/dev/null || true)
    fi
    
    if [[ ${#candidates[@]} -eq 0 ]]; then
        log_debug "No $anim_type animations found"
        return 1
    fi
    
    # Select random candidate
    local selected="${candidates[$RANDOM % ${#candidates[@]}]}"
    echo "$selected"
}

apply_animation() {
    local anim_type="$1"
    local source_file="$2"
    local target_file="$3"
    
    if [[ ! -f "$source_file" ]]; then
        log_error "Animation file not found: $source_file"
        return 1
    fi
    
    # Create optimized version
    local optimized_file="$CACHE_DIR/$(basename "$source_file" .webm)_optimized.webm"
    
    if ! optimize_video "$source_file" "$optimized_file"; then
        log_warn "Using original file due to optimization failure"
        optimized_file="$source_file"
    fi
    
    # Mount the animation
    mount_animation "$optimized_file" "$target_file" "$anim_type"
}

prepare_boot_animation() {
    log_info "Preparing boot animation"
    
    local source_file=""
    
    case "$RANDOMIZE_MODE" in
        "disabled")
            if [[ -n "$CURRENT_BOOT" && -f "$CURRENT_BOOT" ]]; then
                source_file="$CURRENT_BOOT"
            fi
            ;;
        "per_boot")
            source_file=$(select_random_animation "boot")
            ;;
        "per_set")
            # TODO: Implement set-based randomization
            source_file=$(select_random_animation "boot")
            ;;
    esac
    
    if [[ -n "$source_file" ]]; then
        apply_animation "boot" "$source_file" "$STEAM_OVERRIDE_DIR/$BOOT_VIDEO"
    else
        log_info "No boot animation configured, using Steam default"
    fi
}

prepare_suspend_animation() {
    log_info "Preparing suspend animation"
    
    local source_file=""
    
    if [[ -n "$CURRENT_SUSPEND" && -f "$CURRENT_SUSPEND" ]]; then
        source_file="$CURRENT_SUSPEND"
    else
        source_file=$(select_random_animation "suspend")
    fi
    
    if [[ -n "$source_file" ]]; then
        apply_animation "suspend" "$source_file" "$STEAM_OVERRIDE_DIR/$SUSPEND_VIDEO"
    fi
    
    # Also handle throbber animation (in-game suspend)
    local throbber_file=""
    if [[ -n "$CURRENT_THROBBER" && -f "$CURRENT_THROBBER" ]]; then
        throbber_file="$CURRENT_THROBBER"
    else
        throbber_file=$(select_random_animation "throbber")
    fi
    
    if [[ -n "$throbber_file" ]]; then
        apply_animation "throbber" "$throbber_file" "$STEAM_OVERRIDE_DIR/$THROBBER_VIDEO"
    fi
}

# Cache management
cleanup_cache() {
    log_debug "Cleaning up video cache"
    
    if [[ ! -d "$CACHE_DIR" ]]; then
        log_debug "Cache directory doesn't exist, skipping cleanup"
        return 0
    fi
    
    # Remove files older than CACHE_MAX_DAYS (if any exist)
    local old_files
    old_files=$(find "$CACHE_DIR" -type f -name "*.webm" -mtime +$CACHE_MAX_DAYS 2>/dev/null | wc -l)
    if [[ $old_files -gt 0 ]]; then
        log_debug "Removing $old_files old cache files"
        find "$CACHE_DIR" -type f -name "*.webm" -mtime +$CACHE_MAX_DAYS -delete 2>/dev/null || true
    fi
    
    # Check cache size and remove oldest files if needed
    local cache_size_kb
    cache_size_kb=$(du -sk "$CACHE_DIR" 2>/dev/null | cut -f1 || echo 0)
    local max_cache_kb=$((MAX_CACHE_MB * 1024))
    
    if [[ $cache_size_kb -gt $max_cache_kb ]]; then
        log_info "Cache size ${cache_size_kb}KB exceeds limit ${max_cache_kb}KB, cleaning up"
        
        # Simple approach: remove all cache files and let them regenerate
        # This avoids complex sorting that might hang
        local files_removed=0
        for file in "$CACHE_DIR"/*.webm; do
            if [[ -f "$file" ]]; then
                rm -f "$file"
                ((files_removed++))
                # Check size after each removal
                cache_size_kb=$(du -sk "$CACHE_DIR" 2>/dev/null | cut -f1 || echo 0)
                if [[ $cache_size_kb -le $max_cache_kb ]]; then
                    break
                fi
            fi
        done
        log_debug "Removed $files_removed cache files"
    fi
    
    log_debug "Cache cleanup completed"
}

# Main daemon loop
main_loop() {
    log_info "Starting main daemon loop"
    
    local maintenance_counter=0
    
    while true; do
        # Monitor Steam processes
        monitor_steam_processes
        
        # Periodic maintenance every 5 minutes (300 seconds)
        ((maintenance_counter++))
        if [[ $maintenance_counter -ge 300 ]]; then
            log_debug "Running periodic maintenance"
            cleanup_cache
            maintenance_counter=0
        fi
        
        sleep 1
    done
}

# Daemon management
start_daemon() {
    # Check if already running when called manually (not from systemd)
    if [[ -z "$SYSTEMD_EXEC_PID" && -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        log_error "Daemon already running (PID: $(cat "$PID_FILE"))"
        exit 1
    fi
    
    log_info "Starting Steam Animation Daemon v$VERSION"
    
    # Write PID file
    echo $$ > "$PID_FILE"
    
    # Setup
    setup_directories
    load_config
    load_animations
    
    # Start system event monitoring
    monitor_system_events
    
    log_info "Steam Animation Daemon started successfully"
    
    # Run main loop
    main_loop
}

# Command line interface
show_help() {
    cat << EOF
Steam Animation Manager Daemon v$VERSION

Usage: $0 [COMMAND] [OPTIONS]

Commands:
    start           Start the daemon (default)
    stop            Stop the daemon
    restart         Restart the daemon
    status          Show daemon status
    reload          Reload configuration
    help            Show this help

Options:
    -c, --config    Configuration file path
    -d, --debug     Enable debug mode
    -h, --help      Show help

Examples:
    $0 start
    $0 --config /custom/config.conf start
    $0 status

Configuration file: $CONFIG_FILE
EOF
}

show_status() {
    if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        local pid
        pid=$(cat "$PID_FILE")
        echo "Steam Animation Daemon is running (PID: $pid)"
        
        # Show current animations
        echo "Current animations:"
        echo "  Boot: ${CURRENT_BOOT:-default}"
        echo "  Suspend: ${CURRENT_SUSPEND:-default}" 
        echo "  Throbber: ${CURRENT_THROBBER:-default}"
        echo "  Randomize: $RANDOMIZE_MODE"
        
        return 0
    else
        echo "Steam Animation Daemon is not running"
        return 1
    fi
}

stop_daemon() {
    if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        local pid
        pid=$(cat "$PID_FILE")
        echo "Stopping Steam Animation Daemon (PID: $pid)"
        kill "$pid"
        
        # Wait for graceful shutdown
        local count=0
        while kill -0 "$pid" 2>/dev/null && [[ $count -lt 10 ]]; do
            sleep 1
            ((count++))
        done
        
        if kill -0 "$pid" 2>/dev/null; then
            echo "Force killing daemon"
            kill -9 "$pid"
        fi
        
        rm -f "$PID_FILE"
        echo "Daemon stopped"
        return 0
    else
        echo "Daemon is not running"
        return 1
    fi
}

# Main entry point
main() {
    local command="start"
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            start|stop|restart|status|reload|help)
                command="$1"
                ;;
            -c|--config)
                CONFIG_FILE="$2"
                shift
                ;;
            -d|--debug)
                DEBUG_MODE=true
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
        shift
    done
    
    # Execute command
    case "$command" in
        start)
            start_daemon
            ;;
        stop)
            stop_daemon
            ;;
        restart)
            stop_daemon
            sleep 2
            start_daemon
            ;;
        status)
            show_status
            ;;
        reload)
            if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
                kill -HUP "$(cat "$PID_FILE")"
                echo "Configuration reloaded"
            else
                echo "Daemon is not running"
                exit 1
            fi
            ;;
        help)
            show_help
            ;;
        *)
            echo "Unknown command: $command"
            show_help
            exit 1
            ;;
    esac
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi