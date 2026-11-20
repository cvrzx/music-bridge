// iOS arm64 native experiment. No audio is recorded, retained beyond the DSP ring, or transmitted separately.
#include <stdint.h>
#include <stddef.h>
#include <stdatomic.h>
#include "pitch.h"
#include "MusicInput.h"
#include <unistd.h>
typedef void *AU; typedef int32_t OSStatus; typedef uint32_t U32;
typedef struct { U32 channels, bytes; void *data; } Buffer;
typedef struct { U32 count; Buffer buffers[1]; } Buffers;
typedef struct { double rate; U32 format,flags,bytesPacket,framesPacket,bytesFrame,channels,bits,reserved; } ASBD;
typedef struct { U32 type,subtype,manufacturer,flags,mask; } ComponentDesc;
typedef struct { U32 magic,cpu,sub,filetype,ncmds,sizeofcmds,flags,reserved; } MachHeader;
extern const MachHeader *_dyld_get_image_header(U32);
extern intptr_t _dyld_get_image_vmaddr_slide(U32);
extern void *dlsym(void *,const char *); extern int getpagesize(void);
extern unsigned int mach_task_self_; extern int mach_vm_protect(unsigned int,uint64_t,uint64_t,int,int);

extern float powf(float,float);
#define SYM(n) dlsym((void *)(intptr_t)-2,n)
#define FOUR(a,b,c,d) (((U32)(a)<<24)|((U32)(b)<<16)|((U32)(c)<<8)|(U32)(d))
static OSStatus (*origRender)(AU,U32*,const void*,U32,U32,Buffers*);
static OSStatus (*origInit)(AU),(*origUninit)(AU),(*origDispose)(AU);
static OSStatus (*getProp)(AU,U32,U32,U32,void*,U32*);
static void *(*getComp)(AU); static OSStatus (*getDesc)(void*,ComponentDesc*);
static _Atomic(uintptr_t) capture;
static _Atomic(U32) sampleRate,formatKind,generation,processed,enabled;
static _Atomic(float) ratio=1.f,gain=1.f,blend=1.f,eqGain[MF_EQ];
static _Atomic(U32) eqEnabled,configSeq;
static const char *eqKeys[MF_EQ]={"MicFXEQ0","MicFXEQ1","MicFXEQ2","MicFXEQ3","MicFXEQ4","MicFXEQ5","MicFXEQ6","MicFXEQ7"};
static float dspRatio=1.f,dspGain=1.f,dspMix=1.f,dspBands[MF_EQ];static U32 dspEq;
static atomic_flag renderBusy=ATOMIC_FLAG_INIT;
static MFPitch dsp; static U32 dspGeneration; static const char *bootStatus="Native bridge not initialized";
static void clearCapture(AU u) { uintptr_t expected=(uintptr_t)u; if(atomic_compare_exchange_strong(&capture,&expected,0)) atomic_fetch_add(&generation,1); }
static OSStatus initHook(AU u) {
    OSStatus r=origInit(u); if(r)return r;
    ComponentDesc d={0}; ASBD f={0}; U32 size=sizeof(f); void *c=getComp(u);
    if(!c||getDesc(c,&d)||d.type!=FOUR('a','u','o','u')||d.manufacturer!=FOUR('a','p','p','l')||(d.subtype!=FOUR('r','i','o','c')&&d.subtype!=FOUR('v','p','i','o')))return r;
    clearCapture(u);
    if(getProp(u,8,2,1,&f,&size)||size!=sizeof(f)||f.format!=FOUR('l','p','c','m')||f.channels!=1||f.rate<8000||f.rate>96000||f.framesPacket!=1||(f.flags&2u)||!(f.flags&8u))return r;
    U32 kind=0;if(f.bits==16&&f.bytesFrame==2&&(f.flags&4u)&&!(f.flags&1u))kind=1;else if(f.bits==32&&f.bytesFrame==4&&(f.flags&1u))kind=2;
    if(!kind)return r;
    atomic_store(&capture,0); atomic_store(&sampleRate,(U32)f.rate);atomic_store(&formatKind,kind);atomic_fetch_add(&generation,1);atomic_store(&capture,(uintptr_t)u);return r;
}
static OSStatus uninitHook(AU u){clearCapture(u);return origUninit(u);}
static OSStatus disposeHook(AU u){clearCapture(u);return origDispose(u);}
static OSStatus renderHook(AU u,U32 *flags,const void *ts,U32 bus,U32 n,Buffers *b){
    OSStatus r=origRender(u,flags,ts,bus,n,b); if(r||bus!=1||(!atomic_load(&enabled)&&!atomic_load(&musicOn))||atomic_load(&capture)!=(uintptr_t)u||!b||b->count!=1||!n||n>4096||!b->buffers[0].data||b->buffers[0].channels!=1)return r;
    U32 fmt=atomic_load(&formatKind),sr=atomic_load(&sampleRate),gen=atomic_load(&generation); if((fmt!=1&&fmt!=2)||sr<8000||sr>96000||b->buffers[0].bytes<n*(fmt==1?2u:4u))return r;
    if(atomic_flag_test_and_set(&renderBusy))return r;
    if(atomic_load(&capture)==(uintptr_t)u&&atomic_load(&generation)==gen){
        if(dspGeneration!=gen){mf_reset(&dsp);dspGeneration=gen;}
        // Coherent snapshot without blocking the real-time thread. If a writer is active, retain prior settings.
        U32 seq=atomic_load(&configSeq);if(!(seq&1u)){float p=atomic_load(&ratio),g=atomic_load(&gain),m=atomic_load(&blend),bands[MF_EQ];U32 e=atomic_load(&eqEnabled);for(unsigned i=0;i<MF_EQ;i++)bands[i]=atomic_load(&eqGain[i]);if(seq==atomic_load(&configSeq)){dspRatio=p;dspGain=g;dspMix=m;dspEq=e;for(unsigned i=0;i<MF_EQ;i++)dspBands[i]=bands[i];}}
        float p=dspRatio,g=dspGain,m=dspMix;mf_config(&dsp,p,dspEq,dspBands,sr);
        int fx=atomic_load(&enabled), mus=atomic_load(&musicOn);int locked=mus&&pthread_mutex_trylock(&musicLock)==0;float mv=atomic_load(&musicVol),iv=atomic_load(&micVol);
        int silent=flags&&(*flags&16u);int audible=0;
        if(!silent||mus)for(U32 i=0;i<n;i++){float x=silent?0:fmt==1?((int16_t*)b->buffers[0].data)[i]/32768.f:((float*)b->buffers[0].data)[i];float y=fx?mf_sample(&dsp,x,p,g,m,sr):x;if(mus){float z=locked?musicNext(sr):0;y=mf_clip(y*iv+z*mv);if(z!=0)audible=1;}if(fmt==1)((int16_t*)b->buffers[0].data)[i]=(int16_t)(y>=0?y*32767.f:y*32768.f);else ((float*)b->buffers[0].data)[i]=y;}
        if(locked)pthread_mutex_unlock(&musicLock);if(audible){if(flags)*flags&=~16u;atomic_fetch_add(&musicMixed,1);}
        atomic_fetch_add(&processed,1);
    }atomic_flag_clear(&renderBusy);return r;
}
// Exact-build GOT slots verified against the submitted IPA indirect symbol table.
static int match(const MachHeader *h){
    static const unsigned char uuid[]={0xc7,0x69,0x35,0x51,0xf7,0xaa,0x39,0x9a,0x9d,0x24,0x41,0x01,0x4f,0x85,0xf9,0xb8};
    if(!h||h->magic!=0xfeedfacf||h->cpu!=0x0100000c||h->sizeofcmds>65536)return 0;
    const unsigned char *p=(const unsigned char *)(h+1),*end=p+h->sizeofcmds;
    for(U32 i=0;i<h->ncmds&&p+8<=end;i++){const U32 *c=(const U32 *)p;if(c[1]<8||c[1]>(size_t)(end-p))return 0;if(c[0]==0x1b&&c[1]>=24){for(int j=0;j<16;j++)if(p[8+j]!=uuid[j])return 0;return 1;}p+=c[1];}return 0;
}
static int install(void){
    const MachHeader *h=_dyld_get_image_header(0);if(!match(h)){bootStatus="Unsupported Discord executable UUID; no hooks installed";return 0;}
    intptr_t slide=_dyld_get_image_vmaddr_slide(0);
    void **slots[]={ (void**)(slide+0x102ccdad0ull),(void**)(slide+0x102ccdad8ull),(void**)(slide+0x102ccdae8ull),(void**)(slide+0x102ccda88ull) };
    void *expected[]={SYM("AudioUnitInitialize"),SYM("AudioUnitRender"),SYM("AudioUnitUninitialize"),SYM("AudioComponentInstanceDispose")};
    void *replacement[]={initHook,renderHook,uninitHook,disposeHook};
    getProp=SYM("AudioUnitGetProperty");getComp=SYM("AudioComponentInstanceGetComponent");getDesc=SYM("AudioComponentGetDescription");
    if(!getProp||!getComp||!getDesc){bootStatus="Audio format inspection unavailable; no hooks installed";return 0;}
    for(int i=0;i<4;i++)if(!expected[i]||*slots[i]!=expected[i]){bootStatus="Unexpected audio import pointers; no hooks installed";return 0;}
    origInit=expected[0];origRender=expected[1];origUninit=expected[2];origDispose=expected[3];
    uint64_t pageSize=(uint64_t)getpagesize(); if(!pageSize||(pageSize&(pageSize-1))){bootStatus="Unexpected page size";return 0;}
    uint64_t page=(uintptr_t)slots[0]&~(pageSize-1);for(int i=1;i<4;i++)if(((uintptr_t)slots[i]&~(pageSize-1))!=page){bootStatus="Audio import slots not on one page";return 0;}
    if(mach_vm_protect(mach_task_self_,page,pageSize,0,1|2|16)){bootStatus="iOS denied import rebinding; no hooks installed";return 0;}
    for(int i=0;i<4;i++)__atomic_store_n(slots[i],replacement[i],__ATOMIC_RELEASE);
    int protect=mach_vm_protect(mach_task_self_,page,pageSize,0,1);
    if(protect){for(int i=0;i<4;i++)__atomic_store_n(slots[i],expected[i],__ATOMIC_RELEASE);mach_vm_protect(mach_task_self_,page,pageSize,0,1);bootStatus="Page protection restore failed; hooks rolled back";return 0;}
    bootStatus="Native hooks installed; waiting for supported microphone initialization";return 1;
}
// Use NSUserDefaults via the ObjC runtime for RN Settings bridge; no private audio data crosses it.
static void *(*getClass)(const char*),*(*sel)(const char*);static void *msg;
static void *(*poolPush)(void);static void (*poolPop)(void*);
static void *str(const char *c){return ((void*(*)(void*,void*,const char*))msg)(getClass("NSString"),sel("stringWithUTF8String:"),c);}
static double getNum(void *defaults,const char *key){return ((double(*)(void*,void*,void*))msg)(defaults,sel("doubleForKey:"),str(key));}
static void put(void *defaults,const char *key,const char *val){((void(*)(void*,void*,void*,void*))msg)(defaults,sel("setObject:forKey:"),str(val),str(key));}
static void putNum(void *defaults,const char *key,double val){((void(*)(void*,void*,double,void*))msg)(defaults,sel("setDouble:forKey:"),val,str(key));}

