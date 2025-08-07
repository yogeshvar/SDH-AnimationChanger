# Steam Animation Manager - Rust Daemon

A high-performance, native systemd daemon for managing Steam Deck boot and suspend animations.

## Key Improvements over Python Plugin

❌ **Old Issues (Python Plugin)**
- Animations get stuck playing to completion
- Uses fragile symlink hacks to Steam's files  
- Suspend/throbber animations incorrectly mapped
- No timing control or optimization

✅ **New Solutions (Rust Daemon)**
- **Hard timeout control** - animations never get stuck
- **Bind mounts** instead of symlinks for safer Steam integration
- **Proper event monitoring** - accurate suspend/resume detection
- **Video optimization** - automatic duration limiting and Steam Deck optimization
- **Native systemd service** - proper Arch Linux integration
- **Performance** - Rust daemon vs Python overhead

## Architecture

```
┌─────────────────────────────────────────┐
│ Steam Animation Manager Daemon          │
├─────────────────────────────────────────┤
│ ┌─────────────┐ ┌─────────────────────┐ │
│ │ Steam       │ │ Animation Manager   │ │
│ │ Monitor     │ │                     │ │
│ │             │ │ - Video processing  │ │
│ │ - Process   │ │ - Bind mounts       │ │
│ │   tracking  │ │ - Randomization     │ │
│ │ - Systemd   │ │ - Cache management  │ │
│ │   events    │ │                     │ │
│ └─────────────┘ └─────────────────────┘ │
└─────────────────────────────────────────┘
```

## Installation

1. **Install dependencies:**
   ```bash
   pacman -S ffmpeg rust
   ```

2. **Build and install:**
   ```bash
   cd daemon/
   ./install.sh
   ```

3. **Start the service:**
   ```bash
   systemctl --user start steam-animation-manager.service
   ```

## Usage

### Configuration

Edit `/etc/steam-animation-manager/config.toml`:

```toml
# Animation settings
current_boot_animation = "my-animation-set/deck_startup.webm"
randomize_mode = "per_boot"  # "disabled", "per_boot", "per_set"

# Video optimization  
max_animation_duration = "5s"    # Prevent stuck animations
target_width = 1280
target_height = 720
video_quality = 23               # VP9 quality (lower = better)
```

### Managing Animations

Place animation directories in `/home/deck/.local/share/steam-animation-manager/animations/`:

```
animations/
├── my-cool-set/
│   ├── deck_startup.webm              # Boot animation
│   ├── steam_os_suspend.webm          # Suspend animation  
│   └── steam_os_suspend_from_throbber.webm  # In-game suspend
└── another-set/
    └── deck_startup.webm
```

### Service Management

```bash
# Service control
systemctl --user start steam-animation-manager.service
systemctl --user stop steam-animation-manager.service
systemctl --user status steam-animation-manager.service

# View logs
journalctl --user -u steam-animation-manager.service -f

# Reload configuration
systemctl --user reload steam-animation-manager.service
```

## Technical Details

### Video Processing Pipeline

1. **Input validation** - Check format, duration, resolution
2. **Optimization** - Limit duration, resize for Steam Deck, VP9 encoding
3. **Caching** - Store optimized videos for faster access
4. **Bind mounting** - Safe integration with Steam's override system

### Steam Integration

- **Process monitoring** - Tracks Steam lifecycle via `/proc`
- **Systemd events** - Monitors suspend/resume via journalctl
- **Bind mounts** - Replaces symlink hacks with proper filesystem operations
- **Timeout control** - Hard limits prevent stuck animations

### Security

- Runs as `deck` user with minimal privileges
- Uses systemd security features (NoNewPrivileges, ProtectSystem)
- Only requires CAP_SYS_ADMIN for bind mounts
- Memory and CPU limits prevent resource abuse

## Migration from Python Plugin

The install script automatically migrates data from the old SDH-AnimationChanger plugin:

- Animations from `~/homebrew/data/Animation Changer/animations/`
- Downloads from `~/homebrew/data/Animation Changer/downloads/`
- Preserves existing configuration where possible

After installation, you can disable/remove the old plugin from Decky Loader.

## Development

### Building

```bash
cargo build --release
```

### Testing

```bash
cargo test
```

### Configuration for Development

```bash
STEAM_ANIMATION_ENV=development cargo run
```

This uses test directories instead of system paths.

## Troubleshooting

### Service won't start

```bash
# Check service status
systemctl --user status steam-animation-manager.service

# Check logs for errors
journalctl --user -u steam-animation-manager.service --no-pager
```

### Animations not changing

1. Check Steam settings: Settings > Customization > Startup Movie = "deck_startup.webm"
2. Verify override directory: `ls -la ~/.steam/root/config/uioverrides/movies/`
3. Check bind mounts: `mount | grep uioverrides`

### Performance issues

1. Check video cache: `/tmp/steam-animation-cache/`
2. Adjust video quality in config (higher CRF = smaller files)
3. Monitor resource usage: `systemctl --user status steam-animation-manager.service`

## Comparison: Old vs New

| Feature | Python Plugin | Rust Daemon |
|---------|---------------|-------------|
| **Integration** | Symlinks (fragile) | Bind mounts (safe) |
| **Timing Control** | None (gets stuck) | Hard timeouts |
| **Performance** | Python overhead | Native Rust |
| **Event Detection** | Basic polling | systemd + procfs |
| **Video Optimization** | None | FFmpeg pipeline |
| **Service Management** | Plugin lifecycle | systemd service |
| **Configuration** | JSON in plugin dir | TOML in /etc |
| **Security** | Plugin sandbox | systemd hardening |
| **Maintenance** | Manual cleanup | Automated cache mgmt |

The Rust daemon solves all the core issues while providing a proper Arch Linux experience.