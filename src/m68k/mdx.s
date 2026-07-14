        global  mxdrv_mdx_reset
        global  mxdrv_mdx_start
        global  mxdrv_mdx_tick
        global  mxdrv_mdx_active_mask
        global  mxdrv_mdx_timer_service
        global  mxdrv_mdx_timer_period
        global  mxdrv_mdx_timer_ticks
        global  mxdrv_mdx_tempo
        global  mxdrv_mdx_error

MDX_TRACK_POINTER       equ     0
MDX_TRACK_WAIT          equ     4
MDX_TRACK_GATE          equ     6
MDX_TRACK_ACTIVE        equ     8
MDX_TRACK_SOUNDING      equ     9
MDX_TRACK_PAN           equ     10
MDX_TRACK_VOLUME        equ     11
MDX_TRACK_NOTE_LENGTH   equ     12
MDX_TRACK_BANK          equ     13
MDX_TRACK_VOICE         equ     14
MDX_TRACK_VOICE_DIRTY   equ     18
MDX_TRACK_BYTES         equ     20
MDX_TRACK_COUNT         equ     16
MDX_TRACK_TABLE_BYTES   equ     2+MDX_TRACK_COUNT*2
MDX_COMMAND_BUDGET      equ     64

        text

; Clear all parser-owned state. This does not write key-offs; callers stopping
; live playback do that before discarding the track state.
mxdrv_mdx_reset:
        lea     mxdrv_mdx_tracks,a0
        moveq   #0,d0
        move.w  #(MDX_TRACK_BYTES*MDX_TRACK_COUNT/2)-1,d1
.clear_tracks:
        move.w  d0,(a0)+
        dbra    d1,.clear_tracks
        clr.l   mxdrv_mdx_end
        clr.l   mxdrv_mdx_voice_table
        clr.w   mxdrv_mdx_active
        clr.b   mxdrv_mdx_error
        clr.b   mxdrv_mdx_timer_busy
        clr.l   mxdrv_mdx_service_count
        move.b  #$c8,mxdrv_mdx_tempo
        rts

mxdrv_mdx_active_mask:
        moveq   #0,d0
        move.w  mxdrv_mdx_active,d0
        rts

; Return the current Timer-B overflow period in native 62.5 kHz YM samples.
; YM2151 Timer B advances once per 1024 input clocks, or every 16 native
; samples here, and overflows after (256-latch) increments.
mxdrv_mdx_timer_period:
        moveq   #0,d0
        move.b  mxdrv_mdx_tempo,d0
        neg.w   d0
        addi.w  #256,d0
        lsl.w   #4,d0
        rts

mxdrv_mdx_timer_ticks:
        move.l  mxdrv_mdx_service_count,d0
        rts

; Scheduler/interrupt-facing entry point. One accepted call advances exactly
; one MXDRV timer tick. The byte guard makes an accidental nested call a no-op;
; mxdrv_mdx_tick itself preserves every register except its d0 result.
mxdrv_mdx_timer_service:
        tst.b   mxdrv_mdx_timer_busy
        bne     mxdrv_mdx_active_mask
        tst.b   mxdrv_playing
        beq     mxdrv_mdx_active_mask
        tst.b   mxdrv_paused
        bne     mxdrv_mdx_active_mask
        move.b  #1,mxdrv_mdx_timer_busy
        addq.l  #1,mxdrv_mdx_service_count
        bsr     mxdrv_mdx_tick
        clr.b   mxdrv_mdx_timer_busy
        rts

; Initialize the 16 MDX tracks using MXDRV's sequence-block layout:
;   mdx+4 -> sequence block
;   sequence+0 -> voice table, relative to sequence
;   sequence+2..32 -> sixteen track pointers, relative to sequence
; Every resolved byte must remain inside the copied MDX buffer.
; out: d0.l=0 on success, -1 for a malformed/truncated MDX image
mxdrv_mdx_start:
        bsr     mxdrv_mdx_reset
        move.l  mxdrv_mdx_size,d2
        cmpi.l  #8,d2
        bcs     mdx_start_error

        lea     mxdrv_mdx_buffer,a0
        lea     (a0,d2.l),a1
        move.l  a1,mxdrv_mdx_end

        moveq   #0,d0
        move.w  4(a0),d0
        cmp.l   d2,d0
        bcc     mdx_start_error
        lea     (a0,d0.l),a2
        lea     MDX_TRACK_TABLE_BYTES(a2),a3
        cmpa.l  a1,a3
        bhi     mdx_start_error

        moveq   #0,d0
        move.w  (a2),d0
        lea     (a2,d0.l),a3
        cmpa.l  a1,a3
        bcc     mdx_start_error
        move.l  a3,mxdrv_mdx_voice_table

        lea     2(a2),a4
        lea     mxdrv_mdx_tracks,a6
        moveq   #MDX_TRACK_COUNT-1,d7
