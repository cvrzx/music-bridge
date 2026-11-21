#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuickLook/QuickLook.h>
#import "RecordBuffer.h"
#import "RecordFile.h"
#import "vendor/shine/layer3.h"
#include <stdio.h>
#include <stdint.h>
#import <math.h>

MFRecordBuffer mfRec;
static _Atomic bool quietRequested,monitorStopped;
static _Atomic int includeReceivedMusic;
int mf_rec_wants_music(void){return atomic_load_explicit(&includeReceivedMusic,memory_order_relaxed);}
int mf_rec_wants_quiet(void){return atomic_load(&quietRequested);}
void mf_rec_monitor_ack(int quiet){atomic_store(&monitorStopped,quiet!=0);}

typedef NS_ENUM(unsigned, MFRecPhase){ MFIdle, MFArming, MFTaking, MFFinishing, MFWaitingPreview, MFPresenting };
static MFRecPhase phase;
static dispatch_queue_t worker;
static dispatch_source_t timer;
static NSString *session,*finishReason;
static NSURL *folder,*scratchURL,*finalURL,*previewURL;
static ExtAudioFileRef encoder;
static shine_t mp3Encoder;
static FILE *mp3File;
static int mp3Pass,mp3Filled;
static int16_t mp3Samples[SHINE_MAX_SAMPLES];
static BOOL wantsMP3;
static unsigned captureRate;
static uint64_t framesWritten;
static NSTimeInterval lastData;
static double lastCommand;
static NSInteger lastSeconds;
static BOOL writerFailed,hookAvailable;
static NSUserDefaults *prefs;

