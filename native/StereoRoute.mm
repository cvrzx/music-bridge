#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

// These are the session configuration selectors exposed by WebRTC in 344.1.
@protocol MFSessionConfiguration <NSObject>
+ (instancetype)webRTCConfiguration;
+ (void)setWebRTCConfiguration:(id)configuration;
@property(nonatomic) NSInteger inputNumberOfChannels;
@end

extern "C" void mf_request_stereo_route(bool enabled) {
    static id<MFSessionConfiguration> owned;
    static NSInteger previous;
    Class<MFSessionConfiguration> cls = (Class)NSClassFromString(@"DiscordRTCAudioSessionConfiguration");
    if (![cls respondsToSelector:@selector(webRTCConfiguration)] ||
        ![cls respondsToSelector:@selector(setWebRTCConfiguration:)]) return;
    id<MFSessionConfiguration> configuration = [cls webRTCConfiguration];
    if (![configuration respondsToSelector:@selector(setInputNumberOfChannels:)] ||
        ![configuration respondsToSelector:@selector(inputNumberOfChannels)]) return;
    if (enabled && !owned) {
        previous = configuration.inputNumberOfChannels;
        configuration.inputNumberOfChannels = 2;
        [cls setWebRTCConfiguration:configuration];
        owned = configuration;
    } else if (!enabled && owned) {
        if (configuration == owned && configuration.inputNumberOfChannels == 2) {
            configuration.inputNumberOfChannels = previous;
            [cls setWebRTCConfiguration:configuration];
        }
        owned = nil;
    }
}

// Endcord loads local extensions from this directory. Use a link to the resource
// in this app, so the extension runs only while its matching IPA is installed.
extern "C" void mf_install_call_controls(void) {
    @autoreleasepool {
        NSFileManager *fm=NSFileManager.defaultManager;
        NSURL *script=[NSBundle.mainBundle URLForResource:@"MicFXCallControls" withExtension:@"js"];
        NSURL *documents=[fm URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].lastObject;
        if (!script || !documents) return;
        NSURL *dir=[documents URLByAppendingPathComponent:@"pyoncord/preloads" isDirectory:YES];
        if (![fm createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil]) return;
        NSString *path=[[dir URLByAppendingPathComponent:@"MicFXCallControls.js"] path];
        NSString *prior=[fm destinationOfSymbolicLinkAtPath:path error:nil];
        if ([prior isEqualToString:script.path]) return;
        if (prior && ![prior.lastPathComponent isEqualToString:@"MicFXCallControls.js"]) return;
        if (!prior && [fm fileExistsAtPath:path]) return;
        if (prior) [fm removeItemAtPath:path error:nil];
        [fm createSymbolicLinkAtPath:path withDestinationPath:script.path error:nil];
    }
}
