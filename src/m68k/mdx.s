        global  mxdrv_mdx_reset
        global  mxdrv_mdx_start
        global  mxdrv_mdx_tick
        global  mxdrv_mdx_active_mask
        global  mxdrv_mdx_timer_service
        global  mxdrv_mdx_timer_period
        global  mxdrv_mdx_timer_ticks
        global  mxdrv_mdx_tempo
        global  mxdrv_mdx_error
        global  mxdrv_mdx_loops

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
MDX_TRACK_CARRIERS      equ     19

; Second-stage performance state. Pitch is MXDRV's 1/64-semitone word,
; note*64+5 plus detune; portamento and the software pitch LFO accumulate
; in longs whose high words join the pitch sum, exactly like the original's
; +$0c/+$36 channel cells.
MDX_TRACK_FLAGS         equ     20
MDX_TRACK_SLOTS         equ     21      ; KON value: voice slot mask<<3 | ch
MDX_TRACK_DETUNE        equ     22      ; signed, 1/64 semitone
MDX_TRACK_PITCH         equ     24      ; note*64+5+detune at note parse
MDX_TRACK_PITCH_CACHE   equ     26      ; last pitch written to KC/KF
MDX_TRACK_PORTA_DELTA   equ     28      ; F2 operand<<8, added per tick
MDX_TRACK_PORTA_ACC     equ     32
MDX_TRACK_KEYON_DELAY   equ     36      ; F0 setting
MDX_TRACK_KEYON_COUNT   equ     37      ; remaining delay ticks
MDX_TRACK_LFO_DELAY     equ     38      ; E9 setting
MDX_TRACK_LFO_COUNT     equ     39      ; remaining LFO hold ticks
MDX_TRACK_PMS_AMS       equ     40      ; EA cache for $38+ch
MDX_TRACK_TL_CACHE      equ     41      ; last carrier attenuation; $ff forces
MDX_TRACK_PLFO_WAVE     equ     42
MDX_TRACK_PCM_FREQ      equ     43      ; ED on a PCM track (0-4)
MDX_TRACK_PLFO_PERIOD   equ     44
MDX_TRACK_PLFO_START    equ     46      ; keyon counter: half/full/1 by wave
MDX_TRACK_PLFO_COUNT    equ     48
MDX_TRACK_PLFO_DELTA    equ     50      ; amp<<8, or <<16 for waves 4-7
MDX_TRACK_PLFO_DELTA_W  equ     54
MDX_TRACK_PLFO_ACC0     equ     58      ; delta for triangle, else 0
MDX_TRACK_PLFO_ACC      equ     62
MDX_TRACK_ALFO_WAVE     equ     66
MDX_TRACK_ALFO_PERIOD   equ     68
MDX_TRACK_ALFO_COUNT    equ     70
MDX_TRACK_ALFO_DELTA    equ     72
MDX_TRACK_ALFO_DELTA_W  equ     74
MDX_TRACK_ALFO_OFFS0    equ     76      ; max(0,-amp*period), max(0,-amp) sq/rnd
MDX_TRACK_ALFO_OFFS     equ     78      ; attenuation added to carrier TLs
MDX_TRACK_BYTES         equ     80
MDX_TRACK_COUNT         equ     16
MDX_TRACK_TABLE_BYTES   equ     2+MDX_TRACK_COUNT*2
MDX_COMMAND_BUDGET      equ     64

; MDX_TRACK_FLAGS bits
MDX_FLAG_KEYON          equ     0       ; note waiting for its keyon service
MDX_FLAG_PORTA          equ     1       ; F2 slide armed for the current note
MDX_FLAG_LEGATO         equ     2       ; F7: suppress this note's gate keyoff
MDX_FLAG_PLFO           equ     3       ; EC software pitch LFO enabled
MDX_FLAG_ALFO           equ     4       ; EB software volume LFO enabled
MDX_FLAG_OPM_SYNC       equ     5       ; EA bit6: reset hardware LFO at keyon
MDX_FLAG_SYNC_WAIT      equ     6       ; EE: parked until EF flags this track
MDX_FLAG_DAMP           equ     7       ; E7 3: force keyoff before every keyon

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
        lea     mxdrv_mdx_sync_flags,a0
        clr.l   (a0)+
        clr.l   (a0)+
        clr.l   (a0)+
        clr.l   (a0)+
        move.w  #$1234,mxdrv_mdx_random ; MXDRV's noise-wave LFO seed
        clr.w   mxdrv_mdx_loops
        clr.w   mxdrv_mdx_looped
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

; Initialize a raw MDX file. Its variable header is a Shift-JIS title ending
; in CR/LF/$1a, a zero-terminated PDX name, then the sequence base. Sequence
; offsets are relative to that base: one voice-table word followed by either
; nine legacy track words or sixteen PCM8 track words. The first track offset
; encodes which form is present: (offset-2)/2 is the track count.
; Every scan and resolved byte must remain inside the copied MDX buffer.
; out: d0.l=0 on success, -1 for a malformed/truncated MDX image
mxdrv_mdx_start:
        bsr     mxdrv_mdx_reset
        move.l  mxdrv_mdx_size,d2
        cmpi.l  #9,d2
        bcs     mdx_start_error

        lea     mxdrv_mdx_buffer,a0
        lea     (a0,d2.l),a1
        move.l  a1,mxdrv_mdx_end

        ; Locate the exact title terminator rather than accepting an embedded
        ; $1a byte in the Shift-JIS title.
        movea.l a0,a2
mdx_start_title_scan:
        lea     3(a2),a3
        cmpa.l  a1,a3
        bhi     mdx_start_error
        cmpi.b  #$0d,(a2)
        bne     mdx_start_title_next
        cmpi.b  #$0a,1(a2)
        bne     mdx_start_title_next
        cmpi.b  #$1a,2(a2)
        beq     mdx_start_title_done
mdx_start_title_next:
        addq.l  #1,a2
        bra     mdx_start_title_scan
mdx_start_title_done:
        movea.l a3,a2                  ; byte after CR/LF/$1a

        ; Skip the optional PDX name, including its terminating zero. The
        ; following relative-offset words may legally begin at an odd address
        ; on the Falcon's 68030.
mdx_start_pdx_scan:
        cmpa.l  a1,a2
        bcc     mdx_start_error
        tst.b   (a2)+
        bne     mdx_start_pdx_scan

        lea     4(a2),a3               ; voice plus first track offset
        cmpa.l  a1,a3
        bhi     mdx_start_error

        moveq   #0,d5
        move.w  2(a2),d5
        cmpi.w  #2,d5
        bls     mdx_start_error
        subq.w  #2,d5
        btst    #0,d5
        bne     mdx_start_error
        lsr.w   #1,d5
        cmpi.w  #9,d5
        beq     mdx_start_track_count_ready
        cmpi.w  #MDX_TRACK_COUNT,d5
        bne     mdx_start_error