.init_track:
        moveq   #0,d0
        move.w  (a4)+,d0
        lea     (a2,d0.l),a3
        cmpa.l  a1,a3
        bcc     mdx_start_error
        move.l  a3,MDX_TRACK_POINTER(a6)
        move.b  #1,MDX_TRACK_ACTIVE(a6)
        move.b  #3,MDX_TRACK_PAN(a6)
        move.b  #8,MDX_TRACK_VOLUME(a6)
        move.b  #8,MDX_TRACK_NOTE_LENGTH(a6)
        lea     MDX_TRACK_BYTES(a6),a6
        dbra    d7,.init_track

        move.w  #$ffff,mxdrv_mdx_active
        moveq   #$12,d1
        moveq   #-$38,d2               ; MXDRV's initial tempo is $c8
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     mdx_start_error
        moveq   #0,d0
        rts

mdx_start_error:
        bsr     mxdrv_mdx_reset
        move.b  #1,mxdrv_mdx_error
        moveq   #-1,d0
        rts

; Advance every active track by one MXDRV timer tick. This first executor
; supports waits, FM/PCM notes, tempo and raw OPM writes, FM voice/PCM bank
; selection, pan, PCM volume, note length, legato-as-a-no-op, and normal ends.
; Commands whose operand shape is not implemented end only that track and set
; mxdrv_mdx_error, keeping malformed or newer streams bounded.
; out: d0.w=one bit per still-active track
mxdrv_mdx_tick:
        movem.l d1-d7/a0-a6,-(sp)
        tst.b   mxdrv_playing
        beq     mdx_tick_return
        tst.b   mxdrv_paused
        bne     mdx_tick_return

        lea     mxdrv_mdx_tracks,a6
        moveq   #0,d7
mdx_tick_track:
        tst.b   MDX_TRACK_ACTIVE(a6)
        beq     mdx_tick_next

        tst.w   MDX_TRACK_GATE(a6)
        beq     mdx_tick_duration
        subq.w  #1,MDX_TRACK_GATE(a6)
        bne     mdx_tick_duration
        bsr     mdx_stop_voice

mdx_tick_duration:
        tst.w   MDX_TRACK_WAIT(a6)
        beq     mdx_parse_track
        subq.w  #1,MDX_TRACK_WAIT(a6)
        bne     mdx_tick_next

mdx_parse_track:
        movea.l MDX_TRACK_POINTER(a6),a4
        moveq   #MDX_COMMAND_BUDGET-1,d6
mdx_parse_command:
        movea.l mxdrv_mdx_end,a3
        cmpa.l  a3,a4
        bcc     mdx_track_invalid
        moveq   #0,d0
        move.b  (a4)+,d0
        cmpi.b  #$80,d0
        bcs     mdx_parse_rest
        cmpi.b  #$e0,d0
        bcs     mdx_parse_note
        cmpi.b  #$e0,d0
        beq     mdx_command_tempo
        cmpi.b  #$e1,d0
        beq     mdx_command_opm
        cmpi.b  #$e2,d0
        beq     mdx_command_voice
        cmpi.b  #$e3,d0
        beq     mdx_command_pan
        cmpi.b  #$e4,d0
        beq     mdx_command_volume
        cmpi.b  #$e5,d0
        beq     mdx_command_volume_down
        cmpi.b  #$e6,d0
        beq     mdx_command_volume_up
        cmpi.b  #$e7,d0
        beq     mdx_command_note_length
        cmpi.b  #$e8,d0
        beq     mdx_command_continue
        cmpi.b  #$e9,d0
        beq     mdx_command_repeat_start
        cmpi.b  #$ea,d0
        beq     mdx_command_repeat_end
        cmpi.b  #$eb,d0
        beq     mdx_command_repeat_escape
        cmpi.b  #$ee,d0
        beq     mdx_command_performance_end
        cmpi.b  #$f9,d0
        bcc     mdx_track_end
        bra     mdx_track_invalid

mdx_parse_rest:
        addq.w  #1,d0
        move.w  d0,MDX_TRACK_WAIT(a6)
        clr.w   MDX_TRACK_GATE(a6)
        move.l  a4,MDX_TRACK_POINTER(a6)
        bra     mdx_tick_next