// Opt-in: preserve Discord's chosen call category and mode, adding only the public
// AVAudioSessionCategoryOptionMixWithOthers bit (1). This can help other playback
// sessions coexist, but iOS may still interrupt Spotify or change routing.
// No audio buffers are accessed or recorded by this hook.
typedef signed char MBObjCBool;
static _Atomic(U32) callMixRequested;
static int callMixHooked;
static MBObjCBool (*origSessionCategory)(void*,void*,void*,void*,unsigned long,void**);
static MBObjCBool sessionCategoryHook(void *receiver,void *cmd,void *category,void *mode,unsigned long options,void **error){
    if(atomic_load(&callMixRequested)&&category){
        void *playRecord=str("AVAudioSessionCategoryPlayAndRecord");
        if(((MBObjCBool(*)(void*,void*,void*))msg)(category,sel("isEqualToString:"),playRecord))options|=1ul;
    }
    return origSessionCategory(receiver,cmd,category,mode,options,error);
}
static int installCallMixHook(void){
    void *cls=getClass("AVAudioSession");
    if(!cls)return 0;
    void *(*classMethod)(void*,void*)=SYM("class_getInstanceMethod");
    void *(*getIMP)(void*)=SYM("method_getImplementation");
    void *(*setIMP)(void*,void*)=SYM("method_setImplementation");
    if(!classMethod||!getIMP||!setIMP)return 0;
    void *method=classMethod(cls,sel("setCategory:mode:options:error:"));
    if(!method)return 0;
    void *original=getIMP(method);
    if(!original||original==(void*)sessionCategoryHook)return 0;
    origSessionCategory=original;
    setIMP(method,(void*)sessionCategoryHook);
    return 1;
}
static float limit(double v,float lo,float hi){return !(v>=lo)?lo:v>hi?hi:(float)v;}
static void *poll(void *arg){int hooked=(int)(intptr_t)arg;const char *last=0;U32 prev=0;int activeLast=0;double lastRequest=-1; int lastOn=-1; U32 lastCapture=0; int hold=0;int lastMix=-1;
    for(;;){void *pool=poolPush();void *d=((void*(*)(void*,void*))msg)(getClass("NSUserDefaults"),sel("standardUserDefaults"));
        int on=hooked&&getNum(d,"MicFXPitchEnabled")==1.0;float p=limit(getNum(d,"MicFXPitchSemitones"),-12,12),dt=limit(getNum(d,"MicFXPitchDetune"),-100,100),g=limit(getNum(d,"MicFXPitchGain"),-12,12),m=limit(getNum(d,"MicFXPitchBlend"),0,100);
        atomic_fetch_add(&configSeq,1);atomic_store(&ratio,powf(2.f,(p+dt/100.f)/12.f));atomic_store(&gain,powf(10.f,g/20.f));atomic_store(&blend,m/100.f);
        atomic_store(&eqEnabled,getNum(d,"MicFXEQEnabled")==1.0);for(unsigned i=0;i<MF_EQ;i++)atomic_store(&eqGain[i],limit(getNum(d,eqKeys[i]),-12,12));atomic_fetch_add(&configSeq,1);
        int wantMix=hooked&&callMixHooked&&getNum(d,"MicFXMusicCallMix")==1.0;
        atomic_store(&callMixRequested,wantMix);
        if(wantMix!=lastMix){put(d,"MicFXCallMixStatus",!hooked?"Unavailable: MicFX audio hook not installed":!callMixHooked?"Unavailable: iOS session API not found":wantMix?"Mix With Others requested for future Discord PlayAndRecord category changes; unverified":"Off; future Discord category calls unchanged");lastMix=wantMix;}
        if(on!=activeLast){atomic_fetch_add(&generation,1);activeLast=on;}
        atomic_store(&enabled,on);U32 now=atomic_load(&processed);const char *status=bootStatus;
        if(now!=prev)hold=25;else if(hold>0)hold--;
        U32 cap=atomic_load(&capture)!=0; double request=getNum(d,"MicFXRequestID");
        if(hooked){if(!cap)status="Hooks installed; ready for supported mono microphone";else if(!on)status="Microphone detected; processor disabled";else if(hold)status="Native processor active (microphone buffers processed)";else status="Pitch enabled; waiting for microphone buffers";}
        if(request!=lastRequest||on!=lastOn||cap!=lastCapture){putNum(d,"MicFXNativeVersion",4);putNum(d,"MicFXNativeHooked",hooked);putNum(d,"MicFXNativeOn",on);putNum(d,"MicFXNativeRate",cap?atomic_load(&sampleRate):0);putNum(d,"MicFXNativeAck",request);lastRequest=request;lastOn=on;lastCapture=cap;}
        if(status!=last){put(d,"MicFXPitchStatus",status);last=status;}prev=now;int mo=hooked&&getNum(d,"MicFXMusicEnabled")==1;atomic_store(&musicVol,limit(getNum(d,"MicFXMusicVolume"),0,100)/100);atomic_store(&micVol,limit(getNum(d,"MicFXMicVolume"),0,100)/100);atomic_store(&musicOn,mo);if(mo){void *fm=((void*(*)(void*,void*))msg)(getClass("NSFileManager"),sel("defaultManager"));void *url=((void*(*)(void*,void*,void*))msg)(fm,sel("containerURLForSecurityApplicationGroupIdentifier:"),str("group.f172ad8c5e5f97bc.1"));void *path=url?((void*(*)(void*,void*))msg)(url,sel("path")):0;const char *dir=path?((const char*(*)(void*,void*))msg)(path,sel("UTF8String")):0;if(dir)musicRead(dir);else musicReset();put(d,"MicFXMusicStatus",dir?"Group accessible; check packet and mix counters":"App Group denied");}else {musicReset();put(d,"MicFXMusicStatus","Off");}putNum(d,"MicFXMusicPackets",atomic_load(&musicPackets));putNum(d,"MicFXMusicMixed",atomic_load(&musicMixed));poolPop(pool);usleep(20000);
    }return 0;
}
__attribute__((constructor)) static void start(void){getClass=SYM("objc_getClass");sel=SYM("sel_registerName");msg=SYM("objc_msgSend");poolPush=SYM("objc_autoreleasePoolPush");poolPop=SYM("objc_autoreleasePoolPop");if(!getClass||!sel||!msg||!poolPush||!poolPop)return;
    // Ensure stale settings cannot enable processing on app launch, even after a previous crash.
    void *pool=poolPush();void *d=((void*(*)(void*,void*))msg)(getClass("NSUserDefaults"),sel("standardUserDefaults"));put(d,"MicFXPitchEnabled","0");putNum(d,"MicFXMusicEnabled",0);putNum(d,"MicFXMusicCallMix",0);putNum(d,"MicFXNativeAck",0);putNum(d,"MicFXNativeVersion",4);putNum(d,"MicFXNativeHooked",0);putNum(d,"MicFXNativeOn",0);put(d,"MicFXPitchStatus","Native processor starting");poolPop(pool);
    int hooked=install();if(hooked)callMixHooked=installCallMixHook();pthread_t t;if(!pthread_create(&t,0,poll,(void*)(intptr_t)hooked))pthread_detach(t);
}
