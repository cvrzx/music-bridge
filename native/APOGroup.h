#ifndef MICFX_APO_GROUP_H
#define MICFX_APO_GROUP_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// Equalizer APO iOS controller bridge; optional, disabled unless the controller
// explicitly sets mic.enabled=true. Keeps all pre-existing MicFX keys intact.
void mf_apo_start(void);
int mf_apo_active(void);
void mf_apo_prepare(unsigned sampleRate); // once per AudioUnit render block
float mf_apo_sample(float rawMic, unsigned channel, unsigned channels);         // realtime, no alloc/IO/locks
// Stereo 48kHz 20ms packets from an authorized sender, downmixed only when
// Discord exposes a mono outgoing AudioUnit.
int mf_apo_music_next(unsigned sampleRate,float* left,float* right);
float mf_apo_music_gain(void);
unsigned mf_apo_settings_updates(void);
unsigned mf_apo_music_packets(void);
// Diagnostics: 0 starting, 1 App Group denied, 2 settings file missing,
// 3 JSON invalid/unusable, 4 JSON valid (may be unchanged).
unsigned mf_apo_read_state(void);
unsigned mf_apo_worker_ticks(void);
#ifdef __cplusplus
}
#endif
#endif
