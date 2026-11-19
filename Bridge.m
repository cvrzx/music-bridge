#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import "BridgePacket.h"

static uint64_t nowms(void){return (uint64_t)(NSDate.date.timeIntervalSince1970*1000.0);}
static void u16(NSMutableData *d,uint16_t x){[d appendBytes:&x length:2];}
static void u32(NSMutableData *d,uint32_t x){[d appendBytes:&x length:4];}
static NSData *toneWav(void){MBPacket p;mb_fill(&p,1,1,1);NSMutableData *d=[NSMutableData data];[d appendBytes:"RIFF" length:4];u32(d,36+MB_RATE*2);[d appendBytes:"WAVEfmt " length:8];u32(d,16);u16(d,1);u16(d,1);u32(d,MB_RATE);u32(d,MB_RATE*2);u16(d,2);u16(d,16);[d appendBytes:"data" length:4];u32(d,MB_RATE*2);for(int i=0;i<10;i++)[d appendBytes:p.pcm length:sizeof(p.pcm)];return d;}

@interface BridgeVC : UIViewController
@property (nonatomic, strong) UITextField *group;
@property (nonatomic, strong) UITextView *report;
@property (nonatomic, strong) UILabel *status;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) AVAudioPlayer *player;
@property (nonatomic, strong) NSURL *dir;
@property (nonatomic, strong) NSString *role;
@property uint64_t session,seq,last,received,missed,maxAge,ageSum;
@property BOOL running;
@property (nonatomic, strong) NSString *accessResult;
@end
@implementation BridgeVC
- (UIButton *)button:(NSString *)name action:(SEL)a {UIButton *b=[UIButton buttonWithType:UIButtonTypeSystem];[b setTitle:name forState:UIControlStateNormal];b.titleLabel.font=[UIFont boldSystemFontOfSize:16];b.backgroundColor=UIColor.secondarySystemGroupedBackgroundColor;b.layer.cornerRadius=12;[b.heightAnchor constraintEqualToConstant:44].active=YES;[b addTarget:self action:a forControlEvents:UIControlEventTouchUpInside];return b;}
- (void)viewDidLoad {[super viewDidLoad];self.view.backgroundColor=UIColor.systemGroupedBackgroundColor;self.role=[NSBundle.mainBundle objectForInfoDictionaryKey:@"BridgeRole"]?:@"sender";self.accessResult=@"Not checked";
 UIStackView *s=[[UIStackView alloc]init];s.axis=UILayoutConstraintAxisVertical;s.spacing=12;s.translatesAutoresizingMaskIntoConstraints=NO;[self.view addSubview:s];UILayoutGuide *g=self.view.safeAreaLayoutGuide;[NSLayoutConstraint activateConstraints:@[[s.topAnchor constraintEqualToAnchor:g.topAnchor constant:16],[s.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:18],[s.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-18],[s.bottomAnchor constraintLessThanOrEqualToAnchor:g.bottomAnchor constant:-12]]];
 UILabel *title=[UILabel new];title.font=[UIFont boldSystemFontOfSize:29];title.text=[self.role isEqual:@"sender"]?@"Bridge Sender":@"Bridge Receiver";[s addArrangedSubview:title];
 UILabel *desc=[UILabel new];desc.font=[UIFont systemFontOfSize:14];desc.numberOfLines=0;desc.text=@"Local test only. Generated 440 Hz tone; no microphone, Spotify or network access.";[s addArrangedSubview:desc];
 self.group=[UITextField new];self.group.borderStyle=UITextBorderStyleRoundedRect;self.group.autocapitalizationType=UITextAutocapitalizationTypeNone;self.group.autocorrectionType=UITextAutocorrectionTypeNo;self.group.placeholder=@"Enter authorized group ID";self.group.text=[NSUserDefaults.standardUserDefaults stringForKey:@"bridgeGroup"]?:@"";[s addArrangedSubview:self.group];
 [s addArrangedSubview:[self button:@"Check group access" action:@selector(checkTap)]];
 [s addArrangedSubview:[self button:@"Start test" action:@selector(startTap)]];
 [s addArrangedSubview:[self button:@"Stop test" action:@selector(stopTap)]];
 self.status=[UILabel new];self.status.numberOfLines=0;self.status.font=[UIFont boldSystemFontOfSize:15];self.status.text=@"Ready";[s addArrangedSubview:self.status];
 self.report=[UITextView new];self.report.editable=NO;self.report.font=[UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];self.report.layer.cornerRadius=10;[self.report.heightAnchor constraintGreaterThanOrEqualToConstant:120].active=YES;[self.report.heightAnchor constraintLessThanOrEqualToConstant:220].active=YES;[s addArrangedSubview:self.report];[s addArrangedSubview:[self button:@"Copy report" action:@selector(copyTap)]];[self updateReport];
 [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(interrupted:) name:AVAudioSessionInterruptionNotification object:nil];}
