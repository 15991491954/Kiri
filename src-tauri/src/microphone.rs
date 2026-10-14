//! Explicit, bounded microphone checks. PCM is inspected in memory and never saved.
pub mod devices;
#[cfg(not(target_os = "linux"))]
use cpal::traits::{DeviceTrait, StreamTrait};
use serde::Serialize;
#[cfg(not(target_os = "linux"))]
use std::sync::atomic::AtomicU32;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
#[cfg(not(target_os = "linux"))]
use std::sync::Arc;
#[cfg(not(target_os = "linux"))]
use std::time::{Duration, Instant};
use tauri::{AppHandle, Manager, WebviewWindow};

static GENERATION: AtomicU64 = AtomicU64::new(0);
static RUNNING: AtomicBool = AtomicBool::new(false);

pub fn stop() {
    GENERATION.fetch_add(1, Ordering::SeqCst);
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MicrophoneLevel {
    device: String,
    level: f32,
}

#[tauri::command]
pub fn stop_microphone_check(window: WebviewWindow) -> Result<(), String> {
    if !window.label().starts_with("overlay") {
        return Err("Microphone checks are only available in capture.".into());
    }
    stop();
    Ok(())
}

fn capture_is_current(app: &AppHandle, label: &str, id: uuid::Uuid) -> bool {
    app.state::<crate::state::AppState>()
        .capture
        .lock()
        .unwrap()
        .session
        .as_ref()
        .is_some_and(|session| {
            session.capture_id == id && session.overlay_labels.iter().any(|item| item == label)
        })
}

#[tauri::command]
pub async fn microphone_check(
    app: AppHandle,
    window: WebviewWindow,
    on_level: tauri::ipc::Channel<MicrophoneLevel>,
    device_id: Option<String>,
) -> Result<(), String> {
    let label = window.label().to_owned();
    let id = {
        let state = app.state::<crate::state::AppState>();
        let capture = state.capture.lock().unwrap();
        let session = capture
            .session
            .as_ref()
            .ok_or("No active capture session.")?;
        if !session.overlay_labels.contains(&label) {
            return Err("Microphone checks are only available in capture.".into());
        }
        session.capture_id
    };
    if RUNNING
        .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
        .is_err()
    {
        return Err("A microphone check is already running.".into());
    }
    let generation = GENERATION.load(Ordering::SeqCst);
    tauri::async_runtime::spawn_blocking(move || {
        struct RunningGuard;
        impl Drop for RunningGuard {
            fn drop(&mut self) {
                RUNNING.store(false, Ordering::SeqCst);
            }
        }
        let _guard = RunningGuard;
        if GENERATION.load(Ordering::SeqCst) != generation || !capture_is_current(&app, &label, id)
        {
            return Ok(());
        }
        match crate::platform::request_microphone_access().map_err(|e| e.to_string())? {
            crate::platform::MicrophoneAccess::Authorized => {}
            _ => return Err("Microphone access is unavailable.".to_owned()),
        }
        if GENERATION.load(Ordering::SeqCst) != generation || !capture_is_current(&app, &label, id)
        {
            return Ok(());
        }
        #[cfg(target_os = "linux")]
        {
            crate::linux_audio::microphone_check(
                device_id.as_deref(),
                || {
                    GENERATION.load(Ordering::SeqCst) == generation
                        && capture_is_current(&app, &label, id)
                },
                |device, peak| {
                    on_level
                        .send(MicrophoneLevel {
                            device,
                            level: meter_level(peak),
                        })
                        .map_err(Into::into)
                },
            )
            .map_err(|error| error.to_string())
        }
        #[cfg(not(target_os = "linux"))]
        {
            let device = devices::cpal_input_device(device_id.as_deref()).map_err(|error| error.to_string())?;
            let name = device
                .description()
                .map_err(|e| e.to_string())?
                .name()
                .to_owned();
            let config = device.default_input_config().map_err(|e| e.to_string())?;
            let level = Arc::new(AtomicU32::new(0));
            let failed = Arc::new(AtomicBool::new(false));
            let callback_level = level.clone();
            let callback_failed = failed.clone();
            let format = config.sample_format();
            if !matches!(
                format,
                cpal::SampleFormat::F32 | cpal::SampleFormat::I16 | cpal::SampleFormat::U16
            ) {
                return Err("This microphone's sample format is not supported.".into());
            }
            let stream = device
                .build_input_stream_raw(
                    config.config(),
                    format,
                    move |data, _| {
                        let peak = match format {
                            cpal::SampleFormat::F32 => data
                                .as_slice::<f32>()
                                .unwrap_or_default()
                                .iter()
                                .copied()
                                .map(|v| if v.is_finite() { v.abs() } else { 0.0 })
                                .fold(0.0_f32, f32::max),
                            cpal::SampleFormat::I16 => data
                                .as_slice::<i16>()
                                .unwrap_or_default()
                                .iter()
                                .map(|v| (*v as f32 / 32768.0).abs())
                                .fold(0.0_f32, f32::max),
                            cpal::SampleFormat::U16 => data
                                .as_slice::<u16>()
                                .unwrap_or_default()
                                .iter()
                                .map(|v| ((*v as f32 - 32768.0) / 32768.0).abs())
                                .fold(0.0_f32, f32::max),
                            _ => 0.0,
                        };
                        callback_level.fetch_max(peak.clamp(0.0, 1.0).to_bits(), Ordering::Relaxed);
                    },
                    move |_| {
                        callback_failed.store(true, Ordering::Relaxed);
                    },
                    None,
                )
                .map_err(|e| e.to_string())?;
            stream.play().map_err(|e| e.to_string())?;
            let started = Instant::now();
            while started.elapsed() < Duration::from_secs(5) {
                if GENERATION.load(Ordering::SeqCst) != generation
                    || !capture_is_current(&app, &label, id)
                {
                    break;
                }
                if failed.load(Ordering::Relaxed) {
                    return Err("The microphone stopped responding.".into());
                }
                let peak = f32::from_bits(level.swap(0, Ordering::Relaxed));
                on_level
                    .send(MicrophoneLevel {
                        device: name.clone(),
                        level: meter_level(peak),
                    })
                    .map_err(|e| e.to_string())?;
                std::thread::sleep(Duration::from_millis(100));
            }
            drop(stream);
            Ok(())
        }
    })
    .await
    .map_err(|e| e.to_string())?
}

fn meter_level(peak: f32) -> f32 {
    if !peak.is_finite() || peak <= 0.001 {
        0.0
    } else {
        ((20.0 * peak.log10() + 60.0) / 60.0).clamp(0.0, 1.0)
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn meter_has_silence_floor_and_decibel_scale() {
        assert_eq!(super::meter_level(0.0), 0.0);
        assert_eq!(super::meter_level(f32::NAN), 0.0);
        assert_eq!(super::meter_level(0.001), 0.0);
        assert!((super::meter_level(0.1) - 2.0 / 3.0).abs() < 0.001);
        assert_eq!(super::meter_level(1.0), 1.0);
        assert_eq!(super::meter_level(10.0), 1.0);
    }
}
