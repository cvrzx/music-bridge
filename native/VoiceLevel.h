#ifndef MF_VOICE_LEVEL_H
#define MF_VOICE_LEVEL_H
#include <math.h>

typedef struct {
    float power, gain, follow, turnDown, turnUp;
} MFVoiceLevel;

static inline void mf_level_reset(MFVoiceLevel *s, unsigned rate) {
    *s = (MFVoiceLevel){.gain=1, .follow=1.f-expf(-1.f/(.030f*rate)),
        .turnDown=1.f-expf(-1.f/(.006f*rate)), .turnUp=1.f-expf(-1.f/(.080f*rate))};
}

// One detector and one gain for both channels to preserve the stereo image.
static inline void mf_level_frame(MFVoiceLevel *s, float mic[2], float target) {
    float peak = fmaxf(fabsf(mic[0]), fabsf(mic[1]));
    s->power += s->follow * (peak*peak - s->power);
    float rms = sqrtf(fmaxf(s->power, 0));
    float wanted = rms > .0032f ? fminf(32.f, target/rms) : 1.f;
    s->gain += (wanted < s->gain ? s->turnDown : s->turnUp) * (wanted - s->gain);
    // Shared soft knee approaches -0.1 dBFS without clipping consonants flat.
    float driven = peak*s->gain, scale = s->gain;
    if (driven > .75f) {
        float over = driven-.75f;
        scale = (.75f + .23855f*over/(.23855f+over))/peak;
    }
    mic[0] *= scale;
    mic[1] *= scale;
}
#endif
