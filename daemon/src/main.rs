use anyhow::Result;
use clap::Parser;
use std::path::PathBuf;
use systemd::daemon;
use tokio::signal;
use tracing::{info, error};
use tracing_subscriber;

mod animation;
mod config;
mod steam_monitor;
mod video_processor;

use crate::config::Config;
use crate::steam_monitor::SteamMonitor;
use crate::animation::AnimationManager;

#[derive(Parser)]
#[command(name = "steam-animation-daemon")]
#[command(about = "Native Steam Deck animation management daemon")]
struct Cli {
    #[arg(short, long, value_name = "FILE")]
    config: Option<PathBuf>,
    
    #[arg(short, long)]
    verbose: bool,
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();

    // Initialize logging
    let subscriber = tracing_subscriber::fmt()
        .with_max_level(if cli.verbose { 
            tracing::Level::DEBUG 
        } else { 
            tracing::Level::INFO 
        })
        .finish();
    tracing::subscriber::set_global_default(subscriber)?;

    info!("Starting Steam Animation Daemon v{}", env!("CARGO_PKG_VERSION"));

    // Load configuration
    let config_path = cli.config.unwrap_or_else(|| {
        PathBuf::from("/etc/steam-animation-manager/config.toml")
    });
    
    let config = Config::load(&config_path).await?;
    info!("Configuration loaded from {}", config_path.display());

    // Initialize components
    let animation_manager = AnimationManager::new(config.clone()).await?;
    let steam_monitor = SteamMonitor::new(config.clone()).await?;

    // Notify systemd we're ready
    daemon::notify(false, [(daemon::STATE_READY, "1")].iter())?;
    info!("Daemon started successfully");

    // Main event loop
    tokio::select! {
        result = run_daemon(steam_monitor, animation_manager) => {
            if let Err(e) = result {
                error!("Daemon error: {}", e);
            }
        }
        _ = signal::ctrl_c() => {
            info!("Received shutdown signal");
        }
    }

    // Cleanup
    daemon::notify(false, [(daemon::STATE_STOPPING, "1")].iter())?;
    info!("Steam Animation Daemon shutting down");

    Ok(())
}

async fn run_daemon(
    mut steam_monitor: SteamMonitor,
    mut animation_manager: AnimationManager,
) -> Result<()> {
    let mut steam_events = steam_monitor.subscribe();
    
    loop {
        tokio::select! {
            event = steam_events.recv() => {
                match event? {
                    crate::steam_monitor::SteamEvent::Starting => {
                        info!("Steam starting - preparing boot animation");
                        animation_manager.prepare_boot_animation().await?;
                    }
                    crate::steam_monitor::SteamEvent::Suspending => {
                        info!("Steam suspending - preparing suspend animation");
                        animation_manager.prepare_suspend_animation().await?;
                    }
                    crate::steam_monitor::SteamEvent::Resuming => {
                        info!("Steam resuming - preparing resume animation");
                        animation_manager.prepare_resume_animation().await?;
                    }
                    crate::steam_monitor::SteamEvent::Shutdown => {
                        info!("Steam shutdown detected");
                        animation_manager.cleanup().await?;
                    }
                }
            }
            
            // Periodic maintenance
            _ = tokio::time::sleep(tokio::time::Duration::from_secs(30)) => {
                animation_manager.maintenance().await?;
            }
        }
    }
}