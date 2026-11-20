#ifndef MICFX_MIC_MONITOR_H
#define MICFX_MIC_MONITOR_H
/* Short, opt-in local preview of the final processed microphone PCM.
   Audio callback never allocates, locks, performs file I/O, or plays sound.
   Playback occurs only after capture ends, avoiding live feedback loops. */
#include <stdint.h>
#include <stdatomic.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#define MON_SECONDS 5u
#define MON_CAPACITY (96000u*MON_SECONDS)
static int16_t monPcm[MON_CAPACITY];
/* 0=idle, 1=recording, 2=finalize pending, 3=saved, 4=error. */
static _Atomic(unsigned) monState,monCount,monRate,monCallbacks,monMeterOn;
static _Atomic(float) monRms,monPeak;
static inline float mon_safe(float x){
    if(!isfinite(x))return 0.f;
    return x>1.f?1.f:x< -1.f?-1.f:x;
}
static inline void mon_begin(void){
    atomic_store(&monState,0);
    atomic_store(&monCount,0);
    atomic_store(&monRate,0);
    atomic_store_explicit(&monState,1,memory_order_release);
}
static inline void mon_cancel(void){
    atomic_store(&monState,0);
    atomic_store(&monCount,0);
}
static inline void mon_capture(float x,unsigned rate){
    if(atomic_load_explicit(&monState,memory_order_acquire)!=1)return;
    if(rate<8000||rate>96000){atomic_store(&monState,4);return;}
    unsigned activeRate=atomic_load(&monRate);
    if(!activeRate){atomic_store(&monRate,rate);activeRate=rate;}
    if(activeRate!=rate){atomic_store(&monState,4);return;}
    unsigned index=atomic_load_explicit(&monCount,memory_order_relaxed);
    unsigned target=activeRate*MON_SECONDS;
    if(index>=target||index>=MON_CAPACITY){atomic_store(&monState,2);return;}
    float sample=mon_safe(x);
    monPcm[index]=(int16_t)(sample>=0.f?sample*32767.f:sample*32768.f);
    atomic_store_explicit(&monCount,index+1,memory_order_release);
    if(index+1>=target)atomic_store_explicit(&monState,2,memory_order_release);
}
static inline void mon_meter(float rms,float peak){
    atomic_store(&monRms,mon_safe(rms));
    atomic_store(&monPeak,mon_safe(peak));
    atomic_fetch_add(&monCallbacks,1);
}
static inline void mon_write_u16(FILE*f,uint16_t x){
    unsigned char d[2]={(unsigned char)x,(unsigned char)(x>>8)};
    (void)fwrite(d,1,2,f);
}
static inline void mon_write_u32(FILE*f,uint32_t x){
    unsigned char d[4]={(unsigned char)x,(unsigned char)(x>>8),(unsigned char)(x>>16),(unsigned char)(x>>24)};
    (void)fwrite(d,1,4,f);
}
static inline int mon_write_wav(const char*path){
    if(atomic_load_explicit(&monState,memory_order_acquire)!=2||!path||!*path)return 0;
    unsigned n=atomic_load_explicit(&monCount,memory_order_acquire);
    unsigned rate=atomic_load_explicit(&monRate,memory_order_acquire);
    if(n==0||n>MON_CAPACITY||rate<8000||rate>96000){atomic_store(&monState,4);return 0;}
    FILE*f=fopen(path,"wb");if(!f){atomic_store(&monState,4);return 0;}
    uint32_t bytes=(uint32_t)n*2u;
    fwrite("RIFF",1,4,f);mon_write_u32(f,36u+bytes);
    fwrite("WAVEfmt ",1,8,f);mon_write_u32(f,16);
    mon_write_u16(f,1);mon_write_u16(f,1);
    mon_write_u32(f,rate);mon_write_u32(f,rate*2u);
    mon_write_u16(f,2);mon_write_u16(f,16);
    fwrite("data",1,4,f);mon_write_u32(f,bytes);
    /* Host is little-endian on iOS arm64; samples were stored as signed LE16. */
    size_t done=fwrite(monPcm,2,n,f);
    int ok=done==n&&fflush(f)==0&&ferror(f)==0;
    if(fclose(f)!=0)ok=0;
    atomic_store(&monState,ok?3u:4u);
    if(!ok)remove(path);
    return ok;
}
#endif
