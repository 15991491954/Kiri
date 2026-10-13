//! Native PCM normalization for explicitly selected microphones. AVAudioConverter
//! retains its sample-rate phase across callbacks; encoders keep their 48k stereo contract.

use anyhow::{anyhow, Result};
use objc2_core_media::CMSampleBuffer;
use std::ffi::{c_char, c_void, CStr};

extern "C" {
    fn kiri_microphone_normalize(
        context: *mut *mut c_void,
        sample: &CMSampleBuffer,
        bytes: *mut *mut c_void,
        length: *mut usize,
        error: *mut c_char,
        capacity: usize,
    ) -> i32;
    fn kiri_microphone_normalizer_destroy(context: *mut c_void);
    fn kiri_microphone_normalizer_free_bytes(bytes: *mut c_void);
}

#[derive(Default)]
pub(super) struct MicrophoneNormalizer {
    context: *mut c_void,
}
// The opaque context is exclusively owned and only accessed under the delegate's
// Mutex. No AVAudioConverter instance is used concurrently or bound to a UI thread.
unsafe impl Send for MicrophoneNormalizer {}

impl MicrophoneNormalizer {
    pub(super) fn convert(&mut self, sample: &CMSampleBuffer) -> Result<Vec<u8>> {
        let mut bytes = std::ptr::null_mut();
        let mut length = 0;
        let mut error = [0 as c_char; 512];
        let status = unsafe {
            kiri_microphone_normalize(
                &mut self.context,
                sample,
                &mut bytes,
                &mut length,
                error.as_mut_ptr(),
                error.len(),
            )
        };
        if status != 0 {
            return Err(anyhow!(unsafe { CStr::from_ptr(error.as_ptr()) }
                .to_string_lossy()
                .into_owned()));
        }
        if bytes.is_null() {
            return Ok(Vec::new());
        }
        let data = unsafe { std::slice::from_raw_parts(bytes.cast::<u8>(), length) }.to_vec();
        unsafe { kiri_microphone_normalizer_free_bytes(bytes) };
        Ok(data)
    }
}

