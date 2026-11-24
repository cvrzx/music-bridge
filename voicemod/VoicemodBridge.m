#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import <math.h>
#import "../BridgePacket.h"
// Narrow sender for Soundboard 1.25.2. Capture scheduled playback buffers only.
// No raw Mach-O pointer modification or microphone capture; playback mixing is scoped to Playback.
static dispatch_queue_t worker;
static dispatch_source_t timer;
static NSURL *target;
static NSMutableData *pending;
static NSUInteger offset;
static uint64_t session,sequence;
static _Atomic unsigned scheduled,accepted,sent,failures,unsupported;
static _Atomic int hookReady;
static _Atomic unsigned mixRequests,mixFailures,bgFinishes;
static UIBackgroundTaskIdentifier drainTask=UIBackgroundTaskInvalid;
static _Atomic BOOL drainRequested;
// Only playback categories are adjusted; retain every existing category option.
typedef BOOL (*CatOptions)(id,SEL,NSString*,AVAudioSessionCategoryOptions,NSError**);
typedef BOOL (*CatMode)(id,SEL,NSString*,NSString*,AVAudioSessionCategoryOptions,NSError**);
typedef BOOL (*CatRoute)(id,SEL,NSString*,NSString*,AVAudioSessionRouteSharingPolicy,AVAudioSessionCategoryOptions,NSError**);
static CatOptions oldOptions;static CatMode oldMode;static CatRoute oldRoute;
static AVAudioSessionCategoryOptions mixing(NSString *category,AVAudioSessionCategoryOptions options){
    if([category isEqualToString:AVAudioSessionCategoryPlayback]&&!(options&AVAudioSessionCategoryOptionMixWithOthers)){
        atomic_fetch_add(&mixRequests,1);return options|AVAudioSessionCategoryOptionMixWithOthers;
    }return options;
}
static BOOL optionsHook(id self,SEL cmd,NSString *cat,AVAudioSessionCategoryOptions opts,NSError **err){return oldOptions(self,cmd,cat,mixing(cat,opts),err);}
static BOOL modeHook(id self,SEL cmd,NSString *cat,NSString *mode,AVAudioSessionCategoryOptions opts,NSError **err){return oldMode(self,cmd,cat,mode,mixing(cat,opts),err);}
static BOOL routeHook(id self,SEL cmd,NSString *cat,NSString *mode,AVAudioSessionRouteSharingPolicy policy,AVAudioSessionCategoryOptions opts,NSError **err){return oldRoute(self,cmd,cat,mode,policy,mixing(cat,opts),err);}
static void installPlaybackMix(void){
    Class c=AVAudioSession.class;Method m;
    m=class_getInstanceMethod(c,@selector(setCategory:withOptions:error:));if(m)oldOptions=(CatOptions)method_setImplementation(m,(IMP)optionsHook);
    m=class_getInstanceMethod(c,@selector(setCategory:mode:options:error:));if(m)oldMode=(CatMode)method_setImplementation(m,(IMP)modeHook);
    m=class_getInstanceMethod(c,@selector(setCategory:mode:routeSharingPolicy:options:error:));if(m)oldRoute=(CatRoute)method_setImplementation(m,(IMP)routeHook);
}
static void ensurePlaybackMix(void){
    AVAudioSession *a=AVAudioSession.sharedInstance;
    if(![a.category isEqualToString:AVAudioSessionCategoryPlayback]||(a.categoryOptions&AVAudioSessionCategoryOptionMixWithOthers))return;
    NSError *error=nil;
    if(![a setCategory:a.category mode:a.mode routeSharingPolicy:a.routeSharingPolicy options:a.categoryOptions|AVAudioSessionCategoryOptionMixWithOthers error:&error])atomic_fetch_add(&mixFailures,1);
}
// Finish already-queued clip data with the OS's finite background task. No silent audio, no indefinite keepalive.
static void endDrain(void){
    atomic_store(&drainRequested,NO);
    if(drainTask!=UIBackgroundTaskInvalid){[UIApplication.sharedApplication endBackgroundTask:drainTask];drainTask=UIBackgroundTaskInvalid;}
}
static void requestDrain(void){
    if(drainTask!=UIBackgroundTaskInvalid)return;
    atomic_store(&drainRequested,YES);
    drainTask=[UIApplication.sharedApplication beginBackgroundTaskWithName:@"Finish soundboard clip" expirationHandler:^{endDrain();}];
    if(drainTask==UIBackgroundTaskInvalid)atomic_store(&drainRequested,NO);
}
static void finishDrainIfEmpty(void){
    if(atomic_exchange(&drainRequested,NO))dispatch_async(dispatch_get_main_queue(),^{atomic_fetch_add(&bgFinishes,1);endDrain();});
}
typedef void (*Schedule)(id,SEL,AVAudioPCMBuffer *,AVAudioTime *,AVAudioPlayerNodeBufferOptions,AVAudioNodeCompletionHandler);
static Schedule original;
static _Thread_local int inside;
static uint64_t nowms(void){return (uint64_t)(NSDate.date.timeIntervalSince1970*1000.0);}
static float clip(float x){return !isfinite(x)?0.f:fmaxf(-1.f,fminf(1.f,x));}
static NSData *convert(AVAudioPCMBuffer *b){
    if(!b||!b.frameLength||!b.format)return nil;
    double rate=b.format.sampleRate;
    unsigned ch=b.format.channelCount,n=b.frameLength;
    if(rate<8000||rate>96000||ch<1||ch>8||n>rate*120)return nil;
    AVAudioCommonFormat kind=b.format.commonFormat;
    float *const *fp=b.floatChannelData;
    int16_t *const *ip=b.int16ChannelData;
    int interleaved=b.format.isInterleaved;
    if((kind!=AVAudioPCMFormatFloat32||!fp)&&(kind!=AVAudioPCMFormatInt16||!ip))return nil;
    NSUInteger frames=(NSUInteger)ceil(n*48000.0/rate);
    NSMutableData *out=[NSMutableData dataWithLength:frames*sizeof(int16_t)];
    int16_t *dst=out.mutableBytes;
    for(NSUInteger i=0;i<frames;i++){
        unsigned k=(unsigned)fmin(n-1,i*rate/48000.0);
        float sum=0;
        for(unsigned c=0;c<ch;c++){
            unsigned ix=interleaved?k*ch+c:k;
            if(kind==AVAudioPCMFormatFloat32)sum+=fp[interleaved?0:c][ix];
            else sum+=ip[interleaved?0:c][ix]/32768.f;
        }
        dst[i]=(int16_t)lrintf(32767.f*clip(sum/ch));
    }
    return out;
}
static NSURL *sharedTarget(void){
    NSFileManager *fm=NSFileManager.defaultManager;
    NSURL *first=nil;
    for(unsigned i=1;i<=5;i++){
        NSString *group=[NSString stringWithFormat:@"group.f172ad8c5e5f97bc.%u",i];
        NSURL *u=[fm containerURLForSecurityApplicationGroupIdentifier:group];
        if(!u)continue;
        if(!first)first=u;
        if([u.path containsString:@"9FC494BE-4B8C-4F21-BCFE-99CDF3057575"]){first=u;break;}
    }
    if(!first)return nil;
    NSURL *dir=[first URLByAppendingPathComponent:@"MicFXVoicemod-v1" isDirectory:YES];
    if(![fm createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil])return nil;
    return dir;
}
static void tick(void){
    if(offset>=pending.length){[pending setLength:0];offset=0;finishDrainIfEmpty();return;}
    if(!target){target=sharedTarget();if(!target){atomic_fetch_add(&failures,1);[pending setLength:0];offset=0;return;}}
    MBPacket p={0};
    p.magic=MB_MAGIC;p.frames=MB_FRAMES;p.session=session;p.seq=++sequence;p.time_ms=nowms();
    NSUInteger count=MIN(sizeof(p.pcm),pending.length-offset);
    memcpy(p.pcm,(const uint8_t*)pending.bytes+offset,count);offset+=count;p.checksum=mb_hash(p.pcm);
    NSURL *url=[target URLByAppendingPathComponent:[NSString stringWithFormat:@"slot-%02u.bin",(unsigned)(p.seq%MB_SLOTS)]];
    if([[NSData dataWithBytes:&p length:sizeof(p)] writeToURL:url options:NSDataWritingAtomic error:nil])atomic_fetch_add(&sent,1);
    else{atomic_fetch_add(&failures,1);target=nil;}
}
static void schedule(id node,SEL cmd,AVAudioPCMBuffer *buffer,AVAudioTime *time,AVAudioPlayerNodeBufferOptions options,AVAudioNodeCompletionHandler completion){
    if(inside){original(node,cmd,buffer,time,options,completion);return;}
    inside=1;
    @try {
        // Set mixing before actual soundboard playback; never start an audio session artificially.
        ensurePlaybackMix();
        atomic_fetch_add(&scheduled,1);
        NSData *samples=convert(buffer);
        if(samples.length){
            atomic_fetch_add(&accepted,1);
            dispatch_async(worker,^{
                if(offset){[pending replaceBytesInRange:NSMakeRange(0,offset) withBytes:NULL length:0];offset=0;}
                if(pending.length+samples.length<=48000u*2u*120u)[pending appendData:samples];
            });
        }else atomic_fetch_add(&unsupported,1);
    }@catch(__unused NSException *e){atomic_fetch_add(&unsupported,1);}
    @finally{inside=0;}
    original(node,cmd,buffer,time,options,completion);
}
@interface VMBridgeProbe:NSObject
@end
@implementation VMBridgeProbe
-(void)report:(UITapGestureRecognizer*)gesture{
    if(gesture.state!=UIGestureRecognizerStateRecognized)return;
    dispatch_async(worker,^{
        NSString *report=[NSString stringWithFormat:@"Voicemod Bridge — narrow playback hook\nHook: %d\nScheduled: %u\nAccepted: %u\nPackets: %u\nFailures: %u\nUnsupported: %u\nMix requests: %u / failures: %u\nBackground drains finished: %u\nGroup folder: %@",atomic_load(&hookReady),atomic_load(&scheduled),atomic_load(&accepted),atomic_load(&sent),atomic_load(&failures),atomic_load(&unsupported),atomic_load(&mixRequests),atomic_load(&mixFailures),atomic_load(&bgFinishes),target.path?:@"Not resolved"];
        dispatch_async(dispatch_get_main_queue(),^{
            UIViewController *vc=((UIWindow*)gesture.view).rootViewController;
            while(vc.presentedViewController)vc=vc.presentedViewController;
            if(!vc)return;
            UIAlertController *a=[UIAlertController alertControllerWithTitle:@"Voicemod Bridge" message:report preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"Copy report" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action){UIPasteboard.generalPasteboard.string=report;}]];
            [a addAction:[UIAlertAction actionWithTitle:@"Close" style:UIAlertActionStyleCancel handler:nil]];[vc presentViewController:a animated:YES completion:nil];
        });
    });
}
-(void)attach{
    for(UIScene *scene in UIApplication.sharedApplication.connectedScenes){
        if(![scene isKindOfClass:UIWindowScene.class])continue;
        for(UIWindow *w in ((UIWindowScene*)scene).windows){
            if(!w.isKeyWindow)continue;
            BOOL found=NO;for(UIGestureRecognizer *g in w.gestureRecognizers)if([g.name isEqual:@"VMBridgeProbe"])found=YES;
            if(found)continue;
            UITapGestureRecognizer *g=[[UITapGestureRecognizer alloc]initWithTarget:self action:@selector(report:)];
            g.name=@"VMBridgeProbe";g.numberOfTouchesRequired=3;g.numberOfTapsRequired=2;g.cancelsTouchesInView=NO;[w addGestureRecognizer:g];
        }
    }
}
@end
static VMBridgeProbe *probe;
static void startBridge(void){
    worker=dispatch_queue_create("micfx.voicemod.clip",DISPATCH_QUEUE_SERIAL);
    pending=[NSMutableData data];session=(((uint64_t)arc4random()<<32)|arc4random())?:1;
    timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,worker);
    dispatch_source_set_timer(timer,DISPATCH_TIME_NOW,100*NSEC_PER_MSEC,5*NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer,^{@autoreleasepool{tick();}});dispatch_resume(timer);
    Class c=AVAudioPlayerNode.class;SEL sel=@selector(scheduleBuffer:atTime:options:completionHandler:);
    Method m=class_getInstanceMethod(c,sel);
    if(m&&method_getNumberOfArguments(m)==6){
        original=(Schedule)method_getImplementation(m);
        if(original){
            if(!class_addMethod(c,sel,(IMP)schedule,method_getTypeEncoding(m)))method_setImplementation(m,(IMP)schedule);
            atomic_store(&hookReady,1);
        }
    }
    installPlaybackMix();ensurePlaybackMix();
    NSNotificationCenter *nc=NSNotificationCenter.defaultCenter;
    [nc addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *n){requestDrain();}];
    [nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *n){endDrain();}];
    probe=[VMBridgeProbe new];[probe attach];
    [NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(__unused NSTimer*t){[probe attach];}];
}
__attribute__((constructor)) static void setup(void){
    dispatch_async(dispatch_get_main_queue(),^{@autoreleasepool{startBridge();}});
}