mdx_parse_note:
        move.w  d0,d5
        andi.w  #$007f,d5
        cmpa.l  a3,a4
        bcc     mdx_track_invalid
        moveq   #0,d0
        move.b  (a4)+,d0               ; encoded duration (ticks minus one)
        move.w  d0,d1
        addq.w  #1,d1
        move.w  d1,MDX_TRACK_WAIT(a6)

        moveq   #0,d1
        move.b  MDX_TRACK_NOTE_LENGTH(a6),d1
        btst    #7,d1
        bne     .full_gate
        mulu.w  d0,d1
        lsr.w   #3,d1
        addq.w  #1,d1
        bra     .store_gate
.full_gate:
        move.w  MDX_TRACK_WAIT(a6),d1
.store_gate:
        move.w  d1,MDX_TRACK_GATE(a6)
        move.l  a4,MDX_TRACK_POINTER(a6)

        moveq   #0,d4
        move.w  mxdrv_channel_mask,d4
        btst    d7,d4
        bne     mdx_tick_next
        cmpi.w  #8,d7
        bcc     mdx_start_pcm_note

        bsr     mdx_load_fm_voice
        tst.l   d0
        bne     mdx_track_invalid
        moveq   #$30,d1
        add.b   d7,d1
        moveq   #$14,d2               ; (note*64+5)*4 fractional byte
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     mdx_track_invalid
        moveq   #$28,d1
        add.b   d7,d1
        lea     mdx_opm_note_table(pc),a0
        moveq   #0,d2
        move.b  (a0,d5.w),d2
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     mdx_track_invalid
        moveq   #$08,d1
        moveq   #$78,d2
        or.b    d7,d2
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     mdx_track_invalid
        move.b  #1,MDX_TRACK_SOUNDING(a6)
        bra     mdx_tick_next

mdx_start_pcm_note:
        moveq   #0,d1
        move.b  MDX_TRACK_BANK(a6),d1
        mulu.w  #96,d1
        add.w   d5,d1
        move.w  d7,d0
        subi.w  #8,d0
        moveq   #4,d2                  ; MDX PCM default: 15.625 kHz
        moveq   #0,d3
        move.b  MDX_TRACK_PAN(a6),d3
        moveq   #0,d4
        move.b  MDX_TRACK_VOLUME(a6),d4
        bsr     mxdrv_pdx_voice_start
        tst.l   d0
        bne     mdx_tick_next           ; empty/missing PDX is a silent note
        move.b  #1,MDX_TRACK_SOUNDING(a6)
        bra     mdx_tick_next

mdx_command_tempo:
        cmpa.l  a3,a4
        bcc     mdx_track_invalid
        move.b  (a4)+,mxdrv_mdx_tempo
        moveq   #$12,d1
        move.b  mxdrv_mdx_tempo,d2
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     mdx_track_invalid
        bra     mdx_command_more

mdx_command_opm:
        lea     2(a4),a0
        cmpa.l  a3,a0
        bhi     mdx_track_invalid
        moveq   #0,d1
        moveq   #0,d2
        move.b  (a4)+,d1
        move.b  (a4)+,d2
        cmpi.b  #$12,d1
        bne     .write
        move.b  d2,mxdrv_mdx_tempo
.write:
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     mdx_track_invalid
        bra     mdx_command_more

mdx_command_voice:
        cmpa.l  a3,a4
        bcc     mdx_track_invalid
        moveq   #0,d0
        move.b  (a4)+,d0
        cmpi.w  #8,d7
        bcc     .pcm_bank

        movea.l mxdrv_mdx_voice_table,a0
.find_voice:
        cmpa.l  a3,a0
        bcc     mdx_track_invalid
        cmp.b   (a0)+,d0
        beq     .fm_voice
        lea     26(a0),a1              ; ID byte plus 26-byte voice record
        cmpa.l  a3,a1
        bhi     mdx_track_invalid
        movea.l a1,a0
        bra     .find_voice
.fm_voice:
        lea     26(a0),a1
        cmpa.l  a3,a1
        bhi     mdx_track_invalid
        move.l  a0,MDX_TRACK_VOICE(a6)
        move.b  #1,MDX_TRACK_VOICE_DIRTY(a6)
        bra     mdx_command_more
.pcm_bank:
        move.b  d0,MDX_TRACK_BANK(a6)
        bra     mdx_command_more

mdx_command_pan:
        cmpa.l  a3,a4
        bcc     mdx_track_invalid
        moveq   #0,d0
        move.b  (a4)+,d0
        andi.b  #3,d0
        move.b  d0,MDX_TRACK_PAN(a6)
        cmpi.w  #8,d7
        bcc     mdx_command_more
        moveq   #$20,d1
        add.b   d7,d1
        lea     mxdrv_opm_buffer,a0
        moveq   #0,d2
        move.b  (a0,d1.w),d2
        andi.b  #$3f,d2
        lsl.b   #6,d0
        or.b    d0,d2
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     mdx_track_invalid
        bra     mdx_command_more

