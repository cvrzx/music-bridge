#ifndef MICFX_LOUDVOICE_H
#define MICFX_LOUDVOICE_H
#include <math.h>
#include <string.h>
/* Original voice dynamics; intentionally independent of music and pitch state. */
typedef struct {
    float envelope;
    float highpass, previous;
} MFLoudVoice;
static inline void mf_loud_reset(MFLoudVoice *s){memset(s,0,sizeof(*s));}
static inline float mf_loud_sample(MFLoudVoice *s,float input,float boost,float amount,float color,unsigned sr){
    if(!isfinite(input))input=0.f;
    if(sr<8000||sr>96000)return input;
    if(amount<=0.f&&color<=0.f)return input;
    if(amount<0.f)amount=0.f;if(amount>1.f)amount=1.f;
    if(color<0.f)color=0.f;if(color>1.f)color=1.f;
    /* Voice Color: smooth 75 Hz rumble cut plus controllable saturation. */
    float hpA=sr/(sr+471.239f);
    s->highpass=hpA*(s->highpass+input-s->previous);
    s->previous=input;
    float x=(input*(1.f-color)+s->highpass*color)*boost;
    float magnitude=fabsf(x);
    float tc=magnitude>s->envelope?.004f:.080f;
    s->envelope+=(magnitude-s->envelope)/(sr*tc+1.f);
    /* Automatic compression controls peaks after strong preamp boost. */
    float gr=1.f;
    if(amount>0.f&&s->envelope>.16f){
        float excess=s->envelope/.16f-1.f;
        gr=1.f/sqrtf(1.f+excess*amount*3.f);
    }
    x*=gr;
    /* Smooth coloration without copying proprietary Equalizer APO plugins. */
    if(color>0.f){
        float drive=1.f+3.f*color;
        float saturated=tanhf(x*drive)/tanhf(drive);
        x=x*(1.f-color)+saturated*color;
    }
    if(!isfinite(x))return 0.f;
    return fmaxf(-.96f,fminf(.96f,x));
}
#endif
