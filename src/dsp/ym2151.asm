; F030MXDRV YM2151 DSP core
;
; The register, phase, envelope, algorithm, feedback, panning, and YM3012
; behavior here follows the vendored MAME/ymfm core. Continuous SSI output is
; layered on top of this command-clocked kernel.

        include 'ioequ.inc'
        include 'protocol.inc'

; -----------------------------------------------------------------------------
; Bootstrap vector
; -----------------------------------------------------------------------------

        org     p:$0
        jmp     start

; Buffered SSI owns r6/m6 while active. The normal fast interrupt transfers
; one prepared word without disturbing synthesis state. The exception vector
; enters a recovery ISR because clearing TUE requires reading SSISR and then
; writing TX. The normal path remains a two-instruction fast interrupt.
        org     p:$10
        movep   x:(r6)+,x:m_tx
        nop

        org     p:$12
        jsr     ssi_tx_exception

; -----------------------------------------------------------------------------
; YM2151 state in X memory
; -----------------------------------------------------------------------------

; Keep frequently accessed scalar state in the short-addressable internal X
; page. Besides avoiding external-memory traffic, this removes an extension
; word from most scalar loads/stores and recovers scarce TOS loader space.
        org     x:$0

last_command:
        ds      1

query_channel:
        ds      1
query_raw_operator:
        ds      1
query_block_freq:
        ds      1
query_dtmul:
        ds      1
query_detune:
        ds      1

ym_env_counter:
        ds      1
ym_env_tick:
        ds      1
ym_last_left:
        ds      1
ym_last_right:
        ds      1

; OPM global state. The 30-bit LFO counter is split at bit 22 so both pieces
; remain positive native integers. The noise history needs 25 bits because the
; LFO noise waveform consumes bits 17-24.
ym_lfo_fraction:
        ds      1
ym_lfo_phase:
        ds      1
ym_lfo_am:
        ds      1
ym_lfo_pm:
        ds      1
ym_lfo_raw_am:
        ds      1
ym_lfo_raw_pm:
        ds      1
ym_noise_lfsr_low:
        ds      1
ym_noise_lfsr_high:
        ds      1
ym_noise_counter:
        ds      1
ym_noise_frequency:
        ds      1
ym_noise_state:
        ds      1
ym_noise_newbit:
        ds      1

ym_status:
        ds      1
ym_busy:
        ds      1
ym_csm_active:
        ds      1
ym_timer_a_counter:
        ds      1
ym_timer_b_counter:
        ds      1
ym_timer_b_phase:
        ds      1
ym_queue_count:
        ds      1
ssi_native_sample_count:
        ds      1

; The no-PM phase increments are expensive to derive from the OPM key-code,
; detune, and multiplier tables. Keep a copy across samples and rebuild it only
; after a register write that can change frequency. ym_lfo_pm is saved while
; rebuilding so protocol queries still observe the current modulation phase.
ym_phase_cache_saved_pm:
        ds      1

; Falcon SSI output state. The codec's 25.175 MHz / 4 / 128 rate is
; 49,169.921875 Hz, so 62.5 kHz native OPM time advances by exactly 1280/1007
; samples per codec frame.
ssi_resample_phase:
        ds      1
ssi_frame_count:
        ds      1
ym_queue_read_index:
        ds      1
ym_queue_timestamp:
        ds      1
ssi_mix_probe_left:
        ds      1
ssi_mix_probe_sum:
        ds      1
ssi_active_buffer:
        ds      1
ssi_refill_buffer:
        ds      1
ssi_status_snapshot:
        ds      1

; Scratch state. Keeping it explicit makes subroutine register clobbers safe
; and leaves the protocol probes useful while the real-time loop evolves.
synth_index:
        ds      1
synth_channel:
        ds      1
synth_operator:
        ds      1
synth_rate:
        ds      1
synth_increment:
        ds      1
synth_algorithm:
        ds      1
synth_result:
        ds      1
synth_am_offset:
        ds      1
volume_phase:
        ds      1
volume_sign:
        ds      1
volume_envelope:
        ds      1
volume_sine:
        ds      1

synth_opout:
        ds      8

table_remaining:
        ds      1
table_packed:
        ds      1
table_slots:
        ds      1
table_current:
        ds      1

; Raw OPM register slot offsets indexed by logical operator, written once
; at startup. Runtime initialization keeps the words out of the .LOD
; image while making the hot ym_select_operator mapping a single fetch.
ym_slot_offsets:
        ds      4

; State used only by the codec-rate lower-bound profile. The four oscillators
; retain 16-bit fractional table positions while r0-r3 hold their modulo-256
; integer positions for the duration of the benchmark command. The phase ring
; must begin on a four-word boundary for m4/m5 modulo addressing.
rt_profile_alignment_pad:
        ds      4
rt_phase_fraction:
        ds      4
rt_profile_checksum:
        ds      1
rt_gain_alignment_pad:
        ds      3
rt_envelope_gain:
        ds      4

; The real-time spike is mutually exclusive with the exact renderer. Reuse
; its internal-X scratch window for a 64-entry full-wave sine table, populated
; from every fourth entry of rt_linear_sine when command $14 starts. A coarse
; internal lookup avoids the Falcon external-memory penalty on all four hot
; indexed reads while retaining a complete signed waveform.
        org     x:$40
rt2_coarse_sine:
        ds      64

; One operator stage writes this ring while the next consumes it in place
; as its modulator. Modulo-64 addressing requires the 64-word alignment.
        org     x:$80
rt2_stage_ring:
        ds      64

; Block-oriented spike state: four 8.16 operator phases in table-entry
; units, four signed fractional gains advanced by per-frame slopes, and the
; feedback output history. This follows the stage ring in otherwise-unused
; internal X RAM so the coarse sine overlay can occupy a full aligned page.
        org     x:$c0
rt2_phase:
        ds      4
rt2_gain:
        ds      4
rt2_fb_1:
        ds      1

; Larger register and operator arrays remain in external X memory. Operator
; state uses logical per-channel order M1,C1,M2,C2. Phases are native 10.10
; ymfm values; modulo-24-bit storage preserves the low waveform bits at wrap.
        org     x:$200

ym_regdata:
        ds      256

ym_phase:
        ds      32
ym_envelope:
        ds      32
ym_envelope_state:
        ds      32
ym_key_live:
        ds      32
ym_key_state:
        ds      32

ym_feedback_0:
        ds      8
ym_feedback_1:
        ds      8
ym_feedback_in:
        ds      8

ym_lfo_noise_wave:
        ds      256

; Up to 32 exact register events on the rolling 16-bit native-sample clock.
ym_write_queue_times:
        ds      32
ym_write_queue_commands:
        ds      32

; PM-independent per-operator frequency data, rebuilt together with the
; phase-step cache. The dynamic-PM path derives each sample's step from
; these five words instead of re-decoding registers for all 32 operators.
        org     y:$0

ym_cache_position:
        ds      32
ym_cache_block:
        ds      32
ym_cache_pms:
        ds      32
ym_cache_detune:
        ds      32
ym_cache_mul2:
        ds      32

; Keep the two block-spike feedback words in opposite internal memory banks
; so their traffic can share an instruction with the modulator ring.
rt2_fb_0_y:
        ds      1

; One operator at a time consumes this 64-frame gain ramp. Building it once
; per stage lets the synthesis MPY fetch the next per-frame gain for free in
; its otherwise-unused Y-memory parallel-move slot.
        org     y:$c0
rt2_gain_ramp:
        ds      64

; Phase and cache live in opposite internal memory banks so the common no-PM
; clock path can fetch both in one DSP instruction cycle. External Y below the
; reserved table boundary aliases external program RAM on the Falcon, so the
; small cache deliberately stays in the 56001's internal Y RAM.
        org     y:$100

ym_phase_step_cache:
        ds      32

; -----------------------------------------------------------------------------
; Program
; -----------------------------------------------------------------------------

; P:$0040-$007f is reserved for the transient second-stage loader. It remains
; unused after bootstrap and keeps that loader out of the interrupt vectors.
        org     p:$80

start:
        movep   #1,x:m_pbc              ; enable the Falcon host port
        movep   #$3000,x:m_ipr          ; SSI interrupt priority level 2
        move    #>-1,m0                 ; linear addressing for ym_regdata

        jsr     ym_initialize_slot_offsets
        jsr     ym_reset

command_loop:
        jclr    #0,x:m_hsr,*            ; wait for host receive data full
        movep   x:m_hrx,x1
        move    x1,x:last_command

        move    x1,a
        move    #>$ff0000,y0
        and     y0,a1                   ; isolate opcode

        move    #>DSP_CMD_PING,x0
        cmp     x0,a
        jeq     command_ping

        move    #>DSP_CMD_WRITE_REG,x0
        cmp     x0,a
        jeq     command_write

        move    #>DSP_CMD_RESET,x0
        cmp     x0,a
        jeq     command_reset

        move    #>DSP_CMD_CLOCK,x0
        cmp     x0,a
        jeq     command_clock

        move    #>DSP_CMD_QUERY_PHASE,x0
        cmp     x0,a
        jeq     command_query_phase

        move    #>DSP_CMD_QUERY_RIGHT,x0
        cmp     x0,a
        jeq     command_query_right

        move    #>DSP_CMD_QUERY_ENV,x0
        cmp     x0,a
        jeq     command_query_envelope

        move    #>DSP_CMD_QUERY_STATUS,x0
        cmp     x0,a
        jeq     command_query_status

        move    #>DSP_CMD_QUERY_LFO,x0
        cmp     x0,a
        jeq     command_query_lfo

        move    #>DSP_CMD_LOAD_TABLES,x0
        cmp     x0,a
        jeq     command_load_tables

        move    #>DSP_CMD_START_AUDIO,x0
        cmp     x0,a
        jeq     command_start_audio

        move    #>DSP_CMD_STOP_AUDIO,x0
        cmp     x0,a
        jeq     command_stop_audio

        move    #>DSP_CMD_QUERY_AUDIO,x0
        cmp     x0,a
        jeq     command_query_audio

        move    #>DSP_CMD_QUEUE_WRITE,x0
        cmp     x0,a
        jeq     command_queue_write

        move    #>DSP_CMD_QUERY_TIME,x0
        cmp     x0,a
        jeq     command_query_time

        move    #>DSP_CMD_PROFILE_RT,x0
        cmp     x0,a
        jeq     command_profile_realtime

        move    #>DSP_CMD_PROFILE_RT2,x0
        cmp     x0,a
        jeq     command_profile_realtime2

        move    #>DSP_CMD_START_MIXED,x0
        cmp     x0,a
        jeq     command_start_mixed

        move    #>DSP_CMD_QUERY_MIX,x0
        cmp     x0,a
        jeq     command_query_mix

        move    #>DSP_REPLY_ERROR,a
        jsr     send_reply
        jmp     command_loop

; Command $14 reuses the internal-X window containing this persistent table.
; Centralizing setup lets the isolated benchmark restore the exact renderer's
; logical-to-raw operator mapping before returning to the normal protocol.
ym_initialize_slot_offsets:
        ; MAME's raw register order is M1,C1,M2,C2: offsets 0,16,8,24.
        move    #ym_slot_offsets,r0
        clr     a
        move    a1,x:(r0)+
        move    #>16,a
        move    a1,x:(r0)+
        move    #>8,a
        move    a1,x:(r0)+
        move    #>24,a
        move    a1,x:(r0)
        rts

command_ping:
        move    #>DSP_REPLY_HELLO,a
        jsr     send_reply
        jmp     command_loop

; SSI transmit-underrun recovery. Reading SSISR followed by writing TX clears
; TUE; this long exception path is not part of normal buffered playback.
ssi_tx_exception:
        movep   x:m_sr,x:ssi_status_snapshot
        movep   x:(r6)+,x:m_tx
        rti

command_write:
        jsr     ym_write_packed
        jsr     ym_refresh_phase_cache
        move    #>DSP_REPLY_OK,a
        jsr     send_reply
        jmp     command_loop

