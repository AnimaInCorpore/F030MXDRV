        include "xbios.i"
        include "protocol.i"
        include "ym2151_reference.i"

        global  start

DSP_X_WORDS     equ     8192
DSP_Y_WORDS     equ     8192
DSP_ABILITY     equ     3
DSP_LOAD_BUFFER equ     40000

        text

start:
        Cconws  banner

        Dsp_Reserve #DSP_X_WORDS,#DSP_Y_WORDS
        tst.l   d0
        bmi     reserve_failed

        Dsp_LoadProgram dsp_filename,#DSP_ABILITY,dsp_load_buffer
        tst.l   d0
        bne     load_failed

        move.l  #DSP_CMD_PING,d0
        bsr     dsp_exchange
        cmp.l   #DSP_REPLY_HELLO,d0
        bne     protocol_failed

        moveq   #0,d0                  ; MXDRV call $00: reset
        bsr     mxdrv_call
        cmp.l   #DSP_REPLY_OK,d0
        bne     protocol_failed

        moveq   #$1b,d1                ; exercise the MXDRV WriteOPM seam
        moveq   #0,d2
        bsr     mxdrv_write_ym2151
        cmp.l   #DSP_REPLY_OK,d0
        bne     protocol_failed

        ; Configure the exact MAME oracle tuple: channel 0, note C4,
        ; DT1=0, MUL=1, DT2=0. Then compare the DSP's phase step.
        moveq   #$28,d1
        moveq   #$4c,d2
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     protocol_failed

        moveq   #$30,d1
        moveq   #0,d2
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     protocol_failed

        moveq   #$40,d1
        moveq   #1,d2
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     protocol_failed

        moveq   #-$40,d1               ; low byte is register $c0
        moveq   #0,d2
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     protocol_failed

        moveq   #0,d1
        moveq   #0,d2
        bsr     mxdrv_query_phase_step
        cmp.l   #YM_REF_PHASE_CH0_OP0,d0
        bne     protocol_failed

        ; Replay the oracle's all-carriers attack setup through the real
        ; MXDRV WriteOPM seam, then compare DSP samples at four boundaries.
        bsr     mxdrv_reset
        tst.l   d0
        bne     protocol_failed
        lea     attack_trace(pc),a3
        moveq   #27,d3
.write_attack_trace:
        moveq   #0,d1
        moveq   #0,d2
        move.b  (a3)+,d1
        move.b  (a3)+,d2
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     protocol_failed
        dbra    d3,.write_attack_trace

        ; Call $10 from the ported 32-entry dispatcher exposes OPMBuf.
        moveq   #$10,d0
        bsr     mxdrv_call
        move.l  d0,a0
        cmpi.b  #$78,$08(a0)
        bne     protocol_failed

        moveq   #3,d3                  ; samples 0..2
        bsr     clock_samples
        move.l  d0,d4
        moveq   #0,d1
        bsr     mxdrv_query_envelope
        cmpi.l  #$1ff,d0
        bne     protocol_failed
        move.l  d4,d0
        cmp.l   #YM_REF_ATTACK_2_LEFT,d0
        bne     protocol_failed
        bsr     mxdrv_query_right
        cmp.l   #YM_REF_ATTACK_2_RIGHT,d0
        bne     protocol_failed

        moveq   #12,d3                 ; samples 3..14
        bsr     clock_samples
        cmp.l   #YM_REF_ATTACK_14_LEFT,d0
        bne     protocol_failed
        bsr     mxdrv_query_right
        cmp.l   #YM_REF_ATTACK_14_RIGHT,d0
        bne     protocol_failed

        moveq   #26,d3                 ; samples 15..40
        bsr     clock_samples
        cmp.l   #YM_REF_ATTACK_40_LEFT,d0
        bne     protocol_failed
        bsr     mxdrv_query_right
        cmp.l   #YM_REF_ATTACK_40_RIGHT,d0
        bne     protocol_failed

        moveq   #23,d3                 ; samples 41..63
        bsr     clock_samples
        cmp.l   #YM_REF_ATTACK_63_LEFT,d0
        bne     protocol_failed
        bsr     mxdrv_query_right
        cmp.l   #YM_REF_ATTACK_63_RIGHT,d0
        bne     protocol_failed

        ; Reset and replay the same voice through every connection algorithm,
        ; now with operator-1 feedback level 4. The generated table contains
        ; exact ymfm sample-63 results for left and right.
        lea     algorithm_references(pc),a4
        moveq   #0,d5
