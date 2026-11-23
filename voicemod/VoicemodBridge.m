#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import <AudioToolbox/AudioToolbox.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <mach/mach.h>
#import <dlfcn.h>
#import <string.h>
#import <unistd.h>
#import <pthread.h>
#import <math.h>
#import "../BridgePacket.h"

// Mach VM API is not declared by the public iPhoneOS SDK headers. Same ABI used in MicFX.
extern int mach_vm_protect(unsigned int,uint64_t,uint64_t,int,int);
static _Atomic unsigned auInit,auStart,auProp,auRender,aqNew,aqEnqueue,fmtRate,fmtChannels,fmtBits,callbackSets,patched,skipped;
static _Atomic unsigned importedMask,patchedMask,mismatchMask,deniedMask,restoreMask;
static _Atomic unsigned unitCount,unitType[8],unitSubtype[8],unitMaker[8];

/* Spotify Bridge beta: capture an authorized post-render PCM stream without changing the audio.
   The real-time callback ONLY copies into an SPSC memory ring. A separate worker writes App Group packets. */
#define BR_RING (1u<<17)
#define BR_MASK (BR_RING-1)
static float brRing[BR_RING];
static _Atomic uint64_t brWrite,brRead;
static _Atomic unsigned brNotifies,brFrames,brBadFormat,brNoData,brPackets,brWriteErrors,brDropped;
static _Atomic unsigned brAttached,brAttachFail,brSelected,brSourceRate,brSourceChannels;
static uint64_t brSession;
static uint64_t brSeq;
static double brCursor;
static NSURL *brDirectory;
static NSString *brRootPath=@"Unresolved";
static NSString *brForcedStatus=@"Not tested";
static NSString *brForcedDirectory=@"Unavailable";
typedef struct { AudioUnit unit; AudioStreamBasicDescription fmt; unsigned role; } BridgeCtx;
static BridgeCtx brCtx[8];
static _Atomic unsigned brCtxUsed;
static uint64_t brNowMs(void){return (uint64_t)(NSDate.date.timeIntervalSince1970*1000.0);}
static float brClip(float f){return f>1.f?1.f:f< -1.f?-1.f:f;}
static OSStatus brNotify(void *ref,AudioUnitRenderActionFlags *flags,const AudioTimeStamp *ts,UInt32 bus,UInt32 frames,AudioBufferList *data){
 (void)ts;
 BridgeCtx *ctx=(BridgeCtx*)ref;
 if(!flags||!(*flags & kAudioUnitRenderAction_PostRender)||!ctx||bus!=0)return noErr;
 atomic_fetch_add(&brNotifies,1);
 if(*flags & kAudioUnitRenderAction_OutputIsSilence)return noErr;
 if(ctx->role==1&&atomic_load(&brSelected)==2)return noErr;
 if(ctx->role==2)atomic_store(&brSelected,2);
 else {unsigned none=0;atomic_compare_exchange_strong(&brSelected,&none,1);}
 AudioStreamBasicDescription f=ctx->fmt;
 if(f.mFormatID!=kAudioFormatLinearPCM||f.mSampleRate<8000||f.mSampleRate>96000||
    f.mChannelsPerFrame<1||f.mChannelsPerFrame>8||f.mFramesPerPacket!=1||
    (f.mFormatFlags&kAudioFormatFlagIsBigEndian)||
    !((f.mFormatFlags&kAudioFormatFlagIsFloat)&&f.mBitsPerChannel==32||
      (f.mFormatFlags&kAudioFormatFlagIsSignedInteger)&&f.mBitsPerChannel==16)){
   atomic_fetch_add(&brBadFormat,1);return noErr;
 }
 if(!data||!data->mNumberBuffers||frames==0||frames>4096){atomic_fetch_add(&brNoData,1);return noErr;}
 int planar=(f.mFormatFlags&kAudioFormatFlagIsNonInterleaved)!=0;
 unsigned ch=f.mChannelsPerFrame;
 unsigned sampleBytes=f.mBitsPerChannel/8;
 if((planar&&data->mNumberBuffers<ch)||(!planar&&data->mNumberBuffers!=1)){
   atomic_fetch_add(&brBadFormat,1);return noErr;
 }
 for(unsigned b=0;b<(planar?ch:1);b++){
   const AudioBuffer *buf=&data->mBuffers[b];
   if(!buf->mData||buf->mDataByteSize<frames*(planar?sampleBytes:sampleBytes*ch)){
     atomic_fetch_add(&brNoData,1);return noErr;
   }
 }
 uint64_t w=atomic_load_explicit(&brWrite,memory_order_relaxed);
 for(unsigned i=0;i<frames;i++){
   float sum=0.f;
   for(unsigned j=0;j<ch;j++){
     const uint8_t *raw=(const uint8_t*)(planar?data->mBuffers[j].mData:data->mBuffers[0].mData);
     unsigned index=planar?i:i*ch+j;
     float v;
     if(f.mBitsPerChannel==32){float t;memcpy(&t,raw+4*index,4);v=t;}
     else {int16_t t;memcpy(&t,raw+2*index,2);v=t/32768.f;}
     if(isfinite(v))sum+=v;
   }
   brRing[(w+i)&BR_MASK]=brClip(sum/ch);
 }
 atomic_store(&brSourceRate,(unsigned)f.mSampleRate);
 atomic_store(&brSourceChannels,ch);
 atomic_store_explicit(&brWrite,w+frames,memory_order_release);
 atomic_fetch_add(&brFrames,frames);
 return noErr;
}
static void bridgeAttach(AudioUnit unit){
 AudioComponent ac=AudioComponentInstanceGetComponent(unit);
 AudioComponentDescription d={0};
 if(!ac||AudioComponentGetDescription(ac,&d)!=noErr)return;
 if(d.componentType!=kAudioUnitType_Output||d.componentSubType!=kAudioUnitSubType_RemoteIO){
   if(d.componentType!=kAudioUnitType_FormatConverter||d.componentSubType!=kAudioUnitSubType_AUConverter)return;
 }
 unsigned idx=atomic_fetch_add(&brCtxUsed,1);
 if(idx>=8){atomic_fetch_add(&brAttachFail,1);return;}
 BridgeCtx *ctx=&brCtx[idx];
 ctx->unit=unit;
 ctx->role=(d.componentType==kAudioUnitType_Output)?2:1;
 UInt32 size=sizeof(ctx->fmt);
 if(AudioUnitGetProperty(unit,kAudioUnitProperty_StreamFormat,kAudioUnitScope_Output,0,&ctx->fmt,&size)!=noErr||
    size!=sizeof(ctx->fmt)){atomic_fetch_add(&brAttachFail,1);return;}
 OSStatus rc=AudioUnitAddRenderNotify(unit,brNotify,ctx);
 if(rc==noErr)atomic_fetch_add(&brAttached,1);
 else atomic_fetch_add(&brAttachFail,1);
}
static void brWritePackets(void){
 if(!brDirectory)return;
 unsigned rate=atomic_load(&brSourceRate);
 if(rate<8000||rate>96000)return;
 uint64_t write=atomic_load_explicit(&brWrite,memory_order_acquire);
 double need=(MB_FRAMES+2)*(double)rate/MB_RATE+2;
 if(write < (uint64_t)(brCursor+need))return;
 if(write>brCursor+(double)rate*0.6){
   brCursor=write-(double)rate*0.2;
   atomic_fetch_add(&brDropped,1);
 }
 MBPacket pkt={0};
 pkt.magic=MB_MAGIC;
 pkt.frames=MB_FRAMES;
 pkt.session=brSession;
 pkt.seq=++brSeq;
 pkt.time_ms=brNowMs();
 double step=(double)rate/MB_RATE;
 for(unsigned i=0;i<MB_FRAMES;i++){
   uint64_t base=(uint64_t)brCursor;
   float a=brRing[base&BR_MASK],b=brRing[(base+1)&BR_MASK];
   float v=brClip(a+(b-a)*(float)(brCursor-base));
   pkt.pcm[i]=(int16_t)lrintf(v>=0?v*32767.f:v*32768.f);
   brCursor+=step;
 }
 atomic_store(&brRead,(uint64_t)brCursor);
 pkt.checksum=mb_hash(pkt.pcm);
 NSURL *dest=[brDirectory URLByAppendingPathComponent:[NSString stringWithFormat:@"slot-%02u.bin",(unsigned)(pkt.seq%MB_SLOTS)]];
 NSData *body=[NSData dataWithBytes:&pkt length:sizeof(pkt)];
 NSError *err=nil;
 if([body writeToURL:dest options:NSDataWritingAtomic error:&err])atomic_fetch_add(&brPackets,1);
 else atomic_fetch_add(&brWriteErrors,1);
}
static void brStartWorker(void){
 dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
   for(;;){@autoreleasepool{brWritePackets();}usleep(12000);}
 });
}

