// A C interface to WebRTC's echo canceller (AEC3), for Swift. Implemented in EchoCanceller.cpp.
#ifndef MYLOOM_ECHO_CANCELLER_H
#define MYLOOM_ECHO_CANCELLER_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MyLoomEchoCanceller MyLoomEchoCanceller;

/// Samples per channel in one block: WebRTC works in 10 ms blocks (480 at 48 kHz).
int myloom_echo_block_size(int sample_rate);

/// An echo canceller for a mono microphone and a stereo far end (what the speakers play).
/// Returns NULL if WebRTC couldn't be set up.
MyLoomEchoCanceller *myloom_echo_create(int sample_rate);
void myloom_echo_destroy(MyLoomEchoCanceller *canceller);

/// Gives it one block of what the speakers are playing, left and right. Call before the
/// microphone block for the same moment. Returns 0, or a WebRTC error code.
int myloom_echo_far_end(MyLoomEchoCanceller *canceller, const float *left, const float *right);

/// Removes the speakers' sound from one block of microphone audio, in place.
/// Returns 0, or a WebRTC error code.
int myloom_echo_near_end(MyLoomEchoCanceller *canceller, float *microphone);

#ifdef __cplusplus
}
#endif

#endif
