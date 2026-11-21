// Smoke test for the vendored Shine MP3 encoder; no Discord/Spotify access.
#include "../vendor/shine/layer3.h"
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(int argc,char **argv){
  if(argc!=2)return 2;
  shine_config_t cfg={0};
  cfg.wave.channels=PCM_MONO;cfg.wave.samplerate=48000;
  shine_set_config_mpeg_defaults(&cfg.mpeg);
  cfg.mpeg.mode=MONO;cfg.mpeg.bitr=128;
  if(shine_check_config(48000,128)<0)return 3;
  shine_t e=shine_initialise(&cfg);
  if(!e)return 4;
  int pass=shine_samples_per_pass(e);
  if(pass<=0||pass>SHINE_MAX_SAMPLES)return 5;
  FILE *f=fopen(argv[1],"wb");if(!f)return 6;
  int16_t pcm[SHINE_MAX_SAMPLES];int len=0;
  for(int frame=0;frame<48000;frame+=pass){
    for(int i=0;i<pass;i++){
      int t=frame+i;
      pcm[i]=(int16_t)(t<48000?sin(2.0*3.141592653589793*440.0*(double)t/48000.0)*12000.0:0);
    }
    unsigned char *data=shine_encode_buffer_interleaved(e,pcm,&len);
    if(len<0||(len>0&&fwrite(data,1,(size_t)len,f)!=(size_t)len))return 7;
  }
  unsigned char *tail=shine_flush(e,&len);
  if(len<0||(len>0&&fwrite(tail,1,(size_t)len,f)!=(size_t)len))return 8;
  shine_close(e);if(fclose(f)!=0)return 9;
  f=fopen(argv[1],"rb");if(!f)return 10;
  unsigned char bytes[4]={0};size_t n=fread(bytes,1,sizeof(bytes),f);
  fseek(f,0,SEEK_END);long total=ftell(f);fclose(f);
  if(n!=4||total<1000||bytes[0]!=0xff||(bytes[1]&0xe0)!=0xe0)return 11;
  printf("MP3 mono 48 kHz 128 kbps: %ld bytes, sync OK\n",total);
  return 0;
}