static void recordUnit(AudioUnit u){
 AudioComponent a=AudioComponentInstanceGetComponent(u);
 AudioComponentDescription d={0};
 if(!a||AudioComponentGetDescription(a,&d)!=noErr)return;
 unsigned n=atomic_fetch_add(&unitCount,1);
 if(n<8){atomic_store(&unitType[n],d.componentType);atomic_store(&unitSubtype[n],d.componentSubType);atomic_store(&unitMaker[n],d.componentManufacturer);}
}
static NSString *fourCC(unsigned v){char s[5]={0};for(int i=0;i<4;i++){unsigned char b=(unsigned char)(v>>(24-8*i));s[i]=(b>=32&&b<127)?(char)b:'.';}return [NSString stringWithUTF8String:s];}
static NSString *unitReport(void){
 NSMutableString *r=[NSMutableString string];
 unsigned n=atomic_load(&unitCount);
 [r appendFormat:@"\\nUnit descriptions: %u",n];
 for(unsigned i=0;i<n&&i<8;i++)[r appendFormat:@"\\n  %u: %@/%@/%@",i+1,fourCC(atomic_load(&unitType[i])),fourCC(atomic_load(&unitSubtype[i])),fourCC(atomic_load(&unitMaker[i]))];
 return r;
}
static void formatMeta(const AudioStreamBasicDescription *f){if(!f)return;atomic_store(&fmtRate,(unsigned)f->mSampleRate);atomic_store(&fmtChannels,f->mChannelsPerFrame);atomic_store(&fmtBits,f->mBitsPerChannel);}
static OSStatus hInit(AudioUnit u){atomic_fetch_add(&auInit,1);OSStatus result=AudioUnitInitialize(u);if(result==noErr){recordUnit(u);bridgeAttach(u);}return result;}
static OSStatus hStart(AudioUnit u){atomic_fetch_add(&auStart,1);AudioStreamBasicDescription f={0};UInt32 n=sizeof(f);if(!AudioUnitGetProperty(u,kAudioUnitProperty_StreamFormat,kAudioUnitScope_Input,0,&f,&n))formatMeta(&f);return AudioOutputUnitStart(u);}
static OSStatus hProp(AudioUnit u,AudioUnitPropertyID p,AudioUnitScope s,AudioUnitElement e,const void *d,UInt32 n){OSStatus result=AudioUnitSetProperty(u,p,s,e,d,n);atomic_fetch_add(&auProp,1);if(!result&&p==kAudioUnitProperty_StreamFormat&&d&&n==sizeof(AudioStreamBasicDescription))formatMeta(d);if(!result&&p==kAudioUnitProperty_SetRenderCallback)atomic_fetch_add(&callbackSets,1);return result;}
static OSStatus hRender(AudioUnit u,AudioUnitRenderActionFlags *f,const AudioTimeStamp *t,UInt32 b,UInt32 n,AudioBufferList *l){atomic_fetch_add(&auRender,1);return AudioUnitRender(u,f,t,b,n,l);}
static OSStatus hQueue(const AudioStreamBasicDescription *f,AudioQueueOutputCallback cb,void *ctx,CFRunLoopRef loop,CFStringRef mode,UInt32 flags,AudioQueueRef *q){atomic_fetch_add(&aqNew,1);formatMeta(f);return AudioQueueNewOutput(f,cb,ctx,loop,mode,flags,q);}
static OSStatus hEnqueue(AudioQueueRef q,AudioQueueBufferRef b,UInt32 n,const AudioStreamPacketDescription *p){atomic_fetch_add(&aqEnqueue,1);return AudioQueueEnqueueBuffer(q,b,n,p);}
static const struct {const char *name;void *replacement;} targets[]={{"AudioUnitInitialize",(void*)hInit},{"AudioOutputUnitStart",(void*)hStart},{"AudioUnitSetProperty",(void*)hProp},{"AudioUnitRender",(void*)hRender},{"AudioQueueNewOutput",(void*)hQueue},{"AudioQueueEnqueueBuffer",(void*)hEnqueue}};
static void inspectImage(const struct mach_header *raw,intptr_t slide){
 if(!raw||raw->magic!=MH_MAGIC_64)return;
 const struct mach_header_64 *h=(const void*)raw;
 // Only app-bundle images are passed here; never modify system frameworks.
 const struct segment_command_64 *link=NULL;const struct symtab_command *sym=NULL;const struct dysymtab_command *dy=NULL;
 const uint8_t *p=(const uint8_t*)(h+1);
 for(uint32_t i=0;i<h->ncmds;i++){const struct load_command *lc=(const void*)p;if(lc->cmd==LC_SEGMENT_64){const struct segment_command_64 *s=(const void*)p;if(!strcmp(s->segname,"__LINKEDIT"))link=s;}else if(lc->cmd==LC_SYMTAB)sym=(const void*)p;else if(lc->cmd==LC_DYSYMTAB)dy=(const void*)p;p+=lc->cmdsize;}
 if(!link||!sym||!dy)return;
 uintptr_t base=(uintptr_t)(slide+link->vmaddr-link->fileoff);
 const struct nlist_64 *nl=(const void*)(base+sym->symoff);const char *strings=(const void*)(base+sym->stroff);const uint32_t *ind=(const void*)(base+dy->indirectsymoff);
 p=(const uint8_t*)(h+1);
 for(uint32_t i=0;i<h->ncmds;i++){const struct load_command *lc=(const void*)p;if(lc->cmd==LC_SEGMENT_64){const struct segment_command_64 *s=(const void*)p;const struct section_64 *sec=(const void*)(s+1);for(uint32_t j=0;j<s->nsects;j++){uint32_t type=sec[j].flags&SECTION_TYPE;if(type!=S_NON_LAZY_SYMBOL_POINTERS&&type!=S_LAZY_SYMBOL_POINTERS)continue;void **slots=(void**)(slide+sec[j].addr);for(uint64_t k=0;k<sec[j].size/sizeof(void*);k++){uint64_t ix=(uint64_t)sec[j].reserved1+k;if(ix>=dy->nindirectsyms)break;uint32_t si=ind[ix];if(si>=sym->nsyms)continue;uint32_t off=nl[si].n_un.n_strx;if(off>=sym->strsize)continue;const char *name=strings+off;if(*name!='_')continue;for(unsigned z=0;z<sizeof(targets)/sizeof(targets[0]);z++){if(strcmp(name+1,targets[z].name))continue;atomic_fetch_or(&importedMask,1u<<z);void *expected=dlsym(RTLD_DEFAULT,targets[z].name);if(!expected||slots[k]!=expected){atomic_fetch_or(&mismatchMask,1u<<z);atomic_fetch_add(&skipped,1);continue;}
 // Temporarily make only the import-slot page writable, then restore its protection.
 // If iOS denies this, leave the slot untouched and report it as skipped.
 uint64_t pageSize=(uint64_t)getpagesize();
 if(!pageSize||(pageSize&(pageSize-1))){atomic_fetch_or(&deniedMask,1u<<z);atomic_fetch_add(&skipped,1);continue;}
 uint64_t page=(uint64_t)((uintptr_t)&slots[k] & ~(uintptr_t)(pageSize-1));
 int originalProtection=s->initprot&(VM_PROT_READ|VM_PROT_WRITE|VM_PROT_EXECUTE);
 if(!strcmp(s->segname,"__DATA_CONST")||!strcmp(s->segname,"__AUTH_CONST"))originalProtection=VM_PROT_READ;
 if(!originalProtection||mach_vm_protect(mach_task_self(),page,pageSize,0,VM_PROT_READ|VM_PROT_WRITE)){atomic_fetch_or(&deniedMask,1u<<z);atomic_fetch_add(&skipped,1);continue;}
 __atomic_store_n(&slots[k],targets[z].replacement,__ATOMIC_RELEASE);
 if(mach_vm_protect(mach_task_self(),page,pageSize,0,originalProtection)){
   __atomic_store_n(&slots[k],expected,__ATOMIC_RELEASE);
   mach_vm_protect(mach_task_self(),page,pageSize,0,originalProtection);
   atomic_fetch_or(&restoreMask,1u<<z);
   atomic_fetch_add(&skipped,1);
   continue;
 }
 atomic_fetch_or(&patchedMask,1u<<z);atomic_fetch_add(&patched,1);
 }}}}p+=lc->cmdsize;}
}

