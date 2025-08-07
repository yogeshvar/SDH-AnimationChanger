use anyhow::{Result, Context};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use tokio::fs;
use tokio::process::Command;
use tokio::time::{timeout, Duration};
use tracing::{info, warn, error, debug};
use serde::{Deserialize, Serialize};
use rand::seq::SliceRandom;

use crate::config::Config;
use crate::video_processor::VideoProcessor;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Animation {
    pub id: String,
    pub name: String,
    pub path: PathBuf,
    pub animation_type: AnimationType,
    pub duration: Option<Duration>,
    pub optimized_path: Option<PathBuf>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq)]
pub enum AnimationType {
    Boot,
    Suspend,
    Throbber,
}

pub struct AnimationManager {
    config: Config,
    video_processor: VideoProcessor,
    animations: HashMap<String, Animation>,
    current_animations: HashMap<AnimationType, Option<String>>,
    steam_override_path: PathBuf,
}

impl AnimationManager {
    pub async fn new(config: Config) -> Result<Self> {
        let steam_override_path = PathBuf::from(&config.steam_override_path);
        
        // Ensure directories exist
        fs::create_dir_all(&steam_override_path).await
            .context("Failed to create Steam override directory")?;
        fs::create_dir_all(&config.animation_cache_path).await
            .context("Failed to create animation cache directory")?;

        let video_processor = VideoProcessor::new(config.clone())?;
        
        let mut manager = Self {
            config,
            video_processor,
            animations: HashMap::new(),
            current_animations: HashMap::new(),
            steam_override_path,
        };

        manager.load_animations().await?;
        Ok(manager)
    }

    pub async fn load_animations(&mut self) -> Result<()> {
        info!("Loading animations from {}", self.config.animations_path.display());
        
        self.animations.clear();
        
        // Load from animations directory
        let mut entries = fs::read_dir(&self.config.animations_path).await?;
        while let Some(entry) = entries.next_entry().await? {
            if entry.file_type().await?.is_dir() {
                if let Err(e) = self.load_animation_set(&entry.path()).await {
                    warn!("Failed to load animation set {}: {}", entry.path().display(), e);
                }
            }
        }

        // Load downloaded animations
        if self.config.downloads_path.exists() {
            let mut entries = fs::read_dir(&self.config.downloads_path).await?;
            while let Some(entry) = entries.next_entry().await? {
                if entry.path().extension().map_or(false, |ext| ext == "webm") {
                    if let Err(e) = self.load_downloaded_animation(&entry.path()).await {
                        warn!("Failed to load downloaded animation {}: {}", entry.path().display(), e);
                    }
                }
            }
        }

        info!("Loaded {} animations", self.animations.len());
        Ok(())
    }

    async fn load_animation_set(&mut self, set_path: &Path) -> Result<()> {
        let set_name = set_path.file_name()
            .and_then(|n| n.to_str())
            .context("Invalid animation set directory name")?;

        debug!("Loading animation set: {}", set_name);

        // Check for config.json
        let config_path = set_path.join("config.json");
        let set_config: Option<AnimationSetConfig> = if config_path.exists() {
            let content = fs::read_to_string(&config_path).await?;
            Some(serde_json::from_str(&content)?)
        } else {
            None
        };

        // Load individual animations
        for (file_name, anim_type) in [
            ("deck_startup.webm", AnimationType::Boot),
            ("steam_os_suspend.webm", AnimationType::Suspend),
            ("steam_os_suspend_from_throbber.webm", AnimationType::Throbber),
        ] {
            let anim_path = set_path.join(file_name);
            if anim_path.exists() {
                let animation = Animation {
                    id: format!("{}/{}", set_name, file_name),
                    name: if anim_type == AnimationType::Boot {
                        set_name.to_string()
                    } else {
                        format!("{} - {:?}", set_name, anim_type)
                    },
                    path: anim_path,
                    animation_type: anim_type,
                    duration: None,
                    optimized_path: None,
                };
                
                self.animations.insert(animation.id.clone(), animation);
            }
        }

        Ok(())
    }

    async fn load_downloaded_animation(&mut self, path: &Path) -> Result<()> {
        let file_stem = path.file_stem()
            .and_then(|s| s.to_str())
            .context("Invalid downloaded animation filename")?;

        // Determine animation type from filename or metadata
        let anim_type = if file_stem.contains("boot") {
            AnimationType::Boot
        } else if file_stem.contains("suspend") {
            AnimationType::Suspend
        } else {
            AnimationType::Boot // Default
        };

        let animation = Animation {
            id: format!("downloaded/{}", file_stem),
            name: file_stem.replace("_", " ").replace("-", " "),
            path: path.to_path_buf(),
            animation_type: anim_type,
            duration: None,
            optimized_path: None,
        };

        self.animations.insert(animation.id.clone(), animation);
        Ok(())
    }

    pub async fn prepare_boot_animation(&mut self) -> Result<()> {
        info!("Preparing boot animation");
        
        let animation_id = match &self.config.randomize_mode {
            crate::config::RandomizeMode::Disabled => {
                self.config.current_boot_animation.clone()
            }
            crate::config::RandomizeMode::PerBoot => {
                self.select_random_animation(AnimationType::Boot)?
            }
            crate::config::RandomizeMode::PerSet => {
                // Implementation for set-based randomization
                self.select_random_from_set(AnimationType::Boot)?
            }
        };

        if let Some(id) = animation_id {
            self.apply_animation(AnimationType::Boot, &id).await?;
        }

        Ok(())
    }