mdx_command_volume:
        cmpa.l  a3,a4
        bcc     mdx_track_invalid
        moveq   #0,d0
        move.b  (a4)+,d0
        cmpi.b  #15,d0
        bhi     mdx_track_invalid
        move.b  d0,MDX_TRACK_VOLUME(a6)
        bra     mdx_command_more

mdx_command_volume_down:
        tst.b   MDX_TRACK_VOLUME(a6)
        beq     mdx_command_more
        subq.b  #1,MDX_TRACK_VOLUME(a6)
        bra     mdx_command_more

mdx_command_volume_up:
        cmpi.b  #15,MDX_TRACK_VOLUME(a6)
        bcc     mdx_command_more
        addq.b  #1,MDX_TRACK_VOLUME(a6)
        bra     mdx_command_more

mdx_command_note_length:
        cmpa.l  a3,a4
        bcc     mdx_track_invalid
        move.b  (a4)+,MDX_TRACK_NOTE_LENGTH(a6)
        bra     mdx_command_more

mdx_command_continue:
        bra     mdx_command_more

; E9 count,work copies count into the following mutable work byte. MDX data is
; owned by the driver specifically so MXDRV's in-stream repeat state is safe.
mdx_command_repeat_start:
        lea     2(a4),a0
        cmpa.l  a3,a0
        bhi     mdx_track_invalid
        move.b  (a4),1(a4)
        movea.l a0,a4
        bra     mdx_command_more

; EA signed-back-offset decrements the work byte immediately before its target.
; A nonzero count branches to the target; zero falls through after the offset.
mdx_command_repeat_end:
        lea     2(a4),a0
        cmpa.l  a3,a0
        bhi     mdx_track_invalid
        moveq   #0,d0
        move.b  (a4)+,d0
        lsl.w   #8,d0
        move.b  (a4)+,d0
        ext.l   d0
        lea     (a4,d0.l),a0
        lea     mxdrv_mdx_buffer,a1
        cmpa.l  a1,a0
        bls     mdx_track_invalid       ; target-1 must remain in the MDX copy
        cmpa.l  a3,a0
        bcc     mdx_track_invalid
        subq.b  #1,-1(a0)
        beq     mdx_command_more
        movea.l a0,a4
        bra     mdx_command_more

; EB unsigned-forward-offset points at a future EA's two displacement bytes.
; On the final pass (work byte == 1), skip those bytes and continue after EA.
mdx_command_repeat_escape:
        lea     2(a4),a0
        cmpa.l  a3,a0
        bhi     mdx_track_invalid
        moveq   #0,d0
        move.b  (a4)+,d0
        lsl.w   #8,d0
        move.b  (a4)+,d0
        lea     (a4,d0.l),a0
        lea     2(a0),a1
        cmpa.l  a3,a1
        bhi     mdx_track_invalid

        moveq   #0,d0
        move.b  (a0)+,d0
        lsl.w   #8,d0
        move.b  (a0)+,d0
        ext.l   d0
        lea     (a0,d0.l),a1
        lea     mxdrv_mdx_buffer,a2
        cmpa.l  a2,a1
        bls     mdx_track_invalid
        cmpa.l  a3,a1
        bcc     mdx_track_invalid
        cmpi.b  #1,-1(a1)
        bne     mdx_command_more
        movea.l a0,a4
        bra     mdx_command_more

; EE with a zero first operand is the normal performance end. Nonzero EE
; targets also retire this channel in MXDRV; playlist/fade bookkeeping around
; the relative target is outside this standalone-song executor.
mdx_command_performance_end:
        cmpa.l  a3,a4
        bcc     mdx_track_invalid
        addq.w  #1,a4
        bra     mdx_track_end

mdx_command_more:
        dbra    d6,mdx_parse_command
        bra     mdx_track_invalid

mdx_track_invalid:
        move.b  #1,mxdrv_mdx_error
mdx_track_end:
        move.l  a4,MDX_TRACK_POINTER(a6)
        bsr     mdx_stop_voice
        clr.w   MDX_TRACK_WAIT(a6)
        clr.w   MDX_TRACK_GATE(a6)
        clr.b   MDX_TRACK_ACTIVE(a6)
        move.w  mxdrv_mdx_active,d0
        bclr    d7,d0
        move.w  d0,mxdrv_mdx_active

