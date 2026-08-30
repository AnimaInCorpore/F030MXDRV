        include "protocol.i"

        global  mxdrv_reset
        global  mxdrv_write_ym2151
        global  mxdrv_query_phase_step
        global  mxdrv_clock_sample
        global  mxdrv_query_right
        global  mxdrv_query_envelope
        global  mxdrv_query_status
        global  mxdrv_query_lfo
        global  mxdrv_ym_batch_enable
        global  mxdrv_ym_batch_disable
        global  mxdrv_ym_batch_copy
        global  mxdrv_opm_buffer

        text

; Reset the DSP-owned YM2151 core.
; out: d0.l = DSP reply
mxdrv_reset:
        lea     mxdrv_opm_buffer,a0
        moveq   #0,d0
        move.w  #255,d3
.clear_opm:
        move.b  d0,(a0)+
        dbra    d3,.clear_opm
        move.l  #DSP_CMD_RESET,d0
        bra     dsp_exchange

; Porting seam for mxdrv17.s:WriteOPM.
; in:  d1.b = YM2151 register, d2.b = data (original MXDRV convention)
; out: d0.l = DSP reply
;
mxdrv_write_ym2151:
        moveq   #0,d0
        move.b  d1,d0
        lea     mxdrv_opm_buffer,a0
        move.b  d2,(a0,d0.w)           ; MXDRV call $10-compatible mirror
        moveq   #0,d0
        move.b  d1,d0
        lsl.l   #8,d0
        move.b  d2,d0
        ori.l   #DSP_CMD_WRITE_REG,d0
        tst.b   mxdrv_ym_batch_active
        beq     mxdrv_write_ym2151_direct

        ; Realtime playback gives every write drained by one foreground pump
        ; the same next-render timestamp. Keep those packed writes in order and
        ; send them with the following PCM period instead of paying one XBIOS
        ; transaction apiece on a 16 MHz 68030.
        movem.l d3-d6,-(sp)
        moveq   #0,d3
        move.w  mxdrv_ym_batch_count,d3

        ; Every write in this batch lands on frame zero. Replace an earlier
        ; write to the same latch with its final value while retaining the
        ; first-occurrence order (voice parameters therefore remain ahead of
        ; key-on). Register $08 key edges and $14 timer-control edges are never
        ; collapsed; $19 keeps AMD and PM-depth selectors distinct. A batch
        ; generation plus one byte per register maps a latch directly to its
        ; first slot. Dense voice loads used to rescan the growing batch for
        ; every parameter, making this foreground preparation quadratic just
        ; when the audio pipeline had the least headroom.
        move.l  d0,d4
        lsr.l   #8,d4
        andi.w  #$00ff,d4              ; register number
        cmpi.w  #$08,d4
        beq     mxdrv_write_ym2151_batch_append_edge
        cmpi.w  #$14,d4
        beq     mxdrv_write_ym2151_batch_append_edge
        cmpi.w  #$19,d4
        bne     mxdrv_write_ym2151_batch_lookup
        btst    #7,d0                  ; PM depth has its own internal $1a bank
        bne     mxdrv_write_ym2151_batch_lookup_pm

mxdrv_write_ym2151_batch_lookup:
        move.w  d4,d6
        lsl.w   #2,d6
        lea     mxdrv_ym_batch_generation_by_reg,a0
        move.l  mxdrv_ym_batch_generation,d5
        cmp.l   (a0,d6.w),d5
        bne     mxdrv_write_ym2151_batch_append_register
        lea     mxdrv_ym_batch_slot_by_reg,a0
        moveq   #0,d3
        move.b  (a0,d4.w),d3
        bra     mxdrv_write_ym2151_batch_replace_slot

mxdrv_write_ym2151_batch_lookup_pm:
        move.l  mxdrv_ym_batch_generation,d5
        cmp.l   mxdrv_ym_batch_pm_generation,d5
        bne     mxdrv_write_ym2151_batch_append_pm
        moveq   #0,d3
        move.b  mxdrv_ym_batch_pm_slot,d3
        bra     mxdrv_write_ym2151_batch_replace_slot

mxdrv_write_ym2151_batch_append_register:
        cmpi.w  #DSP_RT_BATCH_MAX,d3
        bcc     mxdrv_write_ym2151_batch_full
        move.l  d5,(a0,d6.w)
        lea     mxdrv_ym_batch_slot_by_reg,a0
        move.b  d3,(a0,d4.w)
        bra     mxdrv_write_ym2151_batch_append_slot

mxdrv_write_ym2151_batch_append_pm:
        cmpi.w  #DSP_RT_BATCH_MAX,d3
        bcc     mxdrv_write_ym2151_batch_full
        move.l  d5,mxdrv_ym_batch_pm_generation
        move.b  d3,mxdrv_ym_batch_pm_slot
        bra     mxdrv_write_ym2151_batch_append_slot

mxdrv_write_ym2151_batch_append_edge:
        cmpi.w  #DSP_RT_BATCH_MAX,d3
        bcc     mxdrv_write_ym2151_batch_full
mxdrv_write_ym2151_batch_append_slot:
        move.w  d3,d6
        lsl.w   #2,d6
        lea     mxdrv_ym_batch_words,a0
        move.l  d0,(a0,d6.w)
        addq.w  #1,mxdrv_ym_batch_count
        movem.l (sp)+,d3-d6
        moveq   #DSP_REPLY_OK,d0
        rts
mxdrv_write_ym2151_batch_replace_slot:
        lsl.w   #2,d3
        lea     mxdrv_ym_batch_words,a0
        move.l  d0,(a0,d3.w)
        movem.l (sp)+,d3-d6
        moveq   #DSP_REPLY_OK,d0
        rts
