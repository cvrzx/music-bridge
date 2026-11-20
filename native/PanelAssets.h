#ifndef MICFX_PANEL_ASSETS_H
#define MICFX_PANEL_ASSETS_H
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <string.h>
#include <stdint.h>

// Unsigned builds reserve storage for the owner's locally supplied panel images.
// Packaged before iOS code signing. An empty bank has zero image sizes.
#define MF_PANEL_CAPACITY (1024u*1024u)
static const volatile struct {
    char label[32];
    uint32_t sizes[9];
    unsigned char bytes[MF_PANEL_CAPACITY];
} panelBank __attribute__((section("__TEXT,__micfx_panels"),aligned(4),used))={"MicFX panel images v1",{0},{0}};

static int panel_cache(char *dir,size_t size){
    static const char *names[]={"drumBg","toneBg","big","little","drumName","high","mid","low","output"};
    size_t total=0;
    for(unsigned i=0;i<9;i++){
        size_t n=panelBank.sizes[i];
        if(n<8||n>MF_PANEL_CAPACITY-total)return 0;
        total+=n;
    }
    const char *home=getenv("HOME");
    if(!home||!*home)return 0;
    int len=snprintf(dir,size,"%s/Library/Caches/MicFXPanels-v46",home);
    if(len<1||(size_t)len>=size)return 0;
    mkdir(dir,0700);
    size_t offset=0;
    for(unsigned i=0;i<9;i++){
        char path[1200],tmp[1208];
        if(snprintf(path,sizeof(path),"%s/%s.png",dir,names[i])>=(int)sizeof(path))return 0;
        snprintf(tmp,sizeof(tmp),"%s.tmp",path);
        const size_t n=panelBank.sizes[i];
        FILE *file=fopen(tmp,"wb");
        if(!file)return 0;
        size_t written=fwrite((const void*)(panelBank.bytes+offset),1,n,file);
        int closed=fclose(file);
        if(written!=n||closed!=0||rename(tmp,path)!=0){remove(tmp);return 0;}
        offset+=n;
    }
    return 1;
}
#endif