command_reset:
        jsr     ym_reset
        jsr     ym_rebuild_phase_cache
        move    #>DSP_REPLY_OK,a
        jsr     send_reply
        jmp     command_loop

command_clock:
        jsr     ym_clock_sample
        move    x:ym_last_left,a
        jsr     send_reply
        jmp     command_loop

command_query_phase:
        jsr     ym_query_phase_step
        jsr     send_reply
        jmp     command_loop

command_query_right:
        move    x:ym_last_right,a
        jsr     send_reply
        jmp     command_loop

command_query_envelope:
        move    x1,a
        move    #>$1f,y0
        and     y0,a1
        move    a1,n0
        move    #ym_envelope,r0
        nop
        move    x:(r0+n0),a
        jsr     send_reply
        jmp     command_loop

command_query_status:
        move    x:ym_status,a
        move    x:ym_busy,b
        tst     b
        jeq     command_query_status_ready
        move    #>$80,x0
        or      x0,a
command_query_status_ready:
        jsr     send_reply
        jmp     command_loop

command_query_lfo:
        move    x:ym_lfo_phase,a
        rep     #8
        asl     a
        move    x:ym_lfo_am,x0
        add     x0,a
        rep     #8
        asl     a
        move    x:ym_lfo_pm,b
        move    #>$ff,y0
        and     y0,b1
        move    b1,x0
        add     x0,a
        jsr     send_reply
        jmp     command_loop

; Receive the packed ymfm tables from the 68030, expand the runtime lookup
; arrays, and reset the chip before acknowledging the bootstrap transaction.
; Keeping immutable source data in the host executable leaves the constrained
; TOS DSP loader responsible only for code.
command_load_tables:
        move    #opm_uploaded_tables,r0
        do      #YM_TABLE_WORDS,command_load_tables_loop
        jclr    #0,x:m_hsr,*
        movep   x:m_hrx,a
        move    a1,y:(r0)+
command_load_tables_loop:
        jsr     ym_expand_tables
        jsr     ym_reset
        jsr     ym_rebuild_phase_cache
        move    #>DSP_REPLY_OK,a
        jsr     send_reply
        jmp     command_loop

; Profile a strict lower bound for one four-operator codec-rate channel. It
; includes fractional phase accumulation, modulo table addressing, four linear
; sine lookups, distinct static carrier gains, carrier summing, and a retained
; checksum. It deliberately omits envelope evolution, feedback, modulation
; routing, LFO/noise, register-event service, panning, and SSI, so an eight-
; channel projection is optimistic by design.
command_profile_realtime:
        clr     a
        move    #rt_phase_fraction,r4
        do      #4,rt_profile_clear_fraction
        move    a1,x:(r4)+
rt_profile_clear_fraction:
        move    a1,x:rt_profile_checksum

        move    #rt_linear_sine,r0
        move    #rt_linear_sine,r1
        move    #rt_linear_sine,r2
        move    #rt_linear_sine,r3
        move    #rt_phase_fraction,r4
        move    #rt_phase_fraction,r5
        move    #rt_envelope_gain,r7
        move    #>$400000,x0           ; 0.5 signed fractional gain
        move    x0,x:(r7)+
        move    #>$300000,x0           ; 0.375
        move    x0,x:(r7)+
        move    #>$200000,x0           ; 0.25
        move    x0,x:(r7)+
        move    #>$100000,x0           ; 0.125
        move    x0,x:(r7)+
        move    #rt_envelope_gain,r7
        move    #>255,m0
        move    #>255,m1
        move    #>255,m2
        move    #>255,m3
        move    #>3,m4
        move    #>3,m5
        move    #>3,m7
        move    #>2,n0                  ; 440 Hz: 2 + $4a74/65536 entries
        move    #>2,n1
        move    #>2,n2
        move    #>2,n3
        move    #>$4a74,x1
        move    #>$00ffff,y1

rt_profile_loop_start:
        do      #DSP_RT_PROFILE_FRAMES,rt_profile_frame_done
        clr     b

        move    x:(r4)+,a
        add     x1,a
        move    (r0)+n0
        jclr    #16,a1,rt_profile_op1_no_carry
        move    (r0)+
rt_profile_op1_no_carry:
        and     y1,a1 x:(r7)+,x0 y:(r0),y0
        mac     x0,y0,b a1,x:(r5)+

        move    x:(r4)+,a
        add     x1,a
        move    (r1)+n1
        jclr    #16,a1,rt_profile_op2_no_carry
        move    (r1)+
rt_profile_op2_no_carry:
        and     y1,a1 x:(r7)+,x0 y:(r1),y0
        mac     x0,y0,b a1,x:(r5)+

        move    x:(r4)+,a
        add     x1,a
        move    (r2)+n2
        jclr    #16,a1,rt_profile_op3_no_carry
        move    (r2)+
rt_profile_op3_no_carry:
        and     y1,a1 x:(r7)+,x0 y:(r2),y0
        mac     x0,y0,b a1,x:(r5)+

        move    x:(r4)+,a
        add     x1,a
        move    (r3)+n3
        jclr    #16,a1,rt_profile_op4_no_carry
        move    (r3)+
rt_profile_op4_no_carry:
        and     y1,a1 x:(r7)+,x0 y:(r3),y0
        mac     x0,y0,b a1,x:(r5)+

        move    x:rt_profile_checksum,a
        add     b,a
        move    a1,x:rt_profile_checksum
rt_profile_frame_done:
        nop
rt_profile_loop_done:
        ; The exact renderer uses linear addressing. The benchmark owns these
        ; address-mode registers only for the duration of this command.
        move    #>-1,m0
        move    #>-1,m1
        move    #>-1,m2
        move    #>-1,m3
        move    #>-1,m4
        move    #>-1,m5
        move    #>-1,m7
        move    #>0,n0
        move    #>0,n1
        move    #>0,n2
        move    #>0,n3
        move    x:rt_profile_checksum,a
        jsr     send_reply
        jmp     command_loop

; Profile one block-oriented, algorithm-0-shaped codec-rate channel: a
; serial M1(feedback)->C1->M2->C2 chain with per-frame feedback and
; modulation, per-frame envelope gain slopes, and interleaved stereo output.
; Each operator processes one 64-frame block so its phase and gain stay
; in registers while the modulator ring is consumed in place by the next
; stage. This adds the work the four-carrier lower bound deliberately
; omitted. SSI must be stopped: both audio buffers are reused as the
; 2048-frame stereo output block, and the reply is its checksum.
command_profile_realtime2:
        clr     a
        move    #rt2_phase,r4
        do      #4,rt2_clear_state
        move    a1,x:(r4)+
rt2_clear_state:
        move    a1,x:rt2_fb_1
        move    a1,y:rt2_fb_0_y

        move    #rt2_gain,r4
        move    #>$400000,x0           ; 0.5 signed fractional gain
        move    x0,x:(r4)+
        move    #>$300000,x0           ; 0.375
        move    x0,x:(r4)+
        move    #>$200000,x0           ; 0.25
        move    x0,x:(r4)+
        move    #>$100000,x0           ; 0.125
        move    x0,x:(r4)+

        ; Build a complete 64-step waveform in internal X RAM. The benchmark
        ; markers intentionally exclude this one-time command setup cost.
        move    #rt_linear_sine,r0
        move    #rt2_coarse_sine,r6
        move    #>4,n0
        do      #64,rt2_coarse_sine_ready
        move    y:(r0)+n0,x0
        move    x0,x:(r6)+
rt2_coarse_sine_ready:
        move    #rt2_coarse_sine,r6
        move    #ssi_buffer_a,r1
        move    #>63,m3
        move    #>63,m5
        move    m3,m6
        move    #>63,m7
        move    #>$10,y1               ; 6-bit index into the coarse waveform
        move    #>$024a74,x1           ; 440 Hz: 2 + $4a74/65536 entries

rt2_profile_loop_start:
        do      #DSP_RT2_PROFILE_BLOCKS,rt2_blocks_done

        ; Operator 1: self-feedback, fills the modulator ring. Feedback lives
        ; in opposite X/Y banks, so both history words load together and the
        ; new output is stored to the history and ring in one dual move.
        move    #rt2_stage_ring,r3
        move    #rt2_fb_1,r2
        move    #rt2_fb_0_y,r4
        move    x:rt2_phase,b

        ; Derive a 64-frame operator gain ramp. The parallel store observes
        ; A before SUB, leaving A at the next block's starting gain.
        move    x:rt2_gain,a
        move    #>$10,x0
        move    #rt2_gain_ramp,r7
        do      #DSP_RT2_BLOCK_FRAMES,rt2_op1_gain_ramp_done
        sub     x0,a a1,y:(r7)+
rt2_op1_gain_ramp_done:
        move    a1,x:rt2_gain
        move    y:(r7)+,y0

        do      #DSP_RT2_BLOCK_FRAMES,rt2_op1_done
        move    x:(r2),x0 y:(r4),a
        move    a1,x:(r2)              ; age the history before summing it
        add     x0,a
        asr     a
        asr     a
        asr     a                      ; (out[-1]+out[-2]) >> 3 feedback
        add     b,a
        move    a1,x0
        mpy     x0,y1,a
        move    a1,n6
        add     x1,b
        move    x:(r6+n6),x0
        mpy     x0,y0,a y:(r7)+,y0
        move    a,x:(r3)+ a,y:(r4)
rt2_op1_done:
        move    b1,x:rt2_phase

        ; Operator 2: prefetch the next modulator beside the current MPY, then
        ; store the result while moving that prefetched value into A.
        move    #rt2_stage_ring,r3
        move    #rt2_stage_ring,r5
        move    x:rt2_phase+1,b

        move    x:rt2_gain+1,a
        move    #>$0c,x0
        move    #rt2_gain_ramp,r7
        do      #DSP_RT2_BLOCK_FRAMES,rt2_op2_gain_ramp_done
        sub     x0,a a1,y:(r7)+
rt2_op2_gain_ramp_done:
        move    a1,x:rt2_gain+1
        move    y:(r7)+,y0

        move    x:(r3)+,a
        do      #DSP_RT2_BLOCK_FRAMES,rt2_op2_done
        add     b,a
        move    a1,x0
        mpy     x0,y1,a
        move    a1,n6
        add     x1,b
        move    x:(r6+n6),x0
        mpy     x0,y0,a x:(r3)+,x0 y:(r7)+,y0
        move    a,x:(r5)+ x0,a
rt2_op2_done:
        move    b1,x:rt2_phase+1

        ; Operator 3: same stage shape as operator 2.
        move    #rt2_stage_ring,r3
        move    #rt2_stage_ring,r5
        move    x:rt2_phase+2,b

        move    x:rt2_gain+2,a
        move    #>$08,x0
        move    #rt2_gain_ramp,r7
        do      #DSP_RT2_BLOCK_FRAMES,rt2_op3_gain_ramp_done
        sub     x0,a a1,y:(r7)+
rt2_op3_gain_ramp_done:
        move    a1,x:rt2_gain+2
        move    y:(r7)+,y0

        move    x:(r3)+,a
        do      #DSP_RT2_BLOCK_FRAMES,rt2_op3_done
        add     b,a
        move    a1,x0
        mpy     x0,y1,a
        move    a1,n6
        add     x1,b
        move    x:(r6+n6),x0
        mpy     x0,y0,a x:(r3)+,x0 y:(r7)+,y0
        move    a,x:(r5)+ x0,a
rt2_op3_done:
        move    b1,x:rt2_phase+2

        ; Operator 4: the carrier writes interleaved stereo, right at a
        ; fixed half-amplitude pan.
        move    #rt2_stage_ring,r3
        move    x:rt2_phase+3,b

        move    x:rt2_gain+3,a
        move    #>$04,x0
        move    #rt2_gain_ramp,r7
        do      #DSP_RT2_BLOCK_FRAMES,rt2_op4_gain_ramp_done
        sub     x0,a a1,y:(r7)+
