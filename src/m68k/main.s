        include "xbios.i"
        include "protocol.i"
        include "ym2151_reference.i"

        global  start

DSP_X_WORDS     equ     8192
DSP_Y_WORDS     equ     8192
DSP_ABILITY     equ     3
DSP_LOAD_BUFFER equ     40000

SOUND_STEREO16  equ     1
SOUND_DSP_XMIT  equ     1
SOUND_DAC       equ     8
SOUND_CLK25M    equ     0
SOUND_CLK50K    equ     1
SOUND_NO_SHAKE  equ     1

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

        clr.l   dsp_table_reply
        Dsp_BlkUnpacked ym2151_table_upload,#YM_TABLE_UPLOAD_WORDS,dsp_table_reply,#1
        move.l  dsp_table_reply,d0
        cmp.l   #DSP_REPLY_OK,d0
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

        bsr     mxdrv_query_status
        cmpi.l  #$80,d0                ; every register write is busy for 64 clocks
        bne     protocol_failed
        moveq   #1,d3
        bsr     clock_samples
        bsr     mxdrv_query_status
        tst.l   d0
        bne     protocol_failed

        ; Drive the saw LFO across its first phase boundary. At rate $ff the
        ; fifth sample advances phase to 1; AM depth $7f yields $fc.
        bsr     mxdrv_reset
        tst.l   d0
        bne     protocol_failed
        moveq   #$18,d1
        moveq   #-$01,d2               ; $ff
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     protocol_failed
        moveq   #$19,d1
        moveq   #$7f,d2
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     protocol_failed
        moveq   #5,d3
        bsr     clock_samples
        bsr     mxdrv_query_lfo
        cmpi.l  #$01fc00,d0
        bne     protocol_failed

        bsr     mxdrv_reset
        tst.l   d0
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

        ; Channel 7 replaces operator 4's sine output with the noise LFSR.
        ; Replay the fastest-rate oracle trace and compare sample 63.
        bsr     mxdrv_reset
        tst.l   d0
        bne     protocol_failed
        lea     noise_trace(pc),a3
        moveq   #10,d3
.write_noise_trace:
        moveq   #0,d1
        moveq   #0,d2
        move.b  (a3)+,d1
        move.b  (a3)+,d2
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     protocol_failed
        dbra    d3,.write_noise_trace
        moveq   #64,d3
        bsr     clock_samples
        cmp.l   #YM_REF_NOISE_63_LEFT,d0
        bne     protocol_failed
        bsr     mxdrv_query_right
        cmp.l   #YM_REF_NOISE_63_RIGHT,d0
        bne     protocol_failed

        ; Timer A uses its 10-bit latch directly in native sample units.
        ; Value $3fe therefore expires after two clock commands.
        bsr     mxdrv_reset
        tst.l   d0
        bne     protocol_failed
        moveq   #$10,d1
        moveq   #-$01,d2               ; timer A high = $ff
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     protocol_failed
        moveq   #$11,d1
        moveq   #2,d2                  ; timer A low = 2, value = $3fe
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     protocol_failed
        moveq   #$14,d1
        moveq   #5,d2                  ; enable A + load A
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     protocol_failed

        moveq   #1,d3
        bsr     clock_samples
        bsr     mxdrv_query_status
        tst.l   d0
        bne     protocol_failed
        moveq   #1,d3
        bsr     clock_samples
        bsr     mxdrv_query_status
        cmpi.l  #1,d0
        bne     protocol_failed

        moveq   #$14,d1
        moveq   #$15,d2                ; reset A without restarting loaded timer
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     protocol_failed
        bsr     mxdrv_query_status
        cmpi.l  #$80,d0
        bne     protocol_failed
        moveq   #1,d3
        bsr     clock_samples
        bsr     mxdrv_query_status
        tst.l   d0
        bne     protocol_failed
        moveq   #1,d3
        bsr     clock_samples
        bsr     mxdrv_query_status
        cmpi.l  #1,d0
        bne     protocol_failed

        moveq   #$14,d1
        moveq   #$14,d2                ; reset A + clear load cancels it
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     protocol_failed
        moveq   #3,d3
        bsr     clock_samples
        bsr     mxdrv_query_status
        tst.l   d0
        bne     protocol_failed

        ; Timer B's $ff latch has a 16-sample period.
        bsr     mxdrv_reset
        tst.l   d0
        bne     protocol_failed
        moveq   #$12,d1
        moveq   #-$01,d2
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     protocol_failed
        moveq   #$14,d1
        moveq   #$0a,d2                ; enable B + load B
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     protocol_failed
        moveq   #15,d3
        bsr     clock_samples
        bsr     mxdrv_query_status
        tst.l   d0
        bne     protocol_failed
        moveq   #1,d3
        bsr     clock_samples
        bsr     mxdrv_query_status
        cmpi.l  #2,d0
        bne     protocol_failed
        moveq   #$14,d1
        moveq   #$28,d2                ; reset B + clear load
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     protocol_failed
        moveq   #17,d3
        bsr     clock_samples
        bsr     mxdrv_query_status
        tst.l   d0
        bne     protocol_failed

        ; The divide-by-16 source is free-running. Loading B five samples
        ; after reset shortens this first $ff period from 16 to 11 samples.
        bsr     mxdrv_reset
        tst.l   d0
        bne     protocol_failed
        moveq   #5,d3
        bsr     clock_samples
        moveq   #$12,d1
        moveq   #-$01,d2
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     protocol_failed
        moveq   #$14,d1
        moveq   #$0a,d2
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     protocol_failed
        moveq   #10,d3
        bsr     clock_samples
        bsr     mxdrv_query_status
        tst.l   d0
        bne     protocol_failed
        moveq   #1,d3
        bsr     clock_samples
        bsr     mxdrv_query_status
        cmpi.l  #2,d0
        bne     protocol_failed

        ; With timer-A status disabled, its two-sample expiration still raises
        ; the all-operator CSM key input for sample 2.
        bsr     mxdrv_reset
        tst.l   d0
        bne     protocol_failed
        lea     csm_trace(pc),a3
        moveq   #11,d3
