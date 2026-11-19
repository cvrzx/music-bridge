#ifndef BRIDGE_PACKET_H
#define BRIDGE_PACKET_H
#include <stdint.h>
#include <stddef.h>
#include <math.h>
#define MB_RATE 48000
#define MB_FRAMES 4800
#define MB_MAGIC 0x3142584du
#define MB_SLOTS 16
// Little-endian ARM64, signed 16-bit PCM, 100 ms of mono audio.
typedef struct { uint32_t magic, frames; uint64_t session, seq, time_ms; uint32_t checksum, reserved; int16_t pcm[MB_FRAMES]; } MBPacket;
_Static_assert(offsetof(MBPacket,pcm)==40,"packet header");
_Static_assert(sizeof(MBPacket)==9640,"packet size");
static inline uint32_t mb_hash(const int16_t *a){uint32_t h=2166136261u; for(size_t i=0;i<MB_FRAMES;i++){uint16_t v=(uint16_t)a[i]; h=(h^(v&255))*16777619u; h=(h^(v>>8))*16777619u;}return h;}
static inline void mb_fill(MBPacket *p,uint64_t session,uint64_t seq,uint64_t t){p->magic=MB_MAGIC;p->frames=MB_FRAMES;p->session=session;p->seq=seq;p->time_ms=t;p->reserved=0;for(size_t i=0;i<MB_FRAMES;i++)p->pcm[i]=(int16_t)lrint(4000*sin(6.283185307179586*440.0*i/MB_RATE));p->checksum=mb_hash(p->pcm);}
static inline int mb_valid(const MBPacket *p){return p->magic==MB_MAGIC && p->frames==MB_FRAMES && p->session && p->seq && p->checksum==mb_hash(p->pcm);}
#endif