rt2_op4_gain_ramp_done:
        move    a1,x:rt2_gain+3
        move    y:(r7)+,y0

        move    x:(r3)+,a
        do      #DSP_RT2_BLOCK_FRAMES,rt2_op4_done
        add     b,a
        move    a1,x0
        mpy     x0,y1,a
        move    a1,n6
        add     x1,b
        move    x:(r6+n6),x0
        mpy     x0,y0,a x:(r3)+,x0 y:(r7)+,y0
        asr     a a1,x:(r1)+           ; left, then half-amplitude right
        move    a,x:(r1)+ x0,a
rt2_op4_done:
        move    b1,x:rt2_phase+3
rt2_blocks_done:
        nop
rt2_profile_loop_done:
        jsr     ym_initialize_slot_offsets

        ; Checksum the rendered stereo block. The cycle bracket above
        ; excludes this conformance pass.
        move    #ssi_buffer_a,r1
        clr     a
        do      #DSP_RT2_CHECKSUM_PAIRS,rt2_checksum_done
        move    x:(r1)+,x0
        add     x0,a
        move    x:(r1)+,x0
        add     x0,a
rt2_checksum_done:
        move    #>-1,m0
        move    #>-1,m3
        move    #>-1,m5
        move    m3,m6
        move    #>-1,m7
        move    #>0,n0
        move    #>0,n6
        jsr     send_reply
        jmp     command_loop

; Start a host-controlled Falcon audio session. First pre-render one exact
; 1007-frame resampling period while SSI is disabled, then let the transmit
; interrupt repeat it until the host supplies an inactive-buffer refill.
command_start_audio:
        movep   #0,x:m_crb
        movep   #$4100,x:m_cra          ; 16-bit, two-word network frame
        clr     a
        move    a1,x:ssi_resample_phase
        move    a1,x:ssi_frame_count
        move    a1,x:ssi_active_buffer
        move    #>-1,m6
        move    #ssi_buffer_a,r6
        do      #DSP_MIX_FRAME_COUNT,command_start_audio_render_done
        jsr     ssi_render_frame
        move    x:ym_last_left,a
        rep     #8
        asl     a
        move    a1,x:(r6)+
        move    x:ym_last_right,a
        rep     #8
        asl     a
        move    a1,x:(r6)+
command_start_audio_render_done:

ssi_start_buffered:
        move    #ssi_buffer_a,r6
        move    #>2013,m6              ; one aligned 2014-word stereo block
        nop
        move    x:(r6)+,a
        movep   a1,x:m_tx
        move    #>DSP_MIX_FRAME_COUNT,a
        move    a1,x:ssi_frame_count
        move    #>DSP_REPLY_OK,a
        jsr     send_reply
        movep   #$5a00,x:m_crb          ; network TX + SSI transmit interrupt
        jmp     ssi_stream_loop

; Receive one exact 1007-frame stereo PCM period from the 68030, then render
; the corresponding YM period and add it to PCM with signed 16-bit saturation.
; The completed interleaved host transfer is acknowledged immediately before
; the mixed block begins looping through SSI.
command_start_mixed:
        movep   #0,x:m_crb
        movep   #$4100,x:m_cra
        clr     a
        move    a1,x:ssi_resample_phase
        move    a1,x:ssi_frame_count
        move    a1,x:ssi_mix_probe_left
        move    a1,x:ssi_mix_probe_sum
        move    a1,x:ssi_active_buffer
        move    #>-1,m6
        move    #ssi_buffer_a,r6
        do      #DSP_MIX_FRAME_COUNT,command_start_mixed_receive
        jclr    #0,x:m_hsr,*
        movep   x:m_hrx,a
        move    a1,x:(r6)+
        jclr    #0,x:m_hsr,*
        movep   x:m_hrx,a
        move    a1,x:(r6)+
command_start_mixed_receive:

        move    #ssi_buffer_a,r7
        do      #DSP_MIX_FRAME_COUNT,command_start_mixed_render_done
        jsr     ssi_render_frame

        move    x:(r7),a
        move    x:ym_last_left,x0
        add     x0,a
        jsr     ym_clamp_channel
        move    a1,x:ssi_mix_probe_left
        rep     #8
        asl     a
        move    a1,x:(r7)+

        move    x:(r7),a
        move    x:ym_last_right,x0
        add     x0,a
        jsr     ym_clamp_channel
        move    a1,x0
        move    x:ssi_mix_probe_sum,b
        tst     b
        jne     command_start_mixed_right_ready
        move    x:ssi_mix_probe_left,b
        add     x0,b
        tst     b
        jeq     command_start_mixed_right_ready
        move    b1,x:ssi_mix_probe_sum
command_start_mixed_right_ready:
        rep     #8
        asl     a
        move    a1,x:(r7)+
command_start_mixed_render_done:
        jmp     ssi_start_buffered

; While interrupt-fed buffered audio is active, accept refills, synchronous
; register writes, timestamped writes, clock queries, and stop.
ssi_stream_loop:
        jclr    #0,x:m_hsr,ssi_stream_data
        movep   x:m_hrx,x1
        move    x1,x:last_command
        move    x1,a
        move    #>$ff0000,y0
        and     y0,a1
        move    #>DSP_CMD_STOP_AUDIO,x0
        cmp     x0,a
        jeq     command_stop_audio

        move    #>DSP_CMD_REFILL_MIXED,x0
        cmp     x0,a
        jeq     command_refill_mixed

        move    #>DSP_CMD_WRITE_REG,x0
        cmp     x0,a
        jeq     ssi_stream_write

        move    #>DSP_CMD_QUEUE_WRITE,x0
        cmp     x0,a
        jeq     ssi_stream_queue_write

        move    #>DSP_CMD_QUERY_TIME,x0
        cmp     x0,a
        jeq     ssi_stream_query_time
        jmp     ssi_stream_command_error

ssi_stream_query_time:
        move    x:ssi_native_sample_count,a
        jsr     send_reply
        jmp     ssi_stream_data

ssi_stream_queue_write:
        jsr     ym_enqueue_write
        jsr     send_reply
        jmp     ssi_stream_data

ssi_stream_write:
        jsr     ym_write_packed
        jsr     ym_refresh_phase_cache
        move    #>DSP_REPLY_OK,a
        jsr     send_reply
        jmp     ssi_stream_data

ssi_stream_command_error:
        move    #>DSP_REPLY_ERROR,a
        jsr     send_reply

ssi_stream_data:
        jmp     ssi_stream_loop

; Receive one host-rendered PDX block into the inactive buffer while the SSI
; transmit interrupt keeps the previous complete block looping. Render FM into
; the new block in place, then switch at a stereo boundary. If rendering misses
; one or more codec periods, the old block remains untouched and audible.
command_refill_mixed:
        move    x:ssi_active_buffer,a
        tst     a
        jne     command_refill_buffer_a
        move    #ssi_buffer_b,r7
        jmp     command_refill_receive
command_refill_buffer_a:
        move    #ssi_buffer_a,r7
command_refill_receive:
        move    r7,x:ssi_refill_buffer
        do      #DSP_MIX_FRAME_COUNT,command_refill_receive_done
        jclr    #0,x:m_hsr,*
        movep   x:m_hrx,a
        move    a1,x:(r7)+
        jclr    #0,x:m_hsr,*
        movep   x:m_hrx,a
        move    a1,x:(r7)+
command_refill_receive_done:
        move    x:ssi_refill_buffer,r7
        do      #DSP_MIX_FRAME_COUNT,command_refill_render_done
        jsr     ssi_render_frame
        move    x:(r7),a
        move    x:ym_last_left,x0
        add     x0,a
        jsr     ym_clamp_channel
        rep     #8
        asl     a
        move    a1,x:(r7)+

        move    x:(r7),a
        move    x:ym_last_right,x0
        add     x0,a
        jsr     ym_clamp_channel
        rep     #8
        asl     a
        move    a1,x:(r7)+
command_refill_render_done:

        ; Quiesce transmit interrupts after the current prepared word moves to
        ; the shift register. If that word was a left sample, send its matching
        ; right sample before installing the next block's first left sample.
        movep   #$1a00,x:m_crb
        jclr    #m_tde,x:m_sr,*
        move    r6,a
        jclr    #0,a1,command_refill_boundary
        movep   x:(r6)+,x:m_tx
        jclr    #m_tde,x:m_sr,*
command_refill_boundary:
        move    x:ssi_refill_buffer,r6
        move    x:ssi_active_buffer,a
        move    #>1,x0
        eor     x0,a
        move    a1,x:ssi_active_buffer
        nop
        move    x:(r6)+,a
        movep   a1,x:m_tx
        movep   #$5a00,x:m_crb
        move    x:ssi_frame_count,a
        move    #>DSP_MIX_FRAME_COUNT,x0
        add     x0,a
        move    a1,x:ssi_frame_count
        move    #>DSP_REPLY_OK,a
        jsr     send_reply
        jmp     ssi_stream_loop

command_stop_audio:
        movep   #0,x:m_crb
        move    #>-1,m6
        clr     a
        movep   a1,x:m_tx
        jsr     ym_rebuild_phase_cache
        move    #>DSP_REPLY_OK,a
        jsr     send_reply
        jmp     command_loop

command_query_audio:
        move    x:ssi_frame_count,a
        jsr     send_reply
        jmp     command_loop

; Queue transaction: 0e tt tt followed by 02 rr dd. The 16-bit timestamp is an
; absolute position on the rolling native-sample clock, with a 32767-sample
; scheduling horizon. The host sends entries in nondecreasing modular order;
; invalid/full transactions still consume both words to preserve framing.
command_queue_write:
        jsr     ym_enqueue_write
        jsr     send_reply
        jmp     command_loop

command_query_time:
        move    x:ssi_native_sample_count,a
        jsr     send_reply
        jmp     command_loop

command_query_mix:
        move    x:ssi_mix_probe_sum,a
        jsr     send_reply
        jmp     command_loop

; Zero-order native-rate conversion. Each 49.17 kHz codec frame advances the
; 62.5 kHz YM kernel once or twice according to the exact 1280:1007 ratio.
ssi_render_frame:
        move    x:ssi_resample_phase,a
        move    #>1280,x0
        add     x0,a
ssi_render_frame_loop:
        move    #>1007,x0
        cmp     x0,a
        jlt     ssi_render_frame_done
        sub     x0,a
        move    a1,x:ssi_resample_phase
        jsr     ym_apply_queued_writes
        jsr     ym_clock_sample
        move    x:ssi_native_sample_count,a
        move    #>1,x0
        add     x0,a
        move    #>$00ffff,y0
        and     y0,a1
        move    a1,x:ssi_native_sample_count
        move    x:ssi_resample_phase,a
        jmp     ssi_render_frame_loop
ssi_render_frame_done:
        move    a1,x:ssi_resample_phase
        rts

; Send a single 24-bit reply from a1.
send_reply:
        jclr    #1,x:m_hsr,*            ; wait for host transmit data empty
        movep   a1,x:m_htx
        rts

; Receive and append one exact-timestamp queue entry. The second word is always
; consumed before validation so a rejected transaction cannot desynchronize the
; host port.
ym_enqueue_write:
        move    x1,a
        move    #>$00ffff,y0
        and     y0,a1
        move    a1,x:ym_queue_timestamp

        jclr    #0,x:m_hsr,*
        movep   x:m_hrx,x1

        move    x1,a
        move    #>$ff0000,y0
        and     y0,a1
        move    #>DSP_CMD_WRITE_REG,x0
        cmp     x0,a
        jne     ym_enqueue_error

        ; Convert the timestamp to an unsigned modular distance from now.
        ; Bit 15 set means it is in the past or beyond the supported horizon.
        move    x:ym_queue_timestamp,a
        move    x:ssi_native_sample_count,x0
        sub     x0,a
        move    #>$00ffff,y0
        and     y0,a1
        move    a1,x:synth_result
        jset    #15,a1,ym_enqueue_error

        move    x:ym_queue_count,a
        move    #>32,x0
        cmp     x0,a
        jge     ym_enqueue_error
        tst     a
        jeq     ym_enqueue_store

        move    x:ym_queue_read_index,a
        move    x:ym_queue_count,x0
        add     x0,a
        move    #>1,x0
        sub     x0,a
        move    #>31,y0
        and     y0,a1
        move    a1,n0
        move    #ym_write_queue_times,r0
        nop
        move    x:(r0+n0),b
        move    x:ssi_native_sample_count,x0
        sub     x0,b
        move    #>$00ffff,y0
        and     y0,b1
        move    x:synth_result,a
        move    b1,x0
        cmp     x0,a
        jlt     ym_enqueue_error

