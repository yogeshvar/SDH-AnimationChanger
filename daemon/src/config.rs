use anyhow::{Result, Context};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::time::Duration;
use tokio::fs;
use tracing::{info, warn};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    // Path configurations
    pub animations_path: PathBuf,
    pub downloads_path: PathBuf,
    pub steam_override_path: String,
    pub animation_cache_path: String,
    
    // Animation settings
    pub current_boot_animation: Option<String>,
    pub current_suspend_animation: Option<String>,
    pub current_throbber_animation: Option<String>,
    
    // Randomization
    pub randomize_mode: RandomizeMode,
    pub shuffle_exclusions: Vec<String>,
    
    // Video processing settings
    pub max_animation_duration: Duration,
    pub target_width: u32,
    pub target_height: u32,
    pub video_quality: u32, // CRF value for encoding
    
    // Cache settings
    pub max_cache_size_mb: u64,
    pub cache_max_age_days: u64,
    
    // Network settings
    pub force_ipv4: bool,
    pub connection_timeout: Duration,
    
    // Monitoring settings
    pub process_check_interval: Duration,
    pub maintenance_interval: Duration,
    
    // Logging
    pub log_level: String,
    pub enable_debug: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub enum RandomizeMode {
    #[serde(rename = "disabled")]
    Disabled,
    #[serde(rename = "per_boot")]
    PerBoot,
    #[serde(rename = "per_set")]
    PerSet,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            // Default paths for Steam Deck
            animations_path: PathBuf::from("/home/deck/.local/share/steam-animation-manager/animations"),
            downloads_path: PathBuf::from("/home/deck/.local/share/steam-animation-manager/downloads"),
            steam_override_path: "/home/deck/.steam/root/config/uioverrides/movies".to_string(),
            animation_cache_path: "/tmp/steam-animation-cache".to_string(),
            
            // Current animations
            current_boot_animation: None,
            current_suspend_animation: None,
            current_throbber_animation: None,
            
            // Randomization
            randomize_mode: RandomizeMode::Disabled,
            shuffle_exclusions: Vec::new(),
            
            // Video processing - optimized for Steam Deck
            max_animation_duration: Duration::from_secs(5), // 5 second max to prevent stuck animations
            target_width: 1280,
            target_height: 720, // Steam Deck native resolution
            video_quality: 23, // Good balance of quality/size for VP9
            
            // Cache settings
            max_cache_size_mb: 500, // 500MB cache limit
            cache_max_age_days: 30,
            
            // Network settings
            force_ipv4: false,
            connection_timeout: Duration::from_secs(30),
            
            // Monitoring
            process_check_interval: Duration::from_secs(1),
            maintenance_interval: Duration::from_secs(300), // 5 minutes
            
            // Logging
            log_level: "info".to_string(),
            enable_debug: false,
        }
    }
}

impl Config {
    pub async fn load(path: &Path) -> Result<Self> {
        if !path.exists() {
            info!("Config file not found at {}, creating default config", path.display());
            let config = Self::default();
            config.save(path).await?;
            return Ok(config);
        }

        let content = fs::read_to_string(path).await
            .with_context(|| format!("Failed to read config file: {}", path.display()))?;

        let mut config: Config = toml::from_str(&content)
            .with_context(|| format!("Failed to parse config file: {}", path.display()))?;

        // Validate and fix configuration
        config.validate_and_fix().await?;

        info!("Configuration loaded from {}", path.display());
        Ok(config)
    }