mdx_start_track_count_ready:
        move.w  d5,d6
        add.w   d6,d6
        addq.w  #2,d6                  ; complete sequence-table byte count
        lea     (a2,d6.w),a3
        cmpa.l  a1,a3
        bhi     mdx_start_error

        moveq   #0,d0
        move.w  (a2),d0
        cmp.w   d6,d0
        bcs     mdx_start_error
        lea     (a2,d0.l),a3
        cmpa.l  a1,a3
        bcc     mdx_start_error
        move.l  a3,mxdrv_mdx_voice_table

        lea     2(a2),a4
        lea     mxdrv_mdx_tracks,a6
        moveq   #0,d7
        moveq   #0,d4
.init_track:
        moveq   #0,d0
        move.w  (a4)+,d0
        cmp.w   d6,d0
        bcs     mdx_start_error
        lea     (a2,d0.l),a3
        cmpa.l  a1,a3
        bcc     mdx_start_error
        move.l  a3,MDX_TRACK_POINTER(a6)
        move.b  #1,MDX_TRACK_ACTIVE(a6)
        move.b  #3,MDX_TRACK_PAN(a6)
        move.b  #8,MDX_TRACK_VOLUME(a6)
        move.b  #8,MDX_TRACK_NOTE_LENGTH(a6)
        move.b  #4,MDX_TRACK_PCM_FREQ(a6)      ; MDX PCM default: 15.625 kHz
        move.b  #$ff,MDX_TRACK_TL_CACHE(a6)
        lea     MDX_TRACK_BYTES(a6),a6
        bset    d7,d4
        addq.w  #1,d7
        cmp.w   d5,d7
        bcs     .init_track

        move.w  d4,mxdrv_mdx_active
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

; Advance every active track by one MXDRV timer tick. This second-stage
; executor covers the full MXDRV 2.06 command set: waits, FM/PCM notes, the
; $ff-$f4 tempo/control/repeat commands, detune, portamento, performance
; end with loop targets, keyon delay, channel synchronization, noise and
; PCM frequency, both software LFOs with their keyon delay, the hardware
; OPM LFO, legato slurs, PCM8 enable, and the $e7 extension prefix. Only
; $e7 sub-commands with host-specific operand shapes end a track (with
; mxdrv_mdx_error), keeping malformed or newer streams bounded.
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

        ; An EE-parked track sleeps whole ticks until its EF flag arrives,
        ; then resumes parsing at the saved pointer.
        btst    #MDX_FLAG_SYNC_WAIT,MDX_TRACK_FLAGS(a6)
        beq     mdx_tick_gate
        lea     mxdrv_mdx_sync_flags,a0
        tst.b   (a0,d7.w)
        beq     mdx_tick_next
        clr.b   (a0,d7.w)
        bclr    #MDX_FLAG_SYNC_WAIT,MDX_TRACK_FLAGS(a6)
        bra     mdx_parse_track

mdx_tick_gate:
        tst.w   MDX_TRACK_GATE(a6)
        beq     mdx_tick_duration
        subq.w  #1,MDX_TRACK_GATE(a6)
        bne     mdx_tick_duration
        btst    #MDX_FLAG_LEGATO,MDX_TRACK_FLAGS(a6)
        bne     mdx_tick_duration
        bsr     mdx_stop_voice

mdx_tick_duration:
        tst.w   MDX_TRACK_WAIT(a6)
        beq     mdx_parse_track
        subq.w  #1,MDX_TRACK_WAIT(a6)
        bne     mdx_tick_service

mdx_parse_track:
        ; Portamento is a one-note slide and a legato slur covers exactly the
        ; note it precedes: both arm inside one parse pass and clear at the
        ; start of the next, mirroring the original's andi #$7b.
        moveq   #(1<<MDX_FLAG_PORTA)|(1<<MDX_FLAG_LEGATO),d0
        not.b   d0
        and.b   d0,MDX_TRACK_FLAGS(a6)
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
        cmpi.b  #$ff,d0
        beq     mdx_command_tempo
        cmpi.b  #$fe,d0
        beq     mdx_command_opm
        cmpi.b  #$fd,d0
        beq     mdx_command_voice
        cmpi.b  #$fc,d0
        beq     mdx_command_pan
        cmpi.b  #$fb,d0
        beq     mdx_command_volume
        cmpi.b  #$fa,d0
        beq     mdx_command_volume_down
        cmpi.b  #$f9,d0
        beq     mdx_command_volume_up
        cmpi.b  #$f8,d0
        beq     mdx_command_note_length
        cmpi.b  #$f7,d0
        beq     mdx_command_legato
        cmpi.b  #$f6,d0
        beq     mdx_command_repeat_start
        cmpi.b  #$f5,d0
        beq     mdx_command_repeat_end
        cmpi.b  #$f4,d0
        beq     mdx_command_repeat_escape
        cmpi.b  #$f3,d0
        beq     mdx_command_detune
        cmpi.b  #$f2,d0
        beq     mdx_command_portamento
        cmpi.b  #$f1,d0
        beq     mdx_command_performance_end
        cmpi.b  #$f0,d0
        beq     mdx_command_keyon_delay
        cmpi.b  #$ef,d0
        beq     mdx_command_sync_send
        cmpi.b  #$ee,d0
        beq     mdx_command_sync_wait
        cmpi.b  #$ed,d0
        beq     mdx_command_noise_freq
        cmpi.b  #$ec,d0
        beq     mdx_command_pitch_lfo
        cmpi.b  #$eb,d0
        beq     mdx_command_volume_lfo
        cmpi.b  #$ea,d0
        beq     mdx_command_opm_lfo
        cmpi.b  #$e9,d0
        beq     mdx_command_lfo_delay
        cmpi.b  #$e8,d0
        beq     mdx_command_more          ; PCM8 enable: native voices already
        cmpi.b  #$e7,d0
        beq     mdx_command_extension
        bra     mdx_track_end             ; $e0-$e6 end the performance

mdx_parse_rest:
        addq.w  #1,d0
        move.w  d0,MDX_TRACK_WAIT(a6)
        clr.w   MDX_TRACK_GATE(a6)
        move.l  a4,MDX_TRACK_POINTER(a6)
        bra     mdx_tick_service

