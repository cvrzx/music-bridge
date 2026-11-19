#ifndef MICFX_PITCH_H
#define MICFX_PITCH_H
#include <stdint.h>
#include <math.h>
#include <string.h>
#define MF_RING 16384u
#define MF_MASK (MF_RING-1u)
#define MF_EQ 8
#define MF_PI 3.14159265358979323846f
static const float mf_freq[MF_EQ]={85,150,300,600,1200,2400,4800,8000};
typedef struct {float b0,b1,b2,a1,a2;} MFCoef;
typedef struct {MFCoef c,t;float z1,z2;uint32_t ramp;} MFBiquad;
typedef struct {float ring[MF_RING],raw[MF_RING];uint32_t cursor,filled,age,ready,sr;float delay[2],ratio,gain,mix,limiter,fade;float lastEq[MF_EQ],lastCut;int eqOn;MFBiquad eq[MF_EQ],aa[2];} MFPitch;
static inline float mf_abs(float x){return fabsf(x);}
static inline float mf_clip(float x){return fmaxf(-1.f,fminf(1.f,x));}
static inline MFCoef mf_identity(void){return (MFCoef){1,0,0,0,0};}
static inline MFCoef mf_norm(double b0,double b1,double b2,double a0,double a1,double a2){return (MFCoef){b0/a0,b1/a0,b2/a0,a1/a0,a2/a0};}
static inline void mf_target(MFBiquad *b,MFCoef t,unsigned ramp){b->t=t;b->ramp=ramp;if(!ramp)b->c=t;}
static inline void mf_biquad_reset(MFBiquad *b){*b=(MFBiquad){.c={1,0,0,0,0},.t={1,0,0,0,0}};}
static inline float mf_biquad(MFBiquad*b,float x){if(b->ramp){float f=1.f/b->ramp; b->c.b0+=(b->t.b0-b->c.b0)*f;b->c.b1+=(b->t.b1-b->c.b1)*f;b->c.b2+=(b->t.b2-b->c.b2)*f;b->c.a1+=(b->t.a1-b->c.a1)*f;b->c.a2+=(b->t.a2-b->c.a2)*f;b->ramp--;}
    float y=b->c.b0*x+b->z1; b->z1=b->c.b1*x-b->c.a1*y+b->z2;b->z2=b->c.b2*x-b->c.a2*y;
    if(!isfinite(y)||!isfinite(b->z1)||!isfinite(b->z2)){b->z1=b->z2=0;return x;}
    if(fabsf(b->z1)<1e-20f)b->z1=0;if(fabsf(b->z2)<1e-20f)b->z2=0;return y;
}
// RBJ shelf and peaking filters with double-precision coefficient design.
static inline MFCoef mf_eqcoef(unsigned i,float db,unsigned sr){if(fabsf(db)<.0001f||mf_freq[i]>=.45f*sr)return mf_identity();double A=pow(10.0,db/40.0),w=2.0*MF_PI*mf_freq[i]/sr,c=cos(w),s=sin(w),q=0.95,al=s/(2*q);
    if(i==0||i==MF_EQ-1){double t=s*sqrt(2*A),ap=A+1,am=A-1;
        if(i==0)return mf_norm(A*(ap-am*c+t),2*A*(am-ap*c),A*(ap-am*c-t),ap+am*c+t,-2*(am+ap*c),ap+am*c-t);
        return mf_norm(A*(ap+am*c+t),-2*A*(am+ap*c),A*(ap+am*c-t),ap-am*c+t,2*(am-ap*c),ap-am*c-t);
    }return mf_norm(1+al*A,-2*c,1-al*A,1+al/A,-2*c,1-al/A);
}
static inline MFCoef mf_lowpass(float cut,float q,unsigned sr){double w=2.0*MF_PI*cut/sr,c=cos(w),al=sin(w)/(2*q);return mf_norm((1-c)*.5,1-c,(1-c)*.5,1+al,-2*c,1-al);}
static inline void mf_reset(MFPitch*s){memset(s,0,sizeof(*s));s->ratio=s->gain=s->limiter=1;s->lastCut=-1;s->eqOn=-1;for(unsigned i=0;i<MF_EQ;i++)mf_biquad_reset(&s->eq[i]);for(unsigned i=0;i<2;i++)mf_biquad_reset(&s->aa[i]);}
static inline void mf_config(MFPitch*s,float ratio,int eqOn,const float bands[MF_EQ],unsigned sr){int first=s->sr!=sr;unsigned ramp=first?0:(unsigned)(.018f*sr);float cut=ratio>1.01f?.44f*sr/ratio:0.f;
    if(first||fabsf(cut-s->lastCut)>5){for(unsigned i=0;i<2;i++)mf_target(&s->aa[i],cut>0?mf_lowpass(cut,i?1.306563f:.541196f,sr):mf_identity(),ramp);s->lastCut=cut;}
    for(unsigned i=0;i<MF_EQ;i++){float db=eqOn?fmaxf(-12,fminf(12,bands[i])):0;if(first||s->eqOn!=eqOn||db!=s->lastEq[i]){mf_target(&s->eq[i],mf_eqcoef(i,db,sr),ramp);s->lastEq[i]=db;}}s->eqOn=eqOn;s->sr=sr;
}
static inline float mf_read(MFPitch*s,float d){d=fmaxf(2,fminf(MF_RING-4,d));unsigned n=(unsigned)d;float f=d-n;float a=s->ring[(s->cursor-n)&MF_MASK],b=s->ring[(s->cursor-n-1)&MF_MASK];return a+(b-a)*f;}
static inline float mf_cubic(MFPitch*s,float d){d=fmaxf(2,fminf(MF_RING-4,d));unsigned n=(unsigned)d;float t=d-n;float a=s->ring[(s->cursor-n+1)&MF_MASK],b=s->ring[(s->cursor-n)&MF_MASK],c=s->ring[(s->cursor-n-1)&MF_MASK],e=s->ring[(s->cursor-n-2)&MF_MASK];return b+.5f*t*(c-a+t*(2*a-5*b+4*c-e+t*(3*(b-c)+e-a)));}
// Align over a short future overlap; old and candidate grains are both within the captured ring.
static inline float mf_align(MFPitch*s,float target,float old,float ratio,unsigned sr){int search=(int)(sr*.008f),step=(int)(sr/6000u);if(step<1)step=1;int span=(int)(sr*.006f);float best=target,score=-2;
    for(int j=-search;j<=search;j+=step){float d=target+j,ab=0,aa=0,bb=0; if(d<4+span*ratio||old<4+span*ratio)continue;
        for(int k=0;k<span;k+=step*2){float a=mf_read(s,old-k*ratio),b=mf_read(s,d-k*ratio);ab+=a*b;aa+=a*a;bb+=b*b;}
        if(aa<1e-7f||bb<1e-7f)continue;float v=ab/sqrtf(aa*bb)-.035f*mf_abs((float)j)/(search+1);if(v>score){score=v;best=d;}}
    return best;
}
static inline float mf_sample(MFPitch*s,float x,float ratio,float gain,float mix,unsigned sr){
    unsigned hop=(unsigned)(.018f*sr);if(!hop)hop=1; if(!isfinite(x))x=0;
    if(!s->filled){s->ratio=ratio;s->gain=gain;s->mix=mix;s->limiter=1;}
    float alpha=1.f/(.010f*sr+1.f);s->ratio+=(ratio-s->ratio)*alpha;s->gain+=(gain-s->gain)*alpha;s->mix+=(mix-s->mix)*alpha;float r=s->ratio;
    s->raw[s->cursor]=x;float bandlimited=x;for(unsigned j=0;j<2;j++)bandlimited=mf_biquad(&s->aa[j],bandlimited);s->ring[s->cursor]=bandlimited;if(s->filled<MF_RING)s->filled++;
    float target=.015f*sr+(r>1?(r-1)*2*hop:0),y=x;
    unsigned need=(unsigned)(.075f*sr); if(s->filled>need&&(fabsf(r-1.f)>.001f||s->fade>.0001f)){
        if(!s->ready){s->delay[0]=s->delay[1]=target;s->age=0;s->ready=1;}
        if(s->age>=hop){s->delay[0]=s->delay[1];s->delay[1]=mf_align(s,target,s->delay[0],r,sr);s->age=0;}
        // Smooth partition-of-unity; no amplitude bulge when grains match.
        float w=(float)s->age/hop;w=w*w*(3-2*w);
        float shifted=mf_cubic(s,s->delay[0])*(1-w)+mf_cubic(s,s->delay[1])*w;
        float f=fabsf(r-1.f)>.001f?1.f:0.f;s->fade+=(f-s->fade)*alpha;
        // Match dry latency when blending, to reduce immediate/delayed double voice. Fully dry remains direct.
        unsigned dry=(unsigned)fminf((float)s->filled-1,target);float raw=s->raw[(s->cursor-dry)&MF_MASK];
        y=x+(raw+(shifted-raw)*s->mix-x)*s->fade*fminf(1.f,s->mix*25.f);
        s->delay[0]+=1-r;s->delay[1]+=1-r;s->age++;
        if(s->fade<.0001f&&f==0){s->fade=0;s->ready=0;}
    }
    s->cursor=(s->cursor+1)&MF_MASK;
    for(unsigned j=0;j<MF_EQ;j++){MFBiquad*b=&s->eq[j];if(s->lastEq[j]!=0||b->ramp||fabsf(b->z1)>1e-12f||fabsf(b->z2)>1e-12f)y=mf_biquad(b,y);}
    y*=s->gain; if(!isfinite(y))y=0;
    // Peak limiter: immediate attack; 60 ms release, stays linear below -0.7 dBFS.
    float peak=fabsf(y),needGain=peak>.92f?.92f/peak:1.f;if(needGain<s->limiter)s->limiter=needGain;else s->limiter+=(needGain-s->limiter)/(sr*.060f+1.f);return mf_clip(y*s->limiter);
}
#endif
