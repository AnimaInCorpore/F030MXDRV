; Minimal GEMDOS/XBIOS bindings used by the scaffold.

        macro   Cconin
        move.w  #1,-(sp)
        trap    #1
        addq.l  #2,sp
        endm

        macro   Cconws string
        pea     \1
        move.w  #9,-(sp)
        trap    #1
        addq.l  #6,sp
        endm

        macro   Pterm0
        clr.w   -(sp)
        trap    #1
        endm

        macro   Dsp_Unlock
        move.w  #105,-(sp)
        trap    #14
        addq.l  #2,sp
        endm

        macro   Dsp_Reserve xwords,ywords
        move.l  \2,-(sp)
        move.l  \1,-(sp)
        move.w  #107,-(sp)
        trap    #14
        lea     10(sp),sp
        endm

        macro   Dsp_LoadProgram filename,ability,buffer
        pea     \3
        move.w  \2,-(sp)
        pea     \1
        move.w  #108,-(sp)
        trap    #14
        lea     12(sp),sp
        endm

; Transfer 24-bit DSP words held in 32-bit 68030 slots. Dsp_BlkWords (XBIOS
; 123) is not suitable here: it expands 16-bit CPU words to DSP words.
        macro   Dsp_BlkUnpacked input,input_count,output,output_count
        move.l  \4,-(sp)
        pea     \3
        move.l  \2,-(sp)
        pea     \1
        move.w  #98,-(sp)
        trap    #14
        lea     18(sp),sp
        endm
