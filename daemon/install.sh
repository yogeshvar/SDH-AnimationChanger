#!/bin/bash
set -euo pipefail

# Steam Animation Manager Installation Script
# This script installs the native systemd daemon to replace the Python plugin

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BINARY_NAME="steam-animation-daemon"
INSTALL_PREFIX="${INSTALL_PREFIX:-/usr}"
CONFIG_DIR="${CONFIG_DIR:-/etc/steam-animation-manager}"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
USER="${STEAM_USER:-deck}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_dependencies() {
    log_info "Checking dependencies..."
    
    local missing_deps=()
    
    # Check for required system packages
    if ! command -v ffmpeg >/dev/null 2>&1; then
        missing_deps+=("ffmpeg")
    fi
    
    if ! command -v systemctl >/dev/null 2>&1; then
        missing_deps+=("systemd")
    fi
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        log_error "Missing required dependencies: ${missing_deps[*]}"
        log_info "Please install missing dependencies first:"
        log_info "  pacman -S ${missing_deps[*]}"
        exit 1
    fi
    
    log_success "All dependencies satisfied"
}

build_daemon() {
    log_info "Building Steam Animation Manager daemon..."
    
    if ! command -v cargo >/dev/null 2>&1; then
        log_error "Rust/Cargo not found. Please install rust first:"
        log_info "  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
        exit 1
    fi
    
    cd "$SCRIPT_DIR"
    cargo build --release
    
    if [ ! -f "target/release/$BINARY_NAME" ]; then
        log_error "Build failed - binary not found"
        exit 1
    fi
    
    log_success "Build completed successfully"
}

install_binary() {
    log_info "Installing daemon binary..."
    
    sudo install -m 755 "target/release/$BINARY_NAME" "$INSTALL_PREFIX/bin/"
    log_success "Binary installed to $INSTALL_PREFIX/bin/$BINARY_NAME"
}

install_config() {
    log_info "Installing configuration..."
    
    sudo mkdir -p "$CONFIG_DIR"
    
    if [ ! -f "$CONFIG_DIR/config.toml" ]; then
        sudo cp "config/default.toml" "$CONFIG_DIR/config.toml"
        log_success "Default configuration installed to $CONFIG_DIR/config.toml"
    else
        log_warning "Configuration already exists at $CONFIG_DIR/config.toml"
    fi
    
    # Set proper ownership
    sudo chown -R "$USER:$USER" "$CONFIG_DIR"
}

install_systemd_service() {
    log_info "Installing systemd service..."
    
    sudo cp "systemd/steam-animation-manager.service" "$SYSTEMD_DIR/"
    sudo cp "systemd/steam-animation-manager.timer" "$SYSTEMD_DIR/"
    
    # Reload systemd
    sudo systemctl daemon-reload
    
    log_success "Systemd service installed"
}

setup_directories() {
    log_info "Setting up user directories..."
    
    local user_home="/home/$USER"
    local data_dir="$user_home/.local/share/steam-animation-manager"
    
    # Create directories as the user
    sudo -u "$USER" mkdir -p "$data_dir/animations"
    sudo -u "$USER" mkdir -p "$data_dir/downloads"
    sudo -u "$USER" mkdir -p "$user_home/.steam/root/config/uioverrides/movies"
    
    log_success "User directories created"
}

migrate_from_plugin() {
    log_info "Checking for existing Animation Changer plugin..."
    
    local plugin_dir="/home/$USER/homebrew/plugins/SDH-AnimationChanger"
    local data_dir="/home/$USER/.local/share/steam-animation-manager"
    
    if [ -d "$plugin_dir" ]; then
        log_info "Found existing plugin, migrating data..."
        
        # Migrate animations
        if [ -d "/home/$USER/homebrew/data/Animation Changer/animations" ]; then
            sudo -u "$USER" cp -r "/home/$USER/homebrew/data/Animation Changer/animations"/* "$data_dir/animations/" 2>/dev/null || true
        fi
        
        # Migrate downloads
        if [ -d "/home/$USER/homebrew/data/Animation Changer/downloads" ]; then
            sudo -u "$USER" cp -r "/home/$USER/homebrew/data/Animation Changer/downloads"/* "$data_dir/downloads/" 2>/dev/null || true
        fi
        
        log_success "Plugin data migrated"
        log_warning "You can now disable/remove the old plugin from Decky Loader"
    else
        log_info "No existing plugin found"
    fi
}

enable_service() {
    log_info "Enabling Steam Animation Manager service..."
    
    # Enable and start the service for the user
    systemctl --user enable steam-animation-manager.service
    systemctl --user enable steam-animation-manager.timer
    
    log_success "Service enabled"
    log_info "The service will start automatically on next login"
    log_info "To start now: systemctl --user start steam-animation-manager.service"
}

show_status() {
    log_info "Installation Summary:"
    echo "  Binary: $INSTALL_PREFIX/bin/$BINARY_NAME"
    echo "  Config: $CONFIG_DIR/config.toml"
    echo "  Service: $SYSTEMD_DIR/steam-animation-manager.service"
    echo "  Data: /home/$USER/.local/share/steam-animation-manager/"
    echo ""
    log_info "To manage the service:"
    echo "  Start:   systemctl --user start steam-animation-manager.service"
    echo "  Stop:    systemctl --user stop steam-animation-manager.service"
    echo "  Status:  systemctl --user status steam-animation-manager.service"
    echo "  Logs:    journalctl --user -u steam-animation-manager.service -f"
    echo ""
    log_info "To configure animations, edit: $CONFIG_DIR/config.toml"
}

main() {
    log_info "Steam Animation Manager Installation"
    log_info "===================================="
    
    if [ "$EUID" -eq 0 ]; then
        log_error "Do not run this script as root"
        exit 1
    fi
    
    check_dependencies
    build_daemon
    install_binary
    install_config
    install_systemd_service
    setup_directories
    migrate_from_plugin
    enable_service
    show_status
    
    log_success "Installation completed successfully!"
}

main "$@"