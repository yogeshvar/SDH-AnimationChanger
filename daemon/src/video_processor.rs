use anyhow::{Result, Context};
use std::path::{Path, PathBuf};
use tokio::fs;
use tokio::process::Command;
use tokio::time::{timeout, Duration};
use tracing::{debug, info, warn};
use sha2::{Sha256, Digest};

use crate::animation::Animation;
use crate::config::Config;

pub struct VideoProcessor {
    config: Config,
    cache_path: PathBuf,
}

impl VideoProcessor {
    pub fn new(config: Config) -> Result<Self> {
        let cache_path = PathBuf::from(&config.animation_cache_path);
        
        Ok(Self {
            config,
            cache_path,
        })
    }

    pub async fn optimize_animation(&self, animation: &Animation) -> Result<PathBuf> {
        let cache_key = self.generate_cache_key(&animation.path).await?;
        let cached_path = self.cache_path.join(format!("{}.webm", cache_key));

        // Return cached version if it exists
        if cached_path.exists() {
            debug!("Using cached optimized animation: {}", cached_path.display());
            return Ok(cached_path);
        }

        info!("Optimizing animation: {}", animation.name);

        // Ensure cache directory exists
        fs::create_dir_all(&self.cache_path).await?;

        // Process the video with ffmpeg
        self.process_video(&animation.path, &cached_path).await?;

        info!("Animation optimized and cached: {}", cached_path.display());
        Ok(cached_path)
    }

    async fn process_video(&self, input: &Path, output: &Path) -> Result<()> {
        let max_duration = self.config.max_animation_duration.as_secs();
        
        // Build ffmpeg command with optimizations for Steam Deck
        let mut cmd = Command::new("ffmpeg");
        cmd.args(&[
            "-y", // Overwrite output file
            "-i", input.to_str().unwrap(),
            "-t", &max_duration.to_string(), // Limit duration
            
            // Video filters for Steam Deck optimization
            "-vf", &format!(
                "scale={}:{}:force_original_aspect_ratio=decrease,pad={}:{}:-1:-1:black",
                self.config.target_width,
                self.config.target_height,
                self.config.target_width,
                self.config.target_height
            ),
            
            // Video codec settings optimized for Steam Deck
            "-c:v", "libvpx-vp9",
            "-crf", &self.config.video_quality.to_string(),
            "-speed", "4", // Faster encoding
            "-row-mt", "1", // Multi-threading
            "-tile-columns", "2",
            "-frame-parallel", "1",
            
            // Audio settings (if present)
            "-c:a", "libopus",
            "-b:a", "64k",
            
            // Output format
            "-f", "webm",
            output.to_str().unwrap()
        ]);

        debug!("Running ffmpeg command: {:?}", cmd);

        // Run with timeout to prevent hanging
        let process_timeout = Duration::from_secs(300); // 5 minutes max
        
        let output = timeout(process_timeout, cmd.output()).await
            .context("Video processing timed out")?
            .context("Failed to execute ffmpeg")?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            anyhow::bail!("FFmpeg processing failed: {}", stderr);
        }

        // Verify output file was created and has reasonable size
        let metadata = fs::metadata(&output).await?;
        if metadata.len() == 0 {
            anyhow::bail!("Output video file is empty");
        }