ym_enqueue_store:
        move    x:ym_queue_read_index,a
        move    x:ym_queue_count,x0
        add     x0,a
        move    #>31,y0
        and     y0,a1
        move    a1,n0
        move    n0,n1
        move    #ym_write_queue_times,r0
        move    #ym_write_queue_commands,r1
        nop
        move    x:ym_queue_timestamp,a
        move    a1,x:(r0+n0)
        move    x1,x:(r1+n1)

        move    x:ym_queue_count,a
        move    #>1,x0
        add     x0,a
        move    a1,x:ym_queue_count
        move    #>DSP_REPLY_OK,a
        rts

ym_enqueue_error:
        move    #>DSP_REPLY_ERROR,a
        rts

; Apply every queued write due at or before the next native sample. The signed
; half of the 16-bit modular delta distinguishes future from already-due times.
ym_apply_queued_writes:
        move    x:ym_queue_count,a
        tst     a
        jeq     ym_apply_queued_done

        move    x:ym_queue_read_index,n0
        move    n0,n1
        move    #ym_write_queue_times,r0
        move    #ym_write_queue_commands,r1
        nop
        move    x:(r0+n0),a
        move    x:ssi_native_sample_count,x0
        sub     x0,a
        move    #>$00ffff,y0
        and     y0,a1
        tst     a
        jeq     ym_apply_queued_due
        jclr    #15,a1,ym_apply_queued_done

ym_apply_queued_due:
        move    x:(r1+n1),x1
        move    x1,x:last_command
        jsr     ym_write_packed
        jsr     ym_refresh_phase_cache

        move    x:ym_queue_read_index,a
        move    #>1,x0
        add     x0,a
        move    #>31,y0
        and     y0,a1
        move    a1,x:ym_queue_read_index
        move    x:ym_queue_count,a
        sub     x0,a
        move    a1,x:ym_queue_count
        jmp     ym_apply_queued_writes

ym_apply_queued_done:
        rts

; Reset behavior follows ymfm::opm_registers::reset(): clear all register
; bytes, then enable both output channels for channels 0-7 (registers 20-27).
ym_reset:
        move    #ym_regdata,r0
        clr     a
        do      #256,ym_reset_clear
        move    a1,x:(r0)+
ym_reset_clear:

        move    #ym_regdata+$20,r0
        move    #>$c0,x0
        do      #8,ym_reset_pan
        move    x0,x:(r0)+
ym_reset_pan:

        move    #ym_phase,r0
        clr     a
        do      #32,ym_reset_phase
        move    a1,x:(r0)+
ym_reset_phase:

        move    #ym_envelope,r0
        move    #>$3ff,a
        do      #32,ym_reset_envelope
        move    a1,x:(r0)+
ym_reset_envelope:

        move    #ym_envelope_state,r0
        move    #>4,a                  ; EG_RELEASE
        do      #32,ym_reset_envelope_state
        move    a1,x:(r0)+
ym_reset_envelope_state:

        move    #ym_key_live,r0
        clr     a
        do      #88,ym_reset_runtime_loop
        move    a1,x:(r0)+
ym_reset_runtime_loop:
        move    #ym_env_counter,r0
        clr     a
        do      #34,ym_reset_global_loop
        move    a1,x:(r0)+
ym_reset_global_loop:
        move    #>1,a
        move    a1,x:ym_noise_lfsr_low

        move    #ym_lfo_noise_wave,r0
        clr     a
        do      #256,ym_reset_lfo_noise_loop
        move    a1,x:(r0)+
ym_reset_lfo_noise_loop:
        rts

; Apply command 02 rr dd from x1 to the register image.
; MAME redirects PM depth writes (19 with bit 7 set) to an internal 1a shadow,
; while direct writes to 1a are ignored.
ym_write_packed:
        move    x1,a
        move    #>$00ff00,y0
        and     y0,a1
        rep     #8
        lsr     a
        move    a1,n0                   ; n0 = register

        move    x1,a
        move    #>$0000ff,y0
        and     y0,a1
        move    a1,x0                   ; x0 = data

        move    #>1,a
        move    a1,x:ym_busy

        move    n0,a
        move    #>$1a,y0
        cmp     y0,a
        jeq     ym_write_done           ; ignore direct internal-shadow write

        move    #>$19,y0
        cmp     y0,a
        jne     ym_write_store
        jclr    #7,x0,ym_write_store
        move    #>$1a,n0                ; PM depth shadow

ym_write_store:
        move    n0,a
        move    #>$14,y0
        cmp     y0,a
        jeq     ym_write_mode

        move    #ym_regdata,r0
        nop                             ; address-register pipeline interlock
        move    x0,x:(r0+n0)

        move    n0,a
        move    #>$08,y0
        cmp     y0,a
        jne     ym_write_done
        jsr     ym_write_keyon

ym_write_done:
        rts

; Rebuild cached increments for the register groups containing channel KC/KF
; ($28-$37), operator DT1/MUL ($40-$5f), and DT2 ($c0-$df). The compact masks
; also admit the adjacent $20-$27 and $38-$3f controls; an occasional harmless
; rebuild costs less loader space than exact range dispatch. Rebuilding the full
; 32-operator array keeps the sample loop small, and writes are sparse compared
; with the 62.5 kHz native sample clock.
ym_refresh_phase_cache:
        move    x:last_command,a
        move    #>$00ff00,y0
        and     y0,a1
        rep     #8
        lsr     a

        move    a1,b
        move    #>$e0,y0
        and     y0,a1
        move    #>$20,x0
        cmp     x0,a
        jeq     ym_rebuild_phase_cache

        move    b1,a
        move    #>$60,y0
        and     y0,a1
        move    #>$40,x0
        cmp     x0,a
        jeq     ym_rebuild_phase_cache
ym_refresh_phase_done:
        rts

; Build the static phase-step array with PM temporarily forced to zero. The
; same pass refreshes the per-operator PM-independent caches that
; ym_step_from_statics combines with the live PM value each sample.
ym_rebuild_phase_cache:
        move    x:ym_lfo_pm,a
        move    a1,x:ym_phase_cache_saved_pm
        clr     a
        move    a1,x:ym_lfo_pm
        move    a1,x:synth_index
        move    #ym_phase_step_cache,r2
ym_rebuild_phase_loop:
        jsr     ym_select_operator
        jsr     ym_compute_phase_step
        move    a1,y:(r2)+

        move    x:synth_index,a
        move    #>1,x0
        add     x0,a
        move    a1,x:synth_index
        move    #>32,x0
        cmp     x0,a
        jlt     ym_rebuild_phase_loop

        move    x:ym_phase_cache_saved_pm,a
        move    a1,x:ym_lfo_pm
        rts

; Register 14 controls Timer A/B load and status plus CSM. Mode writes only
; start a timer on a 0->1 load edge; expiration reloads it until load clears.
ym_write_mode:
        move    #ym_regdata+$14,r0
        nop
        move    x:(r0),b                ; old mode
        move    b1,a
        not     a
        move    x0,y1
        and     y1,a1                   ; rising load/control bits
        move    a1,x:synth_result
        move    x0,x:(r0)               ; publish new mode before reload

        jclr    #4,x0,ym_mode_keep_a_status
        bclr    #0,x:ym_status
ym_mode_keep_a_status:
        jclr    #5,x0,ym_mode_keep_b_status
        bclr    #1,x:ym_status
ym_mode_keep_b_status:
        move    x:synth_result,a
        jclr    #0,a1,ym_mode_timer_b
        jsr     ym_reload_timer_a
ym_mode_timer_b:
        move    x:synth_result,a
        jclr    #1,a1,ym_write_done
        jsr     ym_reload_timer_b
        move    x:ym_timer_b_counter,a
        move    x:ym_timer_b_phase,x0
        sub     x0,a
        move    a1,x:ym_timer_b_counter
        rts

; Timer A counts (1024 - 10-bit latch) native samples.
ym_reload_timer_a:
        move    #ym_regdata+$10,r0
        nop
        move    x:(r0)+,a
        rep     #2
        asl     a
        move    x:(r0),b
        move    #>3,y0
        and     y0,b1
        move    b1,x0
        add     x0,a
        move    #>1024,b
        move    a1,x0
        sub     x0,b
        move    b1,x:ym_timer_a_counter
        rts

; Timer B's free-running divide-by-16 is aligned because mode writes enter
; this command-clocked kernel only at native sample boundaries.
ym_reload_timer_b:
        move    #ym_regdata+$12,r0
        nop
        move    x:(r0),a
        move    #>256,b
        move    a1,x0
        sub     x0,b
        rep     #4
        asl     b
        move    b1,x:ym_timer_b_counter
        rts

; Register 08 key-on bits are in logical operator order. Writes update the
; live input; the edge is consumed at the beginning of the next sample just as
; ymfm's prepare()/clock_keystate() path does.
ym_write_keyon:
        move    x0,a
        move    #>7,y0
        and     y0,a1
        rep     #2
        asl     a
        move    #ym_key_live,x1
        add     x1,a
        move    a1,r0
        nop

        move    x0,a
        rep     #3
        lsr     a
        move    #>$0f,y0
        and     y0,a1
        do      #4,ym_write_keyon_loop
        move    a1,b
        move    #>1,y0
        and     y0,b1
        move    b1,x:(r0)+
        lsr     a
ym_write_keyon_loop:
        rts

; Calculate the current phase step for command 05 cc oo, where cc is channel
; 0-7 and oo is the logical MXDRV operator 0-3. This is a direct DSP56001
; transcription of MAME/ymfm's opm_registers::cache_operator_data(),
; compute_phase_step(), and opm_key_code_to_phase_step() for the no-PM case.
;
; The generated Y-memory tables come directly from vendored ymfm. MAME's raw
; register order is M1,C1,M2,C2, so the logical offsets are 0,16,8,24.
; out: a1 = 20-bit phase step, or DSP_REPLY_ERROR for an invalid selector
ym_query_phase_step:
        ; Decode and validate the channel byte.
        move    x1,a
        move    #>$00ff00,y0
        and     y0,a1
        rep     #8
        lsr     a
        move    #>7,x0
        cmp     x0,a
        jgt     ym_query_error
        move    a1,x:query_channel

        ; Decode the logical operator and map it to the OPM register offset.
        move    x1,a
        move    #>$0000ff,y0
        and     y0,a1
        move    #>3,x0
        cmp     x0,a
        jgt     ym_query_error

        ; synth_index = channel*4 + logical operator; ym_select_operator
        ; then derives the channel and raw register slot from it.
        move    x:query_channel,b
        rep     #2
        asl     b
        move    b1,x0
        add     x0,a
        move    a1,x:synth_index
        jsr     ym_select_operator
        jmp     ym_compute_phase_step

; Common phase-step kernel. synth_index, query_channel, and
; query_raw_operator must already identify the selected logical operator.
ym_compute_phase_step:
        jsr     ym_cache_operator_statics
        jmp     ym_step_from_statics

