/* Independent Voicemod soundboard PCM reader. File I/O only on worker; render only reads a locked ring. */
#ifndef MICFX_VOICEMOD_INPUT_H
#define MICFX_VOICEMOD_INPUT_H
#include "BridgePacket.h"
#include <stdio.h>
#include <time.h>
#include <pthread.h>
#include <stdatomic.h>
#define VQ 32768u
static pthread_mutex_t vmLock=PTHREAD_MUTEX_INITIALIZER;
static int16_t vmQ[VQ]; static unsigned qr,qw; static double phase;
static _Atomic(unsigned) vmOn,vmPackets,vmMixed;
static _Atomic(float) vmVol=.5f,micVol=1.f;
/* Reader diagnostics: 1=no files, 2=invalid, 3=stale, 4=fresh, 5=accepted new packet. */
static _Atomic(unsigned) vmReadState,vmFileCount,vmInvalidCount,vmStaleCount,vmNewestAge;
static uint64_t vmSession,vmSeq;
static uint64_t vmNow(void){struct timespec t;clock_gettime(CLOCK_REALTIME,&t);return (uint64_t)t.tv_sec*1000+t.tv_nsec/1000000;}
static void vmReset(void){pthread_mutex_lock(&vmLock);qr=qw=0;phase=0;pthread_mutex_unlock(&vmLock);vmSession=vmSeq=0;}
static void vmRead(const char *dir){
 MBPacket p,best;uint64_t now=vmNow();int found=0;
 unsigned files=0,invalid=0,stale=0;
 for(unsigned i=0;i<MB_SLOTS;i++){
  char path[4096];if(snprintf(path,sizeof(path),"%s/MicFXVoicemod-v1/slot-%02u.bin",dir,i)>=(int)sizeof(path))continue;
  FILE*f=fopen(path,"rb");if(!f)continue;files++;
  size_t n=fread(&p,1,sizeof(p),f);fclose(f);
  if(n!=sizeof(p)){invalid++;continue;}
  /* Files can be delayed while switching apps; never accept very old audio. */
  if(p.time_ms>now||now-p.time_ms>1200){stale++;continue;}
  if(!mb_valid(&p)){invalid++;continue;}
  if(!found||p.time_ms>best.time_ms||(p.time_ms==best.time_ms&&p.seq>best.seq)){best=p;found=1;}
 }
 atomic_store(&vmFileCount,files);
 atomic_store(&vmInvalidCount,invalid);
 atomic_store(&vmStaleCount,stale);
 if(!found){
  atomic_store(&vmReadState,files==0?1:stale?3:2);
  atomic_store(&vmNewestAge,0);
  vmReset();return;
 }
 atomic_store(&vmNewestAge,(unsigned)(now-best.time_ms));
 if(best.session==vmSession&&best.seq<=vmSeq){atomic_store(&vmReadState,4);return;}
 pthread_mutex_lock(&vmLock);
 if(best.session!=vmSession||best.seq!=vmSeq+1||qw-qr>MB_FRAMES*3){qr=qw=0;phase=0;}
 for(unsigned i=0;i<MB_FRAMES;i++)vmQ[qw++&(VQ-1)]=best.pcm[i];
 pthread_mutex_unlock(&vmLock);
 vmSession=best.session;vmSeq=best.seq;
 atomic_fetch_add(&vmPackets,1);atomic_store(&vmReadState,5);
}
/* Probe candidate authorized App Group containers without altering playback state.
   Called only by the reader worker once per second. */
static uint64_t vmLatestPacketTime(const char *dir){
  if(!dir||!*dir)return 0;
  uint64_t now=vmNow(),latest=0;
  MBPacket packet;
  for(unsigned i=0;i<MB_SLOTS;i++){
    char path[4096];
    if(snprintf(path,sizeof(path),"%s/MicFXVoicemod-v1/slot-%02u.bin",dir,i)>=(int)sizeof(path))continue;
    FILE *f=fopen(path,"rb");if(!f)continue;
    size_t n=fread(&packet,1,sizeof(packet),f);fclose(f);
    if(n!=sizeof(packet)||!mb_valid(&packet))continue;
    if(packet.time_ms>now||now-packet.time_ms>1500)continue;
    if(packet.time_ms>latest)latest=packet.time_ms;
  }
  return latest;
}
/* Once per 500 ms, choose the authorized App Group with fresh soundboard packets. */
static uint64_t vmLatestPacketTime(const char *dir){
  if(!dir||!*dir)return 0;
  uint64_t now=vmNow(),latest=0;
  MBPacket p;
  for(unsigned i=0;i<MB_SLOTS;i++){
    char path[4096];
    if(snprintf(path,sizeof(path),"%s/MicFXVoicemod-v1/slot-%02u.bin",dir,i)>=(int)sizeof(path))continue;
    FILE *f=fopen(path,"rb");if(!f)continue;
    size_t n=fread(&p,1,sizeof(p),f);fclose(f);
    if(n!=sizeof(p)||!mb_valid(&p)||p.time_ms>now||now-p.time_ms>1500)continue;
    if(p.time_ms>latest)latest=p.time_ms;
  }
  return latest;
}
static float vmNext(unsigned sr){
 if(qw-qr<2)return 0;
 unsigned a=qr&(VQ-1),b=(qr+1)&(VQ-1);
 float y=(vmQ[a]+(vmQ[b]-vmQ[a])*phase)/32768.f;
 phase+=48000.0/sr;unsigned advance=(unsigned)phase;phase-=advance;
 if(advance>qw-qr)advance=qw-qr;qr+=advance;return y;
}
#endif
