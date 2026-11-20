#include <stdio.h>
#include <math.h>
#include "../native/LoudVoice.h"
static double rms(const float*a,int n){double e=0;for(int i=0;i<n;i++)e+=(double)a[i]*a[i];return sqrt(e/n);}
int main(void){
    MFLoudVoice s; mf_loud_reset(&s);
    float dry[48000],wet[48000],off[48000];double peak=0;
    for(int i=0;i<48000;i++){
        dry[i]=.004f*sinf(6.283185307179586f*220.f*i/48000.f);
        off[i]=mf_loud_sample(&s,dry[i],1.f,0.f,0.f,48000);
    }
    mf_loud_reset(&s);
    for(int i=0;i<48000;i++){
        wet[i]=mf_loud_sample(&s,dry[i],125.8925f,1.f,.45f,48000);
        if(fabsf(wet[i])>peak)peak=fabsf(wet[i]);
    }
    double r0=rms(dry+4800,43200),r1=rms(wet+4800,43200);
    int offpass=1;for(int i=0;i<48000;i++)if(off[i]!=dry[i])offpass=0;
    printf("dry_rms=%.6f loud_rms=%.6f boost=%.1fx peak=%.3f bypass_exact=%d\n",r0,r1,r1/r0,peak,offpass);
    if(r1/r0<6 || peak>.9601 || !offpass)return 1;
    mf_loud_reset(&s);
    for(int i=0;i<48000;i++){
       float v=mf_loud_sample(&s,.9f,125.8925f,1.f,1.f,48000);
       if(!isfinite(v)||fabsf(v)>.961f)return 2;
    }
    return 0;
}
