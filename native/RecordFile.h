#ifndef MICFX_RECORD_FILE_H
#define MICFX_RECORD_FILE_H
#include <AudioToolbox/AudioToolbox.h>

// ExtAudioFile owns conversion and writes actual MPEG-4 container metadata on close.
static inline OSStatus mf_rec_open(CFURLRef url, unsigned rate, ExtAudioFileRef *out){
    AudioStreamBasicDescription aac={0},pcm={0};
    aac.mSampleRate=48000;
    aac.mFormatID=kAudioFormatMPEG4AAC;
    aac.mChannelsPerFrame=1;
    UInt32 bytes=sizeof(aac);
    OSStatus e=AudioFormatGetProperty(kAudioFormatProperty_FormatInfo,0,NULL,&bytes,&aac);
    if(e)return e;
    e=ExtAudioFileCreateWithURL(url,kAudioFileMPEG4Type,&aac,NULL,kAudioFileFlags_EraseFile,out);
    if(e)return e;
    pcm.mFormatID=kAudioFormatLinearPCM;pcm.mFormatFlags=kAudioFormatFlagsNativeFloatPacked;
    pcm.mSampleRate=rate;pcm.mChannelsPerFrame=1;pcm.mFramesPerPacket=1;
    pcm.mBitsPerChannel=32;pcm.mBytesPerPacket=pcm.mBytesPerFrame=sizeof(float);
    e=ExtAudioFileSetProperty(*out,kExtAudioFileProperty_ClientDataFormat,sizeof(pcm),&pcm);
    if(e){ExtAudioFileDispose(*out);*out=NULL;}
    return e;
}
static inline OSStatus mf_rec_write(ExtAudioFileRef file,float *samples,unsigned count){
    AudioBufferList list={.mNumberBuffers=1,.mBuffers={{1,count*(UInt32)sizeof(float),samples}}};
    return ExtAudioFileWrite(file,count,&list);
}
#endif
