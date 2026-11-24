#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <stdatomic.h>
extern int mf_voice_capture_active(void);
// Restore the user's existing built-in speaker selection on returning to a call.
// No changes to Discord buttons, URLs, microphone, recording or external routes.
static BOOL wantedSpeaker, restorePending;
static NSUInteger generation;
static BOOL builtInOnly(AVAudioSession *s){
    NSArray<AVAudioSessionPortDescription*> *outputs=s.currentRoute.outputs;
    if(!outputs.count)return NO;
    for(AVAudioSessionPortDescription *p in outputs)
        if(![p.portType isEqualToString:AVAudioSessionPortBuiltInReceiver]&&
           ![p.portType isEqualToString:AVAudioSessionPortBuiltInSpeaker])return NO;
    return YES;
}
static BOOL speakerOn(AVAudioSession *s){
    for(AVAudioSessionPortDescription *p in s.currentRoute.outputs)
        if([p.portType isEqualToString:AVAudioSessionPortBuiltInSpeaker])return YES;
    return NO;
}
static void snapshot(void){
    AVAudioSession *s=AVAudioSession.sharedInstance;
    generation++;restorePending=NO;
    wantedSpeaker=mf_voice_capture_active()&&
        [s.category isEqualToString:AVAudioSessionCategoryPlayAndRecord]&&builtInOnly(s)&&speakerOn(s);
    [NSUserDefaults.standardUserDefaults setBool:wantedSpeaker forKey:@"MicFXSpeakerSaved"];
}
static void restore(NSUInteger token,BOOL final){
    if(token!=generation||!restorePending)return;
    AVAudioSession *s=AVAudioSession.sharedInstance;
    if(!builtInOnly(s)){restorePending=NO;return;}
    if(mf_voice_capture_active()&&[s.category isEqualToString:AVAudioSessionCategoryPlayAndRecord]){
        if(!speakerOn(s)){
            NSError *error=nil;
            BOOL ok=[s overrideOutputAudioPort:AVAudioSessionPortOverrideSpeaker error:&error];
            [NSUserDefaults.standardUserDefaults setObject:ok?@"Restored speaker on foreground":error.localizedDescription?:@"Speaker restore denied" forKey:@"MicFXSpeakerRestoreStatus"];
        }
        // Once restored, let all subsequent user route selections take precedence.
        if(speakerOn(s)){restorePending=NO;return;}
    }
    if(final)restorePending=NO;
}
static void resume(void){
    if(!wantedSpeaker)return;
    wantedSpeaker=NO;restorePending=YES;
    NSUInteger token=++generation;
    for(NSNumber *delay in @[@0.15,@0.55,@1.3]){
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay.doubleValue*NSEC_PER_SEC)),dispatch_get_main_queue(),^{restore(token,delay.doubleValue>1);});
    }
}
void mf_speaker_resume_install(void){
    dispatch_async(dispatch_get_main_queue(),^{
        NSNotificationCenter *nc=NSNotificationCenter.defaultCenter;
        [nc addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *n){snapshot();}];
        [nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *n){resume();}];
        [nc addObserverForName:AVAudioSessionRouteChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n){
            NSUInteger reason=[n.userInfo[AVAudioSessionRouteChangeReasonKey] unsignedIntegerValue];
            // Never fight a manual override or a connected headset while restoring.
            if(restorePending&&(reason==AVAudioSessionRouteChangeReasonOverride||!builtInOnly(AVAudioSession.sharedInstance)))restorePending=NO;
        }];
    });
}
