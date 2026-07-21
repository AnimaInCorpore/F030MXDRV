        include "xbios.i"
        include "protocol.i"

        global  capture_try_run

; Codec-vector capture mode. When CAPTURE.SCN exists beside the TTP, the
; no-argument launch replays that compiled scenario through the production
; protocol-v23 realtime transport instead of the conformance suite, so an
; external harness can observe block-boundary DSP state. The file is
; big-endian: 'SCN1', frame count (a multiple of the 512-frame buffer),
; an event count of at most the 32 FIFO slots, then time.w/reg.b/data.b
; events in nondecreasing order. Every event is queued before the stream
; starts; the validated scenarios stay inside one FIFO ring.

CAPTURE_MAGIC          equ     $53434e31       ; 'SCN1'
CAPTURE_MAX_EVENTS     equ     32
CAPTURE_BUFFER_BYTES   equ     12+CAPTURE_MAX_EVENTS*4

CAPTURE_SOUND_STEREO16 equ     1
CAPTURE_SOUND_DSP_XMIT equ     1
CAPTURE_SOUND_DAC      equ     8
CAPTURE_SOUND_CLK25M   equ     0
CAPTURE_SOUND_CLK25K   equ     3
CAPTURE_SOUND_NO_SHAKE equ     1

        text

; out: d0.l = 0 no scenario file, 1 scenario replayed, -1 failure
capture_try_run:
        movem.l d1-d7/a0-a6,-(sp)

        Fopen   capture_filename,#0
        tst.w   d0
        bmi     capture_absent
        move.w  d0,d7                  ; GEMDOS handle

        Fread   d7,#CAPTURE_BUFFER_BYTES,capture_buffer
        move.l  d0,d6                  ; bytes read
        Fclose  d7
        cmpi.l  #12,d6
        blt     capture_failed

        lea     capture_buffer,a4
        cmpi.l  #CAPTURE_MAGIC,(a4)+
        bne     capture_failed
        move.l  (a4)+,d5               ; codec frames requested
        ble     capture_failed
        move.l  d5,d0
        divu    #DSP_RT_MIX_FRAME_COUNT,d0
        swap    d0
        tst.w   d0                     ; whole 512-frame buffers only
        bne     capture_failed
        moveq   #0,d4
        move.w  (a4)+,d4               ; event count
        addq.l  #2,a4                  ; reserved pad word
        cmpi.l  #CAPTURE_MAX_EVENTS,d4
        bhi     capture_failed
        move.l  d4,d0
        lsl.l   #2,d0
        add.l   #12,d0
        cmp.l   d6,d0                  ; header promised more than was read
        bhi     capture_failed

        Cconws  capture_start_text

        Locksnd
        cmpi.l  #1,d0
        bne     capture_failed
        Setmode #CAPTURE_SOUND_STEREO16
        Settracks #0,#0
        Dsptristate #1,#0
        Devconnect #CAPTURE_SOUND_DSP_XMIT,#CAPTURE_SOUND_DAC,#CAPTURE_SOUND_CLK25M,#CAPTURE_SOUND_CLK25K,#CAPTURE_SOUND_NO_SHAKE

        ; Native time zero and a clean register image for every scenario.
        bsr     mxdrv_reset
        tst.l   d0
        bne     capture_audio_failed

        ; The whole scenario fits the 32-entry ring, so queue everything
        ; before the first rendered frame; entries due at time zero are
        ; drained ahead of frame zero's block.
        bra     capture_queue_next
capture_queue_event:
        moveq   #0,d0
        move.w  (a4)+,d0               ; rolling native timestamp
        moveq   #0,d1
        move.b  (a4)+,d1               ; register
        moveq   #0,d2
        move.b  (a4)+,d2               ; data
        bsr     dsp_queue_write
        cmp.l   #DSP_REPLY_OK,d0
        bne     capture_audio_failed
capture_queue_next:
        dbra    d4,capture_queue_event

        bsr     dsp_start_realtime_audio
        cmp.l   #DSP_REPLY_OK,d0
        bne     capture_audio_failed

        divu    #DSP_RT_MIX_FRAME_COUNT,d5
        subq.w  #1,d5                  ; the start rendered the first buffer
        bra     capture_refill_next
capture_refill:
        bsr     dsp_refill_realtime_audio
        cmp.l   #DSP_REPLY_OK,d0
        bne     capture_audio_failed
capture_refill_next:
        dbra    d5,capture_refill

        move.l  #DSP_CMD_STOP_AUDIO,d0
        bsr     dsp_exchange
        cmp.l   #DSP_REPLY_OK,d0
        bne     capture_audio_failed

        Dsptristate #0,#0
        Unlocksnd
        Cconws  capture_done_text
        moveq   #1,d0
        bra     capture_return

capture_audio_failed:
        Dsptristate #0,#0
        Unlocksnd
capture_failed:
        Cconws  capture_error_text
        moveq   #-1,d0
        bra     capture_return

capture_absent:
        moveq   #0,d0
capture_return:
        movem.l (sp)+,d1-d7/a0-a6
        rts

capture_filename:
        dc.b    'CAPTURE.SCN',0
capture_start_text:
        dc.b    'Replaying capture scenario through the realtime stream.',13,10,0
capture_done_text:
        dc.b    'Capture scenario complete.',13,10,0
capture_error_text:
        dc.b    'Error: capture scenario failed.',13,10,0
        even

        bss

capture_buffer:
        ds.b    CAPTURE_BUFFER_BYTES

        end
