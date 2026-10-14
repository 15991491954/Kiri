//! Explicit microphone selection. Persist native identifiers, never display names
//! or enumeration indices; a missing selected device must not record another input.

use anyhow::{anyhow, Result};
use serde::Serialize;
use tauri::{AppHandle, Manager, WebviewWindow};

pub const SELECTED_UNAVAILABLE: &str =
    "The selected microphone is unavailable. Choose another microphone and try again.";

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct MicrophoneDevice {
    pub id: String,
    pub name: String,
}

#[tauri::command]
pub async fn list_microphone_devices(
    app: AppHandle,
    window: WebviewWindow,
) -> Result<Vec<MicrophoneDevice>, String> {
    let state = app.state::<crate::state::AppState>();
    let allowed = state
        .capture
        .lock()
        .unwrap()
        .session
        .as_ref()
        .is_some_and(|session| {
            session
                .overlay_labels
                .iter()
                .any(|label| label == window.label())
        });
    if !allowed {
        return Err("Microphones are only available in capture.".into());
    }
    // Device discovery never opens a stream or prompts for microphone access.
    tauri::async_runtime::spawn_blocking(available_devices)
        .await
        .map_err(|error| error.to_string())?
        .map_err(|error| error.to_string())
}

pub fn validate_selection(id: Option<&str>) -> Result<()> {
    let Some(id) = id else {
        return Ok(());
    };
    require_selected(id, &available_devices()?)
}

fn require_selected(id: &str, devices: &[MicrophoneDevice]) -> Result<()> {
    if devices.iter().any(|device| device.id == id) {
        Ok(())
    } else {
        Err(anyhow!(SELECTED_UNAVAILABLE))
    }
}

#[cfg(target_os = "macos")]
pub fn available_devices() -> Result<Vec<MicrophoneDevice>> {
    use objc2_av_foundation::{AVCaptureDevice, AVMediaTypeAudio};
    if !crate::platform::mic_supported() {
        return Ok(Vec::new());
    }
    // SCK requires AVCaptureDevice.uniqueID (not a CPAL display name or index).
    // This API includes every currently connected audio input, including
    // Continuity inputs when macOS exposes them, without starting capture.
    let media_type = unsafe { AVMediaTypeAudio }
        .ok_or_else(|| anyhow!("Audio device discovery is unavailable."))?;
    #[allow(deprecated)]
    let devices = unsafe { AVCaptureDevice::devicesWithMediaType(media_type) };
    Ok(devices
        .iter()
        .filter(|device| unsafe { device.isConnected() })
        .map(|device| MicrophoneDevice {
            id: format!("avfoundation:{}", unsafe { device.uniqueID() }),
            name: unsafe { device.localizedName() }.to_string(),
        })
        .collect())
}

#[cfg(windows)]
pub fn available_devices() -> Result<Vec<MicrophoneDevice>> {
    use cpal::traits::{DeviceTrait, HostTrait};
    let host = cpal::default_host();
    Ok(host
        .input_devices()?
        .filter_map(|device| {
            Some(MicrophoneDevice {
                id: device.id().ok()?.to_string(),
                name: device.description().ok()?.name().to_owned(),
            })
        })
        .collect())
}

#[cfg(target_os = "linux")]
pub fn available_devices() -> Result<Vec<MicrophoneDevice>> {
    crate::linux_audio::microphone_devices()
}

#[cfg(not(target_os = "linux"))]
pub fn cpal_input_device(selected: Option<&str>) -> Result<cpal::Device> {
    use cpal::traits::{DeviceTrait, HostTrait};
    let host = cpal::default_host();
    let Some(selected) = selected else {
        return host
            .default_input_device()
            .ok_or_else(|| anyhow!("No microphone input device is available."));
    };
    // Microphone checks use the same selected Core Audio UID as SCK. Do not
    // substitute the default input if an AVCapture-only device has no CPAL input.
    #[cfg(target_os = "macos")]
    let selected = selected
        .strip_prefix("avfoundation:")
        .ok_or_else(|| anyhow!(SELECTED_UNAVAILABLE))?;
    host.input_devices()?
        .find(|device| {
            device.id().is_ok_and(|id| {
                #[cfg(target_os = "macos")]
                {
                    id.id() == selected
                }
                #[cfg(windows)]
                {
                    id.to_string() == selected
                }
            })
        })
        .ok_or_else(|| anyhow!(SELECTED_UNAVAILABLE))
}

#[cfg(target_os = "macos")]
pub fn macos_capture_id(selected: Option<&str>) -> Result<Option<String>> {
    validate_selection(selected)?;
    selected
        .map(|id| {
            id.strip_prefix("avfoundation:")
                .map(str::to_owned)
                .ok_or_else(|| anyhow!(SELECTED_UNAVAILABLE))
        })
        .transpose()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stable_identifiers_select_between_same_named_inputs_and_reject_removed_devices() {
        let devices = vec![
            MicrophoneDevice {
                id: "device-a".into(),
                name: "Microphone".into(),
            },
            MicrophoneDevice {
                id: "device-b".into(),
                name: "Microphone".into(),
            },
        ];
        assert!(require_selected("device-b", &devices).is_ok());
        assert!(require_selected("Microphone", &devices).is_err());
        assert!(require_selected("device-b", &devices[..1]).is_err());
        assert!(require_selected("device-b", &[]).is_err());
    }

    // Opt in on a physical Mac. Discovery only: no audio stream, permission
    // request, or change to the system/default input is performed.
    #[cfg(target_os = "macos")]
    #[test]
    #[ignore = "requires a Mac with connected microphone hardware"]
    fn connected_microphone_discovery_smoke() {
        assert!(crate::platform::mic_supported());
        let devices = available_devices().expect("native audio device discovery");
        assert!(
            !devices.is_empty(),
            "connect a microphone before running this smoke test"
        );
        let mut identifiers = std::collections::HashSet::new();
        for device in &devices {
            assert!(!device.name.is_empty());
            assert!(
                identifiers.insert(&device.id),
                "duplicate native microphone identifier"
            );
            let native_id = device.id.strip_prefix("avfoundation:").unwrap();
            assert!(!native_id.is_empty());
            assert_eq!(
                macos_capture_id(Some(&device.id)).unwrap().as_deref(),
                Some(native_id)
            );
        }
        println!(
            "Connected audio inputs: {}",
            devices
                .iter()
                .map(|device| device.name.as_str())
                .collect::<Vec<_>>()
                .join(", ")
        );
        assert_eq!(macos_capture_id(None).unwrap(), None);
    }

    #[test]
    fn ipc_exposes_identifiers_and_names_without_fabricated_default_entry() {
        let device = MicrophoneDevice {
            id: "avfoundation:stable-uid".into(),
            name: "Mac microphone".into(),
        };
        let value = serde_json::to_value(device).unwrap();
        assert_eq!(
            value,
            serde_json::json!({"id":"avfoundation:stable-uid", "name":"Mac microphone"})
        );
    }
}
