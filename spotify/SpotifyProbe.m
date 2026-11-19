#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>
#import <stdatomic.h>
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
- (void)report:(UITapGestureRecognizer *)g {if(g.state!=UIGestureRecognizerStateRecognized)return;AVAudioSession *a=AVAudioSession.sharedInstance;NSString *r=[NSString stringWithFormat:@"Spotify Probe v1\nHooks: %u\nEngine starts: %u\nPlayer plays: %u\nPCM schedules: %u\nSample enqueues: %u\nPCM: %u Hz / %u ch\nSession: %.0f Hz / %ld ch\nCategory: %@\nMode: %@\nOptions: %lu\nInterruptions: %u\nHeartbeat: %u\nGroup: %@",hooks,atomic_load(&engines),atomic_load(&plays),atomic_load(&buffers),atomic_load(&samples),atomic_load(&rate),atomic_load(&channels),a.sampleRate,(long)a.outputNumberOfChannels,a.category,a.mode,(unsigned long)a.categoryOptions,atomic_load(&interrupts),atomic_load(&beats),groupStatus];UIViewController *v=((UIWindow *)g.view).rootViewController;while(v.presentedViewController)v=v.presentedViewController;if(!v)return;UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Audio Probe" message:r preferredStyle:UIAlertControllerStyleAlert];[alert addAction:[UIAlertAction actionWithTitle:@"Copy report" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *x){UIPasteboard.generalPasteboard.string=r;}]];[alert addAction:[UIAlertAction actionWithTitle:@"Close" style:UIAlertActionStyleCancel handler:nil]];[v presentViewController:alert animated:YES completion:nil];}
- (void)attach {for(UIScene *s in UIApplication.sharedApplication.connectedScenes){if(![s isKindOfClass:UIWindowScene.class])continue;for(UIWindow *w in ((UIWindowScene *)s).windows){if(!w.isKeyWindow)continue;BOOL exists=NO;for(UIGestureRecognizer *g in w.gestureRecognizers)if([g.name isEqualToString:@"SpotifyProbe"])exists=YES;if(exists)continue;UITapGestureRecognizer *g=[[UITapGestureRecognizer alloc]initWithTarget:self action:@selector(report:)];g.name=@"SpotifyProbe";g.numberOfTouchesRequired=3;g.numberOfTapsRequired=2;g.cancelsTouchesInView=NO;[w addGestureRecognizer:g];}}}
@end
static Probe *probe;
__attribute__((constructor)) static void setup(void){@autoreleasepool{
 hook(AVAudioEngine.class,@selector(startAndReturnError:),(IMP)start,(IMP*)&oldStart);
 hook(AVAudioPlayerNode.class,@selector(play),(IMP)play,(IMP*)&oldPlay);
 hook(AVAudioPlayerNode.class,@selector(scheduleBuffer:completionHandler:),(IMP)buffer,(IMP*)&oldBuffer);
 hook(AVAudioPlayerNode.class,@selector(scheduleBuffer:atTime:options:completionHandler:),(IMP)timed,(IMP*)&oldTimed);
 hook(NSClassFromString(@"AVSampleBufferAudioRenderer"),@selector(enqueueSampleBuffer:),(IMP)sample,(IMP*)&oldSample);
 dispatch_async(dispatch_get_main_queue(),^{probe=[Probe new];NSURL *u=[NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:@"group.f172ad8c5e5f97bc.1"];if(u){NSURL *f=[u URLByAppendingPathComponent:[NSString stringWithFormat:@"probe-%@",NSUUID.UUID.UUIDString]];NSData *d=[@"probe" dataUsingEncoding:NSUTF8StringEncoding];BOOL ok=[d writeToURL:f atomically:YES]&&[[NSData dataWithContentsOfURL:f] isEqualToData:d];[NSFileManager.defaultManager removeItemAtURL:f error:NULL];groupStatus=ok?@"PASS read/write":@"FAIL read/write";}else groupStatus=@"DENIED";
 [NSNotificationCenter.defaultCenter addObserverForName:AVAudioSessionInterruptionNotification object:nil queue:nil usingBlock:^(__unused NSNotification *n){atomic_fetch_add(&interrupts,1);}];
 [NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(__unused NSTimer *t){[probe attach];}];
 probe.timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_global_queue(QOS_CLASS_UTILITY,0));dispatch_source_set_timer(probe.timer,DISPATCH_TIME_NOW,NSEC_PER_SEC,NSEC_PER_SEC/10);dispatch_source_set_event_handler(probe.timer,^{atomic_fetch_add(&beats,1);});dispatch_resume(probe.timer);});}}