.write_csm_trace:
        moveq   #0,d1
        moveq   #0,d2
        move.b  (a3)+,d1
        move.b  (a3)+,d2
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     protocol_failed
        dbra    d3,.write_csm_trace

        moveq   #2,d3                  ; samples 0..1: timer has not keyed yet
        bsr     clock_samples
        tst.l   d0
        bne     protocol_failed
        bsr     mxdrv_query_right
        tst.l   d0
        bne     protocol_failed
        bsr     mxdrv_query_status      ; enable-A is clear, so no status flag
        tst.l   d0
        bne     protocol_failed
        moveq   #1,d3                  ; sample 2 consumes the CSM key input
        bsr     clock_samples
        cmp.l   #YM_REF_CSM_2_LEFT,d0
        bne     protocol_failed
        bsr     mxdrv_query_right
        cmp.l   #YM_REF_CSM_2_RIGHT,d0
        bne     protocol_failed
        moveq   #0,d1
        bsr     mxdrv_query_envelope
        tst.l   d0
        bne     protocol_failed

        ; Unique completion marker for the non-interactive Hatari trace gate.
        move.l  #DSP_CMD_PING+$c0de,d0
        bsr     dsp_exchange
        cmp.l   #DSP_REPLY_HELLO,d0
        bne     protocol_failed

        ; Feed a known sustained voice into the first end-to-end DSP SSI path.
        bsr     mxdrv_reset
        tst.l   d0
        bne     protocol_failed
        lea     attack_trace(pc),a3
        moveq   #27,d3
.write_audio_trace:
        moveq   #0,d1
        moveq   #0,d2
        move.b  (a3)+,d1
        move.b  (a3)+,d2
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     protocol_failed
        dbra    d3,.write_audio_trace

        Locksnd
        cmpi.l  #1,d0
        bne     sound_failed
        Setmode #SOUND_STEREO16
        Settracks #0,#0
        Dsptristate #1,#0
        Devconnect #SOUND_DSP_XMIT,#SOUND_DAC,#SOUND_CLK25M,#SOUND_CLK50K,#SOUND_NO_SHAKE

        move.l  #DSP_CMD_START_AUDIO,d0
        bsr     dsp_exchange
        cmp.l   #DSP_REPLY_OK,d0
        bne     audio_protocol_failed

        ; Prove that the normal MXDRV WriteOPM seam remains serviced while SSI
        ; is active. This changes DSP state for the next render; the current
        ; bounded block was deliberately rendered before transmit started.
        moveq   #$7e,d1
        moveq   #$5a,d2
        bsr     mxdrv_write_ym2151
        cmp.l   #DSP_REPLY_OK,d0
        bne     audio_protocol_failed

        Cconws  audio_text
        move.w  #149,d5               ; 150 VBLs, about three seconds
.audio_wait:
        Vsync
        dbra    d5,.audio_wait
.audio_stop:
        move.l  #DSP_CMD_STOP_AUDIO,d0
        bsr     dsp_exchange
        cmp.l   #DSP_REPLY_OK,d0
        bne     audio_protocol_failed
        move.l  #DSP_CMD_QUERY_AUDIO,d0
        bsr     dsp_exchange
        cmpi.l  #100000,d0             ; reject a stalled/underrunning SSI path
        bcs     audio_protocol_failed
        Dsptristate #0,#0
        Unlocksnd

        Cconws  ready_text
        bra     clean_exit

audio_protocol_failed:
        Dsptristate #0,#0
        Unlocksnd
        bra     protocol_failed

protocol_failed:
        Cconws  protocol_error_text
        Cconin
        bra     clean_exit

load_failed:
        Cconws  load_error_text
        Cconin
        bra     clean_exit

sound_failed:
        Cconws  sound_error_text
        Cconin
        bra     clean_exit

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

        include "ym2151_host_tables.i"

banner:
        dc.b    27,'E','F030MXDRV DSP core',13,10
        dc.b    '68030 MXDRV host + DSP56001 YM2151',13,10,13,10,0

ready_text:
        dc.b    'MXDRV API + DSP YM2151 oracle samples: OK',13,10
        dc.b    'Falcon DSP SSI/crossbar burst: OK',13,10,0

audio_text:
        dc.b    'Playing a three-second DSP YM2151 SSI burst...',13,10,0

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

sound_error_text:
        dc.b    'Error: unable to lock the Falcon sound system.',13,10
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

noise_trace:
        dc.b    $27,$c7,$2f,$4c,$37,$00
        dc.b    $5f,$01,$7f,$00,$9f,$1c,$bf,$00,$df,$00,$ff,$0f
        dc.b    $0f,$9f,$08,$47
        even

csm_trace:
        dc.b    $20,$c7,$28,$4c,$30,$00,$40,$01
        dc.b    $60,$00,$80,$ff,$a0,$00,$c0,$00,$e0,$0f
        dc.b    $10,$ff,$11,$02,$14,$81
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
dsp_table_reply:
        ds.l    1

        end
