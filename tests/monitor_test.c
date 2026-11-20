/* Deterministic monitor ring test; does not open the microphone or audio output. */
#include <stdio.h>
#include <math.h>
#include "../native/MicMonitor.h"
int main(void){
    if(atomic_load(&monFeedOn)||atomic_load(&monRunning)){fprintf(stderr,"monitor not off by default\n");return 1;}
    for(unsigned i=0;i<960;i++){
        float x=(i==0)?2.f:(i==1)?-2.f:.25f;
        mon_store_sample(i,x);
    }
    mon_publish_samples(0,960);
    if(atomic_load(&monWrite)!=960){fprintf(stderr,"samples not published\n");return 2;}
    if(monRing[0]!=32767||monRing[1]!=-32768){fprintf(stderr,"PCM clipping invalid\n");return 3;}
    if(monRing[2] < 8000 || monRing[2]>8300){fprintf(stderr,"PCM conversion invalid\n");return 4;}
    printf("PASS default-off live monitor, PCM clipping, ring publication\n");
    return 0;
}