.algorithm_loop:
        bsr     mxdrv_reset
        tst.l   d0
        bne     protocol_failed
        lea     attack_trace(pc),a3
        moveq   #27,d3
.write_algorithm_trace:
        moveq   #0,d1
        moveq   #0,d2
        move.b  (a3)+,d1
        move.b  (a3)+,d2
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     protocol_failed
        dbra    d3,.write_algorithm_trace

        moveq   #$20,d1
        moveq   #-$20,d2               ; $e0: both pans, feedback level 4
        or.b    d5,d2
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     protocol_failed

        moveq   #64,d3
        bsr     clock_samples
        cmp.l   (a4)+,d0
        bne     protocol_failed
        bsr     mxdrv_query_right
        cmp.l   (a4)+,d0
        bne     protocol_failed

        addq.b  #1,d5
        cmpi.b  #8,d5
        bcs     .algorithm_loop

        ; Unique completion marker for the non-interactive Hatari trace gate.
        move.l  #DSP_CMD_PING+$c0de,d0
        bsr     dsp_exchange
        cmp.l   #DSP_REPLY_HELLO,d0
        bne     protocol_failed

        Cconws  ready_text
        Cconin
        bra     clean_exit

protocol_failed:
        Cconws  protocol_error_text
        Cconin
        bra     clean_exit

load_failed:
        Cconws  load_error_text
        Cconin

clean_exit:
        Dsp_Unlock
        Pterm0

reserve_failed:
        Cconws  reserve_error_text
        Cconin
        Pterm0

; Clock d3 samples and return the final left sample.
clock_samples:
        bsr     mxdrv_clock_sample
        subq.w  #1,d3
        bne     clock_samples
        rts

        data

banner:
        dc.b    27,'E','F030MXDRV DSP core',13,10
        dc.b    '68030 MXDRV host + DSP56001 YM2151',13,10,13,10,0

ready_text:
        dc.b    'MXDRV API + DSP YM2151 oracle samples: OK',13,10
        dc.b    'Press a key to exit.',13,10,0

reserve_error_text:
        dc.b    'Error: unable to reserve the Falcon DSP.',13,10
        dc.b    'Press a key to exit.',13,10,0

load_error_text:
        dc.b    'Error: unable to load YM2151.LOD.',13,10
        dc.b    'Keep it beside F030MXDRV.TOS.',13,10
        dc.b    'Press a key to exit.',13,10,0

protocol_error_text:
        dc.b    'Error: DSP protocol mismatch.',13,10
        dc.b    'Press a key to exit.',13,10,0

dsp_filename:
        dc.b    'ym2151.lod',0
        even

attack_trace:
        dc.b    $20,$c7,$28,$4c,$30,$00
        dc.b    $40,$01,$48,$01,$50,$01,$58,$01
        dc.b    $60,$00,$68,$00,$70,$00,$78,$00
        dc.b    $80,$1c,$88,$1c,$90,$1c,$98,$1c
        dc.b    $a0,$00,$a8,$00,$b0,$00,$b8,$00
        dc.b    $c0,$00,$c8,$00,$d0,$00,$d8,$00
        dc.b    $e0,$0f,$e8,$0f,$f0,$0f,$f8,$0f
        dc.b    $08,$78
        even

algorithm_references:
        dc.l    YM_REF_ALGORITHM_0_LEFT,YM_REF_ALGORITHM_0_RIGHT
        dc.l    YM_REF_ALGORITHM_1_LEFT,YM_REF_ALGORITHM_1_RIGHT
        dc.l    YM_REF_ALGORITHM_2_LEFT,YM_REF_ALGORITHM_2_RIGHT
        dc.l    YM_REF_ALGORITHM_3_LEFT,YM_REF_ALGORITHM_3_RIGHT
        dc.l    YM_REF_ALGORITHM_4_LEFT,YM_REF_ALGORITHM_4_RIGHT
        dc.l    YM_REF_ALGORITHM_5_LEFT,YM_REF_ALGORITHM_5_RIGHT
        dc.l    YM_REF_ALGORITHM_6_LEFT,YM_REF_ALGORITHM_6_RIGHT
        dc.l    YM_REF_ALGORITHM_7_LEFT,YM_REF_ALGORITHM_7_RIGHT

        bss

dsp_load_buffer:
        ds.b    DSP_LOAD_BUFFER

        end
