#!/bin/bash
#
# Steam Animation Suspend Hook
# This script is called by systemd before suspend to play animation
# Install to: /usr/lib/systemd/system-sleep/
#

set -euo pipefail

# Configuration
CONFIG_FILE="/etc/steam-animation-manager/config.conf"
STEAM_OVERRIDE_DIR="${HOME}/.steam/root/config/uioverrides/movies"
SUSPEND_VIDEO="steam_os_suspend.webm"
THROBBER_VIDEO="steam_os_suspend_from_throbber.webm"
LOG_FILE="/tmp/steam-animation-suspend.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
}

get_video_duration() {
    local video_file="$1"
    local duration
    
    if command -v ffprobe >/dev/null 2>&1; then
        duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$video_file" 2>/dev/null || echo "3")
        # Round up to nearest second
        duration=$(echo "$duration" | awk '{print int($1 + 0.999)}')
        echo "$duration"
    else
        echo "3"  # Default 3 seconds
    fi
}

case "$1" in
    pre)
        # This runs BEFORE suspend
        if [[ "$2" == "suspend" || "$2" == "hibernate" || "$2" == "hybrid-sleep" ]]; then
            log "Pre-suspend hook triggered"
            
            # Check if we have a suspend animation
            if [[ -L "$STEAM_OVERRIDE_DIR/$SUSPEND_VIDEO" || -f "$STEAM_OVERRIDE_DIR/$SUSPEND_VIDEO" ]]; then
                # Get the actual animation file
                local anim_file
                if [[ -L "$STEAM_OVERRIDE_DIR/$SUSPEND_VIDEO" ]]; then
                    anim_file=$(readlink -f "$STEAM_OVERRIDE_DIR/$SUSPEND_VIDEO")
                else
                    anim_file="$STEAM_OVERRIDE_DIR/$SUSPEND_VIDEO"
                fi
                
                if [[ -f "$anim_file" ]]; then
                    log "Playing suspend animation for 10s: $anim_file"
                    
                    # Default 10 second delay for suspend animation
                    sleep 10
                    
                    # Clear the suspend animation so it doesn't show on wake up
                    rm -f "$STEAM_OVERRIDE_DIR/$SUSPEND_VIDEO"
                    rm -f "$STEAM_OVERRIDE_DIR/$THROBBER_VIDEO"
                    
                    log "Animation complete, cleared suspend animations, proceeding with suspend"
                fi
            else
                log "No suspend animation configured"
            fi
        fi
        ;;
    post)
        # This runs AFTER resume
        if [[ "$2" == "suspend" || "$2" == "hibernate" || "$2" == "hybrid-sleep" ]]; then
            log "Post-resume hook triggered"
            # Nothing to do on resume, boot animation is handled by daemon
        fi
        ;;
esac

exit 0