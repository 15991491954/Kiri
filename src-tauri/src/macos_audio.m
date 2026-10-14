// ScreenCaptureKit microphone buffers use the device's native PCM format.
// Keep one converter per recording stream so resampling phase survives callbacks.
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

@interface KiriMicrophoneNormalizer : NSObject
@property(nonatomic, strong) AVAudioFormat *inputFormat;
@property(nonatomic, strong) AVAudioConverter *converter;
@end
@implementation KiriMicrophoneNormalizer
@end

static int kiri_audio_error(char *error, size_t capacity, NSString *message) {
    if (error && capacity) strlcpy(error, message.UTF8String ?: "Audio conversion failed", capacity);
    return -1;
}

int kiri_microphone_normalize(void **context, CMSampleBufferRef sample,
                             void **bytes, size_t *length, char *error, size_t capacity) {
    @autoreleasepool {
        *bytes = NULL;
        *length = 0;
        CMItemCount frames = CMSampleBufferGetNumSamples(sample);
        if (frames == 0) return 0;
        CMFormatDescriptionRef description = CMSampleBufferGetFormatDescription(sample);
        AVAudioFormat *format = description ? [[AVAudioFormat alloc] initWithCMAudioFormatDescription:description] : nil;
        if (!format || !isfinite(format.sampleRate) || format.sampleRate < 8000 || format.sampleRate > 384000
            || format.channelCount == 0 || format.channelCount > 32 || frames < 0 || frames > 1048576) {
            return kiri_audio_error(error, capacity, @"Unsupported microphone PCM format");
        }
        KiriMicrophoneNormalizer *state = (__bridge KiriMicrophoneNormalizer *)*context;
        if (!state) {
            state = [KiriMicrophoneNormalizer new];
            state.inputFormat = format;
            AVAudioFormat *outputFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                sampleRate:48000 channels:2 interleaved:YES];
            state.converter = [[AVAudioConverter alloc] initFromFormat:format toFormat:outputFormat];
            if (!state.converter) return kiri_audio_error(error, capacity, @"Cannot convert microphone PCM format");
            state.converter.primeMethod = AVAudioConverterPrimeMethod_None;
            state.converter.channelMap = format.channelCount == 1 ? @[@0, @0] : @[@0, @1];
            *context = (__bridge_retained void *)state;
        } else if (![state.inputFormat isEqual:format]) {
            // A format change midstream cannot keep the established sample clock.
            // Reject the segment instead of saving sped-up or desynchronized audio.
            return kiri_audio_error(error, capacity, @"Microphone format changed during recording");
        }
        AVAudioPCMBuffer *input = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:(AVAudioFrameCount)frames];
        if (!input) return kiri_audio_error(error, capacity, @"Cannot allocate microphone input buffer");
        input.frameLength = (AVAudioFrameCount)frames;
        OSStatus copied = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, 0, (int32_t)frames, input.mutableAudioBufferList);
        if (copied != noErr) return kiri_audio_error(error, capacity, @"Cannot copy microphone PCM buffer");
        AVAudioFrameCount outputCapacity = (AVAudioFrameCount)ceil((double)frames * 48000 / format.sampleRate) + 256;
        AVAudioPCMBuffer *output = [[AVAudioPCMBuffer alloc] initWithPCMFormat:state.converter.outputFormat frameCapacity:outputCapacity];
        if (!output) return kiri_audio_error(error, capacity, @"Cannot allocate microphone output buffer");
        NSMutableData *converted = [NSMutableData data];
        __block AVAudioFrameCount consumed = 0;
        __block BOOL allocationFailed = NO;
        BOOL drained = NO;
        for (unsigned pass = 0; pass < 8; pass++) {
            output.frameLength = 0;
            NSError *conversionError = nil;
            AVAudioConverterOutputStatus status = [state.converter convertToBuffer:output error:&conversionError
                withInputFromBlock:^AVAudioBuffer *(AVAudioPacketCount count, AVAudioConverterInputStatus *inputStatus) {
                    if (consumed == input.frameLength || count == 0) {
                        *inputStatus = AVAudioConverterInputStatus_NoDataNow;
                        return nil;
                    }
                    AVAudioFrameCount take = MIN(count, input.frameLength - consumed);
                    AVAudioPCMBuffer *part = input;
                    if (consumed != 0 || take != input.frameLength) {
                        // The converter may request fewer frames than the SCK
                        // callback supplied. Returning a larger buffer discards
                        // its unread tail, so honor each requested packet count.
                        part = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:take];
                        if (!part) {
                            allocationFailed = YES;
                            *inputStatus = AVAudioConverterInputStatus_NoDataNow;
                            return nil;
                        }
                        part.frameLength = take;
                        const AudioBufferList *source = input.audioBufferList;
                        AudioBufferList *destination = part.mutableAudioBufferList;
                        size_t stride = format.streamDescription->mBytesPerFrame;
                        for (UInt32 channel = 0; channel < source->mNumberBuffers; channel++) {
                            memcpy(destination->mBuffers[channel].mData,
                                (const char *)source->mBuffers[channel].mData + consumed * stride, take * stride);
                        }
                    }
                    consumed += take;
                    *inputStatus = AVAudioConverterInputStatus_HaveData;
                    return part;
                }];
            if (status == AVAudioConverterOutputStatus_Error || conversionError || allocationFailed) {
                return kiri_audio_error(error, capacity, conversionError.localizedDescription ?: @"Microphone conversion failed");
            }
            if (output.frameLength) {
                const AudioBufferList *buffers = output.audioBufferList;
                [converted appendBytes:buffers->mBuffers[0].mData length:(size_t)output.frameLength * 2 * sizeof(float)];
            }
            if (status == AVAudioConverterOutputStatus_InputRanDry || status == AVAudioConverterOutputStatus_EndOfStream) {
                drained = YES;
                break;
            }
        }
        if (!drained || consumed != input.frameLength) return kiri_audio_error(error, capacity, @"Microphone converter did not drain");
        if (converted.length) {
            void *result = malloc(converted.length);
            if (!result) return kiri_audio_error(error, capacity, @"Cannot allocate converted microphone data");
            memcpy(result, converted.bytes, converted.length);
            *bytes = result;
            *length = converted.length;
        }
        return 0;
    }
}

void kiri_microphone_normalizer_destroy(void *context) {
    if (context) { id state = (__bridge_transfer id)context; (void)state; }
}
void kiri_microphone_normalizer_free_bytes(void *bytes) { free(bytes); }
