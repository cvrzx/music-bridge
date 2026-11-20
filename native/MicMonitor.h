#ifndef MICFX_MIC_MONITOR_H
#define MICFX_MIC_MONITOR_H
/*
 * Local, opt-in processed microphone monitor.
 * The RemoteIO capture callback writes to a single-producer lock-free PCM ring.
 * AudioQueue plays the ring on its own callback; no disk recording is performed.
 * The queue is created/stopped only on the native settings worker, never on the
 * real-time capture callback. Disabled by default in the plugin.
 */
#include <stdint.h>
#include <stdatomic.h>
#include <math.h>
#include <string.h>
#include <AudioToolbox/AudioToolbox.h>

#define MON_RING_FRAMES 65536u
#define MON_RING_MASK (MON_RING_FRAMES-1u)
#define MON_FRAMES_PER_BUFFER 960u
#define MON_BUFFER_COUNT 3u

static int16_t monRing[MON_RING_FRAMES];
static _Atomic(uint64_t) monWrite,monRead;
static _Atomic(unsigned) monFeedOn,monRunning,monFramesPlayed,monUnderflows;
static _Atomic(float) monRms,monPeak;
static AudioQueueRef monQueue;
static AudioQueueBufferRef monBuffers[MON_BUFFER_COUNT];
static unsigned monQueueRate;
static OSStatus monLastError;

static inline float mon_clip(float x) {
    return !isfinite(x)?0.f:x>1.f?1.f:x< -1.f?-1.f:x;
}
static inline void mon_store_sample(uint64_t index,float x){
    x=mon_clip(x);
    monRing[index&MON_RING_MASK]=(int16_t)(x>=0.f?x*32767.f:x*32768.f);
}
static inline void mon_publish_samples(uint64_t start,unsigned frames){
    atomic_store_explicit(&monWrite,start+frames,memory_order_release);
}
static void mon_audio_callback(void*user,AudioQueueRef q,AudioQueueBufferRef buffer){
    (void)user;
    if(!buffer||!buffer->mAudioData)return;
    int16_t*dst=(int16_t*)buffer->mAudioData;
    uint64_t r=atomic_load_explicit(&monRead,memory_order_relaxed);
    uint64_t w=atomic_load_explicit(&monWrite,memory_order_acquire);
    if(w<r)r=w;
    /* Skip stale samples rather than playing speech with a long delay. */
    unsigned sr=monQueueRate?monQueueRate:48000u;
    uint64_t maxDelay=sr/4u;
    if(w-r>maxDelay)r=w-sr/12u;
    unsigned missing=0;
    for(unsigned i=0;i<MON_FRAMES_PER_BUFFER;i++){
        if(r<w){dst[i]=monRing[r&MON_RING_MASK];r++;}
        else{dst[i]=0;missing++;}
    }
    atomic_store_explicit(&monRead,r,memory_order_release);
    if(missing)atomic_fetch_add(&monUnderflows,1);
    buffer->mAudioDataByteSize=MON_FRAMES_PER_BUFFER*sizeof(int16_t);
    if(atomic_load(&monRunning)){
        atomic_fetch_add(&monFramesPlayed,MON_FRAMES_PER_BUFFER);
        AudioQueueEnqueueBuffer(q,buffer,0,NULL);
    }
}
static void mon_stop(void){
    atomic_store(&monFeedOn,0);
    atomic_store(&monRunning,0);
    if(monQueue){
        AudioQueueStop(monQueue,true);
        AudioQueueDispose(monQueue,true);
        monQueue=NULL;
    }
    memset(monBuffers,0,sizeof(monBuffers));
    monQueueRate=0;
    atomic_store(&monRms,0.f);
    atomic_store(&monPeak,0.f);
    monLastError=noErr;
}
static int mon_start(unsigned sr,float volume){
    if(sr<8000||sr>96000)return 0;
    if(monQueue)mon_stop();
    AudioStreamBasicDescription fmt={0};
    fmt.mSampleRate=sr;
    fmt.mFormatID=kAudioFormatLinearPCM;
    fmt.mFormatFlags=kLinearPCMFormatFlagIsSignedInteger|kLinearPCMFormatFlagIsPacked;
    fmt.mBytesPerPacket=2;
    fmt.mFramesPerPacket=1;
    fmt.mBytesPerFrame=2;
    fmt.mChannelsPerFrame=1;
    fmt.mBitsPerChannel=16;
    OSStatus e=AudioQueueNewOutput(&fmt,mon_audio_callback,NULL,NULL,NULL,0,&monQueue);
    if(e!=noErr||!monQueue){monLastError=e;monQueue=NULL;return 0;}
    monQueueRate=sr;
    atomic_store(&monRead,atomic_load(&monWrite));
    if(volume<0.f)volume=0.f;if(volume>1.f)volume=1.f;
    AudioQueueSetParameter(monQueue,kAudioQueueParam_Volume,volume);
    for(unsigned i=0;i<MON_BUFFER_COUNT;i++){
        e=AudioQueueAllocateBuffer(monQueue,MON_FRAMES_PER_BUFFER*sizeof(int16_t),&monBuffers[i]);
        if(e!=noErr||!monBuffers[i]){monLastError=e;mon_stop();return 0;}
        memset(monBuffers[i]->mAudioData,0,MON_FRAMES_PER_BUFFER*sizeof(int16_t));
        monBuffers[i]->mAudioDataByteSize=MON_FRAMES_PER_BUFFER*sizeof(int16_t);
        e=AudioQueueEnqueueBuffer(monQueue,monBuffers[i],0,NULL);
        if(e!=noErr){monLastError=e;mon_stop();return 0;}
    }
    atomic_store(&monRunning,1);
    e=AudioQueueStart(monQueue,NULL);
    if(e!=noErr){monLastError=e;mon_stop();return 0;}
    atomic_store(&monFeedOn,1);
    monLastError=noErr;
    return 1;
}
static inline void mon_set_volume(float volume){
    if(!monQueue)return;
    if(volume<0.f)volume=0.f;if(volume>1.f)volume=1.f;
    AudioQueueSetParameter(monQueue,kAudioQueueParam_Volume,volume);
}
#endif