static void status(NSString *message){[prefs setObject:message forKey:@"MicFXRecordStatus"];}
static void state(MFRecPhase next,NSString *name){
    phase=next;
    [prefs setObject:name forKey:@"MicFXRecordState"];
}
static void idle(NSString *message){
    atomic_store(&quietRequested,false);
    state(MFIdle,@"idle");
    status(message);
}
static void refreshList(void){
    NSArray<NSString *> *names=[[NSFileManager defaultManager] contentsOfDirectoryAtPath:folder.path error:nil];
    NSMutableArray<NSString *> *files=[NSMutableArray array];
    for(NSString *n in names){
        if([n hasPrefix:@"MicFX-"]&&([n.pathExtension isEqualToString:@"mp4"]||[n.pathExtension isEqualToString:@"mp3"]))[files addObject:n];
    }
    [files sortUsingComparator:^NSComparisonResult(NSString *a,NSString *b){return [b compare:a];}];
    [prefs setObject:files forKey:@"MicFXRecordFiles"];
}
static NSString *newName(void){
    NSDateFormatter *f=[NSDateFormatter new];f.locale=[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    f.timeZone=NSTimeZone.localTimeZone;f.dateFormat=@"yyyy-MM-dd HH-mm-ss";
    return [NSString stringWithFormat:@"MicFX-%@-%@.%@",[f stringFromDate:NSDate.date],
            [NSUUID.UUID.UUIDString substringToIndex:8],wantsMP3?@"mp3":@"mp4"];
}
static void beginTake(void){
    if(!hookAvailable||mf_rec_capture_rate()==0){idle(@"Join a voice call with Discord’s microphone active, then tap Record.");return;}
    NSError *e=nil;
    if(!folder||![NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:&e]){
        idle(@"Could not open the local recordings folder.");return;
    }
    framesWritten=0;lastSeconds=0;writerFailed=NO;finishReason=nil;
    [prefs setInteger:0 forKey:@"MicFXRecordSeconds"];
    atomic_store(&quietRequested,true);
    lastData=NSProcessInfo.processInfo.systemUptime;
    state(MFArming,@"arming");status(@"Waiting for microphone audio…");
}
static void stopTake(NSString *reason){
    atomic_store(&mfRec.armed,false);
    finishReason=reason;
    state(MFFinishing,@"finishing");status(@"Finishing MP4…");
}
// Shine MP3 encoding runs only on this serial recorder worker, never in the AudioUnit callback.
static BOOL mp3WritePacket(const unsigned char *p,int n){
    if(n<0||!mp3File)return NO;
    return n==0||(p&&fwrite(p,1,(size_t)n,mp3File)==(size_t)n);
}
static BOOL mp3Push(const float *in,unsigned count){
    if(!mp3Encoder||!mp3File||mp3Pass<=0)return NO;
    for(unsigned i=0;i<count;i++){
        const float x=fmaxf(-1.f,fminf(1.f,in[i]));
        mp3Samples[mp3Filled++]=(int16_t)lrintf(x*32767.f);
        if(mp3Filled==mp3Pass){
            int n=0;unsigned char *packet=shine_encode_buffer_interleaved(mp3Encoder,mp3Samples,&n);
            if(!mp3WritePacket(packet,n))return NO;
            mp3Filled=0;
        }
    }
    return YES;
}
static BOOL mp3Finish(void){
    BOOL ok=YES;
    if(mp3Encoder){
        if(mp3Filled){
            while(mp3Filled<mp3Pass)mp3Samples[mp3Filled++]=0;
            int n=0;unsigned char *packet=shine_encode_buffer_interleaved(mp3Encoder,mp3Samples,&n);
            if(!mp3WritePacket(packet,n))ok=NO;
            mp3Filled=0;
        }
        int n=0;unsigned char *last=shine_flush(mp3Encoder,&n);
        if(!mp3WritePacket(last,n))ok=NO;
        shine_close(mp3Encoder);mp3Encoder=NULL;
    }
    if(mp3File){if(fflush(mp3File)!=0)ok=NO;if(fclose(mp3File)!=0)ok=NO;mp3File=NULL;}
    return ok;
}
static BOOL mp3Open(NSURL *url,unsigned sampleRate){
    shine_config_t config={0};
    config.wave.channels=PCM_MONO;config.wave.samplerate=(int)sampleRate;
    shine_set_config_mpeg_defaults(&config.mpeg);
    config.mpeg.mode=MONO;config.mpeg.bitr=128;
    if(shine_check_config(config.wave.samplerate,config.mpeg.bitr)<0)return NO;
    mp3Encoder=shine_initialise(&config);
    if(!mp3Encoder)return NO;
    mp3Pass=shine_samples_per_pass(mp3Encoder);mp3Filled=0;
    if(mp3Pass<=0||mp3Pass>SHINE_MAX_SAMPLES){shine_close(mp3Encoder);mp3Encoder=NULL;return NO;}
    mp3File=fopen(url.fileSystemRepresentation,"wb");
    if(!mp3File){shine_close(mp3Encoder);mp3Encoder=NULL;return NO;}
    return YES;
}
static void pump(void){
    uint32_t t=atomic_load(&mfRec.tail),h=atomic_load(&mfRec.head);
    while(t!=h){
        MFRecordBlock *b=&mfRec.blocks[t%MF_REC_SLOTS];
        if(!writerFailed){
            OSStatus e=wantsMP3?(mp3Push(b->samples,b->frames)?0:-1):mf_rec_write(encoder,b->samples,b->frames);
            if(e)writerFailed=YES;
            else {framesWritten+=b->frames;lastData=NSProcessInfo.processInfo.systemUptime;}
        }
        atomic_store(&mfRec.tail,++t);
    }
    NSInteger seconds=captureRate?(NSInteger)(framesWritten/captureRate):0;
    if(seconds!=lastSeconds){lastSeconds=seconds;[prefs setInteger:seconds forKey:@"MicFXRecordSeconds"];}
}
static void finishTake(void){
    if(atomic_load(&mfRec.writing))return;
    if(encoder||mp3File||mp3Encoder){
        pump();
        if(encoder){if(ExtAudioFileDispose(encoder))writerFailed=YES;encoder=NULL;}
        if(mp3File||mp3Encoder){if(!mp3Finish())writerFailed=YES;}
    }
    NSError *error=nil;
    BOOL saved=!writerFailed&&framesWritten&&[NSFileManager.defaultManager moveItemAtURL:scratchURL toURL:finalURL error:&error];
    if(saved)refreshList();
    else if(scratchURL)[NSFileManager.defaultManager removeItemAtURL:scratchURL error:nil];
    scratchURL=nil;finalURL=nil;
    if(saved)idle(finishReason?:@"Recording ready.");
    else if(writerFailed||error)idle(@"Could not save this recording. Check the available storage and try again.");
    else idle(@"No microphone audio arrived. Join a voice call and try again.");
}
static void advanceTake(void){
    NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
    if(phase==MFArming){
        if(now-lastData>5){stopTake(nil);return;}
        if(!atomic_load(&monitorStopped))return;
        captureRate=mf_rec_capture_rate();
        if(!captureRate){stopTake(nil);return;}
        finalURL=[folder URLByAppendingPathComponent:newName()];
        scratchURL=[finalURL URLByAppendingPathExtension:@"partial"];
        if(wantsMP3?!mp3Open(scratchURL,captureRate):mf_rec_open((__bridge CFURLRef)scratchURL,captureRate,&encoder)!=noErr){
            writerFailed=YES;stopTake(nil);return;
        }
        atomic_store(&mfRec.rate,captureRate);
        atomic_store(&mfRec.interrupted,false);
        atomic_store(&mfRec.armed,true);
        state(MFTaking,@"recording");
    }
    if(phase==MFTaking){
        BOOL first=framesWritten==0;
        pump();
        if(first&&framesWritten)status(atomic_load(&includeReceivedMusic)?(wantsMP3?@"Recording MP3: processed mic + received music.":@"Recording MP4: processed mic + received music."):(wantsMP3?@"Recording processed mic to MP3.":@"Recording your processed mic."));
        if(writerFailed||atomic_load(&mfRec.interrupted)||!mf_rec_capture_rate()||
           now-lastData>(framesWritten?3:5))stopTake(@"Saved up to the microphone interruption.");
    }
    if(phase==MFFinishing)finishTake();
}

// The preview owns its file while presented. Dismissal releases the monitor override.
@interface MFClipPreview : QLPreviewController <QLPreviewControllerDataSource>
@property(nonatomic,strong) NSURL *clip;
@property(nonatomic,copy) void (^finished)(void);
@end
@implementation MFClipPreview
-(NSInteger)numberOfPreviewItemsInPreviewController:(QLPreviewController *)c{return 1;}
-(id<QLPreviewItem>)previewController:(QLPreviewController *)c previewItemAtIndex:(NSInteger)i{return self.clip;}
-(void)viewDidDisappear:(BOOL)animated{
    [super viewDidDisappear:animated];
    if(self.isBeingDismissed||!self.presentingViewController){if(self.finished)self.finished();self.finished=nil;}
}
-(void)dealloc{if(_finished)_finished();}
@end

@interface MFClipPicker : UIDocumentPickerViewController <UIDocumentPickerDelegate>
@property(nonatomic,copy) void (^result)(NSString *);
@end
@implementation MFClipPicker
-(void)documentPicker:(UIDocumentPickerViewController *)c didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls{
    if(self.result)self.result(urls.count?@"Saved to Files.":@"Save cancelled.");self.result=nil;
}
-(void)documentPickerWasCancelled:(UIDocumentPickerViewController *)c{
    if(self.result)self.result(@"Save cancelled.");self.result=nil;
}
-(void)dealloc{if(_result)_result(@"Save closed.");}
@end

static UIViewController *frontController(void){
    for(UIScene *scene in UIApplication.sharedApplication.connectedScenes){
        if(scene.activationState!=UISceneActivationStateForegroundActive||![scene isKindOfClass:UIWindowScene.class])continue;
        for(UIWindow *window in ((UIWindowScene *)scene).windows){
            if(!window.isKeyWindow)continue;
            UIViewController *c=window.rootViewController;
            while(c.presentedViewController)c=c.presentedViewController;
            if(c.viewIfLoaded.window&&!c.isBeingDismissed&&!c.isBeingPresented)return c;
        }
    }
    return nil;
}
static void openClip(NSURL *url,BOOL play){
    state(MFPresenting,@"presenting");
    status(play?@"Listening to the saved clip.":@"Choose a folder in Files.");
    void (^done)(NSString *)=^(NSString *message){dispatch_async(worker,^{idle(message);});};
    dispatch_async(dispatch_get_main_queue(),^{
        UIViewController *front=frontController();
        if(!front){done(@"Open MicFX on screen and try again.");return;}
        if(play){
            if(![QLPreviewController canPreviewItem:url]){done(@"Preview unavailable. Use Save to Files to play the clip.");return;}
            MFClipPreview *p=[MFClipPreview new];p.clip=url;p.dataSource=p;p.finished=^{done(@"Recording ready.");};
            [front presentViewController:p animated:YES completion:nil];
        }else{
            MFClipPicker *p=[[MFClipPicker alloc] initForExportingURLs:@[url] asCopy:YES];
            p.result=done;p.delegate=p;[front presentViewController:p animated:YES completion:nil];
        }
    });
}
static void command(void){
    NSDictionary *c=[prefs dictionaryForKey:@"MicFXRecordCommand"];
    if(![c[@"session"] isEqual:session])return; // stale commands never start a recording after launch
    double seq=[c[@"id"] doubleValue];
    if(!isfinite(seq)||seq<=lastCommand)return;
    lastCommand=seq;
    NSString *action=c[@"action"];
    if([action isEqual:@"stop"]&&(phase==MFArming||phase==MFTaking)){stopTake(nil);return;}
    if(phase!=MFIdle)return;
    if([action isEqual:@"start"]){atomic_store(&includeReceivedMusic,[c[@"includeMusic"] integerValue]==1);wantsMP3=[c[@"format"] isEqualToString:@"mp3"];beginTake();return;}
    BOOL play=[action isEqual:@"play"];
    if(!play&&![action isEqual:@"save"])return;
    NSString *name=c[@"file"];
    if(![name isKindOfClass:NSString.class]||![name isEqual:name.lastPathComponent]||
       ![name hasPrefix:@"MicFX-"]||!([name.pathExtension isEqual:@"mp4"]||[name.pathExtension isEqual:@"mp3"]))return;
    NSURL *url=[folder URLByAppendingPathComponent:name];
    if(![NSFileManager.defaultManager fileExistsAtPath:url.path]){refreshList();status(@"This clip is no longer on this device.");return;}
    if(play){previewURL=url;atomic_store(&quietRequested,true);lastData=NSProcessInfo.processInfo.systemUptime;state(MFWaitingPreview,@"presenting");}
    else openClip(url,NO);
}
void mf_rec_service_start(int supported){
    hookAvailable=supported;
    worker=dispatch_queue_create("micfx.record.local",DISPATCH_QUEUE_SERIAL);
    dispatch_async(worker,^{
        prefs=NSUserDefaults.standardUserDefaults;
        NSURL *support=[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
        folder=[support URLByAppendingPathComponent:@"MicFX Recordings" isDirectory:YES];
        session=NSUUID.UUID.UUIDString;
        [prefs setObject:session forKey:@"MicFXRecordSession"];
        [prefs setObject:@"mp4,mp3" forKey:@"MicFXRecordFormats"];
        [prefs setInteger:1 forKey:@"MicFXRecordMixCapable"];
        [prefs setInteger:0 forKey:@"MicFXRecordSeconds"];
        for(NSURL *url in [NSFileManager.defaultManager contentsOfDirectoryAtURL:folder includingPropertiesForKeys:nil options:0 error:nil]){
            if([url.lastPathComponent hasPrefix:@"MicFX-"]&&[url.pathExtension isEqual:@"partial"])[NSFileManager.defaultManager removeItemAtURL:url error:nil];
        }
        refreshList();idle(@"Ready.");
        timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,worker);
        dispatch_source_set_timer(timer,DISPATCH_TIME_NOW,20*NSEC_PER_MSEC,4*NSEC_PER_MSEC);
        dispatch_source_set_event_handler(timer,^{@autoreleasepool{
            command();advanceTake();
            if(phase==MFWaitingPreview){
                if(atomic_load(&monitorStopped)){openClip(previewURL,YES);previewURL=nil;}
                else if(NSProcessInfo.processInfo.systemUptime-lastData>3){previewURL=nil;idle(@"Could not pause the mic monitor. Try again.");}
            }
        }});
        dispatch_resume(timer);
    });
}
