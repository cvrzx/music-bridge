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
float mf_apo_sample(float rawMic);         // realtime, no alloc/IO/locks
// Stereo 48kHz 20ms packets from an authorized sender, downmixed only when
// Discord exposes a mono outgoing AudioUnit.
int mf_apo_music_next(unsigned sampleRate,float* left,float* right);
float mf_apo_music_gain(void);
unsigned mf_apo_settings_updates(void);
unsigned mf_apo_music_packets(void);
#ifdef __cplusplus
}
#endif
#endif
