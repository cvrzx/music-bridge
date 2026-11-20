#ifndef MICFX_TONE_EQ_H
#define MICFX_TONE_EQ_H
#include "pitch.h"

typedef struct {
    MFBiquad bands[3];
    float trim, targetTrim, alpha;
    unsigned rate;
} MFToneEQ;

// Broad Baxandall-style shelves and a wide mid bell. Centers are design choices.
static inline MFCoef tone_coeff(unsigned band,float db,unsigned rate){
    if(db==0.f)return mf_identity();
    const float centers[3]={100.f,500.f,3000.f};
    double w=2.*MF_PI*centers[band]/rate,c=cos(w),a=pow(10.,db/40.),v=sin(w);
    if(band==1){
        double alpha=v/(2.*.65);
        return mf_norm(1+alpha*a,-2*c,1-alpha*a,1+alpha/a,-2*c,1-alpha/a);
    }
    double t=v*sqrt(2*a),p=a+1,m=a-1;
    if(band==0)return mf_norm(a*(p-m*c+t),2*a*(m-p*c),a*(p-m*c-t),p+m*c+t,-2*(m+p*c),p+m*c-t);
    return mf_norm(a*(p+m*c+t),-2*a*(m+p*c),a*(p+m*c-t),p-m*c+t,2*(m-p*c),p-m*c-t);
}
static inline void tone_config(MFToneEQ *s,unsigned sr,const float gains[3],float output){
    int first=s->rate!=sr;
    if(first){
        memset(s,0,sizeof(*s));s->rate=sr;s->alpha=1.f-expf(-1.f/(.012f*sr));
        for(unsigned i=0;i<3;i++)mf_biquad_reset(&s->bands[i]);
    }
    for(unsigned i=0;i<3;i++)mf_target(&s->bands[i],tone_coeff(i,gains[i],sr),first?0:sr/80);
    s->targetTrim=powf(10.f,output/20.f);
    if(first)s->trim=s->targetTrim;
}
static inline float tone_sample(MFToneEQ *s,float x){
    float y=isfinite(x)?x:0.f;
    for(unsigned i=0;i<3;i++)y=mf_biquad(&s->bands[i],y);
    s->trim+=(s->targetTrim-s->trim)*s->alpha;
    return mf_clip(y*s->trim);
}
#endif
