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