; A note stores its pitch or PCM entry and arms the keyon service; the
; actual register writes happen in this tick's service phase, F0 ticks
; later when a keyon delay is set.
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
        bne     mdx_tick_service
        cmpi.w  #8,d7
        bcc     .pcm_entry

        lsl.w   #6,d5
        addq.w  #5,d5
        add.w   MDX_TRACK_DETUNE(a6),d5
        bra     .arm_keyon
.pcm_entry:
        moveq   #0,d1
        move.b  MDX_TRACK_BANK(a6),d1
        mulu.w  #96,d1
        add.w   d1,d5
.arm_keyon:
        move.w  d5,MDX_TRACK_PITCH(a6)
        bset    #MDX_FLAG_KEYON,MDX_TRACK_FLAGS(a6)
        move.b  MDX_TRACK_KEYON_DELAY(a6),MDX_TRACK_KEYON_COUNT(a6)
        bra     mdx_tick_service

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
        cmpi.w  #8,d7
        bcc     mdx_command_pcm_volume
        btst    #7,d0                  ; negative values encode raw attenuation
        bne     mdx_command_store_fm_volume
        cmpi.b  #15,d0
        bhi     mdx_track_invalid
mdx_command_store_fm_volume:
        move.b  d0,MDX_TRACK_VOLUME(a6)
        bsr     mdx_apply_fm_volume
        tst.l   d0
        bne     mdx_track_invalid
        bra     mdx_command_more
mdx_command_pcm_volume:
        cmpi.b  #15,d0
        bhi     mdx_track_invalid
        move.b  d0,MDX_TRACK_VOLUME(a6)
        bra     mdx_command_apply_volume

mdx_command_volume_down:
        moveq   #0,d0
        move.b  MDX_TRACK_VOLUME(a6),d0
        cmpi.w  #8,d7
        bcc     mdx_command_volume_down_normal
        btst    #7,d0
        beq     mdx_command_volume_down_normal
        cmpi.b  #$ff,d0
        beq     mdx_command_more
        addq.b  #1,MDX_TRACK_VOLUME(a6)
        bra     mdx_command_apply_volume
mdx_command_volume_down_normal:
        tst.b   d0
        beq     mdx_command_more
        subq.b  #1,MDX_TRACK_VOLUME(a6)
mdx_command_apply_volume:
        cmpi.w  #8,d7
        bcc     mdx_command_apply_pcm_volume
        bsr     mdx_apply_fm_volume
        tst.l   d0
        bne     mdx_track_invalid
        bra     mdx_command_more
mdx_command_apply_pcm_volume:
        move.w  d7,d0
        subi.w  #8,d0
        moveq   #0,d1
        move.b  MDX_TRACK_VOLUME(a6),d1
        bsr     mxdrv_pdx_voice_set_volume
        tst.l   d0
        bne     mdx_track_invalid
        bra     mdx_command_more

mdx_command_volume_up:
        moveq   #0,d0
        move.b  MDX_TRACK_VOLUME(a6),d0
        cmpi.w  #8,d7
        bcc     mdx_command_volume_up_normal
        btst    #7,d0
        beq     mdx_command_volume_up_normal
        cmpi.b  #$80,d0
        beq     mdx_command_more
        subq.b  #1,MDX_TRACK_VOLUME(a6)
        bra     mdx_command_apply_volume
mdx_command_volume_up_normal:
        cmpi.b  #15,d0
        bcc     mdx_command_more
        addq.b  #1,MDX_TRACK_VOLUME(a6)
        bra     mdx_command_apply_volume

mdx_command_note_length:
        cmpa.l  a3,a4
        bcc     mdx_track_invalid
        move.b  (a4)+,MDX_TRACK_NOTE_LENGTH(a6)
        bra     mdx_command_more

; F7 arms a slur: the current note's gate keyoff is suppressed, so the next
; note's KON write finds the keys still down and the OPM's edge-triggered
; envelopes continue through the pitch change.
mdx_command_legato:
        bset    #MDX_FLAG_LEGATO,MDX_TRACK_FLAGS(a6)
        bra     mdx_command_more

; F3 signed-word detune in 1/64-semitone pitch units, folded into each
; following note's target pitch.
mdx_command_detune:
        lea     2(a4),a0
        cmpa.l  a3,a0
        bhi     mdx_track_invalid
        move.b  (a4)+,d0
        lsl.w   #8,d0
        move.b  (a4)+,d0
        move.w  d0,MDX_TRACK_DETUNE(a6)
        bra     mdx_command_more

; F2 signed-word portamento: operand<<8 accumulates every tick of the next
; note; the accumulator's high word joins the pitch sum.
mdx_command_portamento:
        lea     2(a4),a0
        cmpa.l  a3,a0
        bhi     mdx_track_invalid
        move.b  (a4)+,d0
        lsl.w   #8,d0
        move.b  (a4)+,d0
        ext.l   d0
        asl.l   #8,d0
        move.l  d0,MDX_TRACK_PORTA_DELTA(a6)
        bset    #MDX_FLAG_PORTA,MDX_TRACK_FLAGS(a6)
        bra     mdx_command_more

mdx_command_keyon_delay:
        cmpa.l  a3,a4
        bcc     mdx_track_invalid
        move.b  (a4)+,MDX_TRACK_KEYON_DELAY(a6)
        bra     mdx_command_more

; EF flags the operand channel; a track parked by EE wakes on its next tick.
mdx_command_sync_send:
        cmpa.l  a3,a4
        bcc     mdx_track_invalid
        moveq   #0,d0
        move.b  (a4)+,d0
        andi.w  #MDX_TRACK_COUNT-1,d0
        lea     mxdrv_mdx_sync_flags,a0
        move.b  #$ff,(a0,d0.w)
        bra     mdx_command_more

; EE with the flag already raised consumes it and parses on; otherwise the
; track parks at the next command until an EF arrives.
mdx_command_sync_wait:
        lea     mxdrv_mdx_sync_flags,a0
        tst.b   (a0,d7.w)
        beq     .park
        clr.b   (a0,d7.w)
        bra     mdx_command_more
.park:
        bset    #MDX_FLAG_SYNC_WAIT,MDX_TRACK_FLAGS(a6)
        move.l  a4,MDX_TRACK_POINTER(a6)
        bra     mdx_tick_service

; ED on an FM track writes the OPM noise register directly (bit 7 enable,
; bits 4-0 frequency); on a PCM track it selects the ADPCM rate for the
; following notes.
mdx_command_noise_freq:
        cmpa.l  a3,a4
        bcc     mdx_track_invalid
        moveq   #0,d2
        move.b  (a4)+,d2
        cmpi.w  #8,d7
        bcc     .pcm_freq
        moveq   #$0f,d1
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     mdx_track_invalid
        bra     mdx_command_more