static _Atomic unsigned engines, plays, buffers, samples, interrupts, beats, rate, channels;
static unsigned hooks;
static NSString *groupStatus=@"Not checked";
static void (*oldPlay)(id,SEL);
static void play(id s,SEL c){atomic_fetch_add(&plays,1);oldPlay(s,c);}
static BOOL (*oldStart)(id,SEL,NSError **);
static BOOL start(id s,SEL c,NSError **e){atomic_fetch_add(&engines,1);return oldStart(s,c,e);}
static void (*oldBuffer)(id,SEL,AVAudioPCMBuffer *,id);
static void buffer(id s,SEL c,AVAudioPCMBuffer *b,id cb){atomic_fetch_add(&buffers,1);atomic_store(&rate,(unsigned)b.format.sampleRate);atomic_store(&channels,b.format.channelCount);oldBuffer(s,c,b,cb);}
static void (*oldTimed)(id,SEL,AVAudioPCMBuffer *,AVAudioTime *,NSUInteger,id);
static void timed(id s,SEL c,AVAudioPCMBuffer *b,AVAudioTime *t,NSUInteger o,id cb){atomic_fetch_add(&buffers,1);atomic_store(&rate,(unsigned)b.format.sampleRate);atomic_store(&channels,b.format.channelCount);oldTimed(s,c,b,t,o,cb);}
static void (*oldSample)(id,SEL,CMSampleBufferRef);
static void sample(id s,SEL c,CMSampleBufferRef b){atomic_fetch_add(&samples,1);oldSample(s,c,b);}
static void hook(Class cls,SEL sel,IMP replacement,IMP *original){if(!cls)return;Method m=class_getInstanceMethod(cls,sel);if(!m)return;*original=method_getImplementation(m);if(!class_addMethod(cls,sel,replacement,method_getTypeEncoding(m)))method_setImplementation(m,replacement);hooks++;}
@interface Probe : NSObject
@property(nonatomic,strong) dispatch_source_t timer;
@end
@implementation Probe
- (void)report:(UITapGestureRecognizer *)g {if(g.state!=UIGestureRecognizerStateRecognized)return;AVAudioSession *a=AVAudioSession.sharedInstance;NSString *r=[NSString stringWithFormat:@"Voicemod Soundboard Bridge beta v1\nHooks: %u\nEngine starts: %u\nPlayer plays: %u\nPCM schedules: %u\nSample enqueues: %u\nPCM: %u Hz / %u ch\nSession: %.0f Hz / %ld ch\nCategory: %@\nMode: %@\nOptions: %lu\nInterruptions: %u\nHeartbeat: %u\nGroup: %@",hooks,atomic_load(&engines),atomic_load(&plays),atomic_load(&buffers),atomic_load(&samples),atomic_load(&rate),atomic_load(&channels),a.sampleRate,(long)a.outputNumberOfChannels,a.category,a.mode,(unsigned long)a.categoryOptions,atomic_load(&interrupts),atomic_load(&beats),groupStatus];r=[r stringByAppendingFormat:@"\nCore slots: %u / skipped %u\nAU init: %u\nAU start: %u\nAU properties: %u\nAU callbacks set: %u\nAU render: %u\nQueue create: %u\nQueue enqueue: %u\nCore format: %u Hz / %u ch / %u bits",atomic_load(&patched),atomic_load(&skipped),atomic_load(&auInit),atomic_load(&auStart),atomic_load(&auProp),atomic_load(&callbackSets),atomic_load(&auRender),atomic_load(&aqNew),atomic_load(&aqEnqueue),atomic_load(&fmtRate),atomic_load(&fmtChannels),atomic_load(&fmtBits)];r=[r stringByAppendingFormat:@"\\nImport masks (Init/Start/Set/Render/QNew/QSend):\\nFound: %02X Hooked: %02X\\nMismatch: %02X Denied: %02X Restore: %02X",atomic_load(&importedMask),atomic_load(&patchedMask),atomic_load(&mismatchMask),atomic_load(&deniedMask),atomic_load(&restoreMask)];r=[r stringByAppendingString:unitReport()];r=[r stringByAppendingFormat:@"\nBridge container: %@\nVoicemod PCM target: %@\nWrite test: %@\nBridge packet directory: %@",brRootPath,brForcedDirectory,brForcedStatus,brDirectory.path?:@"Unavailable"];r=[r stringByAppendingFormat:@"\\nBridge: attached %u / failed %u\\nPost-render callbacks: %u\\nCaptured frames: %u\\nMissing data: %u / bad format %u\\nSource: %u Hz / %u channels\\nPackets sent: %u / write failures %u\\nQueue drops: %u / selection %u",atomic_load(&brAttached),atomic_load(&brAttachFail),atomic_load(&brNotifies),atomic_load(&brFrames),atomic_load(&brNoData),atomic_load(&brBadFormat),atomic_load(&brSourceRate),atomic_load(&brSourceChannels),atomic_load(&brPackets),atomic_load(&brWriteErrors),atomic_load(&brDropped),atomic_load(&brSelected)];UIViewController *v=((UIWindow *)g.view).rootViewController;while(v.presentedViewController)v=v.presentedViewController;if(!v)return;UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Audio Probe" message:r preferredStyle:UIAlertControllerStyleAlert];[alert addAction:[UIAlertAction actionWithTitle:@"Copy report" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *x){UIPasteboard.generalPasteboard.string=r;}]];[alert addAction:[UIAlertAction actionWithTitle:@"Close" style:UIAlertActionStyleCancel handler:nil]];[v presentViewController:alert animated:YES completion:nil];}
- (void)attach {for(UIScene *s in UIApplication.sharedApplication.connectedScenes){if(![s isKindOfClass:UIWindowScene.class])continue;for(UIWindow *w in ((UIWindowScene *)s).windows){if(!w.isKeyWindow)continue;BOOL exists=NO;for(UIGestureRecognizer *g in w.gestureRecognizers)if([g.name isEqualToString:@"VoicemodProbe"])exists=YES;if(exists)continue;UITapGestureRecognizer *g=[[UITapGestureRecognizer alloc]initWithTarget:self action:@selector(report:)];g.name=@"VoicemodProbe";g.numberOfTouchesRequired=3;g.numberOfTapsRequired=2;g.cancelsTouchesInView=NO;[w addGestureRecognizer:g];}}}
@end
static Probe *probe;
__attribute__((constructor)) static void setup(void){@autoreleasepool{
 // Voicemod's native soundboard engine lives in embedded app frameworks.
 // Inspect app-bundle import slots, not any Apple system library.
 for(uint32_t imageIndex=0;imageIndex<_dyld_image_count();imageIndex++){
   const char *nm=_dyld_get_image_name(imageIndex);
   if(nm&&(strstr(nm,"/iosApp.app/")||strstr(nm,"/iosApp.app/Frameworks/")))
     inspectImage(_dyld_get_image_header(imageIndex),_dyld_get_image_vmaddr_slide(imageIndex));
 }
 hook(AVAudioEngine.class,@selector(startAndReturnError:),(IMP)start,(IMP*)&oldStart);
 hook(AVAudioPlayerNode.class,@selector(play),(IMP)play,(IMP*)&oldPlay);
 hook(AVAudioPlayerNode.class,@selector(scheduleBuffer:completionHandler:),(IMP)buffer,(IMP*)&oldBuffer);
 hook(AVAudioPlayerNode.class,@selector(scheduleBuffer:atTime:options:completionHandler:),(IMP)timed,(IMP*)&oldTimed);
 hook(NSClassFromString(@"AVSampleBufferAudioRenderer"),@selector(enqueueSampleBuffer:),(IMP)sample,(IMP*)&oldSample);
 dispatch_async(dispatch_get_main_queue(),^{probe=[Probe new];
 // Share only the explicitly authorized group.f172ad8c5e5f97bc.1 with Endcord.
 // Never touch Spotify's packet directory. A signer must grant the group.
 NSURL *u=[NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:@"group.f172ad8c5e5f97bc.1"];
 if(u){
   brRootPath=u.path?:@"No path";
   NSURL *target=[u URLByAppendingPathComponent:@"MicFXVoicemod-v1" isDirectory:YES];
   NSError *err=nil;
   BOOL created=[NSFileManager.defaultManager createDirectoryAtURL:target withIntermediateDirectories:YES attributes:nil error:&err];
   NSURL *probeURL=[target URLByAppendingPathComponent:[NSString stringWithFormat:@"probe-%@",NSUUID.UUID.UUIDString]];
   NSData *sample=[@"voicemod-bridge" dataUsingEncoding:NSUTF8StringEncoding];
   BOOL good=created&&[sample writeToURL:probeURL options:NSDataWritingAtomic error:&err]&&[[NSData dataWithContentsOfURL:probeURL] isEqualToData:sample];
   [NSFileManager.defaultManager removeItemAtURL:probeURL error:NULL];
   groupStatus=good?@"PASS read/write":@"DENIED";
   brForcedDirectory=target.path?:@"Unavailable";
   brForcedStatus=good?@"PASS: independent Voicemod audio folder":[NSString stringWithFormat:@"DENIED: %@",err.localizedDescription?:@"missing App Group entitlement"];
   if(good){brDirectory=target;brSession=(((uint64_t)arc4random()<<32)|arc4random())?:1;brStartWorker();}
 }else{brRootPath=@"DENIED";groupStatus=@"DENIED";brForcedDirectory=@"DENIED";brForcedStatus=@"Shared App Group not authorized";}
 // Try to preserve playback alongside Spotify without modifying Spotify itself.
 AVAudioSession *session=AVAudioSession.sharedInstance;
 if([session.category isEqualToString:AVAudioSessionCategoryPlayback]){
   NSError *mixError=nil;
   [session setCategory:AVAudioSessionCategoryPlayback
           withOptions:(session.categoryOptions|AVAudioSessionCategoryOptionMixWithOthers)
                 error:&mixError];
 }
 [NSNotificationCenter.defaultCenter addObserverForName:AVAudioSessionInterruptionNotification object:nil queue:nil usingBlock:^(__unused NSNotification *n){atomic_fetch_add(&interrupts,1);}];
 [NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(__unused NSTimer *t){[probe attach];}];
 probe.timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_global_queue(QOS_CLASS_UTILITY,0));dispatch_source_set_timer(probe.timer,DISPATCH_TIME_NOW,NSEC_PER_SEC,NSEC_PER_SEC/10);dispatch_source_set_event_handler(probe.timer,^{atomic_fetch_add(&beats,1);});dispatch_resume(probe.timer);});}}
