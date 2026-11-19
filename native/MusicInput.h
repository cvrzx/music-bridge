/* Single producer / render consumer. File IO only on worker. */
#include "BridgePacket.h"
#include <stdio.h>
#include <time.h>
#include <pthread.h>
#define MQ 32768u
static pthread_mutex_t musicLock=PTHREAD_MUTEX_INITIALIZER;
static int16_t musicQ[MQ]; static unsigned qr,qw; static double phase;
static _Atomic(unsigned) musicOn,musicPackets,musicMixed;
static _Atomic(float) musicVol=.5f,micVol=1.f;
static uint64_t musicSession,musicSeq;
static uint64_t musicNow(void){struct timespec t;clock_gettime(CLOCK_REALTIME,&t);return (uint64_t)t.tv_sec*1000+t.tv_nsec/1000000;}
static void musicReset(void){pthread_mutex_lock(&musicLock);qr=qw=0;phase=0;pthread_mutex_unlock(&musicLock);musicSession=musicSeq=0;}
static void musicRead(const char *dir){MBPacket p,best;uint64_t now=musicNow();int found=0;
 for(unsigned i=0;i<MB_SLOTS;i++){char path[4096];if(snprintf(path,sizeof(path),"%s/MicFXBridgeTest-v1/slot-%02u.bin",dir,i)>=(int)sizeof(path))continue;FILE*f=fopen(path,"rb");if(!f)continue;size_t n=fread(&p,1,sizeof(p),f);fclose(f);if(n!=sizeof(p)||p.time_ms>now||now-p.time_ms>350||!mb_valid(&p))continue;if(!found||p.time_ms>best.time_ms||(p.time_ms==best.time_ms&&p.seq>best.seq)){best=p;found=1;}}
 if(!found){musicReset();return;} if(best.session==musicSession&&best.seq<=musicSeq)return;
 pthread_mutex_lock(&musicLock);if(best.session!=musicSession||best.seq!=musicSeq+1||qw-qr>MB_FRAMES*3){qr=qw=0;phase=0;}for(unsigned i=0;i<MB_FRAMES;i++)musicQ[qw++&(MQ-1)]=best.pcm[i];pthread_mutex_unlock(&musicLock);musicSession=best.session;musicSeq=best.seq;atomic_fetch_add(&musicPackets,1);
}
static float musicNext(unsigned sr){if(qw-qr<2)return 0;unsigned a=qr&(MQ-1),b=(qr+1)&(MQ-1);float y=(musicQ[a]+(musicQ[b]-musicQ[a])*phase)/32768.f;phase+=48000.0/sr;unsigned advance=(unsigned)phase;phase-=advance;if(advance>qw-qr)advance=qw-qr;qr+=advance;return y;}