- (void)interrupted:(NSNotification *)n {if(self.running&&[self.role isEqual:@"sender"]&&[n.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue]==AVAudioSessionInterruptionTypeBegan){[self stopTap];self.status.text=@"Audio interrupted; test stopped";[self updateReport];}}
- (BOOL)checkGroup {NSString *name=[self.group.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];if(![name hasPrefix:@"group."]){self.accessResult=@"Enter a valid group ID";return NO;}[NSUserDefaults.standardUserDefaults setObject:name forKey:@"bridgeGroup"];NSFileManager *fm=NSFileManager.defaultManager;NSURL *root=[fm containerURLForSecurityApplicationGroupIdentifier:name];if(!root){self.accessResult=@"DENIED: shared container unavailable";return NO;}self.dir=[root URLByAppendingPathComponent:@"MicFXBridgeTest-v1" isDirectory:YES];NSError *err=nil;if(![fm createDirectoryAtURL:self.dir withIntermediateDirectories:YES attributes:nil error:&err]){self.accessResult=[@"DENIED: " stringByAppendingString:err.localizedDescription?:@"mkdir failed"];return NO;}NSURL *probe=[self.dir URLByAppendingPathComponent:[NSString stringWithFormat:@"probe-%@.txt",NSUUID.UUID.UUIDString]];NSData *bytes=[@"bridge-probe" dataUsingEncoding:NSUTF8StringEncoding];if(![bytes writeToURL:probe options:NSDataWritingAtomic error:&err]){self.accessResult=[@"WRITE FAILED: " stringByAppendingString:err.localizedDescription?:@"unknown"];return NO;}BOOL same=[[NSData dataWithContentsOfURL:probe] isEqualToData:bytes];[fm removeItemAtURL:probe error:nil];self.accessResult=same?@"PASS: group read/write":@"FAIL: group readback";return same;}
- (void)checkTap {[self.view endEditing:YES];if(self.running)return;[self checkGroup];self.status.text=self.accessResult;[self updateReport];}
- (void)startTap {[self.view endEditing:YES];if(self.running)return;if(![self checkGroup]){self.status.text=self.accessResult;[self updateReport];return;}self.seq=0;self.last=0;self.received=0;self.missed=0;self.maxAge=0;self.ageSum=0;self.session=0;
 if([self.role isEqual:@"sender"]){NSError *err=nil;AVAudioSession *a=AVAudioSession.sharedInstance;if(![a setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault options:AVAudioSessionCategoryOptionMixWithOthers error:&err]||![a setActive:YES error:&err]){self.status.text=err.localizedDescription?:@"Audio session failed";[self updateReport];return;}self.player=[[AVAudioPlayer alloc]initWithData:toneWav() error:&err];self.player.numberOfLoops=-1;self.player.volume=0.08;if(!self.player||![self.player play]){[a setActive:NO error:nil];self.status.text=err.localizedDescription?:@"Tone playback failed";[self updateReport];return;}self.session=(((uint64_t)arc4random()<<32)|arc4random())?:1;}
 self.running=YES;self.status.text=[self.role isEqual:@"sender"]?@"Sending generated tone — switch apps":@"Listening for fresh packets";self.timer=[NSTimer timerWithTimeInterval:[self.role isEqual:@"sender"]?0.1:0.05 target:self selector:@selector(tick) userInfo:nil repeats:YES];[NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];[self tick];}
