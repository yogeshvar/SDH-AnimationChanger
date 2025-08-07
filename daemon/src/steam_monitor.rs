use anyhow::Result;
use procfs::process::{Process, all_processes};
use std::collections::HashSet;
use std::time::Duration;
use tokio::sync::broadcast;
use tokio::time::interval;
use tracing::{debug, info, warn};

use crate::config::Config;

#[derive(Debug, Clone)]
pub enum SteamEvent {
    Starting,
    Suspending, 
    Resuming,
    Shutdown,
}

pub struct SteamMonitor {
    config: Config,
    event_sender: broadcast::Sender<SteamEvent>,
    current_steam_pids: HashSet<i32>,
    was_suspended: bool,
}

impl SteamMonitor {
    pub async fn new(config: Config) -> Result<Self> {
        let (event_sender, _) = broadcast::channel(32);
        
        Ok(Self {
            config,
            event_sender,
            current_steam_pids: HashSet::new(),
            was_suspended: false,
        })
    }

    pub fn subscribe(&self) -> broadcast::Receiver<SteamEvent> {
        self.event_sender.subscribe()
    }

    pub async fn start_monitoring(&mut self) -> Result<()> {
        let mut interval = interval(Duration::from_secs(1));
        let mut journalctl_monitor = self.start_journalctl_monitor().await?;

        loop {
            tokio::select! {
                _ = interval.tick() => {
                    self.check_steam_processes().await?;
                }
                
                event = journalctl_monitor.recv() => {
                    match event? {
                        SystemEvent::Suspend => {
                            info!("System suspend detected");
                            self.was_suspended = true;
                            self.send_event(SteamEvent::Suspending).await?;
                        }
                        SystemEvent::Resume => {
                            info!("System resume detected");
                            if self.was_suspended {
                                self.was_suspended = false;
                                self.send_event(SteamEvent::Resuming).await?;
                            }
                        }
                    }
                }
            }
        }
    }

    async fn check_steam_processes(&mut self) -> Result<()> {
        let mut current_pids = HashSet::new();

        // Find all Steam processes
        for process in all_processes()? {
            let process = match process {
                Ok(p) => p,
                Err(_) => continue,
            };

            if let Ok(cmdline) = process.cmdline() {
                if cmdline.iter().any(|arg| arg.contains("steam")) {
                    current_pids.insert(process.pid);
                }
            }
        }

        // Detect new Steam processes (Steam starting)
        let new_pids: HashSet<_> = current_pids.difference(&self.current_steam_pids).collect();
        if !new_pids.is_empty() && self.current_steam_pids.is_empty() {
            debug!("New Steam processes detected: {:?}", new_pids);
            self.send_event(SteamEvent::Starting).await?;
        }

        // Detect disappeared Steam processes (Steam shutdown)
        let removed_pids: HashSet<_> = self.current_steam_pids.difference(&current_pids).collect();
        if !removed_pids.is_empty() && current_pids.is_empty() {
            debug!("Steam processes terminated: {:?}", removed_pids);
            self.send_event(SteamEvent::Shutdown).await?;
        }

        self.current_steam_pids = current_pids;
        Ok(())
    }

    async fn send_event(&self, event: SteamEvent) -> Result<()> {
        if let Err(_) = self.event_sender.send(event.clone()) {
            warn!("No listeners for Steam event: {:?}", event);
        }
        Ok(())
    }

    async fn start_journalctl_monitor(&self) -> Result<broadcast::Receiver<SystemEvent>> {
        let (sender, receiver) = broadcast::channel(16);

        tokio::spawn(async move {
            if let Err(e) = Self::monitor_systemd_journal(sender).await {
                warn!("Journalctl monitor error: {}", e);
            }
        });

        Ok(receiver)
    }

    async fn monitor_systemd_journal(sender: broadcast::Sender<SystemEvent>) -> Result<()> {
        use tokio::process::Command;
        use tokio::io::{AsyncBufReadExt, BufReader};

        let mut child = Command::new("journalctl")
            .args(&["-f", "-u", "systemd-suspend.service", "-u", "systemd-hibernate.service"])
            .stdout(std::process::Stdio::piped())
            .spawn()?;

        let stdout = child.stdout.take().unwrap();
        let reader = BufReader::new(stdout);
        let mut lines = reader.lines();

        while let Ok(Some(line)) = lines.next_line().await {
            if line.contains("suspend") || line.contains("Suspending system") {
                let _ = sender.send(SystemEvent::Suspend);
            } else if line.contains("resume") || line.contains("System resumed") {
                let _ = sender.send(SystemEvent::Resume);
            }
        }

        Ok(())
    }
}

#[derive(Debug, Clone)]
enum SystemEvent {
    Suspend,
    Resume,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::Config;

    #[tokio::test]
    async fn test_steam_monitor_creation() {
        let config = Config::default();
        let monitor = SteamMonitor::new(config).await;
        assert!(monitor.is_ok());
    }
}