.pcm_freq:
        move.b  d2,MDX_TRACK_PCM_FREQ(a6)
        bra     mdx_command_more

; EC wave,period.w,amp.w programs the software pitch LFO; EC $80/$81
; disables/re-enables it. Waves 0-3 are saw, square, triangle, and random;
; waves 4-7 scale the amplitude by a further 256. The keyon counter starts
; at half a period (full for square, one tick for random) so the swing
; centers on the note.
mdx_command_pitch_lfo:
        cmpa.l  a3,a4
        bcc     mdx_track_invalid
        moveq   #0,d1
        move.b  (a4)+,d1
        bmi     .control
        lea     4(a4),a0
        cmpa.l  a3,a0
        bhi     mdx_track_invalid
        bset    #MDX_FLAG_PLFO,MDX_TRACK_FLAGS(a6)
        move.w  d1,d3                  ; keep the raw form byte
        andi.w  #3,d1
        move.b  d1,MDX_TRACK_PLFO_WAVE(a6)

        move.b  (a4)+,d2
        lsl.w   #8,d2
        move.b  (a4)+,d2
        move.w  d2,MDX_TRACK_PLFO_PERIOD(a6)
        cmpi.b  #1,d1                  ; square starts on a full period
        beq     .store_start
        lsr.w   #1,d2
        cmpi.b  #3,d1                  ; random reloads every tick
        bne     .store_start
        moveq   #1,d2
.store_start:
        move.w  d2,MDX_TRACK_PLFO_START(a6)

        move.b  (a4)+,d0
        lsl.w   #8,d0
        move.b  (a4)+,d0
        ext.l   d0
        asl.l   #8,d0
        cmpi.b  #4,d3
        bcs     .amp_scaled
        asl.l   #8,d0
.amp_scaled:
        move.l  d0,MDX_TRACK_PLFO_DELTA(a6)
        cmpi.b  #2,d1                  ; triangle starts one step in
        beq     .store_acc0
        moveq   #0,d0
.store_acc0:
        move.l  d0,MDX_TRACK_PLFO_ACC0(a6)
        bsr     mdx_pitch_lfo_restart
        bra     mdx_command_more
.control:
        btst    #0,d1
        beq     .disable
        bsr     mdx_pitch_lfo_restart
        bra     mdx_command_more
.disable:
        bclr    #MDX_FLAG_PLFO,MDX_TRACK_FLAGS(a6)
        clr.l   MDX_TRACK_PLFO_ACC(a6)
        bra     mdx_command_more

; EB wave,period.w,amp.w programs the software volume LFO as a carrier-TL
; attenuation offset; EB $80/$81 disables/re-enables it. Saw and triangle
; start at max(0,-amp*period), square and random at max(0,-amp), so a
; positive amplitude ramps quieter from the note's own level.
mdx_command_volume_lfo:
        cmpa.l  a3,a4
        bcc     mdx_track_invalid
        moveq   #0,d1
        move.b  (a4)+,d1
        bmi     .control
        lea     4(a4),a0
        cmpa.l  a3,a0
        bhi     mdx_track_invalid
        bset    #MDX_FLAG_ALFO,MDX_TRACK_FLAGS(a6)
        andi.w  #3,d1
        move.b  d1,MDX_TRACK_ALFO_WAVE(a6)

        move.b  (a4)+,d2
        lsl.w   #8,d2
        move.b  (a4)+,d2
        move.w  d2,MDX_TRACK_ALFO_PERIOD(a6)

        move.b  (a4)+,d0
        lsl.w   #8,d0
        move.b  (a4)+,d0
        move.w  d0,MDX_TRACK_ALFO_DELTA(a6)
        btst    #0,d1
        bne     .amp_only
        muls.w  d2,d0
.amp_only:
        neg.w   d0
        bpl     .store_init
        moveq   #0,d0
.store_init:
        move.w  d0,MDX_TRACK_ALFO_OFFS0(a6)
        bsr     mdx_volume_lfo_restart
        bra     mdx_command_more
.control:
        btst    #0,d1
        beq     .disable
        bsr     mdx_volume_lfo_restart
        bra     mdx_command_more
.disable:
        bclr    #MDX_FLAG_ALFO,MDX_TRACK_FLAGS(a6)
        clr.w   MDX_TRACK_ALFO_OFFS(a6)
        bra     mdx_command_more

; EA sync|wave,lfrq,pmd,amd,pms|ams drives the hardware OPM LFO. Bit 6 of
; the first byte requests an LFO phase reset at each keyon. EA $80/$81
; writes the channel's PMS/AMS off/back on.
mdx_command_opm_lfo:
        cmpa.l  a3,a4
        bcc     mdx_track_invalid
        moveq   #0,d2
        move.b  (a4)+,d2
        bmi     .control
        lea     4(a4),a0
        cmpa.l  a3,a0
        bhi     mdx_track_invalid
        bclr    #MDX_FLAG_OPM_SYNC,MDX_TRACK_FLAGS(a6)
        bclr    #6,d2
        beq     .write_wave
        bset    #MDX_FLAG_OPM_SYNC,MDX_TRACK_FLAGS(a6)
.write_wave:
        lea     mxdrv_opm_buffer,a0
        move.b  $1b(a0),d0
        andi.b  #$c0,d0                ; preserve the CT output bits
        or.b    d0,d2
        moveq   #$1b,d1
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     mdx_track_invalid
        moveq   #$18,d1
        moveq   #0,d2
        move.b  (a4)+,d2
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     mdx_track_invalid
        moveq   #$19,d1
        moveq   #0,d2
        move.b  (a4)+,d2
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     mdx_track_invalid
        moveq   #$19,d1
        moveq   #0,d2
        move.b  (a4)+,d2
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     mdx_track_invalid
        move.b  (a4)+,d2
        move.b  d2,MDX_TRACK_PMS_AMS(a6)
.write_pms:
        andi.w  #$ff,d2
        moveq   #$38,d1
        add.b   d7,d1
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     mdx_track_invalid
        bra     mdx_command_more
.control:
        moveq   #0,d0
        btst    #0,d2
        beq     .pms_value
        move.b  MDX_TRACK_PMS_AMS(a6),d0
.pms_value:
        move.w  d0,d2
        bra     .write_pms

mdx_command_lfo_delay:
        cmpa.l  a3,a4
        bcc     mdx_track_invalid
        move.b  (a4)+,MDX_TRACK_LFO_DELAY(a6)
        bra     mdx_command_more

