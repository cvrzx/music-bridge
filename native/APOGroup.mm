// Optional Equalizer APO iOS App Group control bridge for the EXISTING MicFX v4
// native processor. Never replaces the legacy pitch, EQ, gains or music settings.
// Original APO settings JSON: micfx-control-v1.json.
// A producer (NOT the stock Spotify app) may send 48 kHz stereo PCM packets.
// All file IO is on a utility worker; the audio callback only reads atomics/ring.
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#include "APOGroup.h"
#include <atomic>
#include <cmath>
#include <algorithm>
#include <cstdint>
#include <cstring>
#include <unistd.h>

static constexpr const char* GROUP_ID = "group.f172ad8c5e5f97bc.1";
static constexpr uint32_t MAGIC=0x3258464dU, SLOTS=16, FRAMES=960, RING=16384;
struct Packet {
 uint32_t magic, frames, rate, channels;
 uint64_t session, sequence, timestampMs;
 uint32_t checksum, reserved;
 int16_t pcm[FRAMES*2];
};
static_assert(sizeof(Packet)==3888,"Stereo transport ABI mismatch");

static std::atomic<unsigned> settingsUpdates{0}, musicUpdates{0},readState{0},workerTicks{0};
static std::atomic<int> enabled{0},muteMic{0},filterType{0};
static std::atomic<float> preampDb{0},musicDb{-12},micLeft{1},micRight{1},
                          frequency{1000},filterGain{0},quality{1};
static std::atomic<uint32_t> revision{0};
static float ring[RING][2]={};
static std::atomic<uint32_t> readIndex{0},writeIndex{0};
static uint64_t lastSession=0,lastSequence=0;

struct RtBiquad {
 float b0=1,b1=0,b2=0,a1=0,a2=0,z1=0,z2=0;
};
static RtBiquad dsp;
static uint32_t dspRevision=0;
static bool dspEnabled=false,dspMuted=false;
static float dspLevel=1;
static unsigned dspRate=0;
static int dspType=0;

