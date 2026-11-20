#ifndef MICFX_DRUM_SHAPE_H
#define MICFX_DRUM_SHAPE_H
#include "pitch.h"

// Independent mic effect based on the published SweetDrums 4 control behavior.
typedef struct {
    MFBiquad tone[3], detector[2];
    float bandEnvelope[2], envelope, limiter;
    float drive, output, targetDrive, targetOutput, wet, targetWet;
    float attack, release, smooth, process;
    unsigned rate;
} MFDrumShape;

static inline void drum_config(MFDrumShape *s,unsigned sr,float input,float output,float process){
    int fresh=s->rate!=sr;
    if(fresh){
        memset(s,0,sizeof(*s));
        s->rate=sr;
        s->attack=1.f-expf(-1.f/(.006f*sr));
        s->release=1.f-expf(-1.f/(.090f*sr));
        s->smooth=1.f-expf(-1.f/(.010f*sr));
        s->limiter=1.f;
        for(unsigned i=0;i<3;i++)mf_biquad_reset(&s->tone[i]);
        float frequencies[2]={115.f,fminf(4200.f,.32f*sr)};
        for(unsigned i=0;i<2;i++){
            mf_biquad_reset(&s->detector[i]);
            double w=2.*MF_PI*frequencies[i]/sr,a=sin(w)/(2.*.85);
            mf_target(&s->detector[i],mf_norm(a,0,-a,1+a,-2*cos(w),1-a),0);
        }
    }
    float wet=fmaxf(0,fminf(1,process*.01f));
    if(fresh||process!=s->process){
        const unsigned bands[3]={0,2,6};
        const float levels[3]={3.0f,-3.3f,3.2f};
        for(unsigned i=0;i<3;i++)
            mf_target(&s->tone[i],mf_eqcoef(bands[i],levels[i]*wet,sr),fresh?0:sr/80);
        s->process=process;
    }
    s->targetDrive=powf(10.f,input/20.f);
    s->targetOutput=powf(10.f,output/20.f);
    s->targetWet=wet;
    if(fresh){s->drive=s->targetDrive;s->output=s->targetOutput;s->wet=wet;}
}

static inline float drum_follow(float previous,float level,float attack,float release){
    return previous+(level-previous)*(level>previous?attack:release);
}

static inline float drum_sample(MFDrumShape *s,float x){
    if(!isfinite(x))x=0.f;
    s->drive+=(s->targetDrive-s->drive)*s->smooth;
    s->output+=(s->targetOutput-s->output)*s->smooth;
    s->wet+=(s->targetWet-s->wet)*s->smooth;
    float wet=s->wet;
    float y=x;
    for(unsigned i=0;i<3;i++)y=mf_biquad(&s->tone[i],y);
    // Recombine two independently detected frequency bands before saturation.
    float correction=0.f;
    for(unsigned i=0;i<2;i++){
        float band=mf_biquad(&s->detector[i],y);
        float level=fabsf(band)*s->drive;
        s->bandEnvelope[i]=drum_follow(s->bandEnvelope[i],level,s->attack,s->release);
        float threshold=i?.09f:.16f;
        float over=fmaxf(0.f,s->bandEnvelope[i]-threshold);
        correction-=band*wet*(i?.65f:.5f)*over/(threshold+over);
    }
    y=(y+correction)*s->drive;
    s->envelope=drum_follow(s->envelope,fabsf(y),s->attack,s->release);
    float excess=fmaxf(0.f,s->envelope-.22f);
    // Unity input / process is transparent below full scale. Input drive changes
    // the knee with reciprocal small-signal compensation.
    float driveMix=fminf(1.f,fmaxf(0.f,(s->drive-1.f)/3.f));
    float shape=wet+(1.f-wet)*driveMix;
    float gr=1.f/sqrtf(1.f+shape*excess*4.f);
    float driven=y*gr, knee=1.f+1.5f*wet;
    float saturated=shape>0.f?tanhf(knee*driven)/knee:driven;
    y=(driven+(saturated-driven)*shape)*s->output/s->drive;
    float peak=fabsf(y),goal=peak>1.f?1.f/peak:1.f;
    s->limiter=goal<s->limiter?goal:s->limiter+(goal-s->limiter)*s->release;
    return mf_clip(y*s->limiter);
}
#endif
