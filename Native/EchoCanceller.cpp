// WebRTC's audio processing with only its echo canceller (AEC3) and high-pass filter on: the same
// echo canceller Loom's recorder links (webrtc::EchoCanceller, AecState, AdaptiveFirFilter…).
// Noise suppression and automatic gain are left off, so the voice is otherwise untouched.
#include "EchoCanceller.h"

#include <memory>

#include "api/audio/audio_processing.h"

struct MyLoomEchoCanceller {
    webrtc::scoped_refptr<webrtc::AudioProcessing> processing;
    webrtc::StreamConfig farEndConfig;
    webrtc::StreamConfig microphoneConfig;
};

int myloom_echo_block_size(int sample_rate) {
    return sample_rate / 100;
}

MyLoomEchoCanceller *myloom_echo_create(int sample_rate) {
    auto processing = webrtc::AudioProcessingBuilder().Create();
    if (!processing) return nullptr;

    webrtc::AudioProcessing::Config config;
    config.echo_canceller.enabled = true;
    config.echo_canceller.mobile_mode = false;   // the full desktop canceller, not the light mobile one
    config.high_pass_filter.enabled = true;      // WebRTC recommends it with echo cancellation
    config.noise_suppression.enabled = false;
    config.gain_controller1.enabled = false;
    config.gain_controller2.enabled = false;
    processing->ApplyConfig(config);

    auto canceller = std::make_unique<MyLoomEchoCanceller>();
    canceller->processing = processing;
    canceller->farEndConfig = webrtc::StreamConfig(sample_rate, 2);
    canceller->microphoneConfig = webrtc::StreamConfig(sample_rate, 1);
    if (processing->Initialize() != webrtc::AudioProcessing::kNoError) return nullptr;
    return canceller.release();
}

void myloom_echo_destroy(MyLoomEchoCanceller *canceller) {
    delete canceller;
}

int myloom_echo_far_end(MyLoomEchoCanceller *canceller, const float *left, const float *right) {
    const float *source[2] = {left, right};
    // The far end is only analysed; its output isn't used, so it goes to a scratch copy.
    float leftCopy[960], rightCopy[960];
    float *destination[2] = {leftCopy, rightCopy};
    if (canceller->farEndConfig.num_frames() > 960) return webrtc::AudioProcessing::kBadDataLengthError;
    return canceller->processing->ProcessReverseStream(source, canceller->farEndConfig, canceller->farEndConfig, destination);
}

int myloom_echo_near_end(MyLoomEchoCanceller *canceller, float *microphone) {
    float *channels[1] = {microphone};
    // AEC3 finds the speaker-to-mic delay itself; this is only a starting hint.
    canceller->processing->set_stream_delay_ms(0);
    return canceller->processing->ProcessStream(channels, canceller->microphoneConfig, canceller->microphoneConfig, channels);
}