mxdrv_write_ym2151_batch_full:
        ; The period already holds DSP_RT_BATCH_MAX coalesced writes. Rather than
        ; fail the refill (which stops playback outright), drain the pending
        ; batch to the DSP as direct in-order command-02 writes — the pre-batch
        ; path — then send this write and leave the batch empty. Ordering is
        ; preserved; only this unusually dense tick pays the old per-write cost.
        ; dsp_exchange saves d1-d7/a0-a6, so the loop pointer and counter survive.
        move.l  d0,-(sp)                ; current packed write
        ; With a realtime payload posted, these synchronous command words
        ; would slot into the middle of that payload's block transfer at the
        ; next handoff. Deliver the announced block before using the port.
        bsr     dsp_rt_submit_wait
        moveq   #0,d3
        move.w  mxdrv_ym_batch_count,d3
        lea     mxdrv_ym_batch_words,a0
        subq.w  #1,d3
mxdrv_write_ym2151_flush:
        move.l  (a0)+,d0
        bsr     dsp_exchange
        dbra    d3,mxdrv_write_ym2151_flush
        clr.w   mxdrv_ym_batch_count
        addq.l  #1,mxdrv_ym_batch_generation
        move.l  (sp)+,d0
        bsr     dsp_exchange
        movem.l (sp)+,d3-d6
        rts
mxdrv_write_ym2151_direct:
        bra     dsp_exchange

; Enable/disable the production write accumulator. Conformance and direct API
; calls retain their synchronous command-02 behavior unless the player opts in.
mxdrv_ym_batch_enable:
        clr.w   mxdrv_ym_batch_count
        addq.l  #1,mxdrv_ym_batch_generation
        clr.b   mxdrv_ym_batch_overflow
        move.b  #1,mxdrv_ym_batch_active
        rts

mxdrv_ym_batch_disable:
        clr.b   mxdrv_ym_batch_active
        clr.b   mxdrv_ym_batch_overflow
        clr.w   mxdrv_ym_batch_count
        addq.l  #1,mxdrv_ym_batch_generation
        rts

; Append a count header and the pending packed writes to a realtime transfer.
; in: a3 = next longword slot
; out: a3 advanced, d5.l = header + event word count, d0.l = 0 or -1
mxdrv_ym_batch_copy:
        tst.b   mxdrv_ym_batch_overflow
        beq     mxdrv_ym_batch_copy_valid
        clr.b   mxdrv_ym_batch_overflow
        clr.w   mxdrv_ym_batch_count
        addq.l  #1,mxdrv_ym_batch_generation
        moveq   #-1,d0
        rts
mxdrv_ym_batch_copy_valid:
        moveq   #0,d5
        move.w  mxdrv_ym_batch_count,d5
        move.l  d5,(a3)+
        tst.w   d5
        beq     mxdrv_ym_batch_copy_done
        lea     mxdrv_ym_batch_words,a0
        move.w  d5,d4
        subq.w  #1,d4
mxdrv_ym_batch_copy_loop:
        move.l  (a0)+,d0
        move.l  d0,(a3)+
        dbra    d4,mxdrv_ym_batch_copy_loop
mxdrv_ym_batch_copy_done:
        clr.w   mxdrv_ym_batch_count
        addq.l  #1,mxdrv_ym_batch_generation
        addq.l  #1,d5
        moveq   #0,d0
        rts

; Development-time MAME conformance probe.
; in:  d1.b = channel (0-7), d2.b = logical operator (0-3)
; out: d0.l = current 20-bit phase step calculated by the DSP
mxdrv_query_phase_step:
        moveq   #0,d0
        move.b  d1,d0
        lsl.l   #8,d0
        move.b  d2,d0
        ori.l   #DSP_CMD_QUERY_PHASE,d0
        bra     dsp_exchange

; Advance the DSP-owned YM2151 by one native 62.5 kHz sample.
; out: d0.l = signed left sample in the low 24 bits
mxdrv_clock_sample:
        move.l  #DSP_CMD_CLOCK,d0
        bra     dsp_exchange

; Fetch the right half of the most recently generated sample.
; out: d0.l = signed right sample in the low 24 bits
mxdrv_query_right:
        move.l  #DSP_CMD_QUERY_RIGHT,d0
        bra     dsp_exchange

; Fetch one logical operator's native envelope attenuation (0-1023).
; in:  d1.b = logical operator index (channel*4 + operator)
mxdrv_query_envelope:
        moveq   #0,d0
        move.b  d1,d0
        ori.l   #DSP_CMD_QUERY_ENV,d0
        bra     dsp_exchange

; Fetch the YM2151 status byte (timer flags plus bit 7 while write-busy).
mxdrv_query_status:
        move.l  #DSP_CMD_QUERY_STATUS,d0
        bra     dsp_exchange

; Fetch phase:AM:PM as three packed bytes for conformance tests.
mxdrv_query_lfo:
        move.l  #DSP_CMD_QUERY_LFO,d0
        bra     dsp_exchange

        bss

mxdrv_opm_buffer:
        ds.b    256
mxdrv_ym_batch_active:
        ds.b    1
mxdrv_ym_batch_overflow:
        ds.b    1
mxdrv_ym_batch_count:
        ds.w    1
mxdrv_ym_batch_words:
        ds.l    DSP_RT_BATCH_MAX
mxdrv_ym_batch_generation:
        ds.l    1
mxdrv_ym_batch_generation_by_reg:
        ds.l    256
mxdrv_ym_batch_slot_by_reg:
        ds.b    256
mxdrv_ym_batch_pm_generation:
        ds.l    1
mxdrv_ym_batch_pm_slot:
        ds.b    1

        end
