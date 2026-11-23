#import <Foundation/Foundation.h>
#import <ReplayKit/ReplayKit.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
// Only correct the picker in the Discord host, never create or start a broadcast.
static void (*originalPreferred)(id,SEL,NSString *);
static id (*originalInitFrame)(id,SEL,CGRect);
static NSString *actualExtensionID(void){
    NSBundle *bundle=NSBundle.mainBundle;
    NSString *plist=[bundle.builtInPlugInsPath stringByAppendingPathComponent:@"BroadcastUpload.appex/Info.plist"];
    NSDictionary *info=[NSDictionary dictionaryWithContentsOfFile:plist];
    NSString *identifier=info[@"CFBundleIdentifier"];
    if(![identifier isKindOfClass:NSString.class]||!identifier.length)return nil;
    return identifier;
}
static void setPreferred(id self,SEL cmd,NSString *requested){
    NSString *actual=actualExtensionID();
    NSString *effective=requested;
    if(actual.length&&(!requested.length||[requested isEqualToString:@"null"]||[requested hasPrefix:@"com.hammerandchisel.discord"]))effective=actual;
    [NSUserDefaults.standardUserDefaults setObject:actual?:@"BroadcastUpload extension missing" forKey:@"MicFXScreenShareExtensionID"];
    [NSUserDefaults.standardUserDefaults setObject:effective?:@"No extension selected" forKey:@"MicFXScreenSharePickerTarget"];
    originalPreferred(self,cmd,effective);
}
static id initFrame(id self,SEL cmd,CGRect frame){
    id picker=originalInitFrame(self,cmd,frame);
    NSString *actual=actualExtensionID();
    if(picker&&actual.length)[(RPSystemBroadcastPickerView*)picker setPreferredExtension:actual];
    return picker;
}
static void installPicker(void){
    Class cls=NSClassFromString(@"RPSystemBroadcastPickerView");
    if(!cls||!actualExtensionID())return;
    SEL sel=@selector(setPreferredExtension:);
    Method m=class_getInstanceMethod(cls,sel);
    if(m&&method_getNumberOfArguments(m)==3){
        originalPreferred=(void*)method_getImplementation(m);
        if(originalPreferred){
            if(!class_addMethod(cls,sel,(IMP)setPreferred,method_getTypeEncoding(m)))method_setImplementation(m,(IMP)setPreferred);
        }
    }
    sel=@selector(initWithFrame:);m=class_getInstanceMethod(cls,sel);
    if(originalPreferred&&m&&method_getNumberOfArguments(m)==3){
        originalInitFrame=(void*)method_getImplementation(m);
        if(originalInitFrame){
            if(!class_addMethod(cls,sel,(IMP)initFrame,method_getTypeEncoding(m)))method_setImplementation(m,(IMP)initFrame);
        }
    }
    [NSUserDefaults.standardUserDefaults setObject:actualExtensionID()?:@"Unavailable" forKey:@"MicFXScreenShareExtensionID"];
}
__attribute__((constructor)) static void initializePicker(void){
    dispatch_async(dispatch_get_main_queue(),^{@autoreleasepool{installPicker();}});
}