impl Drop for MicrophoneNormalizer {
    fn drop(&mut self) {
        unsafe { kiri_microphone_normalizer_destroy(self.context) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use objc2::rc::Retained;
    use objc2::runtime::AnyObject;
    use objc2::{class, msg_send};
    use objc2_core_foundation::CFRetained;
    use objc2_core_media::{
        CMBlockBuffer, CMFormatDescription, CMSampleTimingInfo, CMTime, CMTimeFlags,
    };
    use std::ptr::NonNull;

    // Build real CoreMedia PCM buffers from generated signals, without requesting
    // microphone access. Tests run the same AVAudioConverter path as SCK callbacks.
    fn sample_buffer(
        bytes: &[u8],
        sample_rate: u32,
        channels: u32,
        planar: bool,
        common_format: usize,
        start: i64,
    ) -> CFRetained<CMSampleBuffer> {
        let bytes_per_sample = if common_format == 3 { 2 } else { 4 };
        let frames = bytes.len() / (bytes_per_sample * channels as usize);
        unsafe {
            let allocated: *mut AnyObject = msg_send![class!(AVAudioFormat), alloc];
            let format: *mut AnyObject = msg_send![allocated, initWithCommonFormat:common_format,
                sampleRate:f64::from(sample_rate), channels:channels, interleaved:!planar];
            let format = Retained::from_raw(format).unwrap();
            let description: *const CMFormatDescription = msg_send![&*format, formatDescription];
            let mut block = std::ptr::null_mut();
            assert_eq!(
                CMBlockBuffer::create_with_memory_block(
                    None,
                    std::ptr::null_mut(),
                    bytes.len(),
                    None,
                    std::ptr::null(),
                    0,
                    bytes.len(),
                    0,
                    NonNull::from(&mut block)
                ),
                0
            );
            let block = CFRetained::from_raw(NonNull::new(block).unwrap());
            assert_eq!(
                CMBlockBuffer::replace_data_bytes(
                    NonNull::new(bytes.as_ptr().cast_mut().cast()).unwrap(),
                    &block,
                    0,
                    bytes.len()
                ),
                0
            );
            let time = |value| CMTime {
                value,
                timescale: sample_rate as i32,
                flags: CMTimeFlags(1),
                epoch: 0,
            };
            let timing = CMSampleTimingInfo {
                duration: time(1),
                presentationTimeStamp: time(start),
                decodeTimeStamp: time(start),
            };
            let mut buffer = std::ptr::null_mut();
            assert_eq!(
                CMSampleBuffer::create_ready(
                    None,
                    Some(&block),
                    Some(&*description),
                    frames as isize,
                    1,
                    &timing,
                    0,
                    std::ptr::null(),
                    NonNull::from(&mut buffer)
                ),
                0
            );
            CFRetained::from_raw(NonNull::new(buffer).unwrap())
        }
    }

    fn f32_buffer(
        samples: &[f32],
        rate: u32,
        channels: u32,
        planar: bool,
        start: i64,
    ) -> CFRetained<CMSampleBuffer> {
        let bytes: Vec<_> = samples
            .iter()
            .flat_map(|sample| sample.to_ne_bytes())
            .collect();
        sample_buffer(&bytes, rate, channels, planar, 1, start)
    }

    fn floats(bytes: Vec<u8>) -> Vec<f32> {
        bytes
            .chunks_exact(4)
            .map(|sample| f32::from_ne_bytes(sample.try_into().unwrap()))
            .collect()
    }

    #[test]
    fn mono_pcm_is_duplicated_without_speed_or_gain_change() {
        let signal: Vec<f32> = (0..480)
            .map(|index| (index as f32 * 0.04).sin() * 0.5)
            .collect();
        let mut converter = MicrophoneNormalizer::default();
        let output = floats(
            converter
                .convert(&f32_buffer(&signal, 48_000, 1, false, 0))
                .unwrap(),
        );
        assert_eq!(output.len(), signal.len() * 2);
        for (index, frame) in output.chunks_exact(2).enumerate() {
            assert!((frame[0] - signal[index]).abs() < 0.00001);
            assert_eq!(frame[0], frame[1]);
        }
    }

    #[test]
    fn planar_and_interleaved_stereo_preserve_both_channels() {
        let left: Vec<f32> = (0..480)
            .map(|index| (index as f32 * 0.04).sin() * 0.3)
            .collect();
        let right: Vec<f32> = left.iter().map(|value| -value * 0.5).collect();
        let interleaved: Vec<_> = left
            .iter()
            .zip(&right)
            .flat_map(|(left, right)| [*left, *right])
            .collect();
        let planar: Vec<_> = left.into_iter().chain(right).collect();
        for (signal, is_planar) in [(&interleaved, false), (&planar, true)] {
            let mut converter = MicrophoneNormalizer::default();
            let output = floats(
                converter
                    .convert(&f32_buffer(signal, 48_000, 2, is_planar, 0))
                    .unwrap(),
            );
            assert_eq!(output.len(), interleaved.len());
            assert!(output
                .iter()
                .zip(&interleaved)
                .all(|(output, expected)| (output - expected).abs() < 0.00001));
        }
    }

    #[test]
    fn signed_integer_microphone_is_normalized_to_float_stereo() {
        let signal = [0i16, 8192, -8192, 16384, -16384, 0];
        let bytes: Vec<_> = signal
            .iter()
            .flat_map(|sample| sample.to_ne_bytes())
            .collect();
        let mut converter = MicrophoneNormalizer::default();
        let output = floats(
            converter
                .convert(&sample_buffer(&bytes, 48_000, 1, false, 3, 0))
                .unwrap(),
        );
        assert_eq!(output.len(), signal.len() * 2);
        for (frame, expected) in output.chunks_exact(2).zip(signal) {
            assert!((frame[0] - f32::from(expected) / 32768.0).abs() < 0.00001);
            assert_eq!(frame[0], frame[1]);
        }
    }

    #[test]
    fn sample_rate_conversion_is_continuous_across_uneven_callback_boundaries() {
        for rate in [44_100, 96_000] {
            let signal: Vec<f32> = (0..rate * 2)
                .map(|index| {
                    (index as f32 * 440.0 * std::f32::consts::TAU / rate as f32).sin() * 0.5
                })
                .collect();
            let mut whole = MicrophoneNormalizer::default();
            let whole = floats(
                whole
                    .convert(&f32_buffer(&signal, rate, 1, false, 0))
                    .unwrap(),
            );
            let mut chunked = MicrophoneNormalizer::default();
            let mut actual = Vec::new();
            let mut position = 0;
            for size in [17, 255, 441, 1024, 777].into_iter().cycle() {
                if position == signal.len() {
                    break;
                }
                let end = (position + size).min(signal.len());
                actual.extend(floats(
                    chunked
                        .convert(&f32_buffer(
                            &signal[position..end],
                            rate,
                            1,
                            false,
                            position as i64,
                        ))
                        .unwrap(),
                ));
                position = end;
            }
            assert_eq!(
                actual.len(),
                whole.len(),
                "callback partition must not change the sample clock"
            );
            assert!(
                actual
                    .iter()
                    .zip(&whole)
                    .all(|(actual, whole)| (actual - whole).abs() < 0.00001),
                "callback boundaries must not reset resampling phase"
            );
            // NoDataNow drains all output for the supplied input without ending
            // the converter. Exactly two seconds must remain two seconds.
            assert_eq!(actual.len() / 2, 96_000);
            println!("{rate} Hz mono: 96000 stereo frames, identical across uneven callbacks");
        }
    }

    #[test]
    fn changing_native_format_midstream_is_rejected_instead_of_corrupting_the_clock() {
        let mut converter = MicrophoneNormalizer::default();
        converter
            .convert(&f32_buffer(&[0.25; 480], 48_000, 1, false, 0))
            .unwrap();
        let error = converter
            .convert(&f32_buffer(&[0.25; 441], 44_100, 1, false, 480))
            .unwrap_err();
        assert!(error.to_string().contains("format changed"));
    }
}