    pub async fn prepare_suspend_animation(&mut self) -> Result<()> {
        info!("Preparing suspend animation");
        
        let animation_id = self.config.current_suspend_animation.clone()
            .or_else(|| self.select_random_animation(AnimationType::Suspend).unwrap_or(None));

        if let Some(id) = animation_id {
            self.apply_animation(AnimationType::Suspend, &id).await?;
        }

        Ok(())
    }

    pub async fn prepare_resume_animation(&mut self) -> Result<()> {
        info!("Preparing resume animation");
        // Resume typically uses boot animation
        self.prepare_boot_animation().await
    }

    async fn apply_animation(&mut self, anim_type: AnimationType, animation_id: &str) -> Result<()> {
        let animation = self.animations.get(animation_id)
            .context("Animation not found")?
            .clone();

        debug!("Applying {:?} animation: {}", anim_type, animation.name);

        // Optimize video if needed
        let source_path = if let Some(optimized) = &animation.optimized_path {
            optimized.clone()
        } else {
            // Process and optimize the video
            let optimized_path = self.video_processor.optimize_animation(&animation).await?;
            
            // Update the animation record
            if let Some(anim) = self.animations.get_mut(animation_id) {
                anim.optimized_path = Some(optimized_path.clone());
            }
            
            optimized_path
        };

        // Apply using bind mount instead of symlink
        let target_path = self.get_steam_target_path(anim_type);
        self.mount_animation(&source_path, &target_path).await?;

        self.current_animations.insert(anim_type, Some(animation_id.to_string()));
        info!("Applied {:?} animation: {}", anim_type, animation.name);

        Ok(())
    }

    async fn mount_animation(&self, source: &Path, target: &Path) -> Result<()> {
        // Remove existing mount/file
        if target.exists() {
            self.unmount_animation(target).await?;
        }

        // Create empty target file for bind mount
        fs::write(target, b"").await?;

        // Use bind mount instead of symlink
        let output = Command::new("mount")
            .args(&["--bind", source.to_str().unwrap(), target.to_str().unwrap()])
            .output()
            .await?;

        if !output.status.success() {
            anyhow::bail!(
                "Failed to mount animation: {}",
                String::from_utf8_lossy(&output.stderr)
            );
        }

        debug!("Mounted {} -> {}", source.display(), target.display());
        Ok(())
    }

    async fn unmount_animation(&self, target: &Path) -> Result<()> {
        let output = Command::new("umount")
            .arg(target.to_str().unwrap())
            .output()
            .await?;

        // Don't error if unmount fails (file might not be mounted)
        if !output.status.success() {
            debug!("Unmount failed (expected): {}", String::from_utf8_lossy(&output.stderr));
        }

        // Remove the target file
        if target.exists() {
            fs::remove_file(target).await?;
        }

        Ok(())
    }

    fn get_steam_target_path(&self, anim_type: AnimationType) -> PathBuf {
        let filename = match anim_type {
            AnimationType::Boot => "deck_startup.webm",
            AnimationType::Suspend => "steam_os_suspend.webm", 
            AnimationType::Throbber => "steam_os_suspend_from_throbber.webm",
        };
        
        self.steam_override_path.join(filename)
    }

    fn select_random_animation(&self, anim_type: AnimationType) -> Result<Option<String>> {
        let candidates: Vec<_> = self.animations
            .iter()
            .filter(|(_, anim)| anim.animation_type == anim_type)
            .filter(|(id, _)| !self.config.shuffle_exclusions.contains(&id.to_string()))
            .map(|(id, _)| id.clone())
            .collect();

        if candidates.is_empty() {
            return Ok(None);
        }

        let mut rng = rand::thread_rng();
        Ok(candidates.choose(&mut rng).cloned())
    }

    fn select_random_from_set(&self, anim_type: AnimationType) -> Result<Option<String>> {
        // Implement set-based randomization logic
        // For now, fall back to per-animation randomization
        self.select_random_animation(anim_type)
    }

    pub async fn cleanup(&mut self) -> Result<()> {
        info!("Cleaning up animation manager");

        // Unmount all current animations
        for anim_type in [AnimationType::Boot, AnimationType::Suspend, AnimationType::Throbber] {
            let target_path = self.get_steam_target_path(anim_type);
            if target_path.exists() {
                if let Err(e) = self.unmount_animation(&target_path).await {
                    warn!("Failed to cleanup animation {:?}: {}", anim_type, e);
                }
            }
        }

        Ok(())
    }

    pub async fn maintenance(&mut self) -> Result<()> {
        // Periodic maintenance tasks
        debug!("Running maintenance tasks");
        
        // Clean up old optimized videos
        self.video_processor.cleanup_cache().await?;
        
        Ok(())
    }
}

#[derive(Debug, Deserialize)]
struct AnimationSetConfig {
    boot: Option<String>,
    suspend: Option<String>,
    throbber: Option<String>,
    enabled: Option<bool>,
}