    pub async fn save(&self, path: &Path) -> Result<()> {
        // Ensure parent directory exists
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).await?;
        }

        let content = toml::to_string_pretty(self)
            .context("Failed to serialize configuration")?;

        fs::write(path, content).await
            .with_context(|| format!("Failed to write config file: {}", path.display()))?;

        info!("Configuration saved to {}", path.display());
        Ok(())
    }

    async fn validate_and_fix(&mut self) -> Result<()> {
        // Ensure required directories exist
        fs::create_dir_all(&self.animations_path).await
            .with_context(|| format!("Failed to create animations directory: {}", self.animations_path.display()))?;
        
        fs::create_dir_all(&self.downloads_path).await
            .with_context(|| format!("Failed to create downloads directory: {}", self.downloads_path.display()))?;
        
        fs::create_dir_all(&self.animation_cache_path).await
            .with_context(|| format!("Failed to create cache directory: {}", self.animation_cache_path))?;

        // Ensure Steam override directory exists
        let override_path = PathBuf::from(&self.steam_override_path);
        fs::create_dir_all(&override_path).await
            .with_context(|| format!("Failed to create Steam override directory: {}", override_path.display()))?;

        // Validate numeric settings
        if self.max_animation_duration.as_secs() == 0 {
            warn!("Invalid max_animation_duration, using default");
            self.max_animation_duration = Duration::from_secs(5);
        }

        if self.max_animation_duration.as_secs() > 30 {
            warn!("Max animation duration too long ({}s), limiting to 30s", self.max_animation_duration.as_secs());
            self.max_animation_duration = Duration::from_secs(30);
        }

        if self.video_quality < 10 || self.video_quality > 50 {
            warn!("Invalid video quality {}, using default", self.video_quality);
            self.video_quality = 23;
        }

        if self.target_width == 0 || self.target_height == 0 {
            warn!("Invalid target resolution {}x{}, using Steam Deck default", self.target_width, self.target_height);
            self.target_width = 1280;
            self.target_height = 720;
        }

        if self.max_cache_size_mb == 0 {
            warn!("Invalid max cache size, using default");
            self.max_cache_size_mb = 500;
        }

        Ok(())
    }

    pub fn get_steam_override_path(&self) -> PathBuf {
        PathBuf::from(&self.steam_override_path)
    }

    pub fn get_animation_cache_path(&self) -> PathBuf {
        PathBuf::from(&self.animation_cache_path)
    }

    /// Get the configuration for a specific environment (dev/prod)
    pub fn for_environment(env: &str) -> Self {
        let mut config = Self::default();
        
        match env {
            "development" => {
                config.animations_path = PathBuf::from("./test_animations");
                config.downloads_path = PathBuf::from("./test_downloads");
                config.steam_override_path = "./test_overrides".to_string();
                config.animation_cache_path = "./test_cache".to_string();
                config.enable_debug = true;
                config.log_level = "debug".to_string();
            }
            "testing" => {
                config.animations_path = PathBuf::from("/tmp/test_animations");
                config.downloads_path = PathBuf::from("/tmp/test_downloads");
                config.steam_override_path = "/tmp/test_overrides".to_string();
                config.animation_cache_path = "/tmp/test_cache".to_string();
                config.max_animation_duration = Duration::from_secs(2); // Faster tests
            }
            _ => {} // Use defaults for production
        }
        
        config
    }

    /// Update animation settings and save
    pub async fn update_animations(
        &mut self,
        boot: Option<String>,
        suspend: Option<String>,
        throbber: Option<String>,
        config_path: &Path,
    ) -> Result<()> {
        if let Some(boot_anim) = boot {
            self.current_boot_animation = if boot_anim.is_empty() { None } else { Some(boot_anim) };
        }
        
        if let Some(suspend_anim) = suspend {
            self.current_suspend_animation = if suspend_anim.is_empty() { None } else { Some(suspend_anim) };
        }
        
        if let Some(throbber_anim) = throbber {
            self.current_throbber_animation = if throbber_anim.is_empty() { None } else { Some(throbber_anim) };
        }

        self.save(config_path).await
    }

    /// Update randomization settings
    pub async fn update_randomization(
        &mut self,
        mode: RandomizeMode,
        exclusions: Vec<String>,
        config_path: &Path,
    ) -> Result<()> {
        self.randomize_mode = mode;
        self.shuffle_exclusions = exclusions;
        self.save(config_path).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[tokio::test]
    async fn test_config_default() {
        let config = Config::default();
        assert_eq!(config.randomize_mode, RandomizeMode::Disabled);
        assert_eq!(config.video_quality, 23);
        assert_eq!(config.target_width, 1280);
    }

    #[tokio::test]
    async fn test_config_load_create_default() {
        let temp_dir = tempdir().unwrap();
        let config_path = temp_dir.path().join("config.toml");
        
        let config = Config::load(&config_path).await.unwrap();
        assert!(config_path.exists());
        assert_eq!(config.randomize_mode, RandomizeMode::Disabled);
    }

    #[tokio::test]
    async fn test_config_save_load() {
        let temp_dir = tempdir().unwrap();
        let config_path = temp_dir.path().join("config.toml");
        
        let mut original_config = Config::default();
        original_config.randomize_mode = RandomizeMode::PerBoot;
        original_config.video_quality = 30;
        
        original_config.save(&config_path).await.unwrap();
        let loaded_config = Config::load(&config_path).await.unwrap();
        
        assert_eq!(loaded_config.randomize_mode, RandomizeMode::PerBoot);
        assert_eq!(loaded_config.video_quality, 30);
    }
}