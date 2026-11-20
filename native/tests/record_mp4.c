#include "../RecordFile.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void check(OSStatus e,const char *operation){
    if(e){fprintf(stderr,"%s failed (%d)\n",operation,(int)e);exit(1);}
}
int main(int argc,char **argv){
    assert(argc==2);
    CFURLRef url=CFURLCreateFromFileSystemRepresentation(NULL,(const UInt8*)argv[1],strlen(argv[1]),false);
    unsigned rates[]={8000,16000,44100,48000,96000};
    for(unsigned i=0;i<sizeof(rates)/sizeof(rates[0]);i++){
        unsigned rate=rates[i];
        ExtAudioFileRef file=NULL;
        check(mf_rec_open(url,rate,&file),"create MP4");
        for(unsigned n=0;n<rate;){
            float x[512];unsigned len=rate-n<512?rate-n:512;
            for(unsigned k=0;k<len;k++)x[k]=.2f*sinf(2.f*3.14159265f*440.f*(n+k)/rate);
            check(mf_rec_write(file,x,len),"write samples");n+=len;
        }
        check(ExtAudioFileDispose(file),"finish MP4");
        AudioFileID af;check(AudioFileOpenURL(url,kAudioFileReadPermission,0,&af),"open MP4");
        AudioFileTypeID type;UInt32 size=sizeof(type);check(AudioFileGetProperty(af,kAudioFilePropertyFileFormat,&size,&type),"container");assert(type==kAudioFileMPEG4Type);
        AudioStreamBasicDescription format;size=sizeof(format);check(AudioFileGetProperty(af,kAudioFilePropertyDataFormat,&size,&format),"AAC format");
        assert(format.mFormatID==kAudioFormatMPEG4AAC&&format.mChannelsPerFrame==1);
        AudioFileClose(af);
        check(ExtAudioFileOpenURL(url,&file),"reopen for decoding");
        AudioStreamBasicDescription pcm={.mSampleRate=48000,.mFormatID=kAudioFormatLinearPCM,.mFormatFlags=kAudioFormatFlagsNativeFloatPacked,.mBytesPerPacket=4,.mFramesPerPacket=1,.mBytesPerFrame=4,.mChannelsPerFrame=1,.mBitsPerChannel=32};
        check(ExtAudioFileSetProperty(file,kExtAudioFileProperty_ClientDataFormat,sizeof(pcm),&pcm),"decode format");
        unsigned count=0;double power=0;
        for(;;){float x[512];UInt32 len=512;AudioBufferList list={.mNumberBuffers=1,.mBuffers={{1,sizeof(x),x}}};
            check(ExtAudioFileRead(file,&len,&list),"decode samples");if(!len)break;
            for(unsigned k=0;k<len;k++)power+=x[k]*x[k];count+=len;}
        check(ExtAudioFileDispose(file),"close decoded file");
        assert(count>44500&&count<52000&&power/count>.01&&power/count<.04);
        printf("%u Hz mic -> mono AAC in MPEG-4: %u decoded frames\n",rate,count);
    }
    CFRelease(url);return 0;
}