; Decode the PM-independent operator frequency data into the per-operator
; Y caches: gap-removed position including DT2, raw block, channel PM
; sensitivity, signed DT1 delta, and the doubled multiplier.
ym_cache_operator_statics:
        move    x:synth_index,n3

        ; block_freq = ((KC & 7f) << 6) | ((KF >> 2) & 3f).
        move    x:query_channel,n0
        move    #ym_regdata+$28,r0
        nop
        move    x:(r0+n0),a
        move    #>$7f,y0
        and     y0,a1
        rep     #6
        asl     a
        move    a1,x0

        move    #ym_regdata+$30,r0
        nop
        move    x:(r0+n0),a
        move    #>$fc,y0
        and     y0,a1
        rep     #2
        lsr     a
        add     x0,a
        move    a1,x:query_block_freq

        ; Cache the octave/block for the table shift.
        rep     #10
        lsr     a
        move    #>7,y0
        and     y0,a1
        move    #ym_cache_block,r3
        nop
        move    a1,y:(r3+n3)

        ; Cache the channel PM sensitivity beside the operator.
        move    #ym_regdata+$38,r0
        nop
        move    x:(r0+n0),a
        rep     #4
        lsr     a
        move    #>7,y0
        and     y0,a1
        move    #ym_cache_pms,r3
        nop
        move    a1,y:(r3+n3)

        ; Fetch DT2 from C0-DF and translate it to 1/64-semitone units.
        move    x:query_raw_operator,n0
        move    #ym_regdata+$c0,r0
        nop
        move    x:(r0+n0),a
        move    #>$c0,y0
        and     y0,a1
        rep     #6
        lsr     a
        move    a1,n1
        move    #opm_dt2_delta,r1
        nop
        move    y:(r1+n1),y1

        ; Remove the gaps from the 4-bit OPM key code, restore the fraction,
        ; and cache the position with the coarse detune delta folded in.
        move    x:query_block_freq,a
        rep     #6
        lsr     a
        move    #>$0f,y0
        and     y0,a1
        move    a1,x0

        move    x:query_block_freq,a
        rep     #8
        lsr     a
        move    #>3,y0
        and     y0,a1
        move    a1,y0
        move    x0,a
        sub     y0,a
        rep     #6
        asl     a
        move    a1,x0

        move    x:query_block_freq,a
        move    #>$3f,y0
        and     y0,a1
        add     x0,a
        add     y1,a
        move    #ym_cache_position,r3
        nop
        move    a1,y:(r3+n3)

        ; DT1 table index = keycode * 4 + (detune & 3).
        move    x:query_raw_operator,n0
        move    #ym_regdata+$40,r0
        nop
        move    x:(r0+n0),b
        move    b1,x:query_dtmul
        rep     #4
        lsr     b
        move    #>7,y0
        and     y0,b1
        move    b1,x:query_detune
        move    #>3,y0
        and     y0,b1
        move    b1,y1

        move    x:query_block_freq,b
        rep     #8
        lsr     b
        move    #>$1f,y0
        and     y0,b1
        rep     #2
        asl     b
        add     y1,b
        move    b1,n1
        jsr     ym_lookup_detune

        ; DT1 bit 2 selects negative detune; cache the signed delta.
        move    x:query_detune,b
        jclr    #2,b1,ym_cache_detune_positive
        move    x0,b
        neg     b
        move    b1,x0
ym_cache_detune_positive:
        move    #ym_cache_detune,r3
        nop
        move    x0,y:(r3+n3)

        ; The multiplier is stored as x.1: zero means 0.5, otherwise MUL*2.
        move    x:query_dtmul,b
        move    #>$0f,y0
        and     y0,b1
        tst     b
        jeq     ym_cache_multiple_half
        asl     b
        jmp     ym_cache_multiple_store
ym_cache_multiple_half:
        move    #>1,b
ym_cache_multiple_store:
        move    #ym_cache_mul2,r3
        nop
        move    b1,y:(r3+n3)
        rts

; Derive the current phase step for synth_index from the cached
; PM-independent operator data plus the live LFO PM value. This is the
; whole per-sample dynamic-PM path; registers are not re-decoded.
ym_step_from_statics:
        move    x:synth_index,n3
        move    #ym_cache_pms,r3
        nop
        move    y:(r3+n3),a
        move    #ym_cache_position,r3
        tst     a
        jeq     ym_step_no_pm

        ; Scale ym_lfo_pm by the channel sensitivity. ym_lfo_pm is the
        ; signed raw PM value in the same -127..128 domain as ymfm.
        move    a1,b
        move    #>6,x0
        cmp     x0,b
        jge     ym_step_pm_high
        move    #>6,a
        move    b1,y1
        sub     y1,a
        move    a1,y0
        move    x:ym_lfo_pm,a
        rep     y0
        asr     a
        jmp     ym_step_pm_add
ym_step_pm_high:
        move    #>5,x0
        sub     x0,b
        move    b1,y0
        move    x:ym_lfo_pm,a
        rep     y0
        asl     a
ym_step_pm_add:
        move    y:(r3+n3),y1
        add     y1,a
        jmp     ym_step_adjust
ym_step_no_pm:
        move    y:(r3+n3),a
ym_step_adjust:
        move    #ym_cache_block,r3
        nop
        move    y:(r3+n3),b

        ; PM can underflow one octave or overflow two. Adjust a working
        ; block copy with the same boundary/clamp order as
        ; opm_key_code_to_phase_step().
        tst     a
        jlt     ym_step_underflow
        move    #>768,x0
        cmp     x0,a
        jlt     ym_step_ready
        sub     x0,a
        cmp     x0,a
        jlt     ym_step_overflow_once
        sub     x0,a
        move    #>1,y1
        add     y1,b
ym_step_overflow_once:
        move    #>7,x0
        cmp     x0,b
        jge     ym_step_clamp
        move    #>1,x0
        add     x0,b
        jmp     ym_step_ready

ym_step_underflow:
        move    #>768,x0
        add     x0,a
        tst     b
        jeq     ym_step_clamp_low
        move    #>1,x0
        sub     x0,b

ym_step_ready:
        move    a1,n1
        move    #opm_phase_step,r1
        move    b1,y0
        move    y:(r1+n1),a

        ; Shift the base step down according to the octave: block XOR 7.
        move    #>7,b
        sub     y0,b
        tst     b
        jeq     ym_step_shifted
        move    b1,x0
        rep     x0
        lsr     a
        jmp     ym_step_shifted

ym_step_clamp:
        move    #opm_phase_step+767,r1
        nop
        move    y:(r1),a
        jmp     ym_step_shifted

ym_step_clamp_low:
        move    #opm_phase_step,r1
        nop
        move    y:(r1),a
        rep     #7
        lsr     a

ym_step_shifted:
        ; Add the cached signed DT1 delta, then apply the doubled
        ; multiplier: MPY leaves step*mul2 doubled at the B0 end, so two
        ; arithmetic shifts complete the >>1. Fits 24 bits for every OPM
        ; step/MUL pair.
        move    #ym_cache_detune,r3
        nop
        move    y:(r3+n3),x0
        add     x0,a
        move    #ym_cache_mul2,r3
        move    a1,x0
        move    y:(r3+n3),y0
        mpy     x0,y0,b
        asr     b
        asr     b
        move    b0,a
        rts

ym_query_error:
        move    #>DSP_REPLY_ERROR,a
        rts

; Read one 5-bit DT1 adjustment directly from the four-per-word packed table.
; Keeping this small lookup packed saves both loader bytes and startup code.
ym_lookup_detune:
        move    a1,x1
        move    n1,a
        move    #>3,y0
        and     y0,a1
        move    a1,x:table_slots
        move    n1,a
        rep     #2
        lsr     a
        move    a1,n1
        move    #opm_detune_adjustment_packed,r1
        nop
        move    y:(r1+n1),b
        move    x:table_slots,a
        tst     a
        jeq     ym_lookup_detune_mask
        move    a1,y1                 ; shift count = slot*5 in one REP
        rep     #2
        asl     a
        add     y1,a
        move    a1,y0
        rep     y0
        lsr     b
ym_lookup_detune_mask:
        move    #>$1f,y0
        and     y0,b1
        move    b1,x0
        move    x1,a
        rts

        ; Split the LOD program records below TOS 4.02's converter limit.
        ds      1

; -----------------------------------------------------------------------------
; Command-clocked synthesis kernel
; -----------------------------------------------------------------------------

; Expand nibble-packed build tables into their runtime lookup arrays. This
; keeps the TOS .LOD image below the Falcon loader's practical binary size
; limit without changing any ymfm values used by the sample kernel.
ym_expand_tables:
        move    #opm_phase_step_packed,r1
        move    #opm_phase_step,r0
        nop
        move    y:(r1)+,a
        move    a1,x:table_current
        move    a1,y:(r0)+
        move    #>767,a
        move    a1,x:table_remaining

ym_expand_phase_word:
        move    x:table_remaining,a
        tst     a
        jeq     ym_expand_envelope_start
        move    y:(r1)+,a
        move    a1,x:table_packed
        move    #>8,a
        move    a1,x:table_slots
ym_expand_phase_nibble:
        move    x:table_remaining,a
        tst     a
        jeq     ym_expand_envelope_start
        move    x:table_packed,a
        move    #>7,y0
        and     y0,a1
        rep     #5
        asl     a
        move    x:table_current,x0
        add     x0,a
        move    a1,x:table_current
        move    a1,y:(r0)+

        move    x:table_packed,a
        rep     #3
        lsr     a
        move    a1,x:table_packed
        move    x:table_remaining,a
        move    #>1,x0
        sub     x0,a
        move    a1,x:table_remaining
        move    x:table_slots,a
        move    #>1,x0
        sub     x0,a
        move    a1,x:table_slots
        jne     ym_expand_phase_nibble
        jmp     ym_expand_phase_word

ym_expand_envelope_start:
        move    #opm_envelope_increment_packed,r1
        move    #opm_envelope_increment,r0
        move    #>512,a
        move    a1,x:table_remaining
ym_expand_envelope_word:
        move    x:table_remaining,a
        tst     a
        jeq     ym_expand_sine_start
        move    y:(r1)+,a
        move    a1,x:table_packed
        move    #>6,a
        move    a1,x:table_slots
ym_expand_envelope_nibble:
        move    x:table_packed,a
        move    #>$0f,y0
        and     y0,a1
        move    a1,y:(r0)+
        move    x:table_packed,a
        rep     #4
        lsr     a
        move    a1,x:table_packed
        move    x:table_remaining,a
        move    #>1,x0
        sub     x0,a
        move    a1,x:table_remaining
        jeq     ym_expand_sine_start
        move    x:table_slots,a
        move    #>1,x0
        sub     x0,a
        move    a1,x:table_slots
        jne     ym_expand_envelope_nibble
        jmp     ym_expand_envelope_word

; Sine attenuation is monotonic. Keep its first five large deltas verbatim,
; then unpack the remaining 6-bit deltas four per word.
ym_expand_sine_start:
        move    #opm_sine_attenuation_packed,r1
        move    #opm_sine_attenuation,r0
        nop
        move    y:(r1)+,a
        move    a1,x:table_current
        move    a1,y:(r0)+
        move    #>5,a
        move    a1,x:table_remaining
ym_expand_sine_large:
        move    y:(r1)+,a
        move    a1,x0
        move    x:table_current,a
        sub     x0,a
        move    a1,x:table_current
        move    a1,y:(r0)+
        move    x:table_remaining,a
        move    #>1,x0
        sub     x0,a
        move    a1,x:table_remaining
        jne     ym_expand_sine_large

        move    #>250,a
        move    a1,x:table_remaining
ym_expand_sine_word:
        move    y:(r1)+,a
        move    a1,x:table_packed
        move    #>4,a
        move    a1,x:table_slots
ym_expand_sine_delta:
        move    x:table_packed,a
        move    #>$3f,y0
        and     y0,a1
        move    a1,x0
        move    x:table_current,a
        sub     x0,a
        move    a1,x:table_current
        move    a1,y:(r0)+
        move    x:table_packed,a
        rep     #6
        lsr     a
        move    a1,x:table_packed
        move    x:table_remaining,a
        move    #>1,x0
        sub     x0,a
        move    a1,x:table_remaining
        jeq     ym_expand_power_start
        move    x:table_slots,a
        move    #>1,x0
        sub     x0,a
        move    a1,x:table_slots
        jne     ym_expand_sine_delta
        jmp     ym_expand_sine_word

ym_expand_power_start:
        move    #opm_power_packed,r1
        move    #opm_power,r0
        nop
        move    y:(r1)+,a
        move    a1,x:table_current
        rep     #2
        asl     a
        move    a1,y:(r0)+
        move    #>255,a
        move    a1,x:table_remaining