; E7 is MXDRV's extension prefix. Sub-command 0 ends the performance and 3
; sets or clears damp mode (force a keyoff before every keyon). The others
; carry host-PCM8 or fade operands this standalone executor does not model.
mdx_command_extension:
        cmpa.l  a3,a4
        bcc     mdx_track_invalid
        moveq   #0,d0
        move.b  (a4)+,d0
        beq     mdx_track_end
        cmpi.b  #1,d0
        beq     .fade
        cmpi.b  #3,d0
        bne     mdx_track_invalid
        cmpa.l  a3,a4
        bcc     mdx_track_invalid
        tst.b   (a4)+
        beq     .damp_off
        bset    #MDX_FLAG_DAMP,MDX_TRACK_FLAGS(a6)
        bra     mdx_command_more
.damp_off:
        bclr    #MDX_FLAG_DAMP,MDX_TRACK_FLAGS(a6)
        bra     mdx_command_more
.fade:
        cmpa.l  a3,a4
        bcc     mdx_track_invalid
        move.b  (a4)+,mxdrv_fade_wait
        clr.w   mxdrv_fade_counter
        move.b  #1,mxdrv_fade_active
        bra     mdx_command_more

; F6 count,work copies count into the following mutable work byte. MDX data is
; owned by the driver specifically so MXDRV's in-stream repeat state is safe.
mdx_command_repeat_start:
        lea     2(a4),a0
        cmpa.l  a3,a0
        bhi     mdx_track_invalid
        move.b  (a4),1(a4)
        movea.l a0,a4
        bra     mdx_command_more

; F5 signed-back-offset decrements the work byte immediately before its target.
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

; F4 unsigned-forward-offset points at a future F5's two displacement bytes.
; On the final pass (work byte == 1), skip those bytes and continue after F5.
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

; F1 with a zero first operand is the normal performance end. A nonzero
; first byte carries MXDRV's backward loop displacement in its low half:
; the effective long is $ffffxxxx, so the track jumps back and plays
; forever until stopped or faded.
mdx_command_performance_end:
        cmpa.l  a3,a4
        bcc     mdx_track_invalid
        moveq   #0,d0
        move.b  (a4)+,d0
        beq     mdx_track_end
        cmpa.l  a3,a4
        bcc     mdx_track_invalid
        lsl.w   #8,d0
        move.b  (a4)+,d0
        ori.l   #$ffff0000,d0
        adda.l  d0,a4
        lea     mxdrv_mdx_buffer,a0
        cmpa.l  a0,a4
        bls     mdx_track_invalid
        cmpa.l  a3,a4
        bcc     mdx_track_invalid
        ; count completed full-song loops: when every still-active track
        ; has taken its loop jump, the performance wrapped once
        move.w  mxdrv_mdx_looped,d0
        bset    d7,d0
        move.w  d0,mxdrv_mdx_looped
        move.w  mxdrv_mdx_active,d1
        and.w   d1,d0
        cmp.w   d1,d0
        bne     mdx_command_more
        addq.w  #1,mxdrv_mdx_loops
        clr.w   mxdrv_mdx_looped
        bra     mdx_command_more

mdx_command_more:
        dbra    d6,mdx_parse_command
        bra     mdx_track_invalid

mdx_service_invalid:
        move.b  #1,mxdrv_mdx_error
        bra     mdx_track_retire

mdx_track_invalid:
        move.b  #1,mxdrv_mdx_error
mdx_track_end:
        move.l  a4,MDX_TRACK_POINTER(a6)
mdx_track_retire:
        bsr     mdx_stop_voice
        clr.w   MDX_TRACK_WAIT(a6)
        clr.w   MDX_TRACK_GATE(a6)
        clr.b   MDX_TRACK_ACTIVE(a6)
        move.w  mxdrv_mdx_active,d0
        bclr    d7,d0
        move.w  d0,mxdrv_mdx_active

; Per-tick performance service, run for every live track after its parse:
; portamento and software-LFO advance, the delayed keyon sequence, and the
; pitch/volume register refresh. PCM tracks only run the delayed voice
; start; everything else is FM-only.
mdx_tick_service:
        cmpi.w  #8,d7
        bcc     mdx_service_pcm

        btst    #MDX_FLAG_PORTA,MDX_TRACK_FLAGS(a6)
        beq     .no_porta
        tst.b   MDX_TRACK_KEYON_COUNT(a6)
        bne     .no_porta
        move.l  MDX_TRACK_PORTA_DELTA(a6),d0
        add.l   d0,MDX_TRACK_PORTA_ACC(a6)
.no_porta:
        ; With an E9 delay configured the LFOs hold through the keyon delay
        ; and the countdown, then restart centered; without one they run
        ; continuously across notes.
        tst.b   MDX_TRACK_LFO_DELAY(a6)
        beq     .advance_lfos
        tst.b   MDX_TRACK_KEYON_COUNT(a6)
        bne     .lfos_done
        tst.b   MDX_TRACK_LFO_COUNT(a6)
        beq     .advance_lfos
        subq.b  #1,MDX_TRACK_LFO_COUNT(a6)
        bne     .lfos_done
        bsr     mdx_pitch_lfo_restart
        bsr     mdx_volume_lfo_restart
        bra     .lfos_done
.advance_lfos:
        btst    #MDX_FLAG_PLFO,MDX_TRACK_FLAGS(a6)
        beq     .no_plfo
        bsr     mdx_pitch_lfo_step
.no_plfo:
        btst    #MDX_FLAG_ALFO,MDX_TRACK_FLAGS(a6)
        beq     .lfos_done
        bsr     mdx_volume_lfo_step
.lfos_done:
        btst    #MDX_FLAG_KEYON,MDX_TRACK_FLAGS(a6)
        beq     .refresh
        tst.b   MDX_TRACK_KEYON_COUNT(a6)
        beq     .keyon
        subq.b  #1,MDX_TRACK_KEYON_COUNT(a6)
        bra     .refresh

.keyon:
        bsr     mdx_load_fm_voice
        tst.l   d0
        bne     mdx_service_invalid
        move.b  MDX_TRACK_LFO_DELAY(a6),d0
        move.b  d0,MDX_TRACK_LFO_COUNT(a6)
        beq     .no_lfo_delay
        clr.l   MDX_TRACK_PLFO_ACC(a6)
        clr.w   MDX_TRACK_ALFO_OFFS(a6)
        subq.b  #1,MDX_TRACK_LFO_COUNT(a6)
        bne     .no_lfo_delay
        bsr     mdx_pitch_lfo_restart
        bsr     mdx_volume_lfo_restart
