/* Bridge reader protocol smoke test. Generated tone only, no Spotify content. */
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/stat.h>
#include <string.h>
#include "../native/MusicInput.h"
int main(void){
 char root[]="/tmp/micfx-reader-XXXXXX";
 if(!mkdtemp(root)){perror("mkdtemp");return 1;}
 char dir[1024],path[1200];
 snprintf(dir,sizeof(dir),"%s/MicFXBridgeTest-v1",root);
 if(mkdir(dir,0700)){perror("mkdir");return 2;}
 musicRead(root);
 if(atomic_load(&musicReadState)!=1){fprintf(stderr,"empty state incorrect\n");return 3;}
 MBPacket p;mb_fill(&p,5151,1,musicNow());
 snprintf(path,sizeof(path),"%s/slot-01.bin",dir);
 FILE*f=fopen(path,"wb");if(!f)return 4;
 if(fwrite(&p,1,sizeof(p),f)!=sizeof(p)){fclose(f);return 5;}
 fclose(f);
 musicRead(root);
 if(atomic_load(&musicPackets)!=1||atomic_load(&musicReadState)!=5){fprintf(stderr,"valid packet not read\n");return 6;}
 float v=0;for(int i=0;i<100;i++)v+=fabsf(musicNext(48000));
 if(v<.5f){fprintf(stderr,"audio ring has no samples\n");return 7;}
 musicRead(root);if(atomic_load(&musicPackets)!=1){fprintf(stderr,"duplicate packet counted\n");return 8;}
 p.seq=2;p.time_ms=musicNow()-3000;p.checksum=mb_hash(p.pcm);
 f=fopen(path,"wb");fwrite(&p,1,sizeof(p),f);fclose(f);
 musicRead(root);if(atomic_load(&musicReadState)!=3){fprintf(stderr,"stale packet not detected\n");return 9;}
 unlink(path);rmdir(dir);rmdir(root);
 printf("PASS valid reader, 48kHz samples, duplicate protection, stale detection\n");
 return 0;
}