ym_expand_power_word:
        move    y:(r1)+,a
        move    a1,x:table_packed
        move    #>8,a
        move    a1,x:table_slots
ym_expand_power_delta:
        move    x:table_packed,a
        move    #>7,y0
        and     y0,a1
        move    a1,x0
        move    x:table_current,a
        sub     x0,a
        move    a1,x:table_current
        rep     #2
        asl     a
        move    a1,y:(r0)+

        move    x:table_packed,a
        rep     #3
        lsr     a
        move    a1,x:table_packed
        move    x:table_remaining,a
        move    #>1,x0
        sub     x0,a
        move    a1,x:table_remaining
        jeq     ym_expand_done
        move    x:table_slots,a
        move    #>1,x0
        sub     x0,a
        move    a1,x:table_slots
        jne     ym_expand_power_delta
        jmp     ym_expand_power_word

ym_expand_done:
        rts

; The Falcon maps external P over the X/Y SRAM. Emit the larger global-clock
; helpers after the main kernel so the LOD records stay small and monotonic.
ym_lfo_code macro

; Sign-extend the low byte of a1 to a 24-bit integer.
ym_sign_extend_byte:
        move    #>$ff,y0
        and     y0,a1
        jclr    #7,a1,ym_sign_extend_done
        move    #>$ffff00,y0
        or      y0,a
ym_sign_extend_done:
        rts

; Advance the continually-running 25-bit noise history once. Direct bit
; tests replace the former shift-and-mask extraction of single LFSR bits.
ym_clock_noise_once:
        move    #>1,y0
        move    y0,a                  ; newbit = 1 ^ bit16 ^ bit13
        jclr    #16,x:ym_noise_lfsr_low,ym_noise_bit16_clear
        eor     y0,a
ym_noise_bit16_clear:
        jclr    #13,x:ym_noise_lfsr_low,ym_noise_bit13_clear
        eor     y0,a
ym_noise_bit13_clear:
        move    a1,x:ym_noise_newbit

        clr     b
        jclr    #23,x:ym_noise_lfsr_low,ym_noise_bit23_clear
        move    y0,b
ym_noise_bit23_clear:
        move    b1,x:ym_noise_lfsr_high

        move    x:ym_noise_lfsr_low,b
        asl     b
        move    a1,x0
        add     x0,b
        move    b1,x:ym_noise_lfsr_low

        ; C++ post-increment semantics: compare the old counter, then either
        ; latch/reset or increment it.
        move    x:ym_noise_counter,a
        move    x:ym_noise_frequency,x0
        cmp     x0,a
        jlt     ym_clock_noise_increment
        clr     a
        move    a1,x:ym_noise_counter
        jclr    #17,x:ym_noise_lfsr_low,ym_noise_state_clear
        move    y0,a
ym_noise_state_clear:
        move    a1,x:ym_noise_state
        rts
ym_clock_noise_increment:
        move    #>1,x0
        add     x0,a
        move    a1,x:ym_noise_counter
        rts

; Clock OPM noise and LFO state once per native sample and publish the raw PM
; value plus the channel-independent AM value used during operator output.
ym_clock_noise_lfo:
        move    #ym_regdata+$0f,r0
        nop
        move    x:(r0),a
        move    #>$1f,y0
        and     y0,a1
        move    a1,x0
        move    #>$1f,a
        sub     x0,a
        move    a1,x:ym_noise_frequency
        jsr     ym_clock_noise_once
        jsr     ym_clock_noise_once

        ; (0x10 | rate.lo) << rate.hi, accumulated as low 22 + phase 8.
        move    #ym_regdata+$18,r0
        nop
        move    x:(r0),a
        move    a1,b
        move    #>$0f,y0
        and     y0,a1
        move    #>$10,x0
        add     x0,a
        rep     #4
        lsr     b
        and     y0,b1
        tst     b
        jeq     ym_lfo_increment_ready
        move    b1,y0
        rep     y0
        asl     a
ym_lfo_increment_ready:
        move    x:ym_lfo_fraction,x0
        add     x0,a
        move    #>$400000,x0
        cmp     x0,a
        jlt     ym_lfo_store_fraction
        sub     x0,a
        move    a1,x:ym_lfo_fraction
        move    x:ym_lfo_phase,a
        move    #>1,x0
        add     x0,a
        move    #>$ff,y0
        and     y0,a1
        move    a1,x:ym_lfo_phase
        jmp     ym_lfo_check_reset
ym_lfo_store_fraction:
        move    a1,x:ym_lfo_fraction

ym_lfo_check_reset:
        move    #ym_regdata+$01,r0
        nop
        move    x:(r0),a
        jclr    #1,a1,ym_lfo_latch_noise
        clr     a
        move    a1,x:ym_lfo_fraction
        move    a1,x:ym_lfo_phase

ym_lfo_latch_noise:
        ; Noise waveform writes one phase slot ahead, then reads the current
        ; slot, matching ymfm's stable-per-LFO-clock latch.
        move    x:ym_noise_lfsr_low,a
        rep     #17
        lsr     a
        move    #>$7f,y0
        and     y0,a1
        move    a1,b
        move    x:ym_noise_lfsr_high,a
        rep     #7
        asl     a
        move    b1,y1
        add     y1,a
        move    a1,x0

        move    x:ym_lfo_phase,a
        move    #>1,y1
        add     y1,a
        move    #>$ff,y0
        and     y0,a1
        move    a1,n0
        move    #ym_lfo_noise_wave,r0
        nop
        move    x0,x:(r0+n0)

        move    #ym_regdata+$1b,r0
        nop
        move    x:(r0),a
        move    #>3,y0
        and     y0,a1
        tst     a
        jeq     ym_lfo_wave_saw
        move    #>1,x0
        cmp     x0,a
        jeq     ym_lfo_wave_square
        move    #>2,x0
        cmp     x0,a
        jeq     ym_lfo_wave_triangle
        jmp     ym_lfo_wave_noise

ym_lfo_wave_saw:
        move    x:ym_lfo_phase,x0
        move    #>$ff,a
        sub     x0,a
        move    a1,x:ym_lfo_raw_am
        move    x:ym_lfo_phase,a
        jsr     ym_sign_extend_byte
        move    a1,x:ym_lfo_raw_pm
        jmp     ym_lfo_apply_depth

ym_lfo_wave_square:
        move    x:ym_lfo_phase,a
        jset    #7,a1,ym_lfo_square_high
        move    #>$ff,a
        move    a1,x:ym_lfo_raw_am
        move    #>$7f,a
        move    a1,x:ym_lfo_raw_pm
        jmp     ym_lfo_apply_depth
ym_lfo_square_high:
        clr     a
        move    a1,x:ym_lfo_raw_am
        move    #>$ffff80,a
        move    a1,x:ym_lfo_raw_pm
        jmp     ym_lfo_apply_depth

ym_lfo_wave_triangle:
        move    x:ym_lfo_phase,a
        jset    #7,a1,ym_lfo_triangle_high
        move    #>$ff,b
        move    a1,x0
        sub     x0,b
        move    b1,a
ym_lfo_triangle_high:
        asl     a
        move    #>$ff,y0
        and     y0,a1
        move    a1,x:ym_lfo_raw_am

        move    x:ym_lfo_phase,b
        jset    #6,b1,ym_lfo_triangle_pm_ready
        move    a1,x0
        move    #>$ff,a
        sub     x0,a
ym_lfo_triangle_pm_ready:
        jsr     ym_sign_extend_byte
        move    a1,x:ym_lfo_raw_pm
        jmp     ym_lfo_apply_depth

ym_lfo_wave_noise:
        move    x:ym_lfo_phase,n0
        move    #ym_lfo_noise_wave,r0
        nop
        move    x:(r0+n0),a
        move    a1,x:ym_lfo_raw_am
        jsr     ym_sign_extend_byte
        move    a1,x:ym_lfo_raw_pm

ym_lfo_apply_depth:
        ; MPY leaves the integer product doubled at the A0 end of the
        ; accumulator, so shifting one extra bit yields raw*depth >> 7.
        move    #ym_regdata+$19,r0
        nop
        move    x:(r0),a
        move    #>$7f,y0
        and     y0,a1
        move    a1,y0
        move    x:ym_lfo_raw_am,x0
        mpy     x0,y0,a
        rep     #8
        asr     a
        move    a0,x:ym_lfo_am

        move    #ym_regdata+$1a,r0
        nop
        move    x:(r0),a
        move    #>$7f,y0
        and     y0,a1
        move    a1,y0
        move    x:ym_lfo_raw_pm,x0
        mpy     x0,y0,a
        rep     #8
        asr     a
        move    a0,x:ym_lfo_pm
        rts

        endm

; Convert synth_index (channel*4 + logical operator) to the channel and raw OPM
; register slot used by ymfm: M1,C1,M2,C2 = +0,+16,+8,+24.
ym_select_operator:
        move    x:synth_index,a
        move    a1,b
        rep     #2
        lsr     a
        move    a1,x:query_channel
        move    a1,x:synth_channel

        move    #>3,y0
        and     y0,b1
        move    b1,x:synth_operator
        move    b1,n1
        move    #ym_slot_offsets,r1
        move    a1,y1                  ; channel; also spaces the r1 load
        move    x:(r1+n1),a
        add     y1,a
        move    a1,x:query_raw_operator
        rts

; Return the effective 0-63 envelope rate for synth_index/state.
ym_effective_rate:
        jsr     ym_select_operator

        ; ksrval = keycode >> (KSR xor 3). OPM keycode is KC >> 2.
        move    x:query_channel,n0
        move    #ym_regdata+$28,r0
        nop
        move    x:(r0+n0),a
        move    #>$7f,y0
        and     y0,a1
        rep     #2
        lsr     a
        move    a1,x:synth_increment  ; temporary keycode

        move    x:query_raw_operator,n0
        move    #ym_regdata+$80,r0
        nop
        move    x:(r0+n0),a
        rep     #6
        lsr     a
        move    #>3,y0
        and     y0,a1
        move    a1,y1
        move    #>3,b
        sub     y1,b
        move    b1,x0
        move    x:synth_increment,a
        tst     b
        jeq     ym_rate_ksr_ready
        rep     x0
        lsr     a
ym_rate_ksr_ready:
        move    a1,x:synth_increment  ; temporary ksrval

        ; Select the raw rate for the current ADSR state.
        move    x:synth_index,n0
        move    #ym_envelope_state,r0
        nop
        move    x:(r0+n0),a
        move    #>1,x0
        cmp     x0,a
        jeq     ym_rate_attack
        move    #>2,x0
        cmp     x0,a
        jeq     ym_rate_decay
        move    #>3,x0
        cmp     x0,a
        jeq     ym_rate_sustain

        move    x:query_raw_operator,n0
        move    #ym_regdata+$e0,r0
        nop
        move    x:(r0+n0),a
        move    #>$0f,y0
        and     y0,a1
        rep     #2
        asl     a
        move    #>2,x0
        add     x0,a
        jmp     ym_rate_apply_ksr

ym_rate_attack:
        move    #ym_regdata+$80,r0
        jmp     ym_rate_read_5bit
ym_rate_decay:
        move    #ym_regdata+$a0,r0
        jmp     ym_rate_read_5bit
ym_rate_sustain:
        move    #ym_regdata+$c0,r0
ym_rate_read_5bit:
        move    x:query_raw_operator,n0
        nop
        move    x:(r0+n0),a
        move    #>$1f,y0
        and     y0,a1
        tst     a
        jeq     ym_rate_done          ; a raw rate of zero ignores KSR
        asl     a

ym_rate_apply_ksr:
        move    x:synth_increment,x0
        add     x0,a
        move    #>63,x0
        cmp     x0,a
        jle     ym_rate_done
        move    x0,a
ym_rate_done:
        move    a1,x:synth_rate
        rts

; Apply pending key edges before advancing the clock.
ym_prepare_keys:
        clr     a
        move    a1,x:synth_index