.no_lfo_delay:
        btst    #MDX_FLAG_OPM_SYNC,MDX_TRACK_FLAGS(a6)
        beq     .no_opm_sync
        moveq   #$01,d1                ; pulse the OPM LFO phase reset
        moveq   #$02,d2
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     mdx_service_invalid
        moveq   #$01,d1
        moveq   #$00,d2
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     mdx_service_invalid
.no_opm_sync:
        clr.l   MDX_TRACK_PORTA_ACC(a6)
        bsr     mdx_write_fm_pitch
        tst.l   d0
        bne     mdx_service_invalid
        bsr     mdx_apply_fm_volume
        tst.l   d0
        bne     mdx_service_invalid
        btst    #MDX_FLAG_DAMP,MDX_TRACK_FLAGS(a6)
        beq     .send_keyon
        bsr     mdx_stop_voice
.send_keyon:
        tst.b   MDX_TRACK_SOUNDING(a6)
        bne     .keyed                 ; keys still held: a slur, no retrigger
        moveq   #$08,d1
        moveq   #0,d2
        move.b  MDX_TRACK_SLOTS(a6),d2
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     mdx_service_invalid
        move.b  #1,MDX_TRACK_SOUNDING(a6)
.keyed:
        bclr    #MDX_FLAG_KEYON,MDX_TRACK_FLAGS(a6)
        bra     mdx_tick_next

.refresh:
        bsr     mdx_write_fm_pitch
        tst.l   d0
        bne     mdx_service_invalid
        bsr     mdx_apply_fm_volume
        tst.l   d0
        bne     mdx_service_invalid
        bra     mdx_tick_next

mdx_service_pcm:
        btst    #MDX_FLAG_KEYON,MDX_TRACK_FLAGS(a6)
        beq     mdx_tick_next
        tst.b   MDX_TRACK_KEYON_COUNT(a6)
        beq     .start
        subq.b  #1,MDX_TRACK_KEYON_COUNT(a6)
        bra     mdx_tick_next
.start:
        bclr    #MDX_FLAG_KEYON,MDX_TRACK_FLAGS(a6)
        moveq   #0,d1
        move.w  MDX_TRACK_PITCH(a6),d1 ; bank*96+note resolved at parse time
        move.w  d7,d0
        subi.w  #8,d0
        moveq   #0,d2
        move.b  MDX_TRACK_PCM_FREQ(a6),d2
        moveq   #0,d3
        move.b  MDX_TRACK_PAN(a6),d3
        moveq   #0,d4
        move.b  MDX_TRACK_VOLUME(a6),d4
        bsr     mxdrv_pdx_voice_start
        tst.l   d0
        bne     mdx_tick_next           ; empty/missing PDX is a silent note
        move.b  #1,MDX_TRACK_SOUNDING(a6)

mdx_tick_next:
        addq.w  #1,d7
        lea     MDX_TRACK_BYTES(a6),a6
        cmpi.w  #MDX_TRACK_COUNT,d7
        bcs     mdx_tick_track

        ; Fade service: an armed fade steps the global attenuation every
        ; wait period (two counts per tick like the original) and reapplies
        ; every voice's volume through the cached paths; full attenuation
        ; silences the voices and retires the performance like a normal
        ; song end.
        tst.b   mxdrv_fade_active
        beq     mdx_fade_done
        move.w  mxdrv_fade_counter,d0
        subq.w  #2,d0
        move.w  d0,mxdrv_fade_counter
        bpl     mdx_fade_done
        moveq   #0,d0
        move.b  mxdrv_fade_wait,d0
        move.w  d0,mxdrv_fade_counter
        addq.b  #1,mxdrv_fade_offset
        cmpi.b  #$3e,mxdrv_fade_offset
        bcs     mdx_fade_apply
        clr.b   mxdrv_fade_active
        move.b  #$7f,mxdrv_fade_offset
        lea     mxdrv_mdx_tracks,a6
        moveq   #0,d7
mdx_fade_stop_all:
        bsr     mdx_stop_voice
        clr.b   MDX_TRACK_ACTIVE(a6)
        addq.w  #1,d7
        lea     MDX_TRACK_BYTES(a6),a6
        cmpi.w  #MDX_TRACK_COUNT,d7
        bcs     mdx_fade_stop_all
        clr.w   mxdrv_mdx_active
        bra     mdx_fade_done
mdx_fade_apply:
        lea     mxdrv_mdx_tracks,a6
        moveq   #0,d7
mdx_fade_apply_track:
        cmpi.w  #8,d7
        bcc     mdx_fade_apply_pcm
        bsr     mdx_apply_fm_volume
        bra     mdx_fade_apply_next
mdx_fade_apply_pcm:
        tst.b   MDX_TRACK_SOUNDING(a6)
        beq     mdx_fade_apply_next
        move.w  d7,d0
        subi.w  #8,d0
        moveq   #0,d1
        move.b  MDX_TRACK_VOLUME(a6),d1
        move.b  mxdrv_fade_offset,d2
        lsr.b   #2,d2
        sub.b   d2,d1
        bpl     mdx_fade_apply_volume
        moveq   #0,d1
mdx_fade_apply_volume:
        bsr     mxdrv_pdx_voice_set_volume
mdx_fade_apply_next:
        addq.w  #1,d7
        lea     MDX_TRACK_BYTES(a6),a6
        cmpi.w  #MDX_TRACK_COUNT,d7
        bcs     mdx_fade_apply_track
mdx_fade_done:

        tst.w   mxdrv_mdx_active
        bne     mdx_tick_return
        clr.b   mxdrv_playing
        move.b  #1,mxdrv_paused
mdx_tick_return:
        moveq   #0,d0
        move.w  mxdrv_mdx_active,d0
        movem.l (sp)+,d1-d7/a0-a6
        rts

; Sum the note pitch with the portamento and pitch-LFO accumulators' high
; words; when the result moved, write KF ($30+ch: pitch<<2 low byte) and KC
; ($28+ch: the clamped 96-semitone table), mirroring mxdrv17.s SetOPMPitch.
; The cache holds the unclamped sum, like the original's +$14 cell.
; out: d0.l=0 or the failing DSP reply
mdx_write_fm_pitch:
        move.w  MDX_TRACK_PITCH(a6),d2
        add.w   MDX_TRACK_PORTA_ACC(a6),d2
        add.w   MDX_TRACK_PLFO_ACC(a6),d2
        cmp.w   MDX_TRACK_PITCH_CACHE(a6),d2
        beq     .unchanged
        move.w  d2,MDX_TRACK_PITCH_CACHE(a6)
        cmpi.w  #$17ff,d2
        bls     .in_range
        tst.w   d2
        bpl     .clamp_high
        moveq   #0,d2
        bra     .in_range
