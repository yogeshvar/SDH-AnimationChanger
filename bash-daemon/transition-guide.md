# Transition Guide: Python Plugin → Bash Daemon

## 🔄 Hybrid Approach (Recommended)

Keep both running temporarily for smooth transition:

### 1. Install Bash Daemon (Keeps Plugin Running)
```bash
cd bash-daemon/
sudo ./install.sh

# Start daemon
sudo -u deck systemctl --user start steam-animation-manager.service
```

### 2. Verify Bash Daemon Works
```bash
# Check status
sudo -u deck systemctl --user status steam-animation-manager.service

# Watch logs
sudo -u deck journalctl --user -u steam-animation-manager.service -f
```

### 3. Test Animation Changes
```bash
# Edit config to test
sudo nano /etc/steam-animation-manager/config.conf

# Set a specific animation
CURRENT_BOOT="/home/deck/homebrew/data/Animation Changer/animations/some-set/deck_startup.webm"
RANDOMIZE_MODE="disabled"

# Reload daemon
sudo -u deck systemctl --user reload steam-animation-manager.service

# Restart Steam to see animation
```

### 4. Disable Plugin (Once Satisfied)
- Open Decky Loader
- Disable "Animation Changer" plugin
- Keep the plugin files for React frontend downloads

## 📁 File Compatibility

Both systems use the same files:

```
~/homebrew/data/Animation Changer/
├── animations/           # ✅ Used by both
│   ├── set1/
│   │   └── deck_startup.webm
│   └── set2/
│       ├── deck_startup.webm
│       └── steam_os_suspend.webm
├── downloads/           # ✅ Used by both
│   ├── download1.webm
│   └── download2.webm
└── settings/           # Only used by plugin
    └── config.json
```

## ⚙️ Configuration Mapping

| Python Plugin (JSON) | Bash Daemon (CONF) | Notes |
|----------------------|---------------------|--------|
| `"boot": "set/file.webm"` | `CURRENT_BOOT="/full/path/file.webv"` | Use full paths in bash |
| `"randomize": "all"` | `RANDOMIZE_MODE="per_boot"` | Similar behavior |
| `"randomize": "set"` | `RANDOMIZE_MODE="per_set"` | Set-based randomization |
| `"randomize": ""` | `RANDOMIZE_MODE="disabled"` | No randomization |

## 🎮 Using React Frontend with Bash Daemon

**You can still use the plugin's React UI for downloads!**

1. Keep plugin **enabled** but **disable** its automation:
   - Set all animations to "Default" in plugin UI
   - Use bash daemon config for actual animation control

2. Or **disable** plugin and use it only for browsing:
   - Plugin UI will still work for browsing/downloading
   - Use bash daemon config to actually apply animations

## 🐛 Troubleshooting Conflicts

### Both Systems Fighting Over Animations

**Symptoms**: Animations changing unpredictably

**Fix**: Disable plugin automation
```bash
# Check what's mounted
mount | grep uioverrides

# Stop plugin service (if running)
systemctl --user stop plugin-related-service

# Restart bash daemon
sudo -u deck systemctl --user restart steam-animation-manager.service
```

### Animation Not Changing

1. **Check which system is active**:
   ```bash
   # Check bash daemon
   sudo -u deck systemctl --user status steam-animation-manager.service
   
   # Check plugin status in Decky Loader
   ```

2. **Check file mounts**:
   ```bash
   ls -la ~/.steam/root/config/uioverrides/movies/
   mount | grep deck_startup.webm
   ```

3. **Verify file paths**:
   ```bash
   # Check config
   cat /etc/steam-animation-manager/config.conf
   
   # Verify files exist
   ls -la "/home/deck/homebrew/data/Animation Changer/animations/"
   ```

## 📊 Benefits Comparison

| Feature | Python Plugin | Bash Daemon | Best Choice |
|---------|---------------|-------------|-------------|
| **Downloads** | ✅ React UI | ❌ Manual | Keep plugin for downloads |
| **Animation Control** | ❌ Stuck/laggy | ✅ Timeout control | Bash daemon |
| **System Integration** | ❌ Plugin hack | ✅ Native systemd | Bash daemon |
| **Performance** | ❌ 50-100MB | ✅ 2-5MB | Bash daemon |
| **Reliability** | ❌ Symlink issues | ✅ Bind mounts | Bash daemon |

## 🎯 Recommended Final Setup

1. **Bash daemon**: Handles all animation logic and timing
2. **Plugin disabled**: But kept for occasional downloads via React UI
3. **Single config**: Use `/etc/steam-animation-manager/config.conf` as source of truth

This gives you the best of both worlds:
- ✅ Reliable animation control (bash daemon)
- ✅ Easy downloads (React UI when needed)
- ✅ No conflicts (plugin disabled for automation)
- ✅ Same file structure (no migration needed)