ym_prepare_key_loop:
        move    x:synth_index,n0
        move    #ym_key_live,r0
        nop
        move    x:(r0+n0),a
        move    x:ym_csm_active,x0
        or      x0,a
        move    a1,b
        move    #ym_key_state,r0
        nop
        move    x:(r0+n0),a
        move    a1,y1
        cmp     y1,b
        jeq     ym_prepare_key_next

        move    b1,x:(r0+n0)
        tst     b
        jeq     ym_prepare_key_off

        move    #>1,a                 ; EG_ATTACK
        move    #ym_envelope_state,r0
        nop
        move    a1,x:(r0+n0)
        clr     a
        move    #ym_phase,r0
        nop
        move    a1,x:(r0+n0)
        jsr     ym_effective_rate
        move    #>62,x0
        cmp     x0,a
        jlt     ym_prepare_key_next
        clr     a
        move    x:synth_index,n0
        move    #ym_envelope,r0
        nop
        move    a1,x:(r0+n0)
        jmp     ym_prepare_key_next

ym_prepare_key_off:
        move    #ym_envelope_state,r0
        nop
        move    x:(r0+n0),a
        move    #>4,x0
        cmp     x0,a
        jge     ym_prepare_key_next
        move    x0,x:(r0+n0)          ; EG_RELEASE

ym_prepare_key_next:
        move    x:synth_index,a
        move    #>1,x0
        add     x0,a
        move    a1,x:synth_index
        move    #>32,x0
        cmp     x0,a
        jlt     ym_prepare_key_loop
        bclr    #0,x:ym_csm_active
        rts

; Sustain target in native 4.6 envelope units.
ym_sustain_target:
        move    x:query_raw_operator,n0
        move    #ym_regdata+$e0,r0
        nop
        move    x:(r0+n0),a
        rep     #4
        lsr     a
        move    #>$0f,y0
        and     y0,a1
        move    a1,b
        move    #>1,x0
        add     x0,b
        move    #>$10,y0
        and     y0,b1
        move    b1,y1
        or      y1,a
        rep     #5
        asl     a
        rts

; Clock one operator envelope on an envelope tick.
ym_clock_envelope:
        ; A released operator at maximum attenuation is a fixed point. Avoid
        ; selecting registers and looking up a rate that can no longer change
        ; its state; key-on processing will make it active again first.
        move    x:synth_index,n0
        move    #ym_envelope,r0
        nop
        move    x:(r0+n0),b
        move    #>$3ff,x0
        cmp     x0,b
        jne     ym_env_active
        move    #ym_envelope_state,r0
        nop
        move    x:(r0+n0),a
        move    #>4,x0
        cmp     x0,a
        jeq     ym_env_done

ym_env_active:
        jsr     ym_select_operator
        move    x:synth_index,n0
        move    #ym_envelope,r0
        nop
        move    x:(r0+n0),b
        move    #ym_envelope_state,r0
        nop
        move    x:(r0+n0),a

        ; Immediate ATTACK->DECAY and DECAY->SUSTAIN transitions.
        move    #>1,x0
        cmp     x0,a
        jne     ym_env_check_decay
        tst     b
        jne     ym_env_state_ready
        move    #>2,a
        move    a1,x:(r0+n0)
ym_env_check_decay:
        move    #>2,x0
        cmp     x0,a
        jne     ym_env_state_ready
        jsr     ym_sustain_target
        move    a1,x0
        move    x:synth_index,n0
        move    #ym_envelope,r0
        nop
        move    x:(r0+n0),b
        cmp     x0,b
        jlt     ym_env_state_ready
        move    #>3,a
        move    #ym_envelope_state,r0
        nop
        move    a1,x:(r0+n0)

ym_env_state_ready:
        jsr     ym_effective_rate
        move    a1,x:synth_rate
        rep     #2
        lsr     a
        move    a1,b                  ; b = rate_shift

        ; Derive ymfm's clock condition and 3-bit stepping index without a
        ; 32-bit temporary. For shifts >11 every envelope tick qualifies.
        move    #>11,a
        move    b1,y1
        sub     y1,a
        jlt     ym_env_fast_rate
        move    a1,x0                 ; x0 = 11-rate_shift
        move    x0,b
        tst     b
        jeq     ym_env_no_mask
        move    #>1,a
        rep     x0
        asl     a
        move    #>1,y0
        sub     y0,a                  ; a = (1 << count)-1
        move    a1,y0
        move    x:ym_env_tick,a
        and     y0,a1
        jne     ym_env_done
ym_env_no_mask:
        move    x:ym_env_tick,a
        move    x0,b
        tst     b
        jeq     ym_env_index_ready
        rep     x0
        lsr     a
        jmp     ym_env_index_ready

ym_env_fast_rate:
        move    x:ym_env_tick,a
ym_env_index_ready:
        move    #>7,y0
        and     y0,a1
        move    a1,b
        move    x:synth_rate,a
        rep     #3
        asl     a
        move    b1,y1
        add     y1,a
        move    a1,n1
        move    #opm_envelope_increment,r1
        nop
        move    y:(r1+n1),a
        move    a1,x:synth_increment

        move    x:synth_index,n0
        move    #ym_envelope_state,r0
        nop
        move    x:(r0+n0),b
        move    #>1,x0
        cmp     x0,b
        jne     ym_env_non_attack

        move    x:synth_rate,b
        move    #>62,x0
        cmp     x0,b
        jge     ym_env_done
        move    x:synth_increment,b

        ; env += (~env * increment) >> 4. The signed MPY leaves the doubled
        ; product at the A0 end, so five arithmetic shifts complete the >>4.
        ; A zero increment multiplies to a zero delta, needing no guard.
        move    #ym_envelope,r0
        nop
        move    x:(r0+n0),a
        not     a
        move    a1,x0
        move    b1,y0
        mpy     x0,y0,a
        rep     #5
        asr     a
        move    a0,y1
        move    x:(r0+n0),a
        add     y1,a
        move    a1,x:(r0+n0)
        rts

ym_env_non_attack:
        move    #ym_envelope,r0
        nop
        move    x:(r0+n0),a
        move    x:synth_increment,x0
        add     x0,a
        move    #>$400,x0
        cmp     x0,a
        jlt     ym_env_store
        move    #>$3ff,a
ym_env_store:
        move    a1,x:(r0+n0)
ym_env_done:
        rts

; Return synth_index phase in the 10-bit waveform domain, before masking.
ym_operator_phase:
        move    x:synth_index,n0
        move    #ym_phase,r0
        nop
        move    x:(r0+n0),a
        rep     #10
        lsr     a
        rts

; Return the signed 14-bit output of synth_index at phase a1.
ym_compute_volume:
        move    a1,x:volume_phase
        move    x:synth_index,n0
        move    #ym_envelope,r0
        nop
        move    x:(r0+n0),a
        move    #>$380,x0
        cmp     x0,a
        jgt     ym_volume_zero
        move    a1,x:volume_envelope

        move    x:volume_phase,a
        move    #>$3ff,y0
        and     y0,a1
        clr     b
        move    b1,x:volume_sign
        jclr    #9,a1,ym_volume_positive
        move    #>1,b
        move    b1,x:volume_sign
ym_volume_positive:
        jclr    #8,a1,ym_volume_sine_index
        not     a
ym_volume_sine_index:
        move    #>$ff,y0
        and     y0,a1
        move    a1,n1
        move    #opm_sine_attenuation,r1
        nop
        move    y:(r1+n1),a           ; a = logarithmic sine attenuation
        move    a1,x:volume_sine

        jsr     ym_select_operator
        move    x:query_raw_operator,n0
        move    #ym_regdata+$60,r0
        nop
        move    x:(r0+n0),a
        move    #>$7f,y0
        and     y0,a1
        rep     #3
        asl     a
        move    x:volume_envelope,y1
        add     y1,a

        move    x:query_raw_operator,n0
        move    #ym_regdata+$a0,r0
        nop
        move    x:(r0+n0),b
        jclr    #7,b1,ym_volume_no_am
        move    x:synth_am_offset,y1
        add     y1,a
ym_volume_no_am:
        move    #>$3ff,y0
        cmp     y0,a
        jle     ym_volume_env_ready
        move    y0,a
ym_volume_env_ready:
        rep     #2
        asl     a
        move    x:volume_sine,x0
        add     x0,a                  ; combined 5.8 attenuation
        move    a1,b
        move    #>$ff,y0
        and     y0,a1
        move    a1,n1
        move    #opm_power,r1
        nop
        move    y:(r1+n1),a

        move    b1,x0
        rep     #8
        lsr     b
        tst     b
        jeq     ym_volume_shifted
        move    b1,y0
        rep     y0
        lsr     a
ym_volume_shifted:
        move    x:volume_sign,b
        tst     b
        jeq     ym_volume_done
        neg     a
ym_volume_done:
        rts
ym_volume_zero:
        clr     a
        rts

; Return channel-7 operator-4 noise output using its raw effective envelope.
; The OPM bypasses the logarithmic sine/power transform for this path.
ym_compute_noise_volume:
        move    x:synth_index,n0
        move    #ym_envelope,r0
        nop
        move    x:(r0+n0),a
        move    a1,x:volume_envelope

        jsr     ym_select_operator
        move    x:query_raw_operator,n0
        move    #ym_regdata+$60,r0
        nop
        move    x:(r0+n0),a
        move    #>$7f,y0
        and     y0,a1
        rep     #3
        asl     a
        move    x:volume_envelope,y1
        add     y1,a

        move    #ym_regdata+$a0,r0
        nop
        move    x:(r0+n0),b
        jclr    #7,b1,ym_noise_volume_no_am
        move    x:synth_am_offset,y1
        add     y1,a
ym_noise_volume_no_am:
        move    #>$3ff,y0
        cmp     y0,a
        jle     ym_noise_volume_invert
        move    y0,a
ym_noise_volume_invert:
        move    a1,x0
        move    #>$3ff,a
        sub     x0,a
        asl     a
        move    x:ym_noise_state,b
        tst     b
        jeq     ym_noise_volume_done
        neg     a
ym_noise_volume_done:
        rts

; Clamp one channel's carrier sum to signed 16-bit, as output_4op does after
; each optional carrier addition.
ym_clamp_channel:
        move    #>$007fff,x0
        cmp     x0,a
        jle     ym_clamp_low
        move    x0,a
        rts
ym_clamp_low:
        move    #>$ff8000,x0
        cmp     x0,a
        jge     ym_clamp_done
        move    x0,a
ym_clamp_done:
        rts

; Synthesize synth_channel and accumulate it into the stereo mix.
ym_compute_am_offset:
        move    x:synth_channel,n0
        move    #ym_regdata+$38,r0
        nop
        move    x:(r0+n0),a
        move    #>3,y0
        and     y0,a1
        tst     a
        jeq     ym_compute_am_zero
        move    #>1,x0
        sub     x0,a
        move    a1,y0
        move    x:ym_lfo_am,a
        move    y0,b
        tst     b
        jeq     ym_compute_am_store
        rep     y0
        asl     a
ym_compute_am_store:
        move    a1,x:synth_am_offset
        rts
ym_compute_am_zero:
        clr     a
        move    a1,x:synth_am_offset
        rts

ym_output_channel:
        move    x:synth_channel,a
        rep     #2
        asl     a
        move    a1,x:synth_index

        ; Four fully attenuated operators produce exactly zero, including the
        ; channel-7 noise substitution. Keep the feedback input clocked to zero
        ; but bypass the expensive algorithm, sine, power, and AM calculations.
        move    #ym_envelope,x0
        add     x0,a
        move    a1,r0
        nop
        move    x:(r0)+,a
        move    x:(r0)+,x0
        add     x0,a
        move    x:(r0)+,x0
        add     x0,a
        move    x:(r0),x0
        add     x0,a
        move    #>$ffc,x0
        cmp     x0,a
        jne     ym_output_channel_active

        move    x:synth_channel,n0
        move    #ym_feedback_in,r0
        nop
        clr     a
        move    a1,x:(r0+n0)
        rts

