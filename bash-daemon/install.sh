#!/bin/bash
#
# Steam Animation Manager - Bash Version Installer
# Simple installation script for SteamOS without compilation requirements
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DAEMON_SCRIPT="steam-animation-daemon.sh"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/steam-animation-manager"
SYSTEMD_DIR="/etc/systemd/system"
USER="${STEAM_USER:-deck}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_requirements() {
    log_info "Checking system requirements..."
    
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        log_error "Please run as root (use sudo)"
        exit 1
    fi
    
    # Check for required commands
    local missing=()
    
    for cmd in systemctl mount umount ffmpeg; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done
    
    if [ ${#missing[@]} -ne 0 ]; then
        log_error "Missing required commands: ${missing[*]}"
        
        if [[ " ${missing[*]} " =~ " ffmpeg " ]]; then
            log_info "Install ffmpeg with: sudo pacman -S ffmpeg"
        fi
        
        exit 1
    fi
    
    log_success "All requirements satisfied"
}

handle_steamos_readonly() {
    # Check if we're on SteamOS
    if command -v steamos-readonly >/dev/null 2>&1; then
        log_info "SteamOS detected - handling readonly filesystem"
        
        # Check current readonly status
        if steamos-readonly status 2>/dev/null | grep -q "enabled"; then
            log_info "Disabling SteamOS readonly mode for installation"
            steamos-readonly disable
            READONLY_WAS_ENABLED=true
        else
            log_info "SteamOS readonly mode already disabled"
            READONLY_WAS_ENABLED=false
        fi
    fi
}

restore_steamos_readonly() {
    # Restore readonly mode if we disabled it
    if [ "$READONLY_WAS_ENABLED" = true ] && command -v steamos-readonly >/dev/null 2>&1; then
        log_info "Re-enabling SteamOS readonly mode"
        steamos-readonly enable
    fi
}

install_daemon() {
    log_info "Installing Steam Animation Manager daemon..."
    
    # Copy daemon script
    cp "$SCRIPT_DIR/$DAEMON_SCRIPT" "$INSTALL_DIR/"
    chmod +x "$INSTALL_DIR/$DAEMON_SCRIPT"
    
    log_success "Daemon installed to $INSTALL_DIR/$DAEMON_SCRIPT"
}

setup_config() {
    log_info "Setting up configuration..."
    
    mkdir -p "$CONFIG_DIR"
    
    # Create default config if it doesn't exist
    if [ ! -f "$CONFIG_DIR/config.conf" ]; then
        cat > "$CONFIG_DIR/config.conf" << 'EOF'
# Steam Animation Manager Configuration

# Current animation selections (full paths or empty for default)
CURRENT_BOOT=""
CURRENT_SUSPEND=""
CURRENT_THROBBER=""

# Randomization: disabled, per_boot, per_set
RANDOMIZE_MODE="disabled"

# Video processing settings
MAX_DURATION=5          # Max animation duration in seconds
VIDEO_QUALITY=23        # FFmpeg CRF value (lower = better quality)
TARGET_WIDTH=1280       # Steam Deck width
TARGET_HEIGHT=720       # Steam Deck height

# Cache settings
MAX_CACHE_MB=500        # Maximum cache size in MB
CACHE_MAX_DAYS=30       # Remove cached files older than this

# Randomization exclusions (space-separated animation IDs)
SHUFFLE_EXCLUSIONS=""

# Debug mode
DEBUG_MODE=false
EOF
        log_success "Default configuration created at $CONFIG_DIR/config.conf"
    else
        log_warning "Configuration already exists at $CONFIG_DIR/config.conf"
    fi
    
    # Set proper permissions
    chown -R "$USER:$USER" "$CONFIG_DIR"
}

install_systemd_service() {
    log_info "Installing systemd service..."
    
    # Install to user systemd directory
    local user_systemd_dir="/home/$USER/.config/systemd/user"
    sudo -u "$USER" mkdir -p "$user_systemd_dir"
    
    # Copy service file to user directory
    cp "$SCRIPT_DIR/steam-animation-manager.service" "$user_systemd_dir/"
    chown "$USER:$USER" "$user_systemd_dir/steam-animation-manager.service"
    
    # Reload user systemd
    sudo -u "$USER" XDG_RUNTIME_DIR="/run/user/$(id -u $USER)" systemctl --user daemon-reload
    
    log_success "Systemd user service installed"
}

setup_user_directories() {
    log_info "Setting up user directories..."
    
    local user_home="/home/$USER"
    local animations_dir="$user_home/homebrew/data/SDH-AnimationChanger"
    
    # Create directories using existing plugin structure
    sudo -u "$USER" mkdir -p "$animations_dir/animations"
    sudo -u "$USER" mkdir -p "$animations_dir/downloads"
    sudo -u "$USER" mkdir -p "$user_home/.steam/root/config/uioverrides/movies"
    
    # Create example animation structure if none exists
    if [ ! -d "$animations_dir/animations" ] || [ -z "$(ls -A "$animations_dir/animations" 2>/dev/null)" ]; then
        sudo -u "$USER" mkdir -p "$animations_dir/animations/example"
        sudo -u "$USER" cat > "$animations_dir/animations/README.md" << 'EOF'
# Animation Changer - Compatible Directory Structure

This directory is compatible with both the original Animation Changer plugin 
and the new native bash daemon.

Place your animation sets in subdirectories here:

- `deck_startup.webm` - Boot animation
- `steam_os_suspend.webm` - Suspend animation (outside games)
- `steam_os_suspend_from_throbber.webm` - Suspend animation (in-game)

Example structure:
```
animations/
├── cool-boot-animation/
│   └── deck_startup.webm
├── complete-set/
│   ├── deck_startup.webm
│   ├── steam_os_suspend.webm
│   └── steam_os_suspend_from_throbber.webm
└── another-set/
    └── deck_startup.webm
```

The bash daemon will automatically find and optimize these animations,
and you can still use the React frontend to download new ones!
EOF
    fi
    
    log_success "User directories ready (compatible with existing plugin)"
}

check_plugin_compatibility() {
    log_info "Checking 'Animation Changer' plugin compatibility..."
    
# Plugin paths based on actual folder name "SDH-AnimationChanger"
    local plugin_data="/home/$USER/homebrew/data/SDH-AnimationChanger"
    local plugin_config="/home/$USER/homebrew/settings/SDH-AnimationChanger/config.json"
    
    if [ -d "$plugin_data" ]; then
        local anim_count=0
        local dl_count=0
        
        if [ -d "$plugin_data/animations" ]; then
            anim_count=$(find "$plugin_data/animations" -name "*.webm" | wc -l)
        fi
        
        if [ -d "$plugin_data/downloads" ]; then
            dl_count=$(find "$plugin_data/downloads" -name "*.webm" | wc -l)
        fi
        
        log_success "Found existing plugin data: $anim_count animations, $dl_count downloads"
        log_info "Bash daemon will use existing files - no migration needed!"
        
        if [ -f "$plugin_config" ]; then
            log_info "Plugin config found at: $plugin_config"
            log_info "You can keep using the React frontend for downloads"
            log_info "Bash daemon config: $CONFIG_DIR/config.conf"
        fi
    else
        log_info "No existing plugin data found - will create fresh directories"
    fi
}

enable_service() {
    log_info "Enabling Steam Animation Manager service..."
    
    # Enable service for the deck user using proper environment
    sudo -u "$USER" XDG_RUNTIME_DIR="/run/user/$(id -u $USER)" systemctl --user enable steam-animation-manager.service
    
    log_success "Service enabled for user $USER"
    log_info "Service will start automatically on next login"
    log_info ""
    log_info "To start now (run as $USER):"
    log_info "systemctl --user start steam-animation-manager.service"
    log_info ""
    log_info "Or to start immediately:"
    sudo -u "$USER" XDG_RUNTIME_DIR="/run/user/$(id -u $USER)" systemctl --user start steam-animation-manager.service
    log_success "Service started!"
}

test_installation() {
    log_info "Testing installation..."
    
    # Test daemon script
    if "$INSTALL_DIR/$DAEMON_SCRIPT" help >/dev/null 2>&1; then
        log_success "Daemon script is working"
    else
        log_warning "Daemon script test failed"
    fi
    
    # Test systemd service
    if sudo -u "$USER" XDG_RUNTIME_DIR="/run/user/$(id -u $USER)" systemctl --user list-unit-files steam-animation-manager.service >/dev/null 2>&1; then
        log_success "Systemd service is registered"
    else
        log_warning "Systemd service registration issue"
    fi
}

cleanup_old_installation() {
    log_info "Cleaning up any old installation..."
    
    # Stop old service if running (both system and user locations)
    sudo -u "$USER" XDG_RUNTIME_DIR="/run/user/$(id -u $USER)" systemctl --user stop steam-animation-manager.service 2>/dev/null || true
    sudo -u "$USER" XDG_RUNTIME_DIR="/run/user/$(id -u $USER)" systemctl --user disable steam-animation-manager.service 2>/dev/null || true
    systemctl stop steam-animation-manager.service 2>/dev/null || true
    systemctl disable steam-animation-manager.service 2>/dev/null || true
    
    # Remove old files from all possible locations
    rm -f /usr/bin/steam-animation-daemon
    rm -f /usr/local/bin/steam-animation-daemon
    rm -f "$SYSTEMD_DIR/steam-animation-manager.service"
    rm -f "/home/$USER/.config/systemd/user/steam-animation-manager.service"
    
    # Reload both systemd instances
    systemctl daemon-reload 2>/dev/null || true
    sudo -u "$USER" XDG_RUNTIME_DIR="/run/user/$(id -u $USER)" systemctl --user daemon-reload 2>/dev/null || true
}

show_status() {
    log_info "Installation Summary"
    log_info "===================="
    echo "Daemon script: $INSTALL_DIR/$DAEMON_SCRIPT"
    echo "Configuration: $CONFIG_DIR/config.conf"
    echo "Service file: /home/$USER/.config/systemd/user/steam-animation-manager.service"
    echo "Animation directory: /home/$USER/homebrew/data/SDH-AnimationChanger/animations/"
    echo ""
    log_info "Service Management:"
    echo "Start:  systemctl --user start steam-animation-manager.service"
    echo "Stop:   systemctl --user stop steam-animation-manager.service"  
    echo "Status: systemctl --user status steam-animation-manager.service"
    echo "Logs:   journalctl --user -u steam-animation-manager.service -f"
    echo ""
    echo "If running as root, use:"
    echo "Start:  sudo -u $USER XDG_RUNTIME_DIR=/run/user/\$(id -u $USER) systemctl --user start steam-animation-manager.service"
    echo ""
    log_info "Manual Control:"
    echo "Status: sudo -u $USER $INSTALL_DIR/$DAEMON_SCRIPT status"
    echo "Start:  sudo -u $USER $INSTALL_DIR/$DAEMON_SCRIPT start"
    echo "Stop:   sudo -u $USER $INSTALL_DIR/$DAEMON_SCRIPT stop"
    echo ""
    log_info "Configuration: Edit $CONFIG_DIR/config.conf"
    echo ""
    log_warning "Remember to set Steam's Startup Movie to 'deck_startup.webm' in Settings > Customization"
}

uninstall() {
    log_info "Uninstalling Steam Animation Manager..."
    
    # Stop and disable service (with proper environment)
    sudo -u "$USER" XDG_RUNTIME_DIR="/run/user/$(id -u $USER)" systemctl --user stop steam-animation-manager.service 2>/dev/null || true
    sudo -u "$USER" XDG_RUNTIME_DIR="/run/user/$(id -u $USER)" systemctl --user disable steam-animation-manager.service 2>/dev/null || true
    
    # Remove files
    rm -f "$INSTALL_DIR/$DAEMON_SCRIPT"
    rm -f "$SYSTEMD_DIR/steam-animation-manager.service"
    rm -f "/home/$USER/.config/systemd/user/steam-animation-manager.service"
    
    # Reload both system and user systemd
    systemctl daemon-reload
    sudo -u "$USER" XDG_RUNTIME_DIR="/run/user/$(id -u $USER)" systemctl --user daemon-reload 2>/dev/null || true
    
    log_success "Steam Animation Manager uninstalled"
    log_info "User data preserved in /home/$USER/homebrew/data/SDH-AnimationChanger/"
    log_info "Configuration preserved in $CONFIG_DIR/"
}

show_help() {
    cat << EOF
Steam Animation Manager - Bash Version Installer

Usage: $0 [COMMAND]

Commands:
    install     Install Steam Animation Manager (default)
    uninstall   Remove Steam Animation Manager
    help        Show this help

The installer will:
1. Install the daemon script to $INSTALL_DIR
2. Create systemd service for automatic startup
3. Setup configuration and user directories
4. Migrate data from old Animation Changer plugin if present

Requirements:
- SteamOS or Arch Linux
- systemd
- ffmpeg (for video optimization)
- Root access (for installation)

After installation, animations go in:
/home/$USER/homebrew/data/SDH-AnimationChanger/animations/

Configuration file:
$CONFIG_DIR/config.conf
EOF
}

main() {
    local command="${1:-install}"
    
    case "$command" in
        install)
            log_info "Installing Steam Animation Manager (Bash Version)"
            log_info "================================================"
            check_requirements
            handle_steamos_readonly
            cleanup_old_installation
            install_daemon
            setup_config
            install_systemd_service
            setup_user_directories
            check_plugin_compatibility
            enable_service
            test_installation
            show_status
            restore_steamos_readonly
            log_success "Installation completed successfully!"
            ;;
        uninstall)
            uninstall
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            log_error "Unknown command: $command"
            show_help
            exit 1
            ;;
    esac
}

main "$@"