        debug!("Video processed successfully: {} bytes", metadata.len());
        Ok(())
    }

    async fn generate_cache_key(&self, input_path: &Path) -> Result<String> {
        // Generate cache key based on file path, size, and modification time
        let metadata = fs::metadata(input_path).await?;
        
        let mut hasher = Sha256::new();
        hasher.update(input_path.to_string_lossy().as_bytes());
        hasher.update(metadata.len().to_le_bytes());
        
        if let Ok(modified) = metadata.modified() {
            if let Ok(duration) = modified.duration_since(std::time::UNIX_EPOCH) {
                hasher.update(duration.as_secs().to_le_bytes());
            }
        }
        
        // Include processing settings in cache key
        hasher.update(self.config.max_animation_duration.as_secs().to_le_bytes());
        hasher.update(self.config.target_width.to_le_bytes());
        hasher.update(self.config.target_height.to_le_bytes());
        hasher.update(self.config.video_quality.to_le_bytes());

        let result = hasher.finalize();
        Ok(format!("{:x}", result)[..16].to_string()) // Use first 16 chars
    }

    pub async fn cleanup_cache(&self) -> Result<()> {
        debug!("Cleaning up video cache");
        
        let max_cache_size = self.config.max_cache_size_mb * 1024 * 1024; // Convert MB to bytes
        let max_age = Duration::from_secs(self.config.cache_max_age_days * 24 * 3600); // Convert days to seconds
        
        let mut entries = Vec::new();
        let mut total_size = 0u64;
        
        // Collect cache entries with metadata
        let mut cache_dir = fs::read_dir(&self.cache_path).await?;
        while let Some(entry) = cache_dir.next_entry().await? {
            if let Ok(metadata) = entry.metadata().await {
                if metadata.is_file() {
                    let size = metadata.len();
                    let modified = metadata.modified().unwrap_or(std::time::SystemTime::UNIX_EPOCH);
                    
                    entries.push((entry.path(), size, modified));
                    total_size += size;
                }
            }
        }

        // Sort by modification time (oldest first)
        entries.sort_by_key(|(_, _, modified)| *modified);

        let now = std::time::SystemTime::now();
        let mut cleaned_files = 0;
        let mut cleaned_size = 0u64;

        // Remove old files and files if cache is too large
        for (path, size, modified) in entries {
            let should_remove = if let Ok(age) = now.duration_since(modified) {
                age > max_age || total_size > max_cache_size
            } else {
                false
            };

            if should_remove {
                if let Err(e) = fs::remove_file(&path).await {
                    warn!("Failed to remove cache file {}: {}", path.display(), e);
                } else {
                    debug!("Removed cache file: {}", path.display());
                    cleaned_files += 1;
                    cleaned_size += size;
                    total_size -= size;
                }
            }
        }

        if cleaned_files > 0 {
            info!("Cache cleanup: removed {} files ({} MB)", 
                  cleaned_files, cleaned_size / (1024 * 1024));
        }

        Ok(())
    }

    pub async fn get_video_info(&self, path: &Path) -> Result<VideoInfo> {
        let output = Command::new("ffprobe")
            .args(&[
                "-v", "quiet",
                "-show_format",
                "-show_streams",
                "-of", "json",
                path.to_str().unwrap()
            ])
            .output()
            .await?;

        if !output.status.success() {
            anyhow::bail!("ffprobe failed: {}", String::from_utf8_lossy(&output.stderr));
        }

        let info: FfprobeOutput = serde_json::from_slice(&output.stdout)?;
        
        let video_stream = info.streams.iter()
            .find(|s| s.codec_type == "video")
            .context("No video stream found")?;

        Ok(VideoInfo {
            duration: info.format.duration.parse::<f64>().unwrap_or(0.0),
            width: video_stream.width.unwrap_or(0),
            height: video_stream.height.unwrap_or(0),
            codec: video_stream.codec_name.clone(),
        })
    }
}

#[derive(Debug)]
pub struct VideoInfo {
    pub duration: f64,
    pub width: i32,
    pub height: i32,
    pub codec: String,
}

#[derive(serde::Deserialize)]
struct FfprobeOutput {
    format: FfprobeFormat,
    streams: Vec<FfprobeStream>,
}

#[derive(serde::Deserialize)]
struct FfprobeFormat {
    duration: String,
}

#[derive(serde::Deserialize)]
struct FfprobeStream {
    codec_type: String,
    codec_name: String,
    width: Option<i32>,
    height: Option<i32>,
}