mdx_tick_next:
        addq.w  #1,d7
        lea     MDX_TRACK_BYTES(a6),a6
        cmpi.w  #MDX_TRACK_COUNT,d7
        bcs     mdx_tick_track

        tst.w   mxdrv_mdx_active
        bne     mdx_tick_return
        clr.b   mxdrv_playing
        move.b  #1,mxdrv_paused
mdx_tick_return:
        moveq   #0,d0
        move.w  mxdrv_mdx_active,d0
        movem.l (sp)+,d1-d7/a0-a6
        rts

; Stop the currently sounding FM key or PCM voice for track d7/a6.
mdx_stop_voice:
        tst.b   MDX_TRACK_SOUNDING(a6)
        beq     .done
        cmpi.w  #8,d7
        bcc     .pcm
        moveq   #$08,d1
        moveq   #0,d2
        move.b  d7,d2
        bsr     mxdrv_write_ym2151
        bra     .clear
.pcm:
        move.w  d7,d0
        subi.w  #8,d0
        bsr     mxdrv_pdx_voice_stop
.clear:
        clr.b   MDX_TRACK_SOUNDING(a6)
.done:
        rts

; Load the selected 26-byte MXDRV FM voice record into this channel. The
; record is ID, algorithm/feedback, PMS/AMS, four DT1/MUL bytes, four TL bytes,
; then sixteen envelope/DT2 bytes. E2 stores the pointer after the ID.
mdx_load_fm_voice:
        tst.b   MDX_TRACK_VOICE_DIRTY(a6)
        beq     .success
        movea.l MDX_TRACK_VOICE(a6),a1
        move.l  a1,d0
        beq     .error

        moveq   #0,d2
        move.b  (a1)+,d2
        andi.b  #$3f,d2
        moveq   #0,d0
        move.b  MDX_TRACK_PAN(a6),d0
        lsl.b   #6,d0
        or.b    d0,d2
        moveq   #$20,d1
        add.b   d7,d1
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     .error

        moveq   #0,d2
        move.b  (a1)+,d2
        lsl.b   #3,d2
        moveq   #$38,d1
        add.b   d7,d1
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     .error

        moveq   #$40,d1
        add.b   d7,d1
        moveq   #3,d3
.write_dt_mul:
        moveq   #0,d2
        move.b  (a1)+,d2
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     .error
        addq.b  #8,d1
        dbra    d3,.write_dt_mul

        moveq   #$60,d1
        add.b   d7,d1
        moveq   #3,d3
.write_tl:
        moveq   #0,d2
        move.b  (a1)+,d2
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     .error
        addq.b  #8,d1
        dbra    d3,.write_tl

        moveq   #0,d1
        move.b  #$80,d1
        add.b   d7,d1
        moveq   #15,d3
.write_envelope:
        moveq   #0,d2
        move.b  (a1)+,d2
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     .error
        addq.b  #8,d1
        dbra    d3,.write_envelope

        clr.b   MDX_TRACK_VOICE_DIRTY(a6)
.success:
        moveq   #0,d0
        rts
.error:
        moveq   #-1,d0
        rts

; YM2151 KC code for MDX semitones 0..95, copied from MXDRV's OPMNoteTable.
mdx_opm_note_table:
        dc.b    $00,$01,$02,$04,$05,$06,$08,$09,$0a,$0c,$0d,$0e,$10,$11,$12,$14
        dc.b    $15,$16,$18,$19,$1a,$1c,$1d,$1e,$20,$21,$22,$24,$25,$26,$28,$29
        dc.b    $2a,$2c,$2d,$2e,$30,$31,$32,$34,$35,$36,$38,$39,$3a,$3c,$3d,$3e
        dc.b    $40,$41,$42,$44,$45,$46,$48,$49,$4a,$4c,$4d,$4e,$50,$51,$52,$54
        dc.b    $55,$56,$58,$59,$5a,$5c,$5d,$5e,$60,$61,$62,$64,$65,$66,$68,$69
        dc.b    $6a,$6c,$6d,$6e,$70,$71,$72,$74,$75,$76,$78,$79,$7a,$7c,$7d,$7e
        even

        bss

mxdrv_mdx_end:
        ds.l    1
mxdrv_mdx_voice_table:
        ds.l    1
mxdrv_mdx_active:
        ds.w    1
mxdrv_mdx_tempo:
        ds.b    1
mxdrv_mdx_error:
        ds.b    1
mxdrv_mdx_timer_busy:
        ds.b    1
        even
mxdrv_mdx_service_count:
        ds.l    1
mxdrv_mdx_tracks:
        ds.b    MDX_TRACK_BYTES*MDX_TRACK_COUNT
        even

        end