.clamp_high:
        move.w  #$17ff,d2
.in_range:
        add.w   d2,d2
        add.w   d2,d2
        moveq   #$30,d1
        add.b   d7,d1
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     .done
        lsr.w   #8,d2
        lea     mdx_opm_note_table(pc),a0
        move.b  (a0,d2.w),d2
        moveq   #$28,d1
        add.b   d7,d1
        bra     mxdrv_write_ym2151
.unchanged:
        moveq   #0,d0
.done:
        rts

; Reload a software LFO's working state for a keyon or an $81 re-enable:
; the pitch counter starts at its centering value, the amplitude counter at
; a full period.
mdx_pitch_lfo_restart:
        move.w  MDX_TRACK_PLFO_START(a6),MDX_TRACK_PLFO_COUNT(a6)
        move.l  MDX_TRACK_PLFO_DELTA(a6),MDX_TRACK_PLFO_DELTA_W(a6)
        move.l  MDX_TRACK_PLFO_ACC0(a6),MDX_TRACK_PLFO_ACC(a6)
        rts

mdx_volume_lfo_restart:
        move.w  MDX_TRACK_ALFO_PERIOD(a6),MDX_TRACK_ALFO_COUNT(a6)
        move.w  MDX_TRACK_ALFO_DELTA(a6),MDX_TRACK_ALFO_DELTA_W(a6)
        move.w  MDX_TRACK_ALFO_OFFS0(a6),MDX_TRACK_ALFO_OFFS(a6)
        rts

; One tick of the software pitch LFO. Saw accumulates and flips its sign at
; each period, square holds the delta and flips it, triangle accumulates
; and flips the delta, and the noise wave resamples delta-scaled randomness
; every period tick, all per the original's four L0010be-L001100 stepping
; functions.
mdx_pitch_lfo_step:
        moveq   #0,d0
        move.b  MDX_TRACK_PLFO_WAVE(a6),d0
        add.w   d0,d0
        move.w  .waves(pc,d0.w),d0
        jmp     .waves(pc,d0.w)
.waves:
        dc.w    .saw-.waves
        dc.w    .square-.waves
        dc.w    .triangle-.waves
        dc.w    .random-.waves
.saw:
        move.l  MDX_TRACK_PLFO_DELTA_W(a6),d0
        add.l   d0,MDX_TRACK_PLFO_ACC(a6)
        subq.w  #1,MDX_TRACK_PLFO_COUNT(a6)
        bne     .done
        move.w  MDX_TRACK_PLFO_PERIOD(a6),MDX_TRACK_PLFO_COUNT(a6)
        neg.l   MDX_TRACK_PLFO_ACC(a6)
        rts
.square:
        move.l  MDX_TRACK_PLFO_DELTA_W(a6),MDX_TRACK_PLFO_ACC(a6)
        subq.w  #1,MDX_TRACK_PLFO_COUNT(a6)
        bne     .done
        move.w  MDX_TRACK_PLFO_PERIOD(a6),MDX_TRACK_PLFO_COUNT(a6)
        neg.l   MDX_TRACK_PLFO_DELTA_W(a6)
        rts
.triangle:
        move.l  MDX_TRACK_PLFO_DELTA_W(a6),d0
        add.l   d0,MDX_TRACK_PLFO_ACC(a6)
        subq.w  #1,MDX_TRACK_PLFO_COUNT(a6)
        bne     .done
        move.w  MDX_TRACK_PLFO_PERIOD(a6),MDX_TRACK_PLFO_COUNT(a6)
        neg.l   MDX_TRACK_PLFO_DELTA_W(a6)
.done:
        rts
.random:
        subq.w  #1,MDX_TRACK_PLFO_COUNT(a6)
        bne     .done
        bsr     mdx_random
        muls.w  MDX_TRACK_PLFO_DELTA_W+2(a6),d0
        move.l  d0,MDX_TRACK_PLFO_ACC(a6)
        move.w  MDX_TRACK_PLFO_PERIOD(a6),MDX_TRACK_PLFO_COUNT(a6)
        rts

; One tick of the software volume LFO over the attenuation offset word;
; its application reads only the high byte, so amplitudes are in 1/256 TL
; steps like the original's +$4a cell.
mdx_volume_lfo_step:
        moveq   #0,d0
        move.b  MDX_TRACK_ALFO_WAVE(a6),d0
        add.w   d0,d0
        move.w  .waves(pc,d0.w),d0
        jmp     .waves(pc,d0.w)
.waves:
        dc.w    .saw-.waves
        dc.w    .square-.waves
        dc.w    .triangle-.waves
        dc.w    .random-.waves
.saw:
        move.w  MDX_TRACK_ALFO_DELTA_W(a6),d0
        add.w   d0,MDX_TRACK_ALFO_OFFS(a6)
        subq.w  #1,MDX_TRACK_ALFO_COUNT(a6)
        bne     .done
        move.w  MDX_TRACK_ALFO_PERIOD(a6),MDX_TRACK_ALFO_COUNT(a6)
        move.w  MDX_TRACK_ALFO_OFFS0(a6),MDX_TRACK_ALFO_OFFS(a6)
        rts
.square:
        subq.w  #1,MDX_TRACK_ALFO_COUNT(a6)
        bne     .done
        move.w  MDX_TRACK_ALFO_PERIOD(a6),MDX_TRACK_ALFO_COUNT(a6)
        move.w  MDX_TRACK_ALFO_DELTA_W(a6),d0
        add.w   d0,MDX_TRACK_ALFO_OFFS(a6)
        neg.w   MDX_TRACK_ALFO_DELTA_W(a6)
        rts
.triangle:
        move.w  MDX_TRACK_ALFO_DELTA_W(a6),d0
        add.w   d0,MDX_TRACK_ALFO_OFFS(a6)
        subq.w  #1,MDX_TRACK_ALFO_COUNT(a6)
        bne     .done
        move.w  MDX_TRACK_ALFO_PERIOD(a6),MDX_TRACK_ALFO_COUNT(a6)
        neg.w   MDX_TRACK_ALFO_DELTA_W(a6)
.done:
        rts
.random:
        subq.w  #1,MDX_TRACK_ALFO_COUNT(a6)
        bne     .done
        bsr     mdx_random
        muls.w  MDX_TRACK_ALFO_DELTA_W(a6),d0
        move.w  d0,MDX_TRACK_ALFO_OFFS(a6)
        move.w  MDX_TRACK_ALFO_PERIOD(a6),MDX_TRACK_ALFO_COUNT(a6)
        rts

