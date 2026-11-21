#ifndef MF_VOICE_PAN_H
#define MF_VOICE_PAN_H
// For a hard pan, fold both input sides into the selected speaker. At center
// the original stereo pair passes unchanged. Mono routes are handled by caller.
static inline void mf_pan_pair(float pair[2], int side) {
    if (!side) return;
    float mono = .5f*(pair[0]+pair[1]);
    pair[0] = side < 0 ? mono : 0;
    pair[1] = side > 0 ? mono : 0;
}
#endif