- (NSURL *)slot:(NSUInteger)i {return [self.dir URLByAppendingPathComponent:[NSString stringWithFormat:@"slot-%02lu.bin",(unsigned long)i]];}
- (void)tick {if(!self.running)return;if([self.role isEqual:@"sender"]){if(!self.player.isPlaying){[self stopTap];self.status.text=@"Tone playback stopped";[self updateReport];return;}MBPacket p;mb_fill(&p,self.session,++self.seq,nowms());NSError *e=nil;NSData *d=[NSData dataWithBytes:&p length:sizeof(p)];if(![d writeToURL:[self slot:p.seq%MB_SLOTS] options:NSDataWritingAtomic error:&e]){[self stopTap];self.status.text=e.localizedDescription?:@"Packet write failed";[self updateReport];return;}}
 else {uint64_t now=nowms();NSMutableArray<NSData *> *fresh=[NSMutableArray array];uint64_t newestTime=0,newSession=0;for(NSUInteger i=0;i<MB_SLOTS;i++){NSData *d=[NSData dataWithContentsOfURL:[self slot:i]];if(d.length!=sizeof(MBPacket))continue;MBPacket p;[d getBytes:&p length:sizeof(p)];if(!mb_valid(&p)||p.time_ms>now||now-p.time_ms>1500)continue;[fresh addObject:d];if(p.time_ms>newestTime){newestTime=p.time_ms;newSession=p.session;}}
 if(newSession&&newSession!=self.session){self.session=newSession;self.last=0;self.received=0;self.missed=0;self.maxAge=0;self.ageSum=0;}
 [fresh sortUsingComparator:^NSComparisonResult(NSData *a,NSData *b){MBPacket pa,pb;[a getBytes:&pa length:sizeof(pa)];[b getBytes:&pb length:sizeof(pb)];return pa.seq<pb.seq?NSOrderedAscending:pa.seq>pb.seq?NSOrderedDescending:NSOrderedSame;}];for(NSData *d in fresh){MBPacket p;[d getBytes:&p length:sizeof(p)];if(p.session!=self.session||p.seq<=self.last)continue;if(self.last&&p.seq>self.last+1)self.missed+=p.seq-self.last-1;self.last=p.seq;self.received++;uint64_t age=now-p.time_ms;self.ageSum+=age;self.maxAge=MAX(self.maxAge,age);}self.status.text=newestTime&&now-newestTime<350?@"LIVE: valid generated audio packets":@"Waiting / sender paused";}
 if(UIApplication.sharedApplication.applicationState==UIApplicationStateActive)[self updateReport];}
- (void)stopTap {self.running=NO;[self.timer invalidate];self.timer=nil;if(self.player){[self.player stop];self.player=nil;[AVAudioSession.sharedInstance setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];}self.status.text=@"Stopped";[self updateReport];}
- (void)updateReport {NSString *avg=self.received?[NSString stringWithFormat:@"%.1f ms",(double)self.ageSum/self.received]:@"n/a";self.report.text=[NSString stringWithFormat:@"Music Bridge Probe 1\nRole: %@\nGroup: %@\nAccess: %@\nStatus: %@\nPacket: 48 kHz / 16-bit mono / 100 ms\nSent: %llu\nReceived: %llu\nSequence gaps: %llu\nMean packet age: %@\nMax packet age: %llu ms",self.role,self.group.text?:@"",self.accessResult,self.status.text?:@"",(unsigned long long)self.seq,(unsigned long long)self.received,(unsigned long long)self.missed,avg,(unsigned long long)self.maxAge];}
- (void)copyTap {[self updateReport];UIPasteboard.generalPasteboard.string=self.report.text;}
@end
@interface BridgeDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end
@implementation BridgeDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {self.window=[[UIWindow alloc]initWithFrame:UIScreen.mainScreen.bounds];self.window.rootViewController=[BridgeVC new];[self.window makeKeyAndVisible];return YES;}
@end
int main(int argc,char **argv){@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(BridgeDelegate.class));}}