static double numeric(id x,double lo,double hi,double fallback) {
 if(![x isKindOfClass:[NSNumber class]])return fallback;
 double v=[(NSNumber*)x doubleValue];
 return std::isfinite(v)&&v>=lo&&v<=hi?v:fallback;
}
static int typeFrom(NSString* type) {
 if(![type isKindOfClass:[NSString class]])return 0;
 NSArray<NSString*>* names=@[@"PK",@"LPQ",@"HPQ",@"BP",@"LS",@"HS",@"NO",@"AP"];
 NSUInteger idx=[names indexOfObject:type];
 return idx==NSNotFound?0:static_cast<int>(idx)+1;
}
static uint32_t checksum(const int16_t* data) {
 uint32_t value=2166136261u;
 for(unsigned i=0;i<FRAMES*2;i++){
  const uint16_t x=static_cast<uint16_t>(data[i]);
  value=(value^(x&255))*16777619u;
  value=(value^(x>>8))*16777619u;
 }
 return value;
}
static bool validPacket(const Packet& p,uint64_t now) {
 return p.magic==MAGIC&&p.frames==FRAMES&&p.rate==48000&&p.channels==2&&
        p.session&&p.sequence&&p.timestampMs<=now&&now-p.timestampMs<=350&&
        p.checksum==checksum(p.pcm);
}
static void pushPacket(const Packet& p) {
 if(p.session!=lastSession){lastSession=p.session;lastSequence=0;}
 if(p.sequence<=lastSequence)return;
 lastSequence=p.sequence;
 uint32_t w=writeIndex.load(std::memory_order_relaxed);
 uint32_t r=readIndex.load(std::memory_order_acquire);
 if(w-r>RING-FRAMES-1)return; // never overwrite the render thread
 for(unsigned i=0;i<FRAMES;i++){
  const uint32_t slot=(w+i)&(RING-1);
  ring[slot][0]=static_cast<float>(p.pcm[2*i])/32768.f;
  ring[slot][1]=static_cast<float>(p.pcm[2*i+1])/32768.f;
 }
 writeIndex.store(w+FRAMES,std::memory_order_release);
 musicUpdates.fetch_add(1,std::memory_order_relaxed);
}
static void updateSettings(NSURL* root) {
 NSURL* file=[root URLByAppendingPathComponent:@"micfx-control-v1.json"];
 NSData* raw=[NSData dataWithContentsOfURL:file options:0 error:nil];
 if(!raw){readState.store(2,std::memory_order_relaxed);return;}
 if(raw.length>65536){readState.store(3,std::memory_order_relaxed);return;}
 id parsed=[NSJSONSerialization JSONObjectWithData:raw options:0 error:nil];
 if(![parsed isKindOfClass:[NSDictionary class]]){readState.store(3,std::memory_order_relaxed);return;}
 NSDictionary* data=(NSDictionary*)parsed;
 if(![data[@"schema"] isEqual:@1]){readState.store(3,std::memory_order_relaxed);return;}
 NSDictionary* mic=data[@"mic"],*mus=data[@"music"];
 if(![mic isKindOfClass:[NSDictionary class]]||![mus isKindOfClass:[NSDictionary class]]){readState.store(3,std::memory_order_relaxed);return;}
 readState.store(4,std::memory_order_release);
 bool nextEnabled=[mic[@"enabled"] respondsToSelector:@selector(boolValue)]&&[mic[@"enabled"] boolValue];
 bool nextMute=[mic[@"mute"] respondsToSelector:@selector(boolValue)]&&[mic[@"mute"] boolValue];
 const float nextDb=static_cast<float>(numeric(mic[@"gainDb"],-240,240,0));
 const float nextMusic=static_cast<float>(numeric(mus[@"gainDb"],-240,240,-12));
 const float nextLeft=static_cast<float>(numeric(mic[@"left"],0,2,1));
 const float nextRight=static_cast<float>(numeric(mic[@"right"],0,2,1));
 NSDictionary* eq=data[@"eq"];
 NSArray* filters=[eq isKindOfClass:NSDictionary.class]?eq[@"filters"]:nil;
 NSDictionary* first=[filters isKindOfClass:NSArray.class]&&filters.count>0&&[filters[0] isKindOfClass:NSDictionary.class]?filters[0]:nil;
 const int t=first?typeFrom(first[@"type"]):0;
 const float freq=static_cast<float>(numeric(first[@"freqHz"],20,20000,1000));
 const float gain=static_cast<float>(numeric(first[@"gainDb"],-36,36,0));
 const float q=static_cast<float>(numeric(first[@"q"],.0001,1000,1));
 if(enabled.load()==nextEnabled&&muteMic.load()==nextMute&&preampDb.load()==nextDb&&
    musicDb.load()==nextMusic&&micLeft.load()==nextLeft&&micRight.load()==nextRight&&
    filterType.load()==t&&frequency.load()==freq&&filterGain.load()==gain&&quality.load()==q)return;
 preampDb.store(nextDb);musicDb.store(nextMusic);
 micLeft.store(nextLeft);micRight.store(nextRight);
 muteMic.store(nextMute);filterType.store(t);
 frequency.store(freq);filterGain.store(gain);quality.store(q);
 enabled.store(nextEnabled);
 revision.fetch_add(1,std::memory_order_release);
 settingsUpdates.fetch_add(1,std::memory_order_relaxed);
}
static void updateMusic(NSURL* root) {
 Packet packets[SLOTS];unsigned count=0;
 uint64_t now=static_cast<uint64_t>(NSDate.date.timeIntervalSince1970*1000);
 for(unsigned slot=0;slot<SLOTS;slot++){
  NSURL* path=[root URLByAppendingPathComponent:
              [NSString stringWithFormat:@"stereo-slot-%02u.bin",slot]];
  NSData* raw=[NSData dataWithContentsOfURL:path options:0 error:nil];
  if(raw.length!=sizeof(Packet))continue;
  Packet p;std::memcpy(&p,raw.bytes,sizeof(p));
  if(validPacket(p,now))packets[count++]=p;
 }
 std::sort(packets,packets+count,[](const Packet& a,const Packet& b){
  return a.timestampMs==b.timestampMs?a.sequence<b.sequence:a.timestampMs<b.timestampMs;
 });
 for(unsigned i=0;i<count;i++)pushPacket(packets[i]);
}
static void worker(void) {
 for(;;){
  @autoreleasepool{
   NSURL* root=[[NSFileManager defaultManager]
                containerURLForSecurityApplicationGroupIdentifier:
                [NSString stringWithUTF8String:GROUP_ID]];
   if(root){
    updateSettings(root);
    if(enabled.load(std::memory_order_relaxed))updateMusic(root);
   }else readState.store(1,std::memory_order_relaxed);
   workerTicks.fetch_add(1,std::memory_order_relaxed);
  }
  usleep(25000);
 }
}
extern "C" void mf_apo_start(void) {
 static dispatch_once_t once;
 dispatch_once(&once,^{
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{worker();});
 });
}
extern "C" int mf_apo_active(void) {
 return enabled.load(std::memory_order_relaxed);
}
extern "C" unsigned mf_apo_settings_updates(void) {
 return settingsUpdates.load(std::memory_order_relaxed);
}
extern "C" unsigned mf_apo_music_packets(void) {
 return musicUpdates.load(std::memory_order_relaxed);
}
extern "C" unsigned mf_apo_read_state(void) {
 return readState.load(std::memory_order_acquire);
}
extern "C" unsigned mf_apo_worker_ticks(void) {
 return workerTicks.load(std::memory_order_relaxed);
}
extern "C" float mf_apo_music_gain(void) {
 return std::pow(10.f,musicDb.load(std::memory_order_relaxed)/20.f);
}
extern "C" void mf_apo_prepare(unsigned sr) {
 uint32_t next=revision.load(std::memory_order_acquire);
 if(next==dspRevision&&sr==dspRate)return;
 dspRevision=next;dspRate=sr;
 dspEnabled=enabled.load(std::memory_order_relaxed);
 dspMuted=muteMic.load(std::memory_order_relaxed);
 // The outgoing AudioUnit is mono. A one-sided mic route is halved in mono.
 float l=micLeft.load(std::memory_order_relaxed),r=micRight.load(std::memory_order_relaxed);
 float db=preampDb.load(std::memory_order_relaxed);
 dspLevel=std::pow(10.f,db/20.f)*.5f*(l+r);
 dspType=filterType.load(std::memory_order_relaxed);
 dsp=RtBiquad();
 if(!dspEnabled||!dspType||sr<8000||sr>96000)return;
 float fc=frequency.load(std::memory_order_relaxed);
 if(fc<=0||fc>=.49f*sr)return;
 float Q=quality.load(std::memory_order_relaxed);
 if(Q<=0)return;
 float gain=filterGain.load(std::memory_order_relaxed);
 const float pi=3.14159265358979323846f,w=2*pi*fc/sr,c=cosf(w),ss=sinf(w);
 const float a=ss/(2*Q),A=powf(10.f,gain/40.f);
 float b0=1,b1=0,b2=0,a0=1,a1=0,a2=0;
 switch(dspType){
 case 1: b0=1+a*A;b1=-2*c;b2=1-a*A;a0=1+a/A;a1=-2*c;a2=1-a/A;break; // PK
 case 2: b0=(1-c)/2;b1=1-c;b2=(1-c)/2;a0=1+a;a1=-2*c;a2=1-a;break; // LPQ
 case 3: b0=(1+c)/2;b1=-(1+c);b2=(1+c)/2;a0=1+a;a1=-2*c;a2=1-a;break; // HPQ
 case 4: b0=a;b1=0;b2=-a;a0=1+a;a1=-2*c;a2=1-a;break; // BP
 case 5:{float t=2*sqrtf(A)*a;b0=A*((A+1)-(A-1)*c+t);b1=2*A*((A-1)-(A+1)*c);b2=A*((A+1)-(A-1)*c-t);a0=(A+1)+(A-1)*c+t;a1=-2*((A-1)+(A+1)*c);a2=(A+1)+(A-1)*c-t;break;}
 case 6:{float t=2*sqrtf(A)*a;b0=A*((A+1)+(A-1)*c+t);b1=-2*A*((A-1)+(A+1)*c);b2=A*((A+1)+(A-1)*c-t);a0=(A+1)-(A-1)*c+t;a1=2*((A-1)-(A+1)*c);a2=(A+1)-(A-1)*c-t;break;}
 case 7: b0=1;b1=-2*c;b2=1;a0=1+a;a1=-2*c;a2=1-a;break; // NO
 case 8: b0=1-a;b1=-2*c;b2=1+a;a0=1+a;a1=-2*c;a2=1-a;break; // AP
 default:return;
 }
 if(std::fabs(a0)<1e-8f||!std::isfinite(a0))return;
 dsp.b0=b0/a0;dsp.b1=b1/a0;dsp.b2=b2/a0;dsp.a1=a1/a0;dsp.a2=a2/a0;
}
extern "C" float mf_apo_sample(float x) {
 if(!dspEnabled)return x;
 if(dspMuted)return 0;
 float v=x;
 if(dspType&&dspRate){
  float y=dsp.b0*v+dsp.z1;
  dsp.z1=dsp.b1*v-dsp.a1*y+dsp.z2;
  dsp.z2=dsp.b2*v-dsp.a2*y;
  v=y;
 }
 v*=dspLevel;
 // bounded soft limiter: prevents mic clipping at positive dB levels
 return std::isfinite(v)?std::tanh(v):0;
}
extern "C" int mf_apo_music_next(unsigned sr,float* left,float* right) {
 if(left)*left=0;if(right)*right=0;
 if(!enabled.load(std::memory_order_relaxed)||sr!=48000||!left||!right)return 0;
 const uint32_t r=readIndex.load(std::memory_order_relaxed);
 const uint32_t w=writeIndex.load(std::memory_order_acquire);
 if(w==r)return 0;
 *left=ring[r&(RING-1)][0];*right=ring[r&(RING-1)][1];
 readIndex.store(r+1,std::memory_order_release);
 return 1;
}
