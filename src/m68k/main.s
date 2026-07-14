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

        bsr     mxdrv_reset
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

        data

banner:
        dc.b    27,'E','F030MXDRV scaffold',13,10
        dc.b    '68030 MXDRV host + DSP56001 YM2151',13,10,13,10,0

ready_text:
        dc.b    'DSP protocol v2 and MAME phase oracle: OK',13,10
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

        bss

dsp_load_buffer:
        ds.b    DSP_LOAD_BUFFER

        end