; MXDRV's 16-bit LCG behind both noise-wave LFOs.
mdx_random:
        move.w  mxdrv_mdx_random,d0
        mulu.w  #$c549,d0
        addi.l  #12,d0
        move.w  d0,mxdrv_mdx_random
        lsr.l   #8,d0
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
; record is ID, algorithm/feedback, the keyable slot mask, four DT1/MUL
; bytes, four TL bytes, then sixteen envelope/DT2 bytes. FD stores the
; pointer after the ID.
mdx_load_fm_voice:
        tst.b   MDX_TRACK_VOICE_DIRTY(a6)
        beq     .success
        movea.l MDX_TRACK_VOICE(a6),a1
        move.l  a1,d0
        beq     .error

        moveq   #0,d2
        move.b  (a1)+,d2
        moveq   #0,d0
        move.b  d2,d0
        andi.w  #7,d0
        lea     mdx_carrier_slot(pc),a0
        move.b  (a0,d0.w),MDX_TRACK_CARRIERS(a6)
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

        ; The slot mask becomes this channel's KON image; PMS/AMS belongs
        ; to the EA command, not the voice record.
        move.b  (a1)+,d2
        lsl.b   #3,d2
        or.b    d7,d2
        move.b  d2,MDX_TRACK_SLOTS(a6)

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
        moveq   #0,d4
        move.b  MDX_TRACK_CARRIERS(a6),d4
        moveq   #3,d3
.write_tl:
        moveq   #0,d2
        move.b  (a1)+,d2
        lsr.b   #1,d4
        bcc     .write_tl_value
        moveq   #$7f,d2               ; carriers are restored with volume below
.write_tl_value:
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
        move.b  #$ff,MDX_TRACK_TL_CACHE(a6) ; new base TLs force a rewrite
        bsr     mdx_apply_fm_volume
        tst.l   d0
        bne     .error
.success:
        moveq   #0,d0
        rts
.error:
        moveq   #-1,d0
        rts

; Rewrite only the algorithm's carrier TL registers. Normal MDX volumes 0-15
; use MXDRV's attenuation table; values $80-$ff directly encode attenuation
; 0-127. The software volume LFO's offset high byte joins with the
; original's byte-carry saturation, and an unchanged total attenuation
; skips the rewrite entirely (the voice loader forces its cache).
mdx_apply_fm_volume:
        movem.l d1-d5/a0-a1,-(sp)
        tst.b   MDX_TRACK_VOICE_DIRTY(a6)
        bne     mdx_apply_fm_volume_success
        movea.l MDX_TRACK_VOICE(a6),a0
        move.l  a0,d0
        beq     mdx_apply_fm_volume_success

        moveq   #0,d5
        move.b  MDX_TRACK_VOLUME(a6),d5
        bclr    #7,d5
        bne     mdx_apply_fm_volume_lfo
        lea     mdx_volume_table(pc),a1
        move.b  (a1,d5.w),d5
mdx_apply_fm_volume_lfo:
        add.b   mxdrv_fade_offset,d5
        bcs     mdx_apply_fm_volume_clamp
        bmi     mdx_apply_fm_volume_clamp
        add.b   MDX_TRACK_ALFO_OFFS(a6),d5
        bcs     mdx_apply_fm_volume_clamp
        bpl     mdx_apply_fm_volume_ready
mdx_apply_fm_volume_clamp:
        moveq   #$7f,d5
mdx_apply_fm_volume_ready:
        cmp.b   MDX_TRACK_TL_CACHE(a6),d5
        beq     mdx_apply_fm_volume_success
        move.b  d5,MDX_TRACK_TL_CACHE(a6)
        lea     6(a0),a0               ; four base TL bytes in the voice record
        moveq   #0,d3
        move.b  MDX_TRACK_CARRIERS(a6),d3
        moveq   #$60,d1
        add.b   d7,d1
        moveq   #3,d4
mdx_apply_fm_volume_loop:
        moveq   #0,d2
        move.b  (a0)+,d2
        lsr.b   #1,d3
        bcc     mdx_apply_fm_volume_next
        add.b   d5,d2
        bpl     mdx_apply_fm_volume_write
        moveq   #$7f,d2
mdx_apply_fm_volume_write:
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     mdx_apply_fm_volume_error
mdx_apply_fm_volume_next:
        addq.b  #8,d1
        dbra    d4,mdx_apply_fm_volume_loop
mdx_apply_fm_volume_success:
        moveq   #0,d0
        bra     mdx_apply_fm_volume_return
mdx_apply_fm_volume_error:
        moveq   #-1,d0
mdx_apply_fm_volume_return:
        movem.l (sp)+,d1-d5/a0-a1
        rts

; YM2151 KC code for MDX semitones 0..95, copied from MXDRV's OPMNoteTable.
mdx_opm_note_table:
        dc.b    $00,$01,$02,$04,$05,$06,$08,$09,$0a,$0c,$0d,$0e,$10,$11,$12,$14
        dc.b    $15,$16,$18,$19,$1a,$1c,$1d,$1e,$20,$21,$22,$24,$25,$26,$28,$29
        dc.b    $2a,$2c,$2d,$2e,$30,$31,$32,$34,$35,$36,$38,$39,$3a,$3c,$3d,$3e
        dc.b    $40,$41,$42,$44,$45,$46,$48,$49,$4a,$4c,$4d,$4e,$50,$51,$52,$54
        dc.b    $55,$56,$58,$59,$5a,$5c,$5d,$5e,$60,$61,$62,$64,$65,$66,$68,$69
        dc.b    $6a,$6c,$6d,$6e,$70,$71,$72,$74,$75,$76,$78,$79,$7a,$7c,$7d,$7e

mdx_carrier_slot:
        dc.b    $08,$08,$08,$08,$0c,$0e,$0e,$0f

mdx_volume_table:
        dc.b    $2a,$28,$25,$22,$20,$1d,$1a,$18,$15,$12,$10,$0d,$0a,$08,$05,$02
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
mxdrv_mdx_random:
        ds.w    1
mxdrv_mdx_loops:
        ds.w    1
mxdrv_mdx_looped:
        ds.w    1
mxdrv_mdx_sync_flags:
        ds.b    MDX_TRACK_COUNT
        even
mxdrv_mdx_tracks:
        ds.b    MDX_TRACK_BYTES*MDX_TRACK_COUNT
        even

        end