ym_output_channel_active:
        jsr     ym_compute_am_offset

        ; Operator 1 feedback uses the two prior outputs.
        move    x:synth_channel,n0
        move    #ym_feedback_0,r0
        nop
        move    x:(r0+n0),a
        move    #ym_feedback_1,r0
        nop
        move    x:(r0+n0),b
        move    b1,y1
        add     y1,a
        move    a1,x:synth_result

        move    #ym_regdata+$20,r0
        nop
        move    x:(r0+n0),a
        rep     #3
        lsr     a
        move    #>7,y0
        and     y0,a1
        tst     a
        jeq     ym_output_feedback_zero
        move    a1,y1
        move    #>10,b
        sub     y1,b
        move    b1,y0
        tst     b
        jeq     ym_output_feedback_unshifted
        move    x:synth_result,a
        rep     y0
        asr     a
        move    a1,b
        jmp     ym_output_feedback_ready
ym_output_feedback_unshifted:
        move    x:synth_result,b
        jmp     ym_output_feedback_ready
ym_output_feedback_zero:
        clr     b
ym_output_feedback_ready:
        jsr     ym_operator_phase
        move    b1,y1
        add     y1,a
        jsr     ym_compute_volume
        move    a1,x:synth_opout+1
        move    x:synth_channel,n0
        move    #ym_feedback_in,r0
        nop
        move    a1,x:(r0+n0)

        ; Muted channels still update operator-1 feedback.
        move    #ym_regdata+$20,r0
        nop
        move    x:(r0+n0),a
        move    #>$c0,y0
        and     y0,a1
        jeq     ym_output_channel_done

        move    x:(r0+n0),a
        move    #>7,y0
        and     y0,a1
        move    a1,n1
        move    #opm_algorithm_ops,r1
        nop
        move    y:(r1+n1),a
        move    a1,x:synth_algorithm
        clr     a
        move    a1,x:synth_opout

        ; Operator 2 input is either zero or O1.
        move    x:synth_algorithm,a
        jclr    #0,a1,ym_output_op2_zero
        move    x:synth_opout+1,a
        jmp     ym_output_op2_mod
ym_output_op2_zero:
        clr     a
ym_output_op2_mod:
        asr     a
        move    a1,b
        move    x:synth_index,a
        move    #>1,x0
        add     x0,a
        move    a1,x:synth_index
        jsr     ym_operator_phase
        move    b1,y1
        add     y1,a
        jsr     ym_compute_volume
        move    a1,x:synth_opout+2
        move    x:synth_opout+1,b
        move    b1,y1
        add     y1,a
        move    a1,x:synth_opout+5

        ; Operator 3 input selector occupies bits 1-3.
        move    x:synth_algorithm,a
        lsr     a
        move    #>7,y0
        and     y0,a1
        move    a1,n0
        move    #synth_opout,r0
        nop
        move    x:(r0+n0),a
        asr     a
        move    a1,b
        move    x:synth_index,a
        move    #>1,x0
        add     x0,a
        move    a1,x:synth_index
        jsr     ym_operator_phase
        move    b1,y1
        add     y1,a
        jsr     ym_compute_volume
        move    a1,x:synth_opout+3
        move    x:synth_opout+1,b
        move    b1,y1
        add     y1,a
        move    a1,x:synth_opout+6
        move    x:synth_opout+3,a
        move    x:synth_opout+2,x0
        add     x0,a
        move    a1,x:synth_opout+7

        ; Operator 4 input selector occupies bits 4-6.
        move    x:synth_algorithm,a
        rep     #4
        lsr     a
        move    #>7,y0
        and     y0,a1
        move    a1,n0
        move    #synth_opout,r0
        nop
        move    x:(r0+n0),a
        asr     a
        move    a1,b
        move    x:synth_index,a
        move    #>1,x0
        add     x0,a
        move    a1,x:synth_index
        jsr     ym_operator_phase
        move    b1,y1
        add     y1,a
        move    x:synth_channel,b
        move    #>7,x0
        cmp     x0,b
        jne     ym_output_op4_sine
        move    #ym_regdata+$0f,r0
        nop
        move    x:(r0),b
        jclr    #7,b1,ym_output_op4_sine
        jsr     ym_compute_noise_volume
        jmp     ym_output_op4_ready
ym_output_op4_sine:
        jsr     ym_compute_volume
ym_output_op4_ready:
        move    a1,x:synth_result

        ; Add any additional carriers, clipping after each one.
        move    x:synth_algorithm,b
        jclr    #7,b1,ym_output_no_op1
        move    x:synth_opout+1,x0
        add     x0,a
        jsr     ym_clamp_channel
ym_output_no_op1:
        move    x:synth_algorithm,b
        jclr    #8,b1,ym_output_no_op2
        move    x:synth_opout+2,x0
        add     x0,a
        jsr     ym_clamp_channel
ym_output_no_op2:
        move    x:synth_algorithm,b
        jclr    #9,b1,ym_output_no_op3
        move    x:synth_opout+3,x0
        add     x0,a
        jsr     ym_clamp_channel
ym_output_no_op3:
        move    a1,x:synth_result

        move    x:synth_channel,n0
        move    #ym_regdata+$20,r0
        nop
        move    x:(r0+n0),b
        jclr    #6,b1,ym_output_no_left
        move    x:ym_last_left,a
        move    x:synth_result,x0
        add     x0,a
        move    a1,x:ym_last_left
ym_output_no_left:
        jclr    #7,b1,ym_output_channel_done
        move    x:ym_last_right,a
        move    x:synth_result,x0
        add     x0,a
        move    a1,x:ym_last_right
ym_output_channel_done:
        rts

        ; Keep each initialized P record within TOS 4.02's converter limit.
        ds      1

; Simulate the YM3012's 10.3-float encode/decode truncation.
ym_roundtrip_fp:
        jsr     ym_clamp_channel
        move    a1,x:synth_result
        move    a1,b
        tst     b
        jge     ym_roundtrip_scan
        neg     b                    ; value ^ -1 = -value - 1
        move    #>1,x0
        sub     x0,b
ym_roundtrip_scan:
        clr     a                    ; number of low bits to clear
ym_roundtrip_scan_loop:
        move    #>512,x0
        cmp     x0,b
        jlt     ym_roundtrip_mask
        lsr     b
        move    #>1,x0
        add     x0,a
        jmp     ym_roundtrip_scan_loop
ym_roundtrip_mask:
        tst     a
        jeq     ym_roundtrip_unmasked
        move    a1,y0
        move    #>1,a
        rep     y0
        asl     a
        move    #>1,x0
        sub     x0,a
        not     a
        move    a1,x0
        move    x:synth_result,a
        and     x0,a1
        rts
ym_roundtrip_unmasked:
        move    x:synth_result,a
        rts

; Generate one native 62.5 kHz YM2151 sample.
ym_clock_sample:
        jsr     ym_prepare_keys

        ; Feedback pipeline is clocked before the operators.
        move    #ym_feedback_0,r0
        move    #ym_feedback_1,r1
        move    #ym_feedback_in,r2
        nop
        do      #8,ym_clock_feedback
        move    x:(r1),a
        move    a1,x:(r0)+
        move    x:(r2)+,a
        move    a1,x:(r1)+
ym_clock_feedback:

        ; OPM's envelope divider skips counter values whose low bits are 3.
        move    x:ym_env_counter,a
        move    #>1,x0
        add     x0,a
        move    a1,b
        move    #>3,y0
        and     y0,b1
        move    #>3,x0
        cmp     x0,b
        jne     ym_clock_counter_ready
        move    #>1,x0
        add     x0,a
ym_clock_counter_ready:
        move    a1,x:ym_env_counter
        move    a1,b
        move    #>3,y0
        and     y0,b1
        jne     ym_clock_phase_all

        rep     #2
        lsr     a
        move    a1,x:ym_env_tick
        clr     a
        move    a1,x:synth_index
ym_clock_envelope_loop:
        jsr     ym_clock_envelope
        move    x:synth_index,a
        move    #>1,x0
        add     x0,a
        move    a1,x:synth_index
        move    #>32,x0
        cmp     x0,a
        jlt     ym_clock_envelope_loop

ym_clock_phase_all:
        jsr     ym_clock_noise_lfo

        ; PM depth is zero for the common case. Fetch cached phase steps from Y
        ; while fetching phases from X, reducing phase advancement to three
        ; instructions per operator. Any non-zero PM sample combines the
        ; per-operator static caches with the live PM value below.
        move    x:ym_lfo_pm,a
        tst     a
        jne     ym_clock_phase_dynamic
        move    #ym_phase,r0
        move    #ym_phase_step_cache,r4
        do      #32,ym_clock_phase_cached
        move    x:(r0),a y:(r4)+,y1
        add     y1,a
        move    a1,x:(r0)+
ym_clock_phase_cached:
        jmp     ym_clock_phase_complete

ym_clock_phase_dynamic:
        clr     a
        move    a1,x:synth_index
ym_clock_phase_loop:
        jsr     ym_step_from_statics
        move    a1,b
        move    x:synth_index,n0
        move    #ym_phase,r0
        nop
        move    x:(r0+n0),a
        move    b1,y1
        add     y1,a
        move    a1,x:(r0+n0)

        move    x:synth_index,a
        move    #>1,x0
        add     x0,a
        move    a1,x:synth_index
        move    #>32,x0
        cmp     x0,a
        jlt     ym_clock_phase_loop

ym_clock_phase_complete:
        clr     a
        move    a1,x:ym_last_left
        move    a1,x:ym_last_right
        move    a1,x:synth_channel
ym_clock_channel_loop:
        jsr     ym_output_channel
        move    x:synth_channel,a
        move    #>1,x0
        add     x0,a
        move    a1,x:synth_channel
        move    #>8,x0
        cmp     x0,a
        jlt     ym_clock_channel_loop

        move    x:ym_last_left,a
        jsr     ym_roundtrip_fp
        move    a1,x:ym_last_left
        move    x:ym_last_right,a
        jsr     ym_roundtrip_fp
        move    a1,x:ym_last_right
        jsr     ym_clock_timers
        clr     a                       ; one sample is the 64-clock busy time
        move    a1,x:ym_busy
        rts

; Clock the two OPM timers after the generated sample. Thus a period of N is
; visible in status after N clock commands, while CSM is consumed by the key
; preparation at the beginning of sample N.
ym_clock_timers:
        move    x:ym_timer_b_phase,a
        move    #>1,x0
        add     x0,a
        move    #>$0f,y0
        and     y0,a1
        move    a1,x:ym_timer_b_phase

        move    x:ym_regdata+$14,b
        move    b1,y1

        jclr    #0,y1,ym_clock_timer_b
        move    x:ym_timer_a_counter,a
        sub     x0,a
        move    a1,x:ym_timer_a_counter
        tst     a
        jne     ym_clock_timer_b
        jclr    #2,y1,ym_clock_timer_a_csm
        bset    #0,x:ym_status
ym_clock_timer_a_csm:
        jclr    #7,y1,ym_clock_timer_a_reload
        bset    #0,x:ym_csm_active
ym_clock_timer_a_reload:
        jsr     ym_reload_timer_a

ym_clock_timer_b:
        jclr    #1,y1,ym_clock_timers_done
        move    x:ym_timer_b_counter,a
        move    #>1,x0
        sub     x0,a
        move    a1,x:ym_timer_b_counter
        tst     a
        jne     ym_clock_timers_done
        jclr    #3,y1,ym_clock_timer_b_reload
        bset    #1,x:ym_status
ym_clock_timer_b_reload:
        jsr     ym_reload_timer_b
ym_clock_timers_done:
        rts

        ym_lfo_code

; Uninitialized external X RAM does not consume TOS's converted .LOD budget.
; Each aligned buffer holds one interleaved 1007-frame stereo period. Modulo
; addressing loops the active block while the other is rendered and swapped.
        org     x:$1000
ssi_buffer_a:
        ds      2014

        org     x:$1800
ssi_buffer_b:
        ds      2014

        include 'ymtables.inc'          ; DOS assembler requires an 8.3 name

        end
