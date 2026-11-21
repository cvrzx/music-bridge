#ifndef MICFX_RECORD_BUFFER_H
#define MICFX_RECORD_BUFFER_H
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>

#define MF_REC_SLOTS 64u
#define MF_REC_FRAMES 4096u
typedef struct { unsigned frames; float samples[MF_REC_FRAMES]; } MFRecordBlock;
typedef struct {
    _Atomic bool armed, writing, interrupted;
    _Atomic uint32_t head,tail;
    _Atomic unsigned rate;
    MFRecordBlock blocks[MF_REC_SLOTS];
} MFRecordBuffer;
extern MFRecordBuffer mfRec;

// Only the serialized mic render callback produces data; only the recorder worker consumes it.
static inline MFRecordBlock *mf_rec_begin(unsigned n,unsigned sr){
    if(!atomic_load(&mfRec.armed))return 0;
    atomic_store(&mfRec.writing,true);
    uint32_t h=atomic_load(&mfRec.head);
    if(!atomic_load(&mfRec.armed)||atomic_load(&mfRec.interrupted))goto skip;
    if(!n||n>MF_REC_FRAMES||sr!=atomic_load(&mfRec.rate)||h-atomic_load(&mfRec.tail)>=MF_REC_SLOTS){
        atomic_store(&mfRec.interrupted,true);
        goto skip;
    }
    MFRecordBlock *b=&mfRec.blocks[h%MF_REC_SLOTS];b->frames=n;return b;
skip:
    atomic_store(&mfRec.writing,false);
    return 0;
}
static inline void mf_rec_publish(void){
    atomic_fetch_add(&mfRec.head,1);
    atomic_store(&mfRec.writing,false);
}

int mf_rec_wants_quiet(void);
int mf_rec_wants_music(void);
void mf_rec_monitor_ack(int quiet);
unsigned mf_rec_capture_rate(void);
void mf_rec_service_start(int supported);
#endif
