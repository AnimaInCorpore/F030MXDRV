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

; The block spikes keep oscillator position as a 48-bit table index: the X
; word is the integer position and the Y word is its fractional remainder.
; These locations overlay exact-renderer cache words only while a block-profile
; command owns the DSP; the cache is rebuilt before returning to the loop.
        org     l:$54
rt2_phase:
        ds      4
        org     l:$58
rt2_phase_correction:
        ds      1

; The integrated eight-channel profile extends that overlay to all 32 phases.
; Its eight feedback pairs occupy the following internal words. Keeping both
; histories and every phase on chip prevents their traffic from contending
; with the live SSI fetches on the Falcon external bus.
        org     l:$54
rt5_phase:
        ds      32

        org     x:$74
rt5_feedback_1:
        ds      8

        org     y:$74
rt5_feedback_0:
        ds      8

; Modulo-2 gain pair for the all-carrier O1 helper: entry 0 holds the
; fold-scale history gain and entry 1 the carrier gain, each parallel-
; reloading y0 inside the two-product loop. Overlays the exact detune
; cache tail exactly like the phases above; stop rebuilds it.
rt5_alg7_gain_ring:
        ds      2

; One operator stage writes this ring while the next consumes its quantized
; table-index modulation. Modulo-64 addressing requires 64-word alignment.
        org     x:$80
rt2_stage_ring:
        ds      64

; Block-oriented spike state: four gains and the feedback output history.
; This follows the stage ring in otherwise-unused internal X RAM.
        org     x:$c0
rt2_gain:
        ds      4
rt2_fb_1:
        ds      1
rt4_carrier_gain:
        ds      4
rt4_algorithm:
        ds      1

; Integrated block-engine support-spike state. The 32 decoded envelope levels
; occupy the next internal-X line and the decoded LFO/timer scalars fill the
; rest of internal X; the hot phase and feedback overlays above are valid
; because the exact engine is idle while this profiling command owns the DSP.
rt5_native_phase:
        ds      1
rt5_lfo_phase:
        ds      1
rt5_noise_lfsr:
        ds      1
rt5_timer_counter:
        ds      1
rt5_event_clock:
        ds      1
rt5_event_read:
        ds      1
rt5_event_count:
        ds      1
rt5_checksum:
        ds      1
rt5_block_control:
        ds      1
rt5_pan_left_base:
        ds      1
rt5_pan_right_base:
        ds      1
rt5_current_channel_control:
        ds      1
rt5_lfo_step_block:
        ds      1
rt5_lfo_step_tick:
        ds      1

        org     x:$d8
rt5_envelope_level:
        ds      32
rt5_pm_scale:
        ds      1
rt5_lfo_amd:
        ds      1
rt5_lfo_waveform:
        ds      1
rt5_timer_a_reload:
        ds      1
rt5_timer_b_reload:
        ds      1
rt5_timer_b_counter:
        ds      1
rt5_timer_control:
        ds      1
rt5_timer_status:
        ds      1

; Per-operator half-block envelope multipliers and the block's PM-adjusted
; phase increments overlay the exact renderer's internal-Y frequency caches,
; which rt2_restore_common rebuilds before the command replies. Both arrays
; use operator-major order (slot = operator * 8 + channel), so the render
; bodies can read one increment per 64-frame stage through the channel's
; feedback pointer as y:(r2+n2) with a statically known negative offset per
; operator position; indexed DSP56001 addressing only pairs same-numbered
; registers.
        org     y:$0
rt5_env_a:
        ds      32
rt5_operator_increment:
        ds      32

; Seventeen single-bit LFSR jump columns, derived once per command before
; the measured bracket and consumed by the slice-table doubling fill.
        org     y:$40
rt5_noise_columns:
        ds      17

; Write-first common-ring state: zero while this block's both-panned carrier
; ring is still unwritten. The first both-routed carrier then writes instead
; of accumulating, and the stereo emit pass skips a never-written ring, so no
; per-block ring clear is needed. Lives outside the checksummed decoded-state
; span, keeping command $17's deterministic reply unchanged.
rt5_mix_written:
        ds      1

; 48-bit LFO accumulator holding ymfm's 32-bit counter times 2^18, so the
; true waveform index (counter bits 22-29) is the top byte of the high word.
; The exact per-tick and per-81-tick advances are decoded into matching
; high/low pairs when register $18 is written.
rt5_lfo_acc_hi:
        ds      1
rt5_lfo_acc_lo:
        ds      1

; The PRE offsets apply before the operator-1 feedback stage advances r2 by
; one channel slot; the POST offsets compensate for that advance. The @cvs
; wrapper only strips the Y-memory attribute so the X-space feedback anchor
; can be subtracted; the numeric offset is unchanged.
; round(2^19 * 2^19/(51*1007)): the exact step-to-increment scale for the
; render's 255-times-two per-frame phase mac against the 256-step sine ROM.
RT5_PITCH_DDA_SCALE equ 5352297

RT5_INC_BASE     equ @cvs(x,rt5_operator_increment)-rt5_feedback_1
RT5_INC_OP1_PRE  equ RT5_INC_BASE+0
RT5_INC_OP2_PRE  equ RT5_INC_BASE+8
RT5_INC_OP3_PRE  equ RT5_INC_BASE+16
RT5_INC_OP2_POST equ RT5_INC_BASE+8-1
RT5_INC_OP3_POST equ RT5_INC_BASE+16-1
RT5_INC_OP4_POST equ RT5_INC_BASE+24-1

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

; Algorithms 4 and 5 need a second block ring because two independently
; modulated branches meet only at the channel output. Keep it in otherwise-
; unused internal Y RAM so neither branch pays an external-memory wait state.
; The integrated profile reuses the same mutually-exclusive ring for its
; eight-channel carrier sum.
        org     y:$c0
rt4_branch_ring:
rt5_mix_ring:
        ds      64

        org     x:$4f8
rt5_channel_control:
        ds      8

        org     x:$500
rt5_event_times:
        ds      32
rt5_event_commands:
        ds      32

; Live per-operator block gains in the same channel-major M1/C1/M2/C2 order
; as rt5_phase: the output-scale array feeds carrier stages and the
; modulation-scale array (2^-13: ymfm's out>>1 serial depth in 256-step
; sine-ROM index units) feeds modulator stages, each algorithm body pointing
; n7 at the constant offset matching the stage's role. The live words carry
; this block's AM; the base pairs below hold the AM-free decoded gains.
        org     x:$540
rt5_operator_gain_out:
        ds      32
rt5_operator_gain_mod:
        ds      32

; AM-free base gains plus the block AM state, all touched only at block
; boundaries or decode time.
        org     x:$24c0
rt5_operator_gain_base_out:
        ds      32
rt5_operator_gain_base_mod:
        ds      32
rt5_lfo_step_block_lo:
        ds      1                       ; low pair words of the scaled steps
rt5_lfo_step_tick_lo:
        ds      1
rt5_am_mult:
        ds      4                       ; 2^(-(am<<(AMS-1))/64); [0] is unity
rt5_ams_previous:
        ds      8                       ; per-channel AMS for turn-off restore
rt5_lfo_am_channel:
        ds      1                       ; AM walk scratch: channel, operator,
rt5_lfo_am_op:
        ds      1                       ; and the channel's multiplier
rt5_lfo_am_mult_ch:
        ds      1
rt5_am_engaged:
        ds      1                       ; nonzero while any live gain is scaled

; Channel pitch-rebuild scratch, decode-time only: the shared gap-removed
; position, octave block, DT1 table row base, and channel index, plus the
; per-operator loop counter and step/DT1 holds across the detune lookup.
rt5_pitch_position:
        ds      1
rt5_pitch_block:
        ds      1
rt5_pitch_keycode4:
        ds      1
rt5_pitch_channel:
        ds      1
rt5_pitch_op:
        ds      1
rt5_pitch_step:
        ds      1
rt5_pitch_dt1:
        ds      1

; Channel-7 noise substitution state. The threshold is the decoded latch
; period (ymfm frequency+1, in 1007ths of a double-rate tick) and doubles
; as the enable flag; the counter is the per-frame 2560-step DDA; the
; snapshot holds the LFSR at the last latch so the sign survives block
; boundaries; the gain is the block-held signed magnitude (1023-att)<<9.
rt5_noise_threshold:
        ds      1
rt5_noise_counter:
        ds      1
rt5_noise_state_snap:
        ds      1
rt5_noise_gain:
        ds      1

RT5_OUT_GAIN_OFFSET equ rt5_operator_gain_out-rt5_phase
RT5_MOD_GAIN_OFFSET equ rt5_operator_gain_mod-rt5_phase

; The integrated profile groups channel carriers by their four hardware pan
; modes. Both-output carriers retain the internal-Y ring above. Left-only and
; right-only carriers accumulate in place into host-prepared planar PCM; the
; two 2,048-frame streams stand in for successively refilled inactive blocks.
; All storage remains inside the 8,192-word X/Y reservations. The Y stream
; temporarily overlays the expanded power table and packed upload source, so
; the latter is backed up in the remaining X window and both are restored when
; the command completes.
        org     x:$580
rt5_pan_left_stream:
        ds      DSP_RT_PROFILE_FRAMES
rt5_packed_table_backup:
        ds      329                     ; generated YM_TABLE_WORDS (forward DS is illegal)

; Decoded per-operator pitch state in the operator-major order of the
; internal-Y increment overlay. The 33rd base word keeps the pipelined
; support-loop prefetch deterministic. The 64-word alignment keeps a
; stride-8 channel rebuild inside one modulo block even though the walking
; pointer carries a modulo-64 modifier.
        org     x:$f00
rt5_increment_base:
        ds      33
rt5_operator_mul:
        ds      32

; Runtime-derived 64-step noise-LFSR jump tables in 6/6/5-bit slices. The
; five-bit slice covers state bits 12-16 and must stay inside one modulo-64
; block because its lookup pointer carries the stage-ring modifier.
        org     x:$f48
rt5_noise_jump_high5:
        ds      32
rt5_noise_jump_low6:
        ds      64
rt5_noise_jump_mid6:
        ds      64

        org     y:$1780
rt5_pan_right_stream:
        ds      DSP_RT_PROFILE_FRAMES

; Envelope-active bookkeeping lives in the physically free window above the
; 8,192-word external X/Y reservations. External P aliases external Y word
; for word on the Falcon (and external X aliases P at +$4000), so phys
; $2000-$28ff carries the cold-code island while these uninitialized arrays
; own phys $2a00 (Y) and $6400 (X); the stage-two island check keeps program
; code below Y:$2a00. Both base addresses are 64-aligned so (r5+n5)
; state reads stay inside one modulo block under the render's m5=63.
        org     x:$2400
rt5_env_state:
        ds      32                      ; bits 2:0 ADSR, bit 3 active, bit 4 keyed
rt5_tl_base:
        ds      32                      ; decoded 0.23 total-level amplitude
rt5_active_list:
        ds      32
rt5_active_count:
        ds      1
rt5_active_index:
        ds      1
rt5_env_current:
        ds      1                       ; operator index shared by the helpers
rt5_env_slot:
        ds      1
rt5_env_rate:
        ds      1
rt5_env_key_phase:
        ds      1

        org     x:$2480
rt5_env_target:
        ds      32                      ; cached 10.13 sustain-level target

; Persistent production-stream bookkeeping. This sits beyond the envelope
; arrays in external X and is touched only at block/refill boundaries.
rt5_runtime_mode:
        ds      1
rt5_runtime_output:
        ds      1


; Raised above the enlarged code island; only block-boundary code touches it.
        org     y:$2a00
rt5_env_b:
        ds      32                      ; signed 10.13 full-block addend

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

; -----------------------------------------------------------------------------
; Block-boundary envelope pass
; -----------------------------------------------------------------------------
; This is the only recurring per-block envelope cost, so it leads the program
; inside internal P RAM ($0080-$01ff) where instruction fetches avoid the
; external-memory penalty; the amortized event-decode helpers live in the
; external island instead. Each envelope-active operator advances by one
; composed full-block affine step - the capture harness derives mid-block
; levels analytically from the same defining recurrence - and its AM gain
; pair is rebuilt only when the 10-bit attenuation actually moved. R4 walks
; the active list; a retirement swaps the list tail into the current slot.
rt5_env_scan:
        move    x:rt5_active_count,a
        move    #>rt5_active_list,x0
        add     x0,a
        move    a1,y1                   ; list end, held across the helpers
        move    #rt5_active_list,r4
rt5_env_scan_next:
        move    r4,b
        cmp     y1,b                    ; walker - end
        jge     rt5_env_scan_done
        move    x:(r4),b                ; operator index
        ; fall through: the advance body is fused into the walk, ending in
        ; either rt5_env_keep_done or a retirement jump back to this loop
        move    b1,n1
        move    b1,n2
        move    b1,n3
        move    b1,n5
        ; a unity multiplier with a zero addend can never move the level
        ; again: rebuild the gain once and retire the operator
        move    #0,r2
        nop
        move    y:(r2+n2),x0            ; block multiplier
        move    #rt5_env_b,r2
        nop
        move    y:(r2+n2),a             ; block addend
        tst     a                       ; a zero addend can never move the
        jne     rt5_env_op_moving       ; level: attack addends are a-1 and
        jsr     rt5_env_gain_op         ; zero decay addends pair with unity
        jmp     rt5_env_remove
rt5_env_op_moving:
        move    #rt5_envelope_level,r1
        nop
        move    x:(r1+n1),y0            ; pre-advance level, kept for the
                                        ; gain-rebuild change test below
        mac     x0,y0,a                 ; end-of-block level
        move    #rt5_env_state,r5
        move    #>$7fe000,x1            ; 1023 in 10.13 units
        move    x:(r5+n5),b
        jset    #2,b1,rt5_env_cap_path  ; release
        jclr    #1,b1,rt5_env_attack_path
        jset    #0,b1,rt5_env_cap_path  ; sustain
        ; decay: the silence cap first, then the sustain boundary against
        ; the target the decay-entry reload cached for this operator
        cmp     x1,a
        jge     rt5_env_retire_capped
        move    #rt5_env_target,r3
        nop
        move    x:(r3+n3),x0
        cmp     x0,a
        jlt     rt5_env_store_keep
        ; the decay reached its sustain level: keep the level, switch to D2R
        move    x:(r5+n5),b
        bset    #0,b1
        move    b1,x:(r5+n5)
        move    a1,x:(r1+n1)
        jsr     rt5_env_transition_reload
        jmp     rt5_env_finish_keep
rt5_env_attack_path:
        ; the affine attack converges past four attenuation units within the
        ; block in which the exact recurrence lands on zero
        move    #>$008000,x0
        cmp     x0,a
        jge     rt5_env_store_keep
        clr     a
        bclr    #0,b1
        bset    #1,b1
        move    b1,x:(r5+n5)
        move    a1,x:(r1+n1)
        jsr     rt5_env_transition_reload
        jmp     rt5_env_finish_keep
rt5_env_cap_path:
        cmp     x1,a
        jlt     rt5_env_store_keep
rt5_env_retire_capped:
        ; full attenuation: pin the level, silence all four gain words
        move    x1,a
        move    a1,x:(r1+n1)
        move    n2,b
        move    #>rt5_env_gainmap,x0
        add     x0,b
        move    b1,r3
        nop
        movem   p:(r3),b
        move    b1,n1
        move    #rt5_operator_gain_out,r1
        clr     a
        move    a1,x:(r1+n1)
        move    #rt5_operator_gain_mod,r1
        nop
        move    a1,x:(r1+n1)
        move    #rt5_operator_gain_base_out,r1
        nop
        move    a1,x:(r1+n1)
        move    #rt5_operator_gain_base_mod,r1
        nop
        move    a1,x:(r1+n1)
        jmp     rt5_env_remove
rt5_env_store_keep:
        move    a1,x:(r1+n1)
        ; skip the gain rebuild while the 10-bit attenuation is unchanged
        move    a1,x0
        move    y0,b
        eor     x0,b
        move    #>$ffe000,y0
        and     y0,b
        jeq     rt5_env_keep_done
rt5_env_finish_keep:
        jsr     rt5_env_gain_op
rt5_env_keep_done:
        move    (r4)+
        jmp     rt5_env_scan_next
rt5_env_scan_done:
        rts
rt5_env_remove:
        ; clear the active bit and swap the list tail into this slot
        move    #rt5_env_state,r5
        nop
        move    x:(r5+n5),a
        bclr    #3,a1
        move    a1,x:(r5+n5)
        move    x:rt5_active_count,a
        move    #>1,x0
        sub     x0,a
        move    a1,x:rt5_active_count
        move    a1,n0
        move    #rt5_active_list,r0
        move    y1,a
        sub     x0,a
        move    a1,y1                   ; the register-held end shrinks too
        move    x:(r0+n0),b
        move    b1,x:(r4)
        jmp     rt5_env_scan_next

; Rebuild both AM gain variants of the operator in N1 from its total-level
; base and current envelope level: gain = tl * 2^(-level/64), decomposed
; into the generated 64-entry fraction table and a per-octave shift.
rt5_env_gain_op:
        move    #rt5_envelope_level,r1
        nop
        move    x:(r1+n1),x0
        move    #>$000400,y0
        mpy     x0,y0,a                 ; integer level = level >> 13
        move    #>1023,x0
        cmp     x0,a
        jge     rt5_env_gain_silent
        move    a1,x0
        move    #>$020000,y0
        mpy     x0,y0,b                 ; octave = level >> 6
        move    b1,b                    ; drop B0 fraction bits: REP of a
                                        ; zero count would run 65536 times
        move    #>$00003f,y0
        and     y0,a
        move    #>rt5_env_fraction,x0
        add     x0,a
        move    a1,r3
        nop
        movem   p:(r3),y0               ; 2^(-fraction/64)
        move    #rt5_tl_base,r1
        nop
        move    x:(r1+n1),x0
        mpy     x0,y0,a                 ; unshifted gain
        tst     b
        jeq     rt5_env_gain_shifted
        move    b1,x0
        rep     x0
        asr     a
rt5_env_gain_shifted:
        move    a1,y0                   ; output-scale gain
        ; The modulation scale is one multiply: $1000 is 2^-11, which under
        ; the 2^21 full-volume amplitude convention lands the ring at ymfm's
        ; exact out>>1 serial depth in 256-step ROM index units. Ring and
        ; history scales are coupled (one product per frame), so an M1 with
        ; feedback splits the error: the half fold k = (10-FB)>>1 shifts its
        ; gain so the history sum lands 2^(k-... within a factor 2^((10-FB)
        ; -1-k) of ymfm's (out0+out1)>>(10-FB) while its onward serial depth
        ; gives up the same factor. The honest-fixture model sweep in
        ; docs/perceptual-compatibility.md picked this rule; level 0
        ; dispatches feedback-less and stays exact everywhere.
        move    n1,a
        move    #>8,x0
        cmp     x0,a
        jge     rt5_env_gain_mod_serial
        move    #>rt5_channel_control,x0
        add     x0,a
        move    a1,r3
        nop
        move    x:(r3),a
        move    #>$38,x0
        and     x0,a                    ; feedback level << 3
        jeq     rt5_env_gain_mod_serial
        rep     #3
        lsr     a                       ; feedback level 1-7
        move    #>10,b
        sub     a,b
        lsr     b                       ; half fold (10-FB)>>1, always 1-4
        ; per-algorithm bias: how much O1's onward serial depth matters
        ; downstream varies by topology, so the honest-fixture sweep tuned
        ; one signed offset per algorithm (clamped at the serial scale)
        move    x:(r3),a
        move    #>7,x0
        and     x0,a
        move    #>rt5_fold_bias,x0
        add     x0,a
        move    a1,r3
        nop
        movem   p:(r3),a
        add     a,b
        jgt     rt5_env_gain_fold_ready
        move    #>$001000,a             ; k clamps to the plain serial scale
        jmp     rt5_env_gain_mod_have
rt5_env_gain_fold_ready:
        move    b1,n0
        move    #>$001000,a
        rep     n0
        lsr     a
rt5_env_gain_mod_have:
        move    a1,x1
        jmp     rt5_env_gain_mod_scale
rt5_env_gain_mod_serial:
        move    #>$001000,x1
rt5_env_gain_mod_scale:
        move    y0,x0
        mpy     x0,x1,a
        move    a1,x1                   ; modulation-scale gain
rt5_env_gain_store:
        move    n1,a                    ; operator to channel-major index
        move    #>rt5_env_gainmap,x0
        add     x0,a
        move    a1,r3
        nop
        movem   p:(r3),a
        move    a1,n1
        move    #rt5_operator_gain_base_out,r1
        nop
        move    y0,x:(r1+n1)
        move    #rt5_operator_gain_base_mod,r1
        nop
        move    x1,x:(r1+n1)
        ; the live pairs start AM-free; the next block's AM pass rescales
        ; any AM-active channel from the base pairs
        move    #rt5_operator_gain_out,r1
        nop
        move    y0,x:(r1+n1)
        move    #rt5_operator_gain_mod,r1
        nop
        move    x1,x:(r1+n1)
        rts
rt5_env_gain_silent:
        clr     b
        move    b1,y0
        move    #>0,x1
        jmp     rt5_env_gain_store

; Boundary transitions call the island's rate decode with the operator
; published in the helper mailbox.
rt5_env_transition_reload:
        move    n2,b
        move    b1,x:rt5_env_current
        jmp     rt5_env_reload_op

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

        move    #>DSP_CMD_PROFILE_RT3,x0
        cmp     x0,a
        jeq     command_profile_realtime3

        move    #>DSP_CMD_PROFILE_RT4,x0
        cmp     x0,a
        jeq     command_profile_realtime4

        move    #>DSP_CMD_PROFILE_RT5,x0
        cmp     x0,a
        jeq     command_profile_realtime5

        move    #>DSP_CMD_START_RT_MIXED,x0
        cmp     x0,a
        jeq     command_start_realtime_mixed

        move    #>DSP_CMD_START_MIXED,x0
        cmp     x0,a
        jeq     command_start_mixed

        move    #>DSP_CMD_QUERY_MIX,x0
        cmp     x0,a
        jeq     command_query_mix

        move    #>DSP_REPLY_ERROR,a
        jsr     send_reply
        jmp     command_loop

; Runtime initialization keeps this persistent table out of the .LOD image
; while making the exact renderer's logical-to-raw operator mapping a single
; fetch.
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
        ; TOS's Dsp_BlkUnpacked polls TXDE only before its first word, so the
        ; host must not start a multi-word block until this handler is parked
        ; in its receive loop; the READY token provides that guarantee.
        move    #>DSP_REPLY_BLOCK_READY,a
        jsr     send_reply
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

        ; Use the same on-chip 256-step sine ROM selected by the block spikes.
        ; The exact-renderer cache at Y:$0100 is rebuilt after restoring the
        ; external map, outside the measured profile bracket.
        ori     #$04,omr
        nop
        move    #>$100,r0
        move    #>$100,r1
        move    #>$100,r2
        move    #>$100,r3
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
        andi    #$fb,omr
        nop
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
        jsr     ym_rebuild_phase_cache
        move    x:rt_profile_checksum,a
        jsr     send_reply
        jmp     command_loop

; Profile one block-oriented, algorithm-0-shaped codec-rate channel: a
; serial M1(feedback)->C1->M2->C2 chain with per-frame feedback and
; modulation, block-held gains, and interleaved stereo output. Each operator
; processes one 64-frame block so its phase stays in an accumulator while the
; modulator ring is consumed in place by the next stage. This adds the work
; the four-carrier lower bound deliberately omitted. SSI must be stopped: both
; audio buffers are reused as the 2048-frame stereo output block, and the
; reply is its checksum.
command_profile_realtime2:
        jsr     rt2_initialize_common

        move    #rt2_gain,r4
        ; Modulator gains are stored in table-index units so their 48-bit
        ; products can feed the following operator without another phase-
        ; extraction multiply. The carrier retains signed fractional gain.
        ; Store O1 at its already-divided feedback/modulation depth. This is
        ; the representation used by commands $15/$16: both history words are
        ; already scaled, so the hot feedback stage needs no three-bit shift.
        move    #>$000010,x0           ; (0.5 * 256) / 8 table-index depth
        move    x0,x:(r4)+
        move    #>$000060,x0           ; 0.375 * 256
        move    x0,x:(r4)+
        move    #>$000040,x0           ; 0.25 * 256
        move    x0,x:(r4)+
        move    #>$100000,x0           ; 0.125
        move    x0,x:(r4)+

rt2_profile_loop_start:
        do      #DSP_RT2_PROFILE_BLOCKS,rt2_blocks_done

        ; Operator 1: self-feedback, fills the modulator ring. Feedback lives
        ; in opposite X/Y banks, so both history words load together and the
        ; new output is stored to the history and ring in one dual move.
        move    #rt2_stage_ring,r3
        move    #rt2_fb_1,r2
        move    #rt2_fb_0_y,r4
        move    l:rt2_phase,b10

        ; Modulator depth is quantized to the sine-ROM step and held for this
        ; 64-frame operator block. The carrier uses the same block-held model;
        ; envelope evolution remains outside this synthesis-only spike.
        move    x:rt2_gain,y0
rt2_op1_loop_start:

        do      #DSP_RT2_BLOCK_FRAMES,rt2_op1_done
        move    x:(r2),x0 y:(r4),a
        add     x0,a a1,x:(r2)         ; scaled (out[-1]+out[-2]) feedback
        add     b,a
        and     y1,a1
        move    a1,n6
        mac     x1,y1,b               ; also spaces the N6 indexed-address use
        move    y:(r6+n6),x0
        mpy     x0,y0,a
        move    a,x:(r3)+ a,y:(r4)
rt2_op1_done:
        move    b10,l:rt2_phase

        ; Operator 2: prefetch the next modulator beside the current MPY, then
        ; store the result while moving that prefetched value into A.
        move    #rt2_stage_ring,r3
        move    #rt2_stage_ring,r5
        move    l:rt2_phase+1,b10

        move    x:rt2_gain+1,y0
rt2_op2_loop_start:

        move    x:(r3)+,a
        do      #DSP_RT2_BLOCK_FRAMES,rt2_op2_done
        add     b,a
        and     y1,a1
        move    a1,n6
        mac     x1,y1,b               ; also spaces the N6 indexed-address use
        move    y:(r6+n6),x0
        mpy     x0,y0,a x:(r3)+,x0
        move    a,x:(r5)+ x0,a
rt2_op2_done:
        move    b10,l:rt2_phase+1

        ; Operator 3: same stage shape as operator 2.
        move    #rt2_stage_ring,r3
        move    #rt2_stage_ring,r5
        move    l:rt2_phase+2,b10

        move    x:rt2_gain+2,y0
rt2_op3_loop_start:

        move    x:(r3)+,a
        do      #DSP_RT2_BLOCK_FRAMES,rt2_op3_done
        add     b,a
        and     y1,a1
        move    a1,n6
        mac     x1,y1,b               ; also spaces the N6 indexed-address use
        move    y:(r6+n6),x0
        mpy     x0,y0,a x:(r3)+,x0
        move    a,x:(r5)+ x0,a
rt2_op3_done:
        move    b10,l:rt2_phase+2

        ; Operator 4: the carrier writes interleaved stereo, right at a
        ; fixed half-amplitude pan.
        move    #rt2_stage_ring,r3
        move    l:rt2_phase+3,b10

        move    x:rt2_gain+3,y0
rt2_op4_loop_start:

        move    x:(r3)+,a
        do      #DSP_RT2_BLOCK_FRAMES,rt2_op4_done
        add     b,a
        and     y1,a1
        move    a1,n6
        mac     x1,y1,b               ; also spaces the N6 indexed-address use
        move    y:(r6+n6),x0
        mpy     x0,y0,a x:(r3)+,x0
        asr     a a1,x:(r1)+           ; left, then half-amplitude right
        move    a,x:(r1)+ x0,a
rt2_op4_done:
        move    b10,l:rt2_phase+3
rt2_blocks_done:
        nop

        jsr     rt2_correct_phase
rt2_profile_loop_done:
        jsr     rt2_restore_common
        jsr     rt2_checksum_output
        jsr     send_reply
        jmp     command_loop

; Profile an algorithm-7-shaped channel. Operator 1 retains per-frame
; feedback, but all four operators are carriers accumulated through the same
; internal ring. The carrier-only stages mask the phase accumulator directly,
; avoiding the modulator add/copy required by the serial algorithm-0 path.
command_profile_realtime3:
        jsr     rt2_initialize_common

        move    #rt2_gain,r4
        ; Operator 1 stores feedback pre-scaled by 1/8, removing three shifts
        ; from the hot loop while preserving command $14's feedback depth. Its
        ; carrier is the ROM sample shifted to 0.5 separately. The remaining
        ; carriers keep the worst-case aligned sum below full scale.
        move    #>$000010,x0           ; pre-scaled feedback depth
        move    x0,x:(r4)+
        move    #>$200000,x0           ; 0.25 carrier
        move    x0,x:(r4)+
        move    #>$100000,x0           ; 0.125 carrier
        move    x0,x:(r4)+
        move    #>$080000,x0           ; 0.0625 carrier
        move    x0,x:(r4)+

rt3_profile_loop_start:
        do      #DSP_RT2_PROFILE_BLOCKS,rt3_blocks_done

        ; Operator 1: feed back a table-index-scaled product while placing a
        ; half-amplitude carrier in the accumulation ring.
        move    #rt2_stage_ring,r3
        move    #rt2_fb_1,r2
        move    #rt2_fb_0_y,r4
        move    l:rt2_phase,b10
        move    x:rt2_gain,y0
rt3_op1_loop_start:
        do      #DSP_RT2_BLOCK_FRAMES,rt3_op1_done
        move    x:(r2),x0 y:(r4),a
        add     x0,a a1,x:(r2)         ; histories are already feedback-scaled
        add     b,a
        and     y1,a1
        move    a1,n6
        mac     x1,y1,b               ; also spaces the N6 indexed-address use
        move    y:(r6+n6),x0
        mpy     x0,y0,a
        move    a,y:(r4)
        move    x0,a
        asr     a
        move    a,x:(r3)+
rt3_op1_done:
        move    b10,l:rt2_phase

        ; Operators 2 and 3 are carrier-only accumulation stages. With no
        ; incoming modulation, masking B in place removes the temporary phase
        ; add used by the serial stages.
        move    #rt2_stage_ring,r3
        move    #rt2_stage_ring,r5
        move    l:rt2_phase+1,b10
        move    x:rt2_gain+1,y0
rt3_op2_loop_start:
        do      #DSP_RT2_BLOCK_FRAMES,rt3_op2_done
        and     y1,b1 x:(r3)+,a
        move    b1,n6
        mac     x1,y1,b               ; also spaces the N6 indexed-address use
        move    y:(r6+n6),x0
        mac     x0,y0,a
        move    a,x:(r5)+
rt3_op2_done:
        move    b10,l:rt2_phase+1

        move    #rt2_stage_ring,r3
        move    #rt2_stage_ring,r5
        move    l:rt2_phase+2,b10
        move    x:rt2_gain+2,y0
rt3_op3_loop_start:
        do      #DSP_RT2_BLOCK_FRAMES,rt3_op3_done
        and     y1,b1 x:(r3)+,a
        move    b1,n6
        mac     x1,y1,b               ; also spaces the N6 indexed-address use
        move    y:(r6+n6),x0
        mac     x0,y0,a
        move    a,x:(r5)+
rt3_op3_done:
        move    b10,l:rt2_phase+2

        ; Operator 4 adds the last carrier and emits interleaved stereo.
        move    #rt2_stage_ring,r3
        move    l:rt2_phase+3,b10
        move    x:rt2_gain+3,y0
rt3_op4_loop_start:
        do      #DSP_RT2_BLOCK_FRAMES,rt3_op4_done
        and     y1,b1 x:(r3)+,a
        move    b1,n6
        mac     x1,y1,b               ; also spaces the N6 indexed-address use
        move    y:(r6+n6),x0
        mac     x0,y0,a
        asr     a a1,x:(r1)+           ; left, then half-amplitude right
        move    a,x:(r1)+
rt3_op4_done:
        move    b10,l:rt2_phase+3
rt3_blocks_done:
        nop

        jsr     rt2_correct_phase
rt3_profile_loop_done:
        jsr     rt2_restore_common
        jsr     rt2_checksum_output
        jsr     send_reply
        jmp     command_loop

; Profile the six mixed serial/parallel YM2151 algorithms. The low byte of
; command $16 selects algorithm 1-6. Each topology has its own outer-loop
; label for cycle capture, but the operator-stage kernels are shared so the
; profile includes their call overhead without duplicating the same 64-frame
; loop bodies in scarce P memory.
command_profile_realtime4:
        move    x1,a
        move    #>$ff,y0
        and     y0,a1
        move    a1,x:rt4_algorithm
        move    #>1,x0
        cmp     x0,a
        jlt     command_profile_realtime4_error
        move    #>6,x0
        cmp     x0,a
        jgt     command_profile_realtime4_error

        jsr     rt2_initialize_common
        move    #>63,m2
        move    #rt2_gain,r4
        ; O1 is stored at the feedback-scaled 1/8 depth used by command $15.
        ; This preserves feedback strength without three shifts in every hot
        ; frame and still supplies non-zero table-index modulation downstream.
        move    #>$000010,x0
        move    x0,x:(r4)+
        move    #>$000060,x0           ; O2 modulation depth
        move    x0,x:(r4)+
        move    #>$000040,x0           ; O3 modulation depth
        move    x0,x:(r4)+
        move    #>$000020,x0           ; retained O4 modulation slot
        move    x0,x:(r4)+
        move    #rt4_carrier_gain,r4
        move    #>$100000,x0           ; 0.125 per carrier
        do      #4,rt4_initialize_carrier_gains
        move    x0,x:(r4)+
rt4_initialize_carrier_gains:

        move    x:rt4_algorithm,a
        move    #>1,x0
        cmp     x0,a
        jeq     rt4_algorithm1_profile
        move    #>2,x0
        cmp     x0,a
        jeq     rt4_algorithm2_profile
        move    #>3,x0
        cmp     x0,a
        jeq     rt4_algorithm3_profile
        move    #>4,x0
        cmp     x0,a
        jeq     rt4_algorithm4_profile
        move    #>5,x0
        cmp     x0,a
        jeq     rt4_algorithm5_profile
        jmp     rt4_algorithm6_profile

; Algorithm 1: (O1 + O2) -> O3 -> O4.
rt4_algorithm1_profile:
rt4_algorithm1_loop_start:
        do      #DSP_RT2_PROFILE_BLOCKS,rt4_algorithm1_blocks_done
        jsr     rt4_feedback_write_x
        move    #rt2_phase+1,r0
        move    x:rt2_gain+1,y0
        jsr     rt4_independent_add_x
        move    #rt2_phase+2,r0
        move    x:rt2_gain+2,y0
        jsr     rt4_serial_transform_x
        move    #rt2_phase+3,r0
        move    x:rt4_carrier_gain+3,y0
        jsr     rt4_serial_emit_x
rt4_algorithm1_blocks_done:
        nop
        jmp     rt4_profile_complete

; Algorithm 2: (O1 + (O2 -> O3)) -> O4. Reordering the independent O2/O3
; branch ahead of O1 is state-equivalent and lets O1 add into the one X ring.
rt4_algorithm2_profile:
rt4_algorithm2_loop_start:
        do      #DSP_RT2_PROFILE_BLOCKS,rt4_algorithm2_blocks_done
        move    #rt2_phase+1,r0
        move    x:rt2_gain+1,y0
        jsr     rt4_independent_write_x
        move    #rt2_phase+2,r0
        move    x:rt2_gain+2,y0
        jsr     rt4_serial_transform_x
        jsr     rt4_feedback_add_x
        move    #rt2_phase+3,r0
        move    x:rt4_carrier_gain+3,y0
        jsr     rt4_serial_emit_x
rt4_algorithm2_blocks_done:
        nop
        jmp     rt4_profile_complete

; Algorithm 3: ((O1 -> O2) + O3) -> O4.
rt4_algorithm3_profile:
rt4_algorithm3_loop_start:
        do      #DSP_RT2_PROFILE_BLOCKS,rt4_algorithm3_blocks_done
        jsr     rt4_feedback_write_x
        move    #rt2_phase+1,r0
        move    x:rt2_gain+1,y0
        jsr     rt4_serial_transform_x
        move    #rt2_phase+2,r0
        move    x:rt2_gain+2,y0
        jsr     rt4_independent_add_x
        move    #rt2_phase+3,r0
        move    x:rt4_carrier_gain+3,y0
        jsr     rt4_serial_emit_x
rt4_algorithm3_blocks_done:
        nop
        jmp     rt4_profile_complete

; Algorithm 4: (O1 -> O2) + (O3 -> O4). Reusable modulation lives in Y while
; the first branch's carrier accumulation remains in X.
rt4_algorithm4_profile:
rt4_algorithm4_loop_start:
        do      #DSP_RT2_PROFILE_BLOCKS,rt4_algorithm4_blocks_done
        jsr     rt4_feedback_write_y
        move    #rt2_phase+1,r0
        move    x:rt4_carrier_gain+1,y0
        jsr     rt4_serial_y_write_x
        move    #rt2_phase+2,r0
        move    x:rt2_gain+2,y0
        jsr     rt4_independent_write_y
        move    #rt2_phase+3,r0
        move    x:rt4_carrier_gain+3,y0
        jsr     rt4_serial_y_add_x_emit
rt4_algorithm4_blocks_done:
        nop
        jmp     rt4_profile_complete

; Algorithm 5: O1 modulates O2, O3, and O4 in parallel. The Y modulation ring
; remains intact while the three carriers accumulate through internal X.
rt4_algorithm5_profile:
rt4_algorithm5_loop_start:
        do      #DSP_RT2_PROFILE_BLOCKS,rt4_algorithm5_blocks_done
        jsr     rt4_feedback_write_y
        move    #rt2_phase+1,r0
        move    x:rt4_carrier_gain+1,y0
        jsr     rt4_serial_y_write_x
        move    #rt2_phase+2,r0
        move    x:rt4_carrier_gain+2,y0
        jsr     rt4_serial_y_add_x
        move    #rt2_phase+3,r0
        move    x:rt4_carrier_gain+3,y0
        jsr     rt4_serial_y_add_x_emit
rt4_algorithm5_blocks_done:
        nop
        jmp     rt4_profile_complete

; Algorithm 6: (O1 -> O2) + O3 + O4. O2 starts the X carrier accumulation;
; the independent O3/O4 carrier stages use the command-$15 MAC shape.
rt4_algorithm6_profile:
rt4_algorithm6_loop_start:
        do      #DSP_RT2_PROFILE_BLOCKS,rt4_algorithm6_blocks_done
        jsr     rt4_feedback_write_x
        move    #rt2_phase+1,r0
        move    x:rt4_carrier_gain+1,y0
        jsr     rt4_serial_transform_x
        move    #rt2_phase+2,r0
        move    x:rt4_carrier_gain+2,y0
        jsr     rt4_independent_add_x
        move    #rt2_phase+3,r0
        move    x:rt4_carrier_gain+3,y0
        jsr     rt4_independent_add_x_emit
rt4_algorithm6_blocks_done:
        nop

rt4_profile_complete:
        jsr     rt2_correct_phase
rt4_profile_loop_done:
        jsr     rt2_restore_common
        jsr     rt2_checksum_output
        jsr     send_reply
        jmp     command_loop

command_profile_realtime4_error:
        move    #>DSP_REPLY_ERROR,a
        jsr     send_reply
        jmp     command_loop

; O1 feedback stage used by algorithms 1 and 3-6. Command $16 stores the
; already-divided feedback/modulation value, so the hot loop needs no shifts.
rt4_feedback_write_x:
        move    #rt2_stage_ring,r3
        move    #rt2_fb_1,r2
        move    #rt2_fb_0_y,r4
        move    l:rt2_phase,b10
        move    x:rt2_gain,y0
        do      #DSP_RT2_BLOCK_FRAMES,rt4_feedback_write_x_done
        move    x:(r2),x0 y:(r4),a
        add     x0,a a1,x:(r2)
        add     b,a
        and     y1,a1
        move    a1,n6
        mac     x1,y1,b
        move    y:(r6+n6),x0
        mpy     x0,y0,a
        move    a,x:(r3)+ a,y:(r4)
rt4_feedback_write_x_done:
        move    b10,l:rt2_phase
        rts

; Algorithm 2 computes its independent O2/O3 branch first, then adds O1's
; feedback-scaled modulation into the existing X ring.
rt4_feedback_add_x:
        move    #rt2_stage_ring,r3
        move    #rt2_fb_1,r2
        move    #rt2_fb_0_y,r4
        move    l:rt2_phase,b10
        move    x:rt2_gain,y0
        do      #DSP_RT2_BLOCK_FRAMES,rt4_feedback_add_x_done
        move    x:(r2),x0 y:(r4),a
        add     x0,a a1,x:(r2)
        add     b,a
        and     y1,a1
        move    a1,n6
        mac     x1,y1,b
        move    y:(r6+n6),x0
        mpy     x0,y0,a x:(r3),x0
        add     x0,a a1,y:(r4)
        move    a,x:(r3)+
rt4_feedback_add_x_done:
        move    b10,l:rt2_phase
        rts

; Dual-branch algorithms keep O1's reusable modulation ring in Y and their
; carrier accumulator in X. The separate Y stores cost one instruction here,
; but later stages can fetch the X accumulation beside the Y sine-ROM lookup.
rt4_feedback_write_y:
        move    #rt4_branch_ring,r7
        move    #rt2_fb_1,r2
        move    #rt2_fb_0_y,r4
        move    l:rt2_phase,b10
        move    x:rt2_gain,y0
        do      #DSP_RT2_BLOCK_FRAMES,rt4_feedback_write_y_done
        move    x:(r2),x0 y:(r4),a
        add     x0,a a1,x:(r2)
        add     b,a
        and     y1,a1
        move    a1,n6
        mac     x1,y1,b
        move    y:(r6+n6),x0
        mpy     x0,y0,a
        move    a,y:(r4)
        move    a,y:(r7)+
rt4_feedback_write_y_done:
        move    b10,l:rt2_phase
        rts

; An operator with no modulation input either starts or adds to the X ring.
; Passing a table-index gain makes it a modulator; a fractional gain makes it
; a carrier, so the same stage serves several algorithm positions.
rt4_independent_write_x:
        move    #rt2_stage_ring,r3
        move    l:(r0),b10
        do      #DSP_RT2_BLOCK_FRAMES,rt4_independent_write_x_done
        and     y1,b1
        move    b1,n6
        mac     x1,y1,b
        move    y:(r6+n6),x0
        mpy     x0,y0,a
        move    a,x:(r3)+
rt4_independent_write_x_done:
        move    b10,l:(r0)
        rts

rt4_independent_write_y:
        move    #rt4_branch_ring,r7
        move    l:(r0),b10
        do      #DSP_RT2_BLOCK_FRAMES,rt4_independent_write_y_done
        and     y1,b1
        move    b1,n6
        mac     x1,y1,b
        move    y:(r6+n6),x0
        mpy     x0,y0,a
        move    a,y:(r7)+
rt4_independent_write_y_done:
        move    b10,l:(r0)
        rts

rt4_independent_add_x:
        move    #rt2_stage_ring,r3
        move    #rt2_stage_ring,r5
        move    l:(r0),b10
        do      #DSP_RT2_BLOCK_FRAMES,rt4_independent_add_x_done
        and     y1,b1 x:(r3)+,a
        move    b1,n6
        mac     x1,y1,b
        move    y:(r6+n6),x0
        mac     x0,y0,a
        move    a,x:(r5)+
rt4_independent_add_x_done:
        move    b10,l:(r0)
        rts

; Consume and replace the X ring with a modulated operator output.
rt4_serial_transform_x:
        move    #rt2_stage_ring,r3
        move    #rt2_stage_ring,r5
        move    l:(r0),b10
        move    x:(r3)+,a
        do      #DSP_RT2_BLOCK_FRAMES,rt4_serial_transform_x_done
        add     b,a
        and     y1,a1
        move    a1,n6
        mac     x1,y1,b
        move    y:(r6+n6),x0
        mpy     x0,y0,a x:(r3)+,x0
        move    a,x:(r5)+ x0,a
rt4_serial_transform_x_done:
        move    b10,l:(r0)
        rts

; Consume the X modulation ring and emit one interleaved stereo carrier.
rt4_serial_emit_x:
        move    #rt2_stage_ring,r3
        move    l:(r0),b10
        move    x:(r3)+,a
        do      #DSP_RT2_BLOCK_FRAMES,rt4_serial_emit_x_done
        add     b,a
        and     y1,a1
        move    a1,n6
        mac     x1,y1,b
        move    y:(r6+n6),x0
        mpy     x0,y0,a x:(r3)+,x0
        asr     a a1,x:(r1)+
        move    a,x:(r1)+ x0,a
rt4_serial_emit_x_done:
        move    b10,l:(r0)
        rts

; Preserve the Y modulation ring while writing or accumulating carriers in
; X. Once the modulated phase has selected the ROM entry, its phase MAC can
; preload the X accumulation before the indexed Y sine read.
rt4_serial_y_write_x:
        move    #rt2_stage_ring,r3
        move    #rt4_branch_ring,r7
        move    l:(r0),b10
        move    y:(r7)+,a
        do      #DSP_RT2_BLOCK_FRAMES,rt4_serial_y_write_x_done
        add     b,a
        and     y1,a1
        move    a1,n6
        mac     x1,y1,b
        move    y:(r6+n6),x0
        mpy     x0,y0,a
        move    a,x:(r3)+ y:(r7)+,a
rt4_serial_y_write_x_done:
        move    b10,l:(r0)
        rts

rt4_serial_y_add_x:
        move    #rt2_stage_ring,r3
        move    #rt2_stage_ring,r2
        move    #rt4_branch_ring,r7
        move    l:(r0),b10
        move    y:(r7)+,a
        do      #DSP_RT2_BLOCK_FRAMES,rt4_serial_y_add_x_done
        add     b,a
        and     y1,a1
        move    a1,n6
        mac     x1,y1,b x:(r3)+,a
        move    y:(r6+n6),x0
        mac     x0,y0,a
        move    a,x:(r2)+ y:(r7)+,a
rt4_serial_y_add_x_done:
        move    b10,l:(r0)
        rts

rt4_serial_y_add_x_emit:
        move    #rt2_stage_ring,r3
        move    #rt4_branch_ring,r7
        move    l:(r0),b10
        move    y:(r7)+,a
        do      #DSP_RT2_BLOCK_FRAMES,rt4_serial_y_add_x_emit_done
        add     b,a
        and     y1,a1
        move    a1,n6
        mac     x1,y1,b x:(r3)+,a
        move    y:(r6+n6),x0
        mac     x0,y0,a
        asr     a a1,x:(r1)+
        move    a,x:(r1)+ y:(r7)+,a
rt4_serial_y_add_x_emit_done:
        move    b10,l:(r0)
        rts

; Add an unmodulated carrier to X and emit the completed accumulation.
rt4_independent_add_x_emit:
        move    #rt2_stage_ring,r3
        move    l:(r0),b10
        do      #DSP_RT2_BLOCK_FRAMES,rt4_independent_add_x_emit_done
        and     y1,b1 x:(r3)+,a
        move    b1,n6
        mac     x1,y1,b
        move    y:(r6+n6),x0
        mac     x0,y0,a
        asr     a a1,x:(r1)+
        move    a,x:(r1)+
rt4_independent_add_x_emit_done:
        move    b10,l:(r0)
        rts

; Derive the exact 64-step noise-LFSR jump tables from the x^17+x^14+1 step
; function. Each of the 17 state bits is advanced 64 steps to its jump
; column, then each slice table is filled by the standard doubling rule
; table[2^k + v] = column[k] ^ table[v]. This runs once per command outside
; the measured bracket and keeps every table word out of the bounded
; P-memory image.
rt5_generate_noise_tables:
        move    #rt5_noise_columns,r1
        move    #>1,b
        do      #17,rt5_noise_columns_done
        move    b,a
        do      #64,rt5_noise_column_stepped
        lsr     a
        jcc     rt5_noise_column_step_clear
        move    #>$012000,x0
        eor     x0,a
rt5_noise_column_step_clear:
        nop
rt5_noise_column_stepped:
        move    a1,y:(r1)+
        asl     b
rt5_noise_columns_done:
        move    #rt5_noise_columns,r2
        move    #rt5_noise_jump_low6,r0
        move    #>6,x1
        jsr     rt5_noise_fill_slice
        move    #rt5_noise_jump_mid6,r0
        move    #>6,x1
        jsr     rt5_noise_fill_slice
        move    #rt5_noise_jump_high5,r0
        move    #>5,x1

; Fill one slice table: r0 is the table base, r2 walks the shared column
; cursor, and x1 is the slice width in bits. Falls through from the third
; setup above and returns to the caller of rt5_generate_noise_tables.
rt5_noise_fill_slice:
        clr     a
        move    a1,x:(r0)
        move    #>1,b
        do      x1,rt5_noise_slice_done
        move    y:(r2)+,x0
        move    r0,r1
        move    r0,a
        add     b,a
        move    a1,r3
        do      b1,rt5_noise_block_copied
        move    x:(r1)+,a
        eor     x0,a
        move    a1,x:(r3)+
rt5_noise_block_copied:
        asl     b
rt5_noise_slice_done:
        rts

; Profile the integrated all-topology block engine with complete decoded
; register control. Unlike commands $14-$16, this command keeps the real SSI
; fast interrupt active and reserves r6/m6 exclusively for its looping
; transmit buffer. It executes one channel of each algorithm per 64-frame
; block, routes a fixture covering mutable algorithm and both/left/right/mute
; pan into grouped carrier rings, mixes a deterministic host-style PDX block
; with saturating 24-bit output moves, and advances the decoded envelope,
; LFO, noise, timer, and event-queue state. The scaled block-held PM offset
; and AM gain selection reach every operator stage through per-operator
; decoded phase increments and gains. The event fixture spans every decoded
; register class: channel control, total level, KC/KF pitch rebuilds from
; the exact phase-step table, key on/off, all four envelope-rate groups,
; LFO rate/depth/waveform, and both timer reloads plus timer control.
command_profile_realtime5:
        clr     b
        move    #rt5_phase,r4
        do      #32,rt5_clear_phase_done
        move    b10,l:(r4)+
rt5_clear_phase_done:
        clr     a
        move    #rt5_feedback_1,r2
        move    #rt5_feedback_0,r4
        do      #8,rt5_clear_feedback_done
        move    a1,x:(r2)+
        move    a1,y:(r4)+
rt5_clear_feedback_done:
        ; Deterministic static attenuation spread: operator i starts at 8*i
        ; units in the 10.13 level fixed point, so every initial gain is a
        ; distinct decoded envelope product.
        move    #rt5_envelope_level,r1
        move    #>$010000,y0
        do      #32,rt5_initialize_levels_done
        move    a1,x:(r1)+
        add     y0,a
rt5_initialize_levels_done:
        clr     a
        move    a1,x:rt5_native_phase
        move    a1,x:rt5_lfo_phase
        move    a1,x:rt5_event_clock
        move    a1,x:rt5_event_read
        move    a1,x:rt5_lfo_amd
        move    a1,x:rt5_lfo_waveform
        move    a1,x:rt5_timer_status
        move    #>32,a
        move    a1,x:rt5_event_count
        move    #>$013579,a
        move    a1,x:rt5_noise_lfsr
        clr     a
        move    a1,x:rt5_noise_threshold
        move    a1,x:rt5_noise_counter
        move    a1,x:rt5_noise_state_snap
        move    a1,x:rt5_noise_gain
        move    #>1024,a
        move    a1,x:rt5_timer_counter
        move    a1,x:rt5_timer_a_reload
        move    #>$380,a
        move    a1,x:rt5_timer_b_reload
        move    a1,x:rt5_timer_b_counter
        move    #>3,a
        move    a1,x:rt5_timer_control
        clr     a
        move    a1,y:rt5_lfo_acc_hi
        move    a1,y:rt5_lfo_acc_lo
        move    a1,x:rt5_am_engaged
        move    #rt5_ams_previous,r0
        do      #8,rt5_profile_ams_previous_done
        move    a1,x:(r0)+
rt5_profile_ams_previous_done:
        ; rate byte $01 decodes to the old fixture's per-tick step 17 with
        ; both scaled step pairs derived by the shared handler
        move    #>$01,y1
        jsr     rt5_lfo_rate_decode
        move    #>$400000,a             ; $19 depth $40 is unity after MPY+ASL
        move    a1,x:rt5_pm_scale

        ; Envelope bookkeeping: unity multipliers, zero addends, and an
        ; empty active list. Operators of channels 0-3 wait released for
        ; their fixture key edges; channels 4-7 hold keyed static sustain so
        ; half the mix is audible from the first block.
        move    #0,r4
        move    #>$7fffff,a
        do      #32,rt5_initialize_env_a_done
        move    a1,y:(r4)+
rt5_initialize_env_a_done:
        clr     a
        move    #rt5_env_b,r4
        do      #32,rt5_initialize_env_b_done
        move    a1,y:(r4)+
rt5_initialize_env_b_done:
        move    a1,x:rt5_active_count
        move    #rt5_env_state,r1
        clr     b
        move    #>1,x0
        move    #>4,y0
        move    #>7,x1
        do      #32,rt5_initialize_env_state_done
        move    b1,a
        and     x1,a
        cmp     y0,a
        jge     rt5_env_state_keyed
        move    #>$04,a                 ; released stasis
        jmp     rt5_env_state_store
rt5_env_state_keyed:
        move    #>$13,a                 ; keyed static sustain
rt5_env_state_store:
        move    a1,x:(r1)+
        add     x0,b
rt5_initialize_env_state_done:

        ; Deterministic decoded-rate register rows: KC/KF pitch context for
        ; the KSR path and all four envelope-rate groups, so fixture key
        ; edges attack and decay through reproducible effective rates.
        move    #ym_regdata+$28,r1
        move    #>$4a,a
        do      #8,rt5_initialize_kc_done
        move    a1,x:(r1)+
        add     x0,a
rt5_initialize_kc_done:
        clr     a
        move    #ym_regdata+$30,r1
        do      #8,rt5_initialize_kf_done
        move    a1,x:(r1)+
rt5_initialize_kf_done:
        move    #ym_regdata+$80,r1
        clr     b
        move    #>$14,y0
        do      #32,rt5_initialize_ar_done
        move    b1,a
        and     x1,a
        add     y0,a
        move    a1,x:(r1)+
        add     x0,b
rt5_initialize_ar_done:
        move    #ym_regdata+$a0,r1
        clr     b
        move    #>$18,y0
        move    #>3,x1
        do      #32,rt5_initialize_d1r_done
        move    b1,a
        and     x1,a
        add     y0,a
        move    a1,x:(r1)+
        add     x0,b
rt5_initialize_d1r_done:
        ; D2R: one keyed operator keeps a perpetual slow sustained decay as
        ; steady-state envelope evidence; every other operator freezes at
        ; its sustain level and retires from the active list.
        move    #ym_regdata+$c0,r1
        move    #ym_regdata+$e0,r2
        clr     b
        move    #>8,y0
        do      #32,rt5_initialize_d2r_done
        move    b1,a
        cmp     y0,a
        jeq     rt5_env_d2r_slow
        clr     a
        jmp     rt5_env_d2r_store
rt5_env_d2r_slow:
        move    #>$04,a
rt5_env_d2r_store:
        move    a1,x:(r1)+
        move    #>$4f,a                 ; D1L 4 with a fast, capping release
        move    a1,x:(r2)+
        add     x0,b
rt5_initialize_d2r_done:

        ; Distinct per-operator base increments replace the former shared
        ; $9330 constant; KC/KF events rebuild four entries at a time. The
        ; final cleared word is the pipelined support-loop prefetch guard.
        move    #rt5_increment_base,r2
        move    #>$9330,a
        move    #>$10,y0
        do      #32,rt5_initialize_increment_bases_done
        move    a1,x:(r2)+
        add     y0,a
rt5_initialize_increment_bases_done:

        ; Doubled per-operator multipliers 1-8 for the pitch rebuild, in the
        ; operator-major order of the decoded pitch arrays. The channel-plus-
        ; operator pattern keeps all four multipliers of a channel distinct.
        ; The support loop's 33rd guard prefetch reads whatever follows the
        ; bases and discards it, so the guard word needs no initialization.
        move    #rt5_operator_mul,r2
        clr     a
        move    #>7,y0
        move    #>1,x0
        do      #32,rt5_initialize_mul_done
        move    a1,b
        rep     #3
        lsr     b
        add     a,b
        and     y0,b
        add     x0,b
        move    b1,x:(r2)+
        add     x0,a
rt5_initialize_mul_done:

        ; Derive the noise jump tables before the measured bracket.
        jsr     rt5_generate_noise_tables

        ; Initialize the eight decoded channel-control registers from the
        ; fixture table: algorithms 0-7 begin one per channel while the pan
        ; fixture covers all four hardware modes. The fixtured KF channels
        ; receive their KC events before any KF event, so no register-mirror
        ; seeding is needed.
        move    #rt5_channel_control_fixture,r3
        move    #rt5_channel_control,r0
        move    #ym_regdata+$20,r1
        do      #8,rt5_initialize_channel_controls_done
        movem   p:(r3)+,a
        move    a1,x:(r0)+
        move    a1,x:(r1)+
rt5_initialize_channel_controls_done:

        ; Schedule one ordered write at each of the first 25 block boundaries,
        ; then cluster the final eight at boundary 24 as one burst. The first
        ; seven rewrite channel algorithm and pan while retaining one instance
        ; of every topology; the remaining 24 cover every decoded register
        ; class: total level, key code, key fraction, key on/off, all four
        ; envelope rate groups, LFO rate/depth/waveform, and both timers. The
        ; burst proves multi-event boundary drain, and blocks 25-31 prove the
        ; empty-boundary fast path.
        clr     a
        move    #rt5_event_times,r0
        move    #>64,y0
        move    #>1536,x0               ; boundary 24: burst timestamp clamp
        do      #32,rt5_initialize_events_done
        move    a1,x:(r0)+
        add     y0,a
        cmp     x0,a
        jle     rt5_event_time_clamped
        move    x0,a
rt5_event_time_clamped:
        nop
rt5_initialize_events_done:
        ; the final ordered write is a late channel-0 key-off: the sustained
        ; decayer releases at boundary 90 and retires through the fast RR
        move    #>5760,a
        move    a1,x:rt5_event_times+31
        move    #rt5_event_fixture,r3
        move    #rt5_event_commands,r1
        do      #32,rt5_initialize_event_commands_done
        movem   p:(r3)+,a
        move    a1,x:(r1)+
rt5_initialize_event_commands_done:

        ; Operator total-level amplitude bases in operator-major order, in
        ; the ymfm-relative 0.23 convention whose full volume is 2^21 (an
        ; operator peaks at 1/4 of the signed output range, like ymfm's
        ; 8191 of 16 bits).
        move    #rt5_tl_base,r1
        move    #>$080000,a
        do      #8,rt5_initialize_tl_m1_done
        move    a1,x:(r1)+
rt5_initialize_tl_m1_done:
        move    #>$180000,a
        do      #8,rt5_initialize_tl_c1_done
        move    a1,x:(r1)+
rt5_initialize_tl_c1_done:
        move    #>$100000,a
        do      #8,rt5_initialize_tl_m2_done
        move    a1,x:(r1)+
rt5_initialize_tl_m2_done:
        move    #>$1e0000,a
        do      #8,rt5_initialize_tl_c2_done
        move    a1,x:(r1)+
rt5_initialize_tl_c2_done:

        ; Derive every operator's initial channel-major gain pair through the
        ; island helper, so static levels attenuate their bases exactly the
        ; way decoded envelope motion will during the profile.
        clr     a
        do      #32,rt5_initialize_gains_done
        move    a1,x:rt5_env_current
        move    a1,n1
        jsr     rt5_env_gain_op
        move    x:rt5_env_current,a
        move    #>1,x0
        add     x0,a
rt5_initialize_gains_done:

        ; Preserve the packed source before the planar right stream overlays
        ; its Y-memory window. Cleanup restores it and mechanically regenerates
        ; every expanded exact-renderer table outside the measured bracket.
        move    #opm_uploaded_tables,r4
        move    #rt5_packed_table_backup,r1
        do      #YM_TABLE_WORDS,rt5_backup_tables_done
        move    y:(r4)+,a
        move    a1,x:(r1)+
rt5_backup_tables_done:

        ; Model 32 successively refilled planar PDX blocks. The real host can
        ; prepare these inactive buffers concurrently; initializing the whole
        ; deterministic stream before the profile keeps that host work outside
        ; the measured DSP render bracket.
        move    #rt5_pan_left_stream,r5
        move    #>$100000,a
        do      #DSP_RT_PROFILE_FRAMES,rt5_initialize_pdx_left_done
        move    a1,x:(r5)+
rt5_initialize_pdx_left_done:
        move    #rt5_pan_right_stream,r5
        move    #>$f00000,a
        do      #DSP_RT_PROFILE_FRAMES,rt5_initialize_pdx_right_done
        move    a1,y:(r5)+
rt5_initialize_pdx_right_done:
        move    #>rt5_pan_left_stream,a
        move    a1,x:rt5_pan_left_base
        move    #>rt5_pan_right_stream,a
        move    a1,x:rt5_pan_right_base

        ori     #$04,omr
        nop                             ; map the on-chip Y sine ROM
        move    #>$100,r0              ; r0 replaces r6 as the sine base
        move    #>255,m0
        move    #>-1,m1
        move    #>-1,m2
        move    #>63,m3
        move    #>-1,m4
        move    #>63,m5
        move    #>-1,m7
        move    #>$ff,y1
        move    #>rt5_channel_control-@cvs(x,rt5_feedback_0),n4

        ; Run real SSI traffic from buffer A while rendering into independent
        ; profile storage. The measured bracket begins only after SSI is live.
        movep   #0,x:m_crb
        movep   #$4100,x:m_cra
        move    #ssi_buffer_a,r6
        move    #>2013,m6
        nop
        move    x:(r6)+,a
        movep   a1,x:m_tx
        movep   #$5a00,x:m_crb

rt5_profile_loop_start:
        do      #DSP_RT5_PROFILE_BLOCKS,rt5_profile_blocks_done
        jsr     rt5_update_support_block

        ; Dynamic pan may produce no both-panned carrier. Instead of clearing
        ; the common ring every block, mark it unwritten: the first both-routed
        ; carrier writes it and the emit pass skips a ring nothing wrote. The
        ; noise pass runs behind the flag clear because a both-panned noise
        ; channel writes the ring first and owns the flag.
        clr     a
        move    a1,y:rt5_mix_written
        jsr     rt5_noise_block

        move    #>$100,r0
        move    #rt5_feedback_1,r2
        move    #rt5_feedback_0,r4
        move    #rt5_phase,r7
        move    #>-1,m7

        ; Every algorithm body preloads its stages' decoded, PM-adjusted
        ; increments through y:(r2+n2); the support block has already folded
        ; this block's scaled LFO offset into all 32 operator-major entries
        ; and selected the AM gain set. The channel-control read rides the
        ; parallel feedback pointer through (r4+n4), so n2 stays free for
        ; the per-stage increment offsets.
        move    #>$ff,y1
        move    #>-1,m5
        do      #8,rt5_channel_block_done
        jsr     rt5_render_channel
rt5_channel_block_done:

        ; Add the both-output carrier group to the planar PDX/side-channel
        ; accumulators, then interleave them for SSI. Moving the full
        ; accumulator (A/B rather than A1/B1) invokes the DSP56001 data limiter,
        ; producing signed 24-bit saturation only after the complete mix. The
        ; rare block whose dynamic pan left the common ring unwritten clears
        ; it here instead of paying that clear on every block.
        move    #rt5_mix_ring,r4
        move    x:rt5_pan_left_base,r1
        move    x:rt5_pan_right_base,r7
        move    #ssi_buffer_b,r5
        move    #>-1,m5
        move    y:rt5_mix_written,a
        tst     a
        jne     rt5_emit_ring_ready
        clr     a
        do      #DSP_RT2_BLOCK_FRAMES,rt5_emit_ring_cleared
        move    a1,y:(r4)+
rt5_emit_ring_cleared:
        move    #rt5_mix_ring,r4
rt5_emit_ring_ready:
        do      #DSP_RT2_BLOCK_FRAMES,rt5_emit_stereo_done
        move    x:(r1)+,x0 y:(r4)+,a
        move    a,b
        add     x0,a y:(r7)+,x0
        move    a,x:(r5)+
        add     x0,b
        move    b,x:(r5)+
rt5_emit_stereo_done:
        move    r1,x:rt5_pan_left_base
        move    r7,x:rt5_pan_right_base
        ; the deterministic planar PDX streams model successively refilled
        ; host buffers: wrap both pointers at the 2048-frame stream end so
        ; the 128-block profile reuses them without new storage
        move    #>rt5_pan_left_stream+DSP_RT_PROFILE_FRAMES,a
        move    r1,b
        cmp     a,b
        jlt     rt5_pan_streams_ready
        move    #>rt5_pan_left_stream,a
        move    a1,x:rt5_pan_left_base
        move    #>rt5_pan_right_stream,a
        move    a1,x:rt5_pan_right_base
rt5_pan_streams_ready:
        move    #>63,m5
rt5_profile_blocks_done:
        nop
rt5_profile_loop_done:

        movep   #0,x:m_crb
        movep   x:m_sr,x:ssi_status_snapshot
        clr     a
        movep   a1,x:m_tx

        ; The planar right stream overlaid the expanded power table and packed
        ; upload source. Restore the packed words, then regenerate all expanded
        ; tables before returning to any exact-renderer command.
        move    #rt5_packed_table_backup,r1
        move    #opm_uploaded_tables,r4
        do      #YM_TABLE_WORDS,rt5_restore_tables_done
        move    x:(r1)+,a
        move    a1,y:(r4)+
rt5_restore_tables_done:
        jsr     ym_expand_tables

        ; Repay the bounded DDA residual for all 32 operator phases outside the
        ; measured window, then restore the exact renderer's memory mapping.
        clr     a
        move    #>$180000,a0            ; 128 blocks of bounded DDA residual
        move    #rt5_phase,r4
        do      #32,rt5_correct_phase_done
        move    l:(r4),b10
        add     a,b
        move    b10,l:(r4)+
rt5_correct_phase_done:
        move    #>-1,m1
        move    #>-1,m4

        ; Fold the decoded per-operator state into the reply before the
        ; cache rebuild below reclaims the internal-Y overlays: the rebuilt
        ; increments, both half-block affine constant arrays, every ADSR
        ; state word, and the surviving active count.
        clr     a
        move    #rt5_operator_increment,r1
        do      #32,rt5_checksum_increments_done
        move    y:(r1)+,x0
        add     x0,a
rt5_checksum_increments_done:
        move    #0,r1
        do      #32,rt5_checksum_env_a_done
        move    y:(r1)+,x0
        add     x0,a
rt5_checksum_env_a_done:
        move    #rt5_env_b,r1
        do      #32,rt5_checksum_env_b_done
        move    y:(r1)+,x0
        add     x0,a
rt5_checksum_env_b_done:
        move    #rt5_env_state,r1
        do      #32,rt5_checksum_env_state_done
        move    x:(r1)+,x0
        add     x0,a
rt5_checksum_env_state_done:
        move    x:rt5_active_count,x0
        add     x0,a
        move    a1,x:rt5_checksum
        jsr     rt2_restore_common

        ; Retain the last stereo block and the complete contiguous decoded
        ; control block (clock/LFO/noise/timer/event scalars, the partial
        ; checksum itself, the envelope levels, and every decoded LFO/timer
        ; scalar) in the reply, while keeping this conformance pass out of
        ; the profile.
        move    x:rt5_checksum,a
        move    #ssi_buffer_b,r1
        do      #128,rt5_checksum_stereo_done
        move    x:(r1)+,x0
        add     x0,a
rt5_checksum_stereo_done:
        move    #rt5_native_phase,r1
        do      #54,rt5_checksum_state_done
        move    x:(r1)+,x0
        add     x0,a
rt5_checksum_state_done:
        move    a1,x:rt5_checksum
        jsr     send_reply
        jmp     command_loop

; The READY token parks the DSP in this tight receive loop before TOS releases
; its blind block transfer. Expanding each signed PCM word by eight bits puts
; it in the same 0.23 accumulator domain as the codec-rate FM carriers.
rt5_receive_runtime_pcm:
        move    #>DSP_REPLY_BLOCK_READY,a
        jsr     send_reply
        do      #DSP_RT_MIX_FRAME_COUNT,rt5_receive_runtime_done
        jclr    #0,x:m_hsr,*
        movep   x:m_hrx,a
        rep     #8
        asl     a
        move    a1,x:(r1)+
        jclr    #0,x:m_hsr,*
        movep   x:m_hrx,a
        rep     #8
        asl     a
        move    a1,y:(r7)+
rt5_receive_runtime_done:
        rts

rt5_enter_runtime_map:
        ori     #$04,omr
        nop
        move    #>255,m0
        move    #>-1,m1
        move    #>-1,m2
        move    #>63,m3
        move    #>-1,m4
        move    #>63,m5
        move    #>-1,m7
        move    #>rt5_channel_control-@cvs(x,rt5_feedback_0),n4
        rts

; Render one production block from the current planar PCM pointers into the
; walking inactive SSI output pointer. This is the command-17 hot topology
; path with only its profile stream wrapping removed.
rt5_render_runtime_block:
        jsr     rt5_update_support_block
        clr     a
        move    a1,y:rt5_mix_written
        jsr     rt5_noise_block
        move    #>$100,r0
        move    #rt5_feedback_1,r2
        move    #rt5_feedback_0,r4
        move    #rt5_phase,r7
        move    #>-1,m7
        move    #>$ff,y1
        move    #>-1,m5
        do      #8,rt5_runtime_channels_done
        jsr     rt5_render_channel
rt5_runtime_channels_done:

        move    #rt5_mix_ring,r4
        move    x:rt5_pan_left_base,r1
        move    x:rt5_pan_right_base,r7
        move    x:rt5_runtime_output,r5
        move    #>-1,m5
        move    y:rt5_mix_written,a
        tst     a
        jne     rt5_runtime_ring_ready
        clr     a
        do      #DSP_RT2_BLOCK_FRAMES,rt5_runtime_ring_cleared
        move    a1,y:(r4)+
rt5_runtime_ring_cleared:
        move    #rt5_mix_ring,r4
rt5_runtime_ring_ready:
        do      #DSP_RT2_BLOCK_FRAMES,rt5_runtime_stereo_done
        move    x:(r1)+,x0 y:(r4)+,a
        move    a,b
        add     x0,a y:(r7)+,x0
        move    a,x:(r5)+
        add     x0,b
        move    b,x:(r5)+
rt5_runtime_stereo_done:
        move    r1,x:rt5_pan_left_base
        move    r7,x:rt5_pan_right_base
        move    r5,x:rt5_runtime_output
        move    #>63,m5
        rts

; Update one 64-frame block of global control state. Every due FIFO event is
; decoded first so its state lands in this block. Native-time, LFO, and timer
; state advance with the exact 1280:1007 block DDA instead of repeating its
; quotient work in every frame; the LFO rate and both timer reloads are the
; decoded values, and the 17-bit maximum-length Galois LFSR still advances
; exactly once per frame. The tail scales the low control bits by the decoded
; PM depth, selects the AM gain set, rebuilds all 32 PM-adjusted phase
; increments in one two-instruction loop, and tail-calls the envelope island
; pass that curves every envelope-active operator at the block boundary.
rt5_update_support_block:
        jsr     rt5_service_event

        ; Over 64 codec frames the native-time DDA always advances by 81
        ; native ticks plus a possible 82nd. Subtracting 17*1007 up front
        ; leaves only one conditional correction while preserving the exact
        ; remainder and boundary state.
        move    x:rt5_native_phase,a
        move    #>353,x0
        add     x0,a
        move    #>81,y0
        move    #>1007,x0
        cmp     x0,a
        jlt     rt5_native_phase_ready
        sub     x0,a
        move    #>82,y0
rt5_native_phase_ready:
        move    a1,x:rt5_native_phase

        ; The 48-bit LFO accumulator (ymfm counter times 2^18) advances by
        ; the decoded 81-tick pair, plus the per-tick pair when the native
        ; DDA consumed an 82nd tick; the true waveform index is then the
        ; high word's top byte.
        move    y:rt5_lfo_acc_lo,a0
        move    y:rt5_lfo_acc_hi,a1
        move    x:rt5_lfo_step_block_lo,b0
        move    x:rt5_lfo_step_block,b1
        add     b,a
        move    #>81,b
        cmp     y0,b
        jeq     rt5_lfo_acc_ready
        move    x:rt5_lfo_step_tick_lo,b0
        move    x:rt5_lfo_step_tick,b1
        add     b,a
rt5_lfo_acc_ready:
        move    a0,y:rt5_lfo_acc_lo
        move    a1,y:rt5_lfo_acc_hi

        ; Timer A runs from its decoded reload while control bit 0 holds it
        ; loaded; expiry sets the status flag and reloads exactly.
        move    x:rt5_timer_control,b
        jclr    #0,b1,rt5_timer_a_done
        move    x:rt5_timer_counter,a
        sub     y0,a
        jgt     rt5_timer_a_store
        move    x:rt5_timer_a_reload,x0
        add     x0,a
        move    x:rt5_timer_status,b
        bset    #0,b1
        move    b1,x:rt5_timer_status
rt5_timer_a_store:
        move    a1,x:rt5_timer_counter
rt5_timer_a_done:

        ; Timer B mirrors Timer A under control bit 1 with its decoded
        ; 16x-scaled reload.
        move    x:rt5_timer_control,b
        jclr    #1,b1,rt5_timer_b_done
        move    x:rt5_timer_b_counter,a
        sub     y0,a
        jgt     rt5_timer_b_store
        move    x:rt5_timer_b_reload,x0
        add     x0,a
        move    x:rt5_timer_status,b
        bset    #1,b1
        move    b1,x:rt5_timer_status
rt5_timer_b_store:
        move    a1,x:rt5_timer_b_counter
rt5_timer_b_done:

        ; Production mode publishes the same drift-free native clock used by
        ; the transport FIFO. The profiling command leaves its independent
        ; deterministic clock untouched.
        move    x:rt5_runtime_mode,a
        tst     a
        jeq     rt5_runtime_clock_done
        move    x:ssi_native_sample_count,a
        add     y0,a
        move    #>$00ffff,x0
        and     x0,a1
        move    a1,x:ssi_native_sample_count
rt5_runtime_clock_done:

        ; Apply the exact 64-step transform for the x^17+x^14+1 right-shifting
        ; Galois LFSR. Linearity splits the old state into 6/6/5-bit slice
        ; contributions; the three lookup tables were derived at command
        ; setup from the step function itself, and the five-bit slice already
        ; carries the bit-16 column. With noise enabled the substitution
        ; pass steps these 64 frames itself, keeping the dumped boundary
        ; states exactly 64 Galois steps apart either way.
        move    x:rt5_noise_threshold,b
        tst     b
        jne     rt5_noise_jump_skipped
        move    x:rt5_noise_lfsr,b
        move    #>$00003f,y0
        move    b,a
        and     y0,a
        move    a1,n1
        rep     #6
        lsr     b
        move    b,a
        and     y0,a
        move    a1,n2
        rep     #6
        lsr     b
        move    #rt5_noise_jump_low6,r1
        move    #rt5_noise_jump_mid6,r2
        move    b1,n3
        move    #rt5_noise_jump_high5,r3
        nop                             ; address-register pipeline interlock
        move    x:(r1+n1),a
        move    x:(r2+n2),x0
        eor     x0,a
        move    x:(r3+n3),x0
        eor     x0,a
        move    a1,x:rt5_noise_lfsr
rt5_noise_jump_skipped:

        ; Derive and apply this block's true AM in the island: waveform AM
        ; byte from the LFO index, m_lfo_am = am*AMD>>7 published through
        ; rt5_block_control, one multiplier per AM sensitivity, and a
        ; rescale of every AM-affected channel's live gain pairs.
        jsr     rt5_lfo_am_block

        ; This block's PM offset scales the published LFO index byte by the
        ; decoded $19 depth: the doubling MPY plus one ASL make depth $40
        ; exactly unity. LFO waveform bit 0 selects the offset sign.
        move    x:rt5_lfo_phase,a
        move    #>$ff,y1
        and     y1,a1
        move    a1,x0
        move    x:rt5_pm_scale,y0
        mpy     x0,y0,a
        asl     a
        move    x:rt5_lfo_waveform,b
        jclr    #0,b1,rt5_pm_sign_ready
        neg     a
rt5_pm_sign_ready:
        move    a1,x1

        ; Two-instruction per-operator increment rebuild: the dual XY move
        ; stores the previous finished sum while fetching the next base, so B
        ; runs one iteration ahead and the final store consumes the cleared
        ; guard word after the 32 bases. Envelope levels no longer ride this
        ; loop; the island pass below moves only envelope-active operators.
        move    #rt5_increment_base,r2
        move    #rt5_operator_increment,r7
        move    x:(r2)+,b
        add     x1,b
        do      #32,rt5_operator_update_done
        move    x:(r2)+,b       b,y:(r7)+
        add     x1,b
rt5_operator_update_done:
        jmp     rt5_env_scan

; Drain every due block-boundary event from the profile-local FIFO and update
; the real register image. Events are already ordered, so the read side pays
; the same count/timestamp/decode structure as the rolling transport, and a
; burst of writes sharing one timestamp — an MXDRV voice load is ~26 —
; is consumed in a single boundary service whose transient cost amortizes
; across the 1007-frame period.
rt5_service_event:
        move    x:rt5_runtime_mode,a
        tst     a
        jne     rt5_service_transport_event
        move    x:rt5_event_count,a
        tst     a
        jeq     rt5_service_event_done
        move    x:rt5_event_read,n0
        move    n0,n1
        move    #rt5_event_times,r0
        move    #rt5_event_commands,r1
        nop
        move    x:(r0+n0),b
        move    x:rt5_event_clock,a
        cmp     b,a
        jlt     rt5_service_event_done

        move    x:(r1+n1),x1
        move    x1,a
        rep     #8
        lsr     a
        move    #>$ff,y0
        and     y0,a1
        move    a1,n0
        move    x1,b
        and     y0,b1
        move    b1,y1
        move    #ym_regdata,r0
        nop
        move    b1,x:(r0+n0)

        jsr     rt5_decode_register
        jmp     rt5_event_decode_done

; Decode n0/a = register and y1 = data after the caller has updated the real
; register image. Keeping this as a subroutine lets the production stream use
; the identical state transition for direct and rolling-FIFO writes.
rt5_decode_register:
        move    n0,a
        move    #>$60,x0
        cmp     x0,a
        jlt     rt5_event_below_60
        move    #>$c0,x0
        cmp     x0,a
        jge     rt5_event_decode_dt2
        move    #>$80,x0
        cmp     x0,a
        jge     rt5_env_rate_event
        jmp     rt5_env_tl_event
rt5_event_below_60:
        move    #>$28,x0
        cmp     x0,a
        jlt     rt5_event_below_28
        move    #>$30,x0
        cmp     x0,a
        jlt     rt5_event_decode_kc
        move    #>$38,x0
        cmp     x0,a
        jlt     rt5_event_decode_kf
        move    #>$40,x0
        cmp     x0,a
        jlt     rt5_decode_register_done
        jmp     rt5_event_decode_mul
rt5_event_below_28:
        move    #>$20,x0
        cmp     x0,a
        jge     rt5_event_decode_channel_control
        move    #>$18,x0
        cmp     x0,a
        jge     rt5_event_decode_lfo
        move    #>$10,x0
        cmp     x0,a
        jge     rt5_event_decode_timer
        move    #>$08,x0
        cmp     x0,a
        jeq     rt5_env_key_event
        move    #>$0f,x0
        cmp     x0,a
        jeq     rt5_event_decode_noise
rt5_decode_register_done:
        rts

rt5_event_decode_done:

        move    x:rt5_event_read,a
        move    #>1,x0
        add     x0,a
        move    #>31,y0
        and     y0,a1
        move    a1,x:rt5_event_read
        move    x:rt5_event_count,a
        sub     x0,a
        move    a1,x:rt5_event_count
        jmp     rt5_service_event       ; drain until the head is not yet due
rt5_service_event_done:
        move    x:rt5_event_clock,a
        move    #>64,x0
        add     x0,a
        move    a1,x:rt5_event_clock
        rts

; Production read side for the existing rolling 32-entry queue. Writes due at
; the current native boundary are mirrored into the exact register image and
; decoded into the persistent codec-rate state before this 64-frame block.
rt5_service_transport_event:
        move    x:ym_queue_count,a
        tst     a
        jeq     rt5_service_transport_done
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
        jeq     rt5_service_transport_due
        jclr    #15,a1,rt5_service_transport_done
rt5_service_transport_due:
        move    x:(r1+n1),x1
        jsr     rt5_apply_packed_write
        move    x:ym_queue_read_index,a
        move    #>1,x0
        add     x0,a
        move    #>31,y0
        and     y0,a1
        move    a1,x:ym_queue_read_index
        move    x:ym_queue_count,a
        sub     x0,a
        move    a1,x:ym_queue_count
        jmp     rt5_service_transport_event
rt5_service_transport_done:
        rts

; Apply one packed command-02 word to both the retained exact register mirror
; and the codec-rate decoder. Reloading x1 protects the packed payload across
; timer/key helpers used by ym_write_packed.
rt5_apply_packed_write:
        move    x1,x:last_command
        jsr     ym_write_packed
        move    x:last_command,x1
        move    x1,a
        move    #>$00ff00,y0
        and     y0,a1
        rep     #8
        lsr     a
        move    a1,n0
        move    x1,a
        move    #>$0000ff,y0
        and     y0,a1
        move    a1,y1
        move    #ym_regdata,r0
        move    n0,a
        jmp     rt5_decode_register

; Render one channel with the topology selected by its decoded $20-$27 state.
; The control read rides the parallel Y-bank feedback pointer through
; (r4+n4), leaving n2 for the operator-major increment offsets: each body
; preloads one decoded phase increment per stage through y:(r2+n2) beside the
; existing (r7+n7) gain preload. Preserve the control word internally so every
; carrier of algorithms 4 and 5 observes the same pan without another external
; lookup. Every path advances r7 by four phases and r2/r4 by one feedback pair.
rt5_render_channel:
        move    x:(r4+n4),a
        move    a1,x:rt5_current_channel_control
        move    #>RT5_INC_OP1_PRE,n2
        move    #>7,x0
        and     x0,a
        jclr    #2,a1,rt5_render_low_half
        jclr    #1,a1,rt5_render_algorithms45
        jclr    #0,a1,rt5_render_algorithm6
        jmp     rt5_render_algorithm7
rt5_render_algorithms45:
        jclr    #0,a1,rt5_render_algorithm4
        jmp     rt5_render_algorithm5
rt5_render_low_half:
        jclr    #1,a1,rt5_render_algorithms01
        jclr    #0,a1,rt5_render_algorithm2
        jmp     rt5_render_algorithm3
rt5_render_algorithms01:
        jclr    #0,a1,rt5_render_algorithm0
        jmp     rt5_render_algorithm1

; Algorithm 0: O1 -> O2 -> O3 -> O4.
rt5_render_algorithm0:
        move    #>RT5_MOD_GAIN_OFFSET,n7
        move    y:(r2+n2),x1
        jsr     rt5_feedback_write_x
        move    #>RT5_INC_OP2_POST,n2
        move    x:(r7+n7),y0
        move    y:(r2+n2),x1
        jsr     rt5_serial_transform_x
        move    #>RT5_INC_OP3_POST,n2
        move    x:(r7+n7),y0
        move    y:(r2+n2),x1
        jsr     rt5_serial_transform_x
        move    #>RT5_OUT_GAIN_OFFSET,n7
        move    #>RT5_INC_OP4_POST,n2
        move    x:(r7+n7),y0
        move    y:(r2+n2),x1
        jsr     rt5_route_carrier
        rts

; Algorithm 1: (O1 + O2) -> O3 -> O4.
rt5_render_algorithm1:
        move    #>RT5_MOD_GAIN_OFFSET,n7
        move    y:(r2+n2),x1
        jsr     rt5_feedback_write_x
        move    #>RT5_INC_OP2_POST,n2
        move    x:(r7+n7),y0
        move    y:(r2+n2),x1
        jsr     rt5_independent_add_x
        move    #>RT5_INC_OP3_POST,n2
        move    x:(r7+n7),y0
        move    y:(r2+n2),x1
        jsr     rt5_serial_transform_x
        move    #>RT5_OUT_GAIN_OFFSET,n7
        move    #>RT5_INC_OP4_POST,n2
        move    x:(r7+n7),y0
        move    y:(r2+n2),x1
        jsr     rt5_route_carrier
        rts

; Algorithm 2: (O1 + (O2 -> O3)) -> O4. Build the independent O2/O3 branch
; first, then rewind to O1 and add feedback into the same modulation ring.
; The feedback stage has not yet advanced r2, so O2/O3 use PRE offsets.
rt5_render_algorithm2:
        move    #>RT5_MOD_GAIN_OFFSET,n7
        move    #>RT5_INC_OP2_PRE,n2
        move    r7,a
        move    #>1,x0
        add     x0,a
        move    a1,r7
        nop                             ; address-register pipeline interlock
        move    x:(r7+n7),y0
        move    y:(r2+n2),x1
        jsr     rt5_independent_write_x
        move    #>RT5_INC_OP3_PRE,n2
        move    x:(r7+n7),y0
        move    y:(r2+n2),x1
        jsr     rt5_serial_transform_x
        move    #>RT5_INC_OP1_PRE,n2
        move    r7,a
        move    #>3,x0
        sub     x0,a
        move    a1,r7
        move    y:(r2+n2),x1
        jsr     rt5_feedback_add_x
        move    #>RT5_OUT_GAIN_OFFSET,n7
        move    #>RT5_INC_OP4_POST,n2
        move    r7,a
        move    #>2,x0
        add     x0,a
        move    a1,r7
        nop                             ; address-register pipeline interlock
        move    x:(r7+n7),y0
        move    y:(r2+n2),x1
        jsr     rt5_route_carrier
        rts

; Algorithm 3: (O1 -> O2 + O3) -> O4.
rt5_render_algorithm3:
        move    #>RT5_MOD_GAIN_OFFSET,n7
        move    y:(r2+n2),x1
        jsr     rt5_feedback_write_x
        move    #>RT5_INC_OP2_POST,n2
        move    x:(r7+n7),y0
        move    y:(r2+n2),x1
        jsr     rt5_serial_transform_x
        move    #>RT5_INC_OP3_POST,n2
        move    x:(r7+n7),y0
        move    y:(r2+n2),x1
        jsr     rt5_independent_add_x
        move    #>RT5_OUT_GAIN_OFFSET,n7
        move    #>RT5_INC_OP4_POST,n2
        move    x:(r7+n7),y0
        move    y:(r2+n2),x1
        jsr     rt5_route_carrier
        rts

; Algorithm 4: (O1 -> O2) + (O3 -> O4). Each branch routes its own carrier;
; the O1 and O3 modulation rings can therefore reuse the same internal X line.
rt5_render_algorithm4:
        move    #>RT5_MOD_GAIN_OFFSET,n7
        move    y:(r2+n2),x1
        jsr     rt5_feedback_write_x
        move    #>RT5_OUT_GAIN_OFFSET,n7
        move    #>RT5_INC_OP2_POST,n2
        move    x:(r7+n7),y0
        move    y:(r2+n2),x1
        jsr     rt5_route_carrier
        move    #>RT5_MOD_GAIN_OFFSET,n7
        move    #>RT5_INC_OP3_POST,n2
        move    x:(r7+n7),y0
        move    y:(r2+n2),x1
        jsr     rt5_independent_write_x
        move    #>RT5_OUT_GAIN_OFFSET,n7
        move    #>RT5_INC_OP4_POST,n2
        move    x:(r7+n7),y0
        move    y:(r2+n2),x1
        jsr     rt5_route_carrier
        rts

; Algorithm 5: O1 modulates O2, O3, and O4 in parallel. Carrier routing only
; reads the shared X modulation ring, so all three branches consume it intact.
rt5_render_algorithm5:
        move    #>RT5_MOD_GAIN_OFFSET,n7
        move    y:(r2+n2),x1
        jsr     rt5_feedback_write_x
        move    #>RT5_OUT_GAIN_OFFSET,n7
        move    #>RT5_INC_OP2_POST,n2
        move    x:(r7+n7),y0
        move    y:(r2+n2),x1
        jsr     rt5_route_carrier
        move    #>RT5_INC_OP3_POST,n2
        move    x:(r7+n7),y0
        move    y:(r2+n2),x1
        jsr     rt5_route_carrier
        move    #>RT5_INC_OP4_POST,n2
        move    x:(r7+n7),y0
        move    y:(r2+n2),x1
        jsr     rt5_route_carrier
        rts

; Algorithm 6: (O1 -> O2) + O3 + O4. Accumulate all three carriers in X,
; then route the completed ring according to the decoded channel pan.
rt5_render_algorithm6:
        move    #>RT5_MOD_GAIN_OFFSET,n7
        move    y:(r2+n2),x1
        jsr     rt5_feedback_write_x
        move    #>RT5_OUT_GAIN_OFFSET,n7
        move    #>RT5_INC_OP2_POST,n2
        move    x:(r7+n7),y0
        move    y:(r2+n2),x1
        jsr     rt5_serial_transform_x
        move    #>RT5_INC_OP3_POST,n2
        move    x:(r7+n7),y0
        move    y:(r2+n2),x1
        jsr     rt5_independent_add_x
        move    #>RT5_INC_OP4_POST,n2
        move    x:(r7+n7),y0
        move    y:(r2+n2),x1
        jsr     rt5_independent_add_x
        jmp     rt5_route_accumulated_carriers

; Algorithm 7: O1 + O2 + O3 + O4. Route the completed four-carrier X ring
; after every operator and its feedback state have advanced.
rt5_render_algorithm7:
        move    #>RT5_OUT_GAIN_OFFSET,n7
        move    y:(r2+n2),x1
        jsr     rt5_feedback_write_carrier
        move    #>RT5_INC_OP2_POST,n2
        move    x:(r7+n7),y0
        move    y:(r2+n2),x1
        jsr     rt5_independent_add_x
        move    #>RT5_INC_OP3_POST,n2
        move    x:(r7+n7),y0
        move    y:(r2+n2),x1
        jsr     rt5_independent_add_x
        move    #>RT5_INC_OP4_POST,n2
        move    x:(r7+n7),y0
        move    y:(r2+n2),x1
        jsr     rt5_independent_add_x
        jmp     rt5_route_accumulated_carriers

; O1 for the all-carrier algorithm: its ring word is the audible carrier
; while its feedback history needs the fold scale, so the loop computes two
; products per frame. The gain pair alternates through a modulo-2 internal
; ring on the mpyr parallel loads — the multiply consumes the previous y0
; while the same instruction fetches the other gain — costing two
; instructions per frame over the standard stage with every access internal.
rt5_feedback_write_carrier:
        move    x:(r7+n7),y0            ; carrier gain; n7 is the OUT offset
        move    x:rt5_current_channel_control,a
        move    #>$38,x0
        and     x0,a
        jeq     rt5_feedback_write_bypass
        move    #>RT5_MOD_GAIN_OFFSET,n7
        move    y0,y:rt5_alg7_gain_ring+1
        move    x:(r7+n7),a             ; fold-scale gain from the mod array
        move    a1,y:rt5_alg7_gain_ring
        move    #>RT5_OUT_GAIN_OFFSET,n7
        move    #rt5_alg7_gain_ring,r5
        move    #>1,m5
        move    #rt2_stage_ring,r3
        move    l:(r7),b10
        do      #DSP_RT2_BLOCK_FRAMES,rt5_feedback_write_carrier_done
        move    x:(r2),x0 y:(r4),a
        add     x0,a a1,x:(r2)
        add     b,a
        and     y1,a1
        move    a1,n0
        mac     x1,y1,b
        move    y:(r0+n0),x0
        mpyr    x0,y0,a y:(r5)+,y0      ; carrier product; y0 becomes fold
        move    a,x:(r3)+
        mpyr    x0,y0,a y:(r5)+,y0      ; history product; y0 becomes carrier
        move    a,y:(r4)
rt5_feedback_write_carrier_done:
        move    b10,l:(r7)+
        move    (r2)+
        move    (r4)+
        move    #>-1,m5
        rts

; All-topology stages for the live-SSI profile. r0 is the sine-ROM base and r7
; walks 32 overlaid internal long phases, leaving r6/m6 untouched for the
; interrupt. Callers preload each stage's decoded PM-adjusted increment into
; x1 and its block gain into y0 before the jsr.
rt5_feedback_write_x:
        ; Feedback level 0 must contribute zero self-modulation, exactly as
        ; ymfm's (out0+out1)>>(10-FB) special-cases it, so dispatch to the
        ; feedback-less stage instead of consuming the stale history pair.
        ; The gain load comes first (the independent twins expect it in y0),
        ; and the bypass still advances the channel's feedback pair: every
        ; later stage and the next channel's control read anchor on r2/r4.
        move    x:(r7+n7),y0
        move    x:rt5_current_channel_control,a
        move    #>$38,x0
        and     x0,a
        jeq     rt5_feedback_write_bypass
        move    #rt2_stage_ring,r3
        move    l:(r7),b10
        do      #DSP_RT2_BLOCK_FRAMES,rt5_feedback_write_x_done
        move    x:(r2),x0 y:(r4),a
        add     x0,a a1,x:(r2)
        add     b,a
        and     y1,a1
        move    a1,n0
        mac     x1,y1,b
        move    y:(r0+n0),x0
        mpyr    x0,y0,a
        move    a,x:(r3)+ a,y:(r4)
rt5_feedback_write_x_done:
        move    b10,l:(r7)+
        move    (r2)+
        move    (r4)+
        rts

; Add operator 1's feedback output to an existing X modulation ring. This is
; the reordered algorithm-2 fan-in used by the isolated command-$16 spike.
rt5_feedback_write_bypass:
        move    (r2)+
        move    (r4)+
        jmp     rt5_independent_write_x

rt5_feedback_add_bypass:
        move    (r2)+
        move    (r4)+
        jmp     rt5_independent_add_x

rt5_feedback_add_x:
        ; Same feedback-level-0 dispatch as the write variant.
        move    x:(r7+n7),y0
        move    x:rt5_current_channel_control,a
        move    #>$38,x0
        and     x0,a
        jeq     rt5_feedback_add_bypass
        move    #rt2_stage_ring,r3
        move    l:(r7),b10
        do      #DSP_RT2_BLOCK_FRAMES,rt5_feedback_add_x_done
        move    x:(r2),x0 y:(r4),a
        add     x0,a a1,x:(r2)
        add     b,a
        and     y1,a1
        move    a1,n0
        mac     x1,y1,b x:(r3),x0
        move    y:(r0+n0),x0
        mpyr    x0,y0,a x:(r3),x0
        add     x0,a a1,y:(r4)
        move    a,x:(r3)+
rt5_feedback_add_x_done:
        move    b10,l:(r7)+
        move    (r2)+
        move    (r4)+
        rts

; Start or add an unmodulated operator in the internal X stage ring.
rt5_independent_write_x:
        move    #rt2_stage_ring,r3
        move    l:(r7),b10
        do      #DSP_RT2_BLOCK_FRAMES,rt5_independent_write_x_done
        and     y1,b1
        move    b1,n0
        mac     x1,y1,b
        move    y:(r0+n0),x0
        mpyr    x0,y0,a
        move    a,x:(r3)+
rt5_independent_write_x_done:
        move    b10,l:(r7)+
        rts

rt5_independent_add_x:
        move    #rt2_stage_ring,r3
        move    #rt2_stage_ring,r5
        move    l:(r7),b10
        do      #DSP_RT2_BLOCK_FRAMES,rt5_independent_add_x_done
        and     y1,b1 x:(r3)+,a
        move    b1,n0
        mac     x1,y1,b
        move    y:(r0+n0),x0
        macr    x0,y0,a
        move    a,x:(r5)+
rt5_independent_add_x_done:
        move    b10,l:(r7)+
        rts

rt5_serial_transform_x:
        move    #rt2_stage_ring,r3
        move    #rt2_stage_ring,r5
        move    l:(r7),b10
        move    x:(r3)+,a
        do      #DSP_RT2_BLOCK_FRAMES,rt5_serial_transform_x_done
        add     b,a
        and     y1,a1
        move    a1,n0
        mac     x1,y1,b
        move    y:(r0+n0),x0
        mpyr    x0,y0,a x:(r3)+,x0
        move    a,x:(r5)+ x0,a
rt5_serial_transform_x_done:
        move    b10,l:(r7)+
        rts

rt5_serial_accumulate_x:
        move    #rt2_stage_ring,r3
        move    l:(r7),b10
        move    x:(r3)+,a
        do      #DSP_RT2_BLOCK_FRAMES,rt5_serial_accumulate_x_done
        add     b,a
        and     y1,a1
        move    a1,n0
        mac     x1,y1,b
        move    y:(r0+n0),x0
        mpyr    x0,y0,a y:(r1)+,x0
        add     x0,a x:(r3)+,x0
        move    a,y:(r5)+
        move    x0,a
rt5_serial_accumulate_x_done:
        move    b10,l:(r7)+
        rts

; Write-first variant of the both-panned carrier: the block's first common
; carrier stores into the Y mix ring without reading it, replacing the former
; per-block ring clear. The stored full-A move keeps the same limiter
; semantics as accumulating onto a cleared ring, so output is bit-identical.
; The shared prologue routes an already-written ring to the accumulate loop.
rt5_serial_mix_common:
        move    y:rt5_mix_written,a
        tst     a
        jne     rt5_serial_accumulate_x
        move    #>1,a
        move    a1,y:rt5_mix_written
rt5_serial_write_y:
        move    #rt2_stage_ring,r3
        move    l:(r7),b10
        move    x:(r3)+,a
        do      #DSP_RT2_BLOCK_FRAMES,rt5_serial_write_y_done
        add     b,a
        and     y1,a1
        move    a1,n0
        mac     x1,y1,b
        move    y:(r0+n0),x0
        mpyr    x0,y0,a x:(r3)+,x0
        move    a,y:(r5)+
        move    x0,a
rt5_serial_write_y_done:
        move    b10,l:(r7)+
        rts

; Left-only channels use an X-memory accumulator so their planar PCM can be
; fetched in parallel with the right Y-memory stream during stereo emission.
rt5_serial_accumulate_left_x:
        move    #rt2_stage_ring,r3
        move    l:(r7),b10
        move    x:(r3)+,a
        do      #DSP_RT2_BLOCK_FRAMES,rt5_serial_accumulate_left_x_done
        add     b,a
        and     y1,a1
        move    a1,n0
        mac     x1,y1,b
        move    y:(r0+n0),x0
        mpyr    x0,y0,a x:(r1)+,x0
        add     x0,a x:(r3)+,x0
        move    a,x:(r5)+
        move    x0,a
rt5_serial_accumulate_left_x_done:
        move    b10,l:(r7)+
        rts

; Algorithms 6 and 7 finish with an already-summed carrier ring rather than a
; final operator awaiting transformation. Route that ring directly while
; retaining the same decoded pan semantics as rt5_route_carrier.
rt5_route_accumulated_carriers:
        move    x:rt5_current_channel_control,a
        jclr    #6,a1,rt5_route_accumulated_no_left
        jclr    #7,a1,rt5_route_accumulated_left
        move    #rt5_mix_ring,r5
        jmp     rt5_ring_mix_common
rt5_route_accumulated_no_left:
        jclr    #7,a1,rt5_route_accumulated_mute
        move    x:rt5_pan_right_base,r5
        jmp     rt5_accumulate_ring_y
rt5_route_accumulated_left:
        move    x:rt5_pan_left_base,r5
        jmp     rt5_accumulate_ring_x
rt5_route_accumulated_mute:
        rts

rt5_accumulate_ring_y:
        move    #rt2_stage_ring,r3
        do      #DSP_RT2_BLOCK_FRAMES,rt5_accumulate_ring_y_done
        move    x:(r3)+,x0 y:(r5),a
        add     x0,a
        move    a,y:(r5)+
rt5_accumulate_ring_y_done:
        rts

; Write-first variant for the already-summed algorithm-6/7 carrier ring: copy
; the X stage ring into the unwritten Y mix ring through the full B move,
; matching the limiter semantics of adding onto a cleared ring. The shared
; prologue routes an already-written ring to the accumulate loop.
rt5_ring_mix_common:
        move    y:rt5_mix_written,a
        tst     a
        jne     rt5_accumulate_ring_y
        move    #>1,a
        move    a1,y:rt5_mix_written
rt5_write_ring_y:
        move    #rt2_stage_ring,r3
        do      #DSP_RT2_BLOCK_FRAMES,rt5_write_ring_y_done
        move    x:(r3)+,b
        move    b,y:(r5)+
rt5_write_ring_y_done:
        rts

rt5_accumulate_ring_x:
        move    #rt2_stage_ring,r3
        do      #DSP_RT2_BLOCK_FRAMES,rt5_accumulate_ring_x_done
        move    x:(r3)+,a
        move    x:(r5),x0
        add     x0,a
        move    a,x:(r5)+
rt5_accumulate_ring_x_done:
        rts

; Select one of the four decoded OPM pan modes once per carrier block. The
; caller has already preloaded the carrier gain and increment. Muted channels
; still clock every operator and retain their carrier state, but do not add
; it to a mix ring.
; Register $20 bit 6 enables ymfm's first output — the reference vectors'
; left column — and bit 7 the second; the first routing had them swapped.
rt5_route_carrier:
        move    x:rt5_current_channel_control,a
        jclr    #6,a1,rt5_route_no_left
        jclr    #7,a1,rt5_route_left
        move    #rt5_mix_ring,r1
        move    #rt5_mix_ring,r5
        jmp     rt5_serial_mix_common
rt5_route_no_left:
        jclr    #7,a1,rt5_route_mute
rt5_route_right:
        move    x:rt5_pan_right_base,r1
        move    x:rt5_pan_right_base,r5
        jmp     rt5_serial_accumulate_x
rt5_route_left:
        move    x:rt5_pan_left_base,r1
        move    x:rt5_pan_left_base,r5
        jmp     rt5_serial_accumulate_left_x
rt5_route_mute:
        jmp     rt5_serial_transform_x

; Shared block-profile setup. The measured brackets deliberately begin after
; this command-local state and memory-map work.
rt2_initialize_common:
        clr     b
        move    #rt2_phase,r4
        do      #4,rt2_clear_state
        move    b10,l:(r4)+
rt2_clear_state:
        clr     a
        move    a1,x:rt2_fb_1
        move    a1,y:rt2_fb_0_y

        ; Using $ff as both the ROM-address mask and the phase MAC operand
        ; makes the per-frame increment $9330*$ff, 48 product units below the
        ; exact $024a74*$40 value. Restore the accumulated $60000 low-word
        ; residual once per full 2,048-frame profile block, keeping its boundary
        ; phase exact while bounding the intermediate error below 0.012 step.
        clr     a
        move    #>$60000,a0
        move    a10,l:rt2_phase_correction

        ; The DSP56001's on-chip Y data ROM is a full 256-step signed sine
        ; wave. Commands $14-$16 are mutually exclusive with the exact renderer,
        ; so temporarily map that ROM over external Y:$0100-$01ff and avoid
        ; both the external-memory wait state and former 64-step quantization.
        ori     #$04,omr
        nop                             ; OMR memory-map pipeline delay
        move    #>$100,r6
        move    #ssi_buffer_a,r1
        move    #>63,m3
        move    #>63,m5
        move    #>255,m6
        move    #>63,m7
        ; MAC fractional products place the integer table step in B1 and the
        ; sub-entry remainder in B0. The profile-block residual above makes
        ; this DDA exactly equal to 2 + $4a74/65536 entries at the boundary.
        move    #>$ff,y1
        move    #>$9330,x1
        rts

; Repay the small DDA residual once per complete profile block.
rt2_correct_phase:
        move    l:rt2_phase_correction,a10
        move    #rt2_phase,r4
        do      #4,rt2_phase_correction_done
        move    l:(r4),b10
        add     a,b
        move    b10,l:(r4)+
rt2_phase_correction_done:
        rts

rt2_restore_common:
        andi    #$fb,omr
        nop                             ; restore external Y:$0100-$01ff
        move    #>-1,m0
        move    #>-1,m2
        move    #>-1,m3
        move    #>-1,m5
        move    m3,m6
        move    #>-1,m7
        move    #>0,n0
        move    #>0,n6
        jsr     ym_rebuild_phase_cache  ; restore Y:$0054-$0058 cache overlays
        rts

; Checksum the rendered stereo block. The cycle brackets above exclude this
; conformance pass.
rt2_checksum_output:
        move    #ssi_buffer_a,r1
        clr     a
        do      #DSP_RT2_CHECKSUM_PAIRS,rt2_checksum_done
        move    x:(r1)+,x0
        add     x0,a
        move    x:(r1)+,x0
        add     x0,a
rt2_checksum_done:
        rts

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
        ; the host holds its PCM block until this READY token arrives, so the
        ; blind TOS block blast cannot outrun the receive loop below
        move    #>DSP_REPLY_BLOCK_READY,a
        jsr     send_reply
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

        move    #>DSP_CMD_REFILL_RT_MIXED,x0
        cmp     x0,a
        jeq     command_refill_realtime_mixed

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
        move    x:rt5_runtime_mode,a
        tst     a
        jne     ssi_stream_write_realtime
        jsr     ym_write_packed
        jsr     ym_refresh_phase_cache
        jmp     ssi_stream_write_reply
ssi_stream_write_realtime:
        jsr     rt5_apply_packed_write
ssi_stream_write_reply:
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
        move    x:rt5_runtime_mode,a
        tst     a
        jne     ssi_stream_command_error
        move    x:ssi_active_buffer,a
        tst     a
        jne     command_refill_buffer_a
        move    #ssi_buffer_b,r7
        jmp     command_refill_receive
command_refill_buffer_a:
        move    #ssi_buffer_a,r7
command_refill_receive:
        move    r7,x:ssi_refill_buffer
        ; same READY gate as command_start_mixed: park here before the host
        ; releases its blind block transfer
        move    #>DSP_REPLY_BLOCK_READY,a
        jsr     send_reply
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

; Refill the inactive production buffer from the matching half of the planar
; PCM workspace, render sixteen whole blocks while SSI loops the old buffer,
; then switch only after completing the current stereo pair.
command_refill_realtime_mixed:
        move    x:rt5_runtime_mode,a
        tst     a
        jeq     ssi_stream_command_error
        move    x:ssi_active_buffer,a
        tst     a
        jne     command_rt_refill_buffer_a
        move    #rt5_pan_left_stream+DSP_RT_MIX_FRAME_COUNT,r1
        move    #rt5_pan_right_stream+DSP_RT_MIX_FRAME_COUNT,r7
        move    #>ssi_buffer_b,a
        jmp     command_rt_refill_receive
command_rt_refill_buffer_a:
        move    #rt5_pan_left_stream,r1
        move    #rt5_pan_right_stream,r7
        move    #>ssi_buffer_a,a
command_rt_refill_receive:
        move    a1,x:ssi_refill_buffer
        move    r1,x:rt5_pan_left_base
        move    r7,x:rt5_pan_right_base
        jsr     rt5_receive_runtime_pcm
        move    x:ssi_refill_buffer,a
        move    a1,x:rt5_runtime_output
        do      #DSP_RT_MIX_BLOCK_COUNT,command_rt_refill_render_done
        jsr     rt5_render_runtime_block
        nop
command_rt_refill_render_done:

        movep   #$1a00,x:m_crb
        jclr    #m_tde,x:m_sr,*
        move    r6,a
        jclr    #0,a1,command_rt_refill_boundary
        movep   x:(r6)+,x:m_tx
        jclr    #m_tde,x:m_sr,*
command_rt_refill_boundary:
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
        move    #>DSP_RT_MIX_FRAME_COUNT,x0
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
        move    x:rt5_runtime_mode,a
        tst     a
        jeq     command_stop_exact

        ; Restore the packed upload source hidden by the planar right PCM
        ; buffers, regenerate the exact tables, and release all RT overlays.
        move    #rt5_packed_table_backup,r1
        move    #opm_uploaded_tables,r4
        do      #YM_TABLE_WORDS,command_stop_rt_restore_done
        move    x:(r1)+,a
        move    a1,y:(r4)+
command_stop_rt_restore_done:
        jsr     ym_expand_tables
        clr     a
        move    a1,x:rt5_runtime_mode
        jsr     rt2_restore_common
        jmp     command_stop_reply
command_stop_exact:
        jsr     ym_rebuild_phase_cache
command_stop_reply:
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
        clr     a
        move    a1,x:rt5_runtime_mode
        move    a1,x:rt5_runtime_output
        move    #ym_regdata,r0
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

; Simulate the YM3012's 10.3-float encode/decode truncation. The exact-path
; YM3012 and native clock helpers moved to the island window between the
; exact LFO helpers and the exact timer clock: they run per native
; sample only in the ungated exact mode, and
; the decoded role-gain support pushed the main stream past its P:$1400
; ceiling.
        org     p:$26e0
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
        jmp     ym_clock_timers

; True block AM. ymfm's waveform AM byte comes from the LFO index (counter
; bits 22-29), m_lfo_am is (am * AMD) >> 7, and each channel with AM
; sensitivity k applies 2^(-(m_lfo_am << (k-1))/64) to its AM-enabled
; operators (D1R register bit 7). The pass rescales live gain pairs from
; the AM-free base pairs, so a channel whose AMS returns to zero restores
; exactly; everything runs once per 64-frame block.
        org     p:$27c0
rt5_lfo_am_block:
        move    y:rt5_lfo_acc_hi,a
        rep     #16
        lsr     a
        move    #>$ff,x1
        and     x1,a1
        move    a1,x:rt5_lfo_phase      ; published block index byte
        ; With zero AM depth and no channel still scaled, the block's AM is
        ; identically idle: publish a zero m_lfo_am and skip the waveform,
        ; multiplier, and walk work entirely.
        move    x:rt5_lfo_amd,b
        move    x:rt5_am_engaged,x0
        or      x0,b
        tst     b
        jne     rt5_lfo_am_engaged_path
        clr     b
        move    b1,x:rt5_block_control
        rts
rt5_lfo_am_engaged_path:
        move    x:rt5_lfo_waveform,b
        move    #>2,x0
        cmp     x0,b
        jeq     rt5_lfo_am_triangle
        jgt     rt5_lfo_am_noise
        move    #>1,x0
        cmp     x0,b
        jeq     rt5_lfo_am_square
        eor     x1,a1                   ; sawtooth: index ^ $ff
        jmp     rt5_lfo_am_ready
rt5_lfo_am_square:
        jset    #7,a1,rt5_lfo_am_zero
        move    #>$ff,a
        jmp     rt5_lfo_am_ready
rt5_lfo_am_zero:
        clr     a
        jmp     rt5_lfo_am_ready
rt5_lfo_am_triangle:
        jset    #7,a1,rt5_lfo_am_tri_fold
        eor     x1,a1
rt5_lfo_am_tri_fold:
        asl     a
        and     x1,a1
        jmp     rt5_lfo_am_ready
rt5_lfo_am_noise:
        ; approximation: the low byte of the block-jumped Galois LFSR
        ; stands in for ymfm's shift-history byte
        move    x:rt5_noise_lfsr,a
        and     x1,a1
rt5_lfo_am_ready:
        move    a1,x0
        move    x:rt5_lfo_amd,y1
        mpy     x0,y1,a                 ; am*AMD*2, entirely in a0
        rep     #8
        asr     a
        move    a0,x0
        move    x0,a
        move    a1,x:rt5_block_control  ; published m_lfo_am

        ; one gain multiplier per AM sensitivity; entry 0 stays unity so a
        ; zero-AMS lookup needs no branch
        move    a1,x1                   ; offset for sensitivity 1
        move    #>$7fffff,a
        move    a1,x:rt5_am_mult
        move    #rt5_am_mult+1,r1
        do      #3,rt5_am_mult_done
        move    #>1023,x0
        move    x1,a
        cmp     x0,a
        jle     rt5_am_mult_in_range
        clr     a
        jmp     rt5_am_mult_store
rt5_am_mult_in_range:
        move    #>$3f,x0
        and     x0,a
        move    #>rt5_env_fraction,x0
        add     x0,a
        move    a1,r2
        move    x1,a
        rep     #6
        lsr     a
        move    a1,n2
        movem   p:(r2),a
        move    n2,b
        tst     b
        jeq     rt5_am_mult_store
        rep     n2
        asr     a
rt5_am_mult_store:
        move    a1,x:(r1)+
        move    x1,b
        asl     b
        move    b1,x1                   ; double the offset per sensitivity
rt5_am_mult_done:

        ; rescale the live gain pairs of every channel whose AM sensitivity
        ; is, or last block was, nonzero, and remember whether any channel
        ; remains scaled for the idle early-out
        clr     b
        move    b1,x:rt5_lfo_am_channel
        move    b1,x:rt5_am_engaged
        do      #8,rt5_am_walk_done
        move    x:rt5_lfo_am_channel,b
        move    #>ym_regdata+$38,a
        add     b,a
        move    a1,r2
        move    #>rt5_ams_previous,a
        add     b,a
        move    a1,r1
        nop
        move    x:(r2),a
        move    #>3,x0
        and     x0,a
        move    a1,y1                   ; ams
        move    a1,x0
        move    x:rt5_am_engaged,b
        or      x0,b
        move    b1,x:rt5_am_engaged
        move    x:(r1),b                ; previous ams, then update it
        move    a1,x:(r1)
        move    b1,x0
        or      x0,a                    ; ams | previous
        tst     a
        jeq     rt5_am_walk_next
        jsr     rt5_am_apply_channel
rt5_am_walk_next:
        move    x:rt5_lfo_am_channel,b
        move    #>1,x0
        add     x0,b
        move    b1,x:rt5_lfo_am_channel
        nop
rt5_am_walk_done:
        rts

; Apply one channel's AM multiplier (sensitivity in y1, channel number in
; x:rt5_lfo_am_channel) to its four live gain pairs. Logical operators
; M1,C1,M2,C2 read their AM-enable bits from raw D1R rows 0,2,1,3.
rt5_am_apply_channel:
        move    #>rt5_am_mult,a
        add     y1,a
        move    a1,r1
        nop
        move    x:(r1),a
        move    a1,x:rt5_lfo_am_mult_ch ; channel multiplier
        clr     b
        move    b1,x:rt5_lfo_am_op
        do      #4,rt5_am_apply_done
        ; raw D1R row for this logical operator
        move    x:rt5_lfo_am_op,b
        move    #>rt5_am_d1r_rows,a
        add     b,a
        move    a1,r1
        nop
        movem   p:(r1),a                ; raw row * 8
        move    x:rt5_lfo_am_channel,b
        move    b1,x0
        add     x0,a
        move    #>ym_regdata+$a0,x0
        add     x0,a
        move    a1,r2
        move    #>$7fffff,x1            ; unity unless AM-enabled
        move    y1,b
        tst     b
        jeq     rt5_am_apply_scale
        move    x:(r2),b
        jclr    #7,b1,rt5_am_apply_scale
        move    x:rt5_lfo_am_mult_ch,x1
rt5_am_apply_scale:
        ; channel-major live slot = channel*4 + logical operator
        move    x:rt5_lfo_am_channel,b
        asl     b
        asl     b
        move    x:rt5_lfo_am_op,a
        add     b,a
        move    a1,n1
        move    a1,n2
        move    #rt5_operator_gain_base_out,r1
        move    #rt5_operator_gain_out,r2
        nop
        move    x:(r1+n1),x0
        mpy     x0,x1,a
        move    a1,x:(r2+n2)
        move    #rt5_operator_gain_base_mod,r1
        move    #rt5_operator_gain_mod,r2
        nop
        move    x:(r1+n1),x0
        mpy     x0,x1,a
        move    a1,x:(r2+n2)
        move    x:rt5_lfo_am_op,b
        move    #>1,x0
        add     x0,b
        move    b1,x:rt5_lfo_am_op
        nop
rt5_am_apply_done:
        rts

rt5_am_d1r_rows:
        dc      0,16,8,24               ; logical M1,C1,M2,C2 raw row * 8

; Signed per-algorithm feedback-fold bias, tuned by the honest-fixture
; model sweep: algorithms 1-2 trade more serial depth for feedback
; accuracy, algorithm 6's carrier chain keeps its serial depth.
rt5_fold_bias:
        dc      0,1,1,0,0,0,$fffffd,0

; The playback start handler runs once per stream, so it rides the
; island; the all-carrier feedback stage it displaced stays hot.
        org     p:$28c0
; Start the production-shaped codec-rate path. Host PCM remains signed
; 16-bit on the wire and is expanded into planar 0.23 accumulators; sixteen
; 64-frame synthesis blocks fill one complete 1024-frame SSI buffer.
command_start_realtime_mixed:
        movep   #0,x:m_crb
        movep   #$4100,x:m_cra
        clr     a
        move    a1,x:ssi_frame_count
        move    a1,x:ssi_mix_probe_left
        move    a1,x:ssi_mix_probe_sum
        move    a1,x:ssi_active_buffer
        jsr     rt5_initialize_runtime
        move    #>1,a
        move    a1,x:rt5_runtime_mode

        move    #rt5_pan_left_stream,r1
        move    #rt5_pan_right_stream,r7
        jsr     rt5_receive_runtime_pcm
        move    #>rt5_pan_left_stream,a
        move    a1,x:rt5_pan_left_base
        move    #>rt5_pan_right_stream,a
        move    a1,x:rt5_pan_right_base
        move    #>ssi_buffer_a,a
        move    a1,x:rt5_runtime_output
        jsr     rt5_enter_runtime_map
        do      #DSP_RT_MIX_BLOCK_COUNT,rt5_start_blocks_done
        jsr     rt5_render_runtime_block
        nop
rt5_start_blocks_done:

        ; Retain a deterministic first-buffer checksum for the existing mix
        ; query after stop; this proves the production path rendered FM data,
        ; rather than only exercising its transport and clock state.
        move    #ssi_buffer_a,r1
        clr     a
        do      #DSP_RT_MIX_FRAME_COUNT,rt5_start_checksum_done
        move    x:(r1)+,x0
        add     x0,a
        move    x:(r1)+,x0
        add     x0,a
rt5_start_checksum_done:
        move    a1,x:ssi_mix_probe_sum

        move    #ssi_buffer_a,r6
        move    #>2047,m6
        nop
        move    x:(r6)+,a
        movep   a1,x:m_tx
        move    #>DSP_RT_MIX_FRAME_COUNT,a
        move    a1,x:ssi_frame_count
        move    #>DSP_REPLY_OK,a
        jsr     send_reply
        movep   #$5a00,x:m_crb
        jmp     ssi_stream_loop

; Channel-7 noise substitution, once per block between the write-first
; flag clear and the channel renders. When register $0f enables noise,
; operator 31's sine amplitude reads zero at decode time and this pass
; supplies ymfm's linear-attenuation noise volume instead: the value is
; ±(1023 - min(1023, TL*8 + level + AM))<<9 in 0.23 units — the exact
; compute_noise_volume law under the kernel's 2^21 amplitude convention,
; with the attenuation block-held like every other realtime control. The
; sign resamples the LFSR output bit (bit 16 of the right-shifting
; Galois form) at the decoded frequency through a 2560-per-frame DDA
; against the (freq+1)*1007 latch period, and the pass steps the LFSR
; through the 64 frames the support block skipped, so boundary dumps
; stay exactly 64 Galois steps apart. The value lands in channel 7's
; pan target: written to the common ring, whose write-first flag it
; owns when panned both (or discarded by the unset flag when unpanned,
; keeping the latch state advancing), or accumulated into a one-sided
; planar stream.
        org     p:$2900
rt5_noise_block:
        move    x:rt5_noise_threshold,a
        tst     a
        jeq     rt5_noise_block_done

        ; block-held linear attenuation for operator 31
        move    x:ym_regdata+$7f,a
        move    #>$7f,x0
        and     x0,a
        rep     #3
        asl     a
        move    x:rt5_envelope_level+31,b
        rep     #13
        lsr     b
        add     b,a
        move    x:ym_regdata+$bf,b
        jclr    #7,b1,rt5_noise_att_ready
        move    x:ym_regdata+$3f,b
        move    #>3,x0
        and     x0,b
        jeq     rt5_noise_att_ready
        move    #>1,x0
        sub     x0,b
        move    x:rt5_block_control,x1  ; published block m_lfo_am
        tst     b
        jeq     rt5_noise_am_add
        move    b1,y0
        move    x1,b
        rep     y0
        asl     b
        move    b1,x1
rt5_noise_am_add:
        add     x1,a
rt5_noise_att_ready:
        move    #>1023,x0
        cmp     x0,a
        jle     rt5_noise_att_clamped
        move    x0,a
rt5_noise_att_clamped:
        move    a1,x1
        move    x0,a
        sub     x1,a
        rep     #9
        asl     a
        move    a1,x:rt5_noise_gain

        ; loop registers: y1 = LFSR, b = latch counter, x0 = threshold,
        ; x1 = per-frame DDA step, y0 = current signed value
        move    x:rt5_noise_gain,a
        move    x:rt5_noise_state_snap,b
        jclr    #16,b1,rt5_noise_sign_ready
        neg     a
rt5_noise_sign_ready:
        move    a1,y0
        move    x:rt5_noise_lfsr,y1
        move    x:rt5_noise_counter,b
        move    x:rt5_noise_threshold,x0
        move    #>2560,x1

        ; channel 7 pan bits pick the target: bit 6 is ymfm's first
        ; output (reference left), bit 7 the second
        move    x:ym_regdata+$27,a
        jclr    #6,a1,rt5_noise_no_left
        jclr    #7,a1,rt5_noise_left_only
        move    #>1,a
        move    a1,y:rt5_mix_written
        move    #rt5_mix_ring,r1
        jsr     rt5_noise_ring_pass
        jmp     rt5_noise_state_store
rt5_noise_left_only:
        move    x:rt5_pan_left_base,r1
        jsr     rt5_noise_stream_pass
        jmp     rt5_noise_state_store
rt5_noise_no_left:
        jclr    #7,a1,rt5_noise_unpanned
        move    x:rt5_pan_right_base,r1
        jsr     rt5_noise_stream_pass
        jmp     rt5_noise_state_store
rt5_noise_unpanned:
        move    #rt5_mix_ring,r1
        jsr     rt5_noise_ring_pass
rt5_noise_state_store:
        move    y1,x:rt5_noise_lfsr
        move    b1,x:rt5_noise_counter
rt5_noise_block_done:
        rts

; Both passes advance one Galois step and the latch DDA per frame; the
; ring form writes the fresh values, the stream form accumulates them.
rt5_noise_ring_pass:
        do      #DSP_RT2_BLOCK_FRAMES,rt5_noise_ring_done
        add     x1,b
        move    y1,a
        lsr     a
        jcc     rt5_noise_ring_stepped
        move    #>$012000,x1
        eor     x1,a
        move    #>2560,x1
rt5_noise_ring_stepped:
        move    a1,y1
rt5_noise_ring_drain:
        cmp     x0,b
        jlt     rt5_noise_ring_value
        sub     x0,b
        move    x:rt5_noise_gain,a
        move    y1,x:rt5_noise_state_snap
        jclr    #16,y1,rt5_noise_ring_pos
        neg     a
rt5_noise_ring_pos:
        move    a1,y0
        jmp     rt5_noise_ring_drain
rt5_noise_ring_value:
        move    y0,y:(r1)+
rt5_noise_ring_done:
        rts

rt5_noise_stream_pass:
        do      #DSP_RT2_BLOCK_FRAMES,rt5_noise_stream_done
        add     x1,b
        move    y1,a
        lsr     a
        jcc     rt5_noise_stream_stepped
        move    #>$012000,x1
        eor     x1,a
        move    #>2560,x1
rt5_noise_stream_stepped:
        move    a1,y1
rt5_noise_stream_drain:
        cmp     x0,b
        jlt     rt5_noise_stream_value
        sub     x0,b
        move    x:rt5_noise_gain,a
        move    y1,x:rt5_noise_state_snap
        jclr    #16,y1,rt5_noise_stream_pos
        neg     a
rt5_noise_stream_pos:
        move    a1,y0
        jmp     rt5_noise_stream_drain
rt5_noise_stream_value:
        move    x:(r1),a
        add     y0,a
        move    a,x:(r1)+
rt5_noise_stream_done:
        rts

; Register $0f: noise enable in bit 7 plus the 5-bit frequency field,
; decoded to the latch period (ymfm frequency = field^$1f; the period is
; frequency+1 double-rate ticks, held in 1007ths so one codec frame adds
; 2560). Enabling mutes operator 31's decoded sine base through the same
; gain rebuild a TL write uses; disabling re-decodes the true TL.
rt5_event_decode_noise:
        move    y1,a
        move    #>$1f,x0
        and     x0,a
        eor     x0,a
        move    #>1,x0
        add     x0,a
        move    a1,x1
        move    #>1007,x0
        mpy     x0,x1,b
        asr     b
        move    b0,a
        jclr    #7,y1,rt5_noise_decode_off
        move    a1,x:rt5_noise_threshold
        move    #>31,b
        move    b1,x:rt5_env_current
        move    b1,n1
        clr     a
        move    #rt5_tl_base,r1
        nop
        move    a1,x:(r1+n1)
        jmp     rt5_env_gain_op
rt5_noise_decode_off:
        clr     a
        move    a1,x:rt5_noise_threshold
        move    #>$7f,a
        move    a1,n0
        move    #ym_regdata,r0
        move    x:ym_regdata+$7f,y1
        jmp     rt5_env_tl_event


; Clock the two OPM timers after the generated sample. Thus a period of N is
; visible in status after N clock commands, while CSM is consumed by the key
; preparation at the beginning of sample N.
        org     p:$2790
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
        clr     a                       ; one sample is the 64-clock busy time
        move    a1,x:ym_busy
        rts

        ; Keep the cold exact global-clock helpers out of the bounded low-P
        ; region now shared with the production codec-rate control path.
        org     p:$25e0
        ym_lfo_code

; -----------------------------------------------------------------------------
; Realtime envelope island
; -----------------------------------------------------------------------------
; External P aliases external Y word for word on the Falcon, so this island
; occupies the physically free window between the external-Y reservation
; (which ends at Y:$1f7f) and the envelope addends at Y:$2900. The stage-two
; generator admits P sections inside [$2000,$2900) and nothing else maps the
; phys page. Everything here runs at block boundaries or event decode time,
; so its cost is proportional to envelope activity and amortizes across the
; 1007-frame period exactly like FIFO event bursts.
        org     p:$2000

; Generated full-block affine constants, amplitude fractions, and index maps.
        include 'envtabs.inc'           ; DOS assembler requires an 8.3 name

; Cold rt5 fixtures and event-decode bodies live in the island so the
; internal-P envelope pass and the sub-$1400 program keep their room;
; every path here is event-amortized.

; Initialize persistent codec-rate state from the exact register mirror at
; the handoff boundary. Playback enters here before its first rendered sample,
; so pending ym_key_live bits recreate key edges into freshly released
; envelopes while phase and feedback begin at reset.
rt5_initialize_runtime:
        clr     b
        move    #rt5_phase,r4
        do      #32,rt5_runtime_clear_phase_done
        move    b10,l:(r4)+
rt5_runtime_clear_phase_done:
        clr     a
        move    #rt5_feedback_1,r2
        move    #rt5_feedback_0,r4
        do      #8,rt5_runtime_clear_feedback_done
        move    a1,x:(r2)+
        move    a1,y:(r4)+
rt5_runtime_clear_feedback_done:

        move    #rt5_envelope_level,r1
        move    #>$7fe000,a             ; released attenuation 1023 in 10.13
        do      #32,rt5_runtime_levels_done
        move    a1,x:(r1)+
rt5_runtime_levels_done:

        clr     a
        move    x:ssi_resample_phase,a
        move    a1,x:rt5_native_phase
        clr     a
        move    a1,x:rt5_lfo_phase
        move    a1,x:rt5_event_clock
        move    a1,x:rt5_event_read
        move    a1,x:rt5_event_count
        move    a1,x:rt5_checksum
        move    a1,x:rt5_block_control
        move    a1,x:rt5_lfo_step_block
        move    a1,x:rt5_lfo_step_tick
        move    a1,x:rt5_lfo_step_block_lo
        move    a1,x:rt5_lfo_step_tick_lo
        move    a1,y:rt5_lfo_acc_hi
        move    a1,y:rt5_lfo_acc_lo
        move    a1,x:rt5_pm_scale
        move    a1,x:rt5_lfo_amd
        move    a1,x:rt5_lfo_waveform
        move    a1,x:rt5_timer_status
        move    a1,x:rt5_am_engaged
        move    #rt5_ams_previous,r4
        do      #8,rt5_runtime_ams_previous_done
        move    a1,x:(r4)+
rt5_runtime_ams_previous_done:
        move    #>1,a
        move    a1,x:rt5_noise_lfsr
        clr     a
        move    a1,x:rt5_noise_threshold
        move    a1,x:rt5_noise_counter
        move    a1,x:rt5_noise_state_snap
        move    a1,x:rt5_noise_gain
        move    #>1024,a
        move    a1,x:rt5_timer_counter
        move    a1,x:rt5_timer_a_reload
        move    #>4096,a
        move    a1,x:rt5_timer_b_reload
        move    a1,x:rt5_timer_b_counter
        clr     a
        move    a1,x:rt5_timer_control

        move    #0,r4
        move    #>$7fffff,a
        do      #32,rt5_runtime_env_a_done
        move    a1,y:(r4)+
rt5_runtime_env_a_done:
        clr     a
        move    #rt5_env_b,r4
        move    #rt5_tl_base,r1
        move    #rt5_env_target,r2
        do      #32,rt5_runtime_env_arrays_done
        move    a1,y:(r4)+
        move    a1,x:(r1)+
        move    a1,x:(r2)+
rt5_runtime_env_arrays_done:
        move    a1,x:rt5_active_count
        move    #rt5_env_state,r1
        move    #>4,a                   ; released, inactive, unkeyed
        do      #32,rt5_runtime_env_state_done
        move    a1,x:(r1)+
rt5_runtime_env_state_done:

        ; Decode the four raw DT1/MUL rows into operator-major doubled
        ; multipliers; the pitch rebuild below reads DT1 and DT2 straight
        ; from the register image per operator.
        move    #ym_regdata+$40,r1
        move    #rt5_operator_mul,r2
        jsr     rt5_initialize_mul_row
        move    #ym_regdata+$48,r1
        move    #rt5_operator_mul+16,r2
        jsr     rt5_initialize_mul_row
        move    #ym_regdata+$50,r1
        move    #rt5_operator_mul+8,r2
        jsr     rt5_initialize_mul_row
        move    #ym_regdata+$58,r1
        move    #rt5_operator_mul+24,r2
        jsr     rt5_initialize_mul_row
        clr     a
        move    a1,x:rt5_increment_base+32

        move    #ym_regdata+$20,r1
        move    #rt5_channel_control,r2
        do      #8,rt5_runtime_controls_done
        move    x:(r1)+,a
        move    a1,x:(r2)+
rt5_runtime_controls_done:

        ; Rebuild all channel pitches through the same decoded KC path used by
        ; rolling writes after the multiplier rows are ready.
        move    #>$28,a
        move    a1,x:rt5_runtime_output
rt5_runtime_pitch_loop:
        move    x:rt5_runtime_output,a
        move    a1,n0
        move    #ym_regdata,r0
        nop
        move    x:(r0+n0),y1
        jsr     rt5_event_decode_kc
        move    x:rt5_runtime_output,a
        move    #>1,x0
        add     x0,a
        move    a1,x:rt5_runtime_output
        move    #>$30,x0
        cmp     x0,a
        jlt     rt5_runtime_pitch_loop

        ; Decode all total levels, which also builds the two initial AM gain
        ; arrays from the released envelope levels.
        move    #>$60,a
        move    a1,x:rt5_runtime_output
rt5_runtime_tl_loop:
        move    x:rt5_runtime_output,a
        move    a1,n0
        move    #ym_regdata,r0
        nop
        move    x:(r0+n0),y1
        jsr     rt5_env_tl_event
        move    x:rt5_runtime_output,a
        move    #>1,x0
        add     x0,a
        move    a1,x:rt5_runtime_output
        move    #>$80,x0
        cmp     x0,a
        jlt     rt5_runtime_tl_loop

        ; Import global LFO and timer controls. PM depth lives in ymfm's
        ; internal $1a shadow, so synthesize its bank-selecting $19 write.
        move    #ym_regdata,r0
        move    #>$18,n0
        move    x:ym_regdata+$18,y1
        jsr     rt5_decode_register
        move    #>$19,n0
        move    x:ym_regdata+$19,y1
        jsr     rt5_decode_register
        move    x:ym_regdata+$1a,a
        bset    #7,a1
        move    a1,y1
        move    #>$19,n0
        jsr     rt5_decode_register
        move    #>$1b,n0
        move    x:ym_regdata+$1b,y1
        jsr     rt5_decode_register
        move    #>$10,n0
        move    x:ym_regdata+$10,y1
        jsr     rt5_decode_register
        move    #>$11,n0
        move    x:ym_regdata+$11,y1
        jsr     rt5_decode_register
        move    #>$12,n0
        move    x:ym_regdata+$12,y1
        jsr     rt5_decode_register
        move    #>$14,n0
        move    x:ym_regdata+$14,y1
        jsr     rt5_decode_register
        move    #>$0f,n0
        move    x:ym_regdata+$0f,y1
        jsr     rt5_decode_register

        ; Recreate pending per-channel key masks from the exact live inputs.
        clr     a
        move    a1,x:rt5_runtime_output
rt5_runtime_key_loop:
        move    x:rt5_runtime_output,a
        rep     #2
        asl     a
        move    #>ym_key_live,x0
        add     x0,a
        move    a1,r1
        clr     b
        move    x:(r1)+,a
        tst     a
        jeq     rt5_runtime_key_c1
        bset    #3,b1
rt5_runtime_key_c1:
        move    x:(r1)+,a
        tst     a
        jeq     rt5_runtime_key_m2
        bset    #4,b1
rt5_runtime_key_m2:
        move    x:(r1)+,a
        tst     a
        jeq     rt5_runtime_key_c2
        bset    #5,b1
rt5_runtime_key_c2:
        move    x:(r1)+,a
        tst     a
        jeq     rt5_runtime_key_ready
        bset    #6,b1
rt5_runtime_key_ready:
        move    x:rt5_runtime_output,a
        move    a1,x0
        add     x0,b
        move    b1,y1
        move    #>$08,n0
        move    n0,a
        jsr     rt5_env_key_event
        move    x:rt5_runtime_output,a
        move    #>1,x0
        add     x0,a
        move    a1,x:rt5_runtime_output
        move    #>8,x0
        cmp     x0,a
        jlt     rt5_runtime_key_loop

        jsr     rt5_generate_noise_tables

        ; The production right PCM planes overlay expanded exact tables just
        ; like command $17. Preserve the packed source for stop-time restore.
        move    #opm_uploaded_tables,r4
        move    #rt5_packed_table_backup,r1
        do      #YM_TABLE_WORDS,rt5_runtime_backup_tables_done
        move    y:(r4)+,a
        move    a1,x:(r1)+
rt5_runtime_backup_tables_done:
        clr     a
        move    a1,x:rt5_runtime_output
        rts

rt5_initialize_mul_row:
        do      #8,rt5_initialize_mul_row_done
        move    x:(r1)+,a
        move    #>$0f,x0
        and     x0,a
        jne     rt5_initialize_mul_nonzero
        move    #>1,a
        jmp     rt5_initialize_mul_store
rt5_initialize_mul_nonzero:
        asl     a
rt5_initialize_mul_store:
        move    a1,x:(r2)+
rt5_initialize_mul_row_done:
        rts

; Fixture data consumed once at command-17 setup: eight initial channel
; control words and 32 ordered block-boundary writes covering every decoded
; register class.
; One channel per feedback level 0-7 keeps the dispatched feedback loops
; inside the measured bracket now that level 0 short-circuits to the
; feedback-less stages.
rt5_channel_control_fixture:
        dc      $000060,$0000d9,$0000ea,$000003
        dc      $00007c,$000095,$000036,$00000f
rt5_event_fixture:
        dc      $0220e1,$02219a,$02222b,$022344
        dc      $0224fd,$022516,$022677,$021433
        dc      $026010,$026933,$027255,$027b7f,$026477
        dc      $02284a,$02295d,$022a3c,$022b65
        dc      $023080,$023144
        dc      $020878,$020801,$02081a,$020863
        dc      $02801f,$02a90a,$02d205,$02fb8f
        dc      $0218c6,$0219c0,$021b02
        dc      $0212c8,$020800


        ; Apply channel-control writes directly to the mutable algorithm/pan
        ; array used by the block renderer.
rt5_event_decode_channel_control:
        move    #>$20,x0
        sub     x0,a
        move    a1,n0
        move    #rt5_channel_control,r0
        nop
        move    y1,x:(r0+n0)
        ; A feedback change moves M1's exact history-depth scale, so rebuild
        ; that operator's gain pair from its current level and total level.
        move    n0,a
        move    a1,n1                   ; M1's operator-major slot = channel
        jmp     rt5_env_gain_op

        ; DT1/MUL writes update the live multiplier in operator-major order,
        ; then rebuild all four channel increments so a mid-song voice load
        ; takes effect in the next production block. DT1 itself remains a
        ; later pitch-accuracy refinement.
rt5_event_decode_mul:
        move    n0,b
        move    #>7,x0
        and     x0,b
        move    b1,n1                   ; channel
        move    n0,a
        jclr    #4,a1,rt5_mul_no_c1
        move    #>8,x0
        add     x0,b
rt5_mul_no_c1:
        jclr    #3,a1,rt5_mul_index_ready
        move    #>16,x0
        add     x0,b
rt5_mul_index_ready:
        move    b1,n2
        move    y1,a
        move    #>$0f,x0
        and     x0,a
        jne     rt5_mul_nonzero
        move    #>1,a
        jmp     rt5_mul_store
rt5_mul_nonzero:
        asl     a
rt5_mul_store:
        move    #rt5_operator_mul,r2
        nop
        move    a1,x:(r2+n2)
        move    n1,a
        move    #>$28,x0
        add     x0,a
        move    a1,n0
        move    #ym_regdata,r0
        nop
        move    x:(r0+n0),y1
        jmp     rt5_event_decode_kc

        ; KC writes rebuild all four operator base increments for their
        ; channel from the exact expanded phase-step table, the stored KF
        ; fraction, the octave shift, and the doubled multiplier.
rt5_event_decode_kc:
        move    #>$28,x0
        sub     x0,a                    ; channel
        move    a1,n1
        move    a1,b
        move    #>$30,x0
        add     x0,b
        move    b1,n0                   ; paired KF register index
        move    y1,b                    ; b1 = key code
        nop
        move    x:(r0+n0),a
        rep     #2
        lsr     a
        move    #>$3f,x0
        and     x0,a
        move    a1,y0                   ; stored key fraction
        jmp     rt5_rebuild_channel_pitch

        ; KF writes reread the stored KC and rebuild the same four
        ; increments through the shared pitch path.
rt5_event_decode_kf:
        move    #>$30,x0
        sub     x0,a                    ; channel
        move    a1,n1
        move    a1,b
        move    #>$28,x0
        add     x0,b
        move    b1,n0                   ; paired KC register index
        move    y1,a
        rep     #2
        lsr     a
        move    #>$3f,x0
        and     x0,a
        move    a1,y0                   ; written key fraction
        move    x:(r0+n0),b             ; b1 = stored key code
        jmp     rt5_rebuild_channel_pitch

        ; DT2/D2R writes decode their envelope rate first, then rebuild the
        ; channel's four increments from the stored KC/KF because the coarse
        ; detune bits may have moved.
rt5_event_decode_dt2:
        move    n0,b
        move    #>7,x0
        and     x0,b
        move    b1,x:rt5_pitch_channel
        jsr     rt5_env_rate_event
        move    x:rt5_pitch_channel,a
        move    a1,n1                   ; channel
        move    a1,b
        move    #>$28,x0
        add     x0,b
        move    b1,n0
        move    #ym_regdata,r0
        nop
        move    x:(r0+n0),b             ; stored key code
        move    n1,a
        move    #>$30,x0
        add     x0,a
        move    a1,n0
        nop
        move    x:(r0+n0),a
        rep     #2
        lsr     a
        move    #>$3f,x0
        and     x0,a
        move    a1,y0                   ; stored key fraction

        ; Shared pitch rebuild: n1 = channel, b1 = KC, y0 = KF fraction,
        ; r0 = the register image. The gap-removed position (note row plus
        ; fraction) is shared by the channel; each operator folds its DT2
        ; coarse delta in 1/64-semitone units into that position with
        ; ymfm's single-overflow block adjust and top-entry clamp, shifts
        ; the exact 10.10 step by the octave, adds its signed DT1 delta
        ; from the keycode-indexed table, and applies the doubled
        ; multiplier before the bounded conversion into block DDA
        ; increment units.
rt5_rebuild_channel_pitch:
        move    n1,a
        move    a1,x:rt5_pitch_channel
        move    b1,a
        rep     #2
        lsr     a
        move    #>$1f,x0
        and     x0,a                    ; 5-bit keycode
        rep     #2
        asl     a
        move    a1,x:rt5_pitch_keycode4 ; DT1 table row base
        move    b1,a
        rep     #4
        lsr     a
        move    #>7,x0
        and     x0,a
        move    a1,x:rt5_pitch_block    ; octave block
        move    b1,a
        move    #>15,x0
        and     x0,a
        move    a1,x1                   ; raw note
        lsr     a
        lsr     a
        move    a1,x0
        move    x1,a
        sub     x0,a                    ; gap-removed note 0-11
        rep     #6
        asl     a
        add     y0,a                    ; 64-step row plus fraction
        move    a1,x:rt5_pitch_position
        clr     a
        move    a1,x:rt5_pitch_op

        move    #8,n2                   ; operator-major array stride
        move    #8,n3
        move    #>rt5_operator_mul,a
        move    n1,x0                   ; channel
        add     x0,a
        move    a1,r2
        move    #>rt5_increment_base,a
        add     x0,a
        move    a1,r3
        do      #4,rt5_pitch_ops_done
        ; raw register offset for this logical operator: the M1,C1,M2,C2
        ; walk maps to raw slots 0,2,1,3 as ((i&1)<<4)+((i>>1)<<3).
        move    x:rt5_pitch_op,a
        move    a1,b
        move    #>1,x0
        and     x0,a
        rep     #4
        asl     a
        lsr     b
        rep     #3
        asl     b
        add     b,a
        move    x:rt5_pitch_channel,x0
        add     x0,a
        move    a1,x:rt5_pitch_dt1      ; raw slot+channel, reused below
        move    #>$c0,x0
        add     x0,a
        move    a1,n0
        nop
        move    x:(r0+n0),a             ; DT2/D2R register
        rep     #6
        lsr     a
        move    #>3,x0
        and     x0,a
        move    a1,n1
        move    #opm_dt2_delta,r1
        nop
        move    y:(r1+n1),a             ; coarse delta, 1/64 semitone
        move    x:rt5_pitch_position,x0
        add     x0,a
        move    x:rt5_pitch_block,b
        ; With no PM in this path the position overflows at most once
        ; (767 + 608); past block 7 the exact engine reads the top table
        ; entry unshifted, which 767/7 reproduces here.
        move    #>768,x0
        cmp     x0,a
        jlt     rt5_pitch_entry_ready
        sub     x0,a
        move    #>1,x0
        add     x0,b
        move    #>8,x0
        cmp     x0,b
        jlt     rt5_pitch_entry_ready
        move    #>767,a
        move    #>7,b
rt5_pitch_entry_ready:
        move    a1,n1
        move    #opm_phase_step,r1
        move    #>7,a
        sub     b,a
        move    a1,b                    ; right-shift count = 7 - block
        move    y:(r1+n1),a             ; exact 10.10 base step
        tst     b
        jeq     rt5_pitch_step_shifted
        move    b1,x0
        rep     x0
        lsr     a
rt5_pitch_step_shifted:
        move    a1,x:rt5_pitch_step
        ; DT1: 5-bit magnitude from the packed table row keycode*4 plus the
        ; low detune bits; bit 2 selects the negative direction. The delta
        ; joins the already-shifted step, exactly like ym_step_shifted.
        move    x:rt5_pitch_dt1,a
        move    #>$40,x0
        add     x0,a
        move    a1,n0
        nop
        move    x:(r0+n0),a             ; DT1/MUL register
        rep     #4
        lsr     a
        move    #>7,x0
        and     x0,a
        move    a1,x:rt5_pitch_dt1
        move    #>3,x0
        and     x0,a
        move    x:rt5_pitch_keycode4,x0
        add     x0,a
        move    a1,n1
        jsr     ym_lookup_detune        ; x0 = magnitude; keeps a, r0
        move    x:rt5_pitch_dt1,a
        jclr    #2,a1,rt5_pitch_dt1_ready
        move    x0,a
        neg     a
        move    a1,x0
rt5_pitch_dt1_ready:
        move    x:rt5_pitch_channel,a
        move    a1,n1                   ; the lookup consumed n1
        move    x:rt5_pitch_step,a
        add     x0,a
        move    a1,y0
        move    x:(r2)+n2,x0            ; doubled multiplier
        mpy     x0,y0,b
        asr     b
        asr     b
        move    b0,a                    ; integer step * MUL
        ; Exact block-DDA conversion. The render's per-frame mac multiplies
        ; each increment by $ff and doubles, and one sine-ROM cycle spans
        ; 256*2^24 accumulator units, so the increment that reproduces the
        ; 10.10 native step at the 1280:1007 codec rate is
        ; step*MUL * 2^19/(51*1007); the scale constant carries 0.04 ppm and
        ; the pitch fixture lands within 0.05 ppm. Only tones already past
        ; the codec Nyquist wrap into the signed alias domain.
        move    #>RT5_PITCH_DDA_SCALE,x0
        move    a1,x1
        mpy     x0,x1,b                 ; step*MUL * scale, <<1
        rep     #20
        asr     b                       ; (step*MUL * scale) >> 19
        move    b0,a
        move    a1,x:(r3)+n3
        move    x:rt5_pitch_op,a
        move    #>1,x0
        add     x0,a
        move    a1,x:rt5_pitch_op
rt5_pitch_ops_done:
        rts

        ; LFO writes: $18 stores the decoded per-tick rate beside its
        ; precomputed 81-tick block product, $19 banks PM depth (bit 7 set)
        ; or AM depth, and $1b keeps the two waveform bits whose low bit
        ; flips the block PM sign.
rt5_event_decode_lfo:
        move    #>$19,x0
        cmp     x0,a
        jeq     rt5_event_decode_lfo_depth
        jgt     rt5_event_decode_lfo_waveform
        ; entered directly by the profile fixture with the rate byte in y1
rt5_lfo_rate_decode:
        move    y1,a
        move    #>15,x0
        and     x0,a
        move    #>16,x0
        add     x0,a                    ; 16 + low nibble
        move    y1,b
        rep     #4
        lsr     b
        move    b1,n0
        tst     b
        jeq     rt5_lfo_rate_shifted
        rep     n0
        asl     a
rt5_lfo_rate_shifted:
        ; The 48-bit accumulator holds ymfm's counter times 2^18, so both
        ; decoded advances become high/low pairs at that scale: the raw
        ; per-tick step shifted up, and its 81-tick block product from the
        ; doubling multiply plus seventeen more shifts.
        move    a1,x0                   ; per-tick step
        move    a,b
        rep     #18
        asl     b
        move    b1,x:rt5_lfo_step_tick
        move    b0,x:rt5_lfo_step_tick_lo
        move    #>81,y0
        mpy     x0,y0,b                 ; step * 81 * 2
        rep     #17
        asl     b
        move    b1,x:rt5_lfo_step_block
        move    b0,x:rt5_lfo_step_block_lo
        rts
rt5_event_decode_lfo_depth:
        jclr    #7,y1,rt5_lfo_amd_write
        move    y1,a
        move    #>$7f,x0
        and     x0,a
        rep     #16
        asl     a
        move    a1,x:rt5_pm_scale
        rts
rt5_lfo_amd_write:
        move    y1,a
        move    #>$7f,x0
        and     x0,a
        move    a1,x:rt5_lfo_amd
        rts
rt5_event_decode_lfo_waveform:
        move    #>$1b,x0
        cmp     x0,a
        jne     rt5_event_decode_done
        move    y1,a
        move    #>3,x0
        and     x0,a
        move    a1,x:rt5_lfo_waveform
        rts

        ; Timer writes: $10/$11 rebuild the 10-bit Timer A reload from the
        ; register mirror, $12 scales the Timer B reload by 16, and $14
        ; applies run/load bits and clears status flags. IRQ enables and CSM
        ; stay outside this gate.
rt5_event_decode_timer:
        move    #>$12,x0
        cmp     x0,a
        jeq     rt5_event_decode_timer_b
        jgt     rt5_event_decode_timer_control
        move    x:ym_regdata+$10,b
        asl     b
        asl     b
        move    x:ym_regdata+$11,a
        move    #>3,x0
        and     x0,a
        add     b,a                     ; CLKA
        move    a1,x0
        move    #>1024,a
        sub     x0,a
        move    a1,x:rt5_timer_a_reload
        rts
rt5_event_decode_timer_b:
        move    y1,x0
        move    #>256,a
        sub     x0,a
        rep     #4
        asl     a
        move    a1,x:rt5_timer_b_reload
        rts
rt5_event_decode_timer_control:
        move    #>$14,x0
        cmp     x0,a
        jne     rt5_event_decode_done
        move    y1,a
        move    #>3,x0
        and     x0,a
        move    a1,x:rt5_timer_control
        jclr    #0,y1,rt5_timer_control_no_a
        move    x:rt5_timer_a_reload,a
        move    a1,x:rt5_timer_counter
rt5_timer_control_no_a:
        jclr    #1,y1,rt5_timer_control_no_b
        move    x:rt5_timer_b_reload,a
        move    a1,x:rt5_timer_b_counter
rt5_timer_control_no_b:
        move    x:rt5_timer_status,a
        jclr    #4,y1,rt5_timer_status_no_a
        bclr    #0,a1
rt5_timer_status_no_a:
        jclr    #5,y1,rt5_timer_status_no_b
        bclr    #1,a1
rt5_timer_status_no_b:
        move    a1,x:rt5_timer_status
        rts


; Rebuild the live affine constants of rt5_env_current from its current ADSR
; state, raw rate register, and KSR-scaled keycode, leaving the effective
; rate in x:rt5_env_rate for the key-on instant-attack test. The attack
; addend is derived from its multiplier because the per-tick attack affine
; has its fixed point at exactly -1.
rt5_env_reload_op:
        move    x:rt5_env_current,b
        move    #>rt5_env_slotmap,x0
        add     x0,b
        move    b1,r3
        nop
        movem   p:(r3),a
        move    a1,x:rt5_env_slot
        move    x:rt5_env_current,b
        move    b1,n5
        move    #rt5_env_state,r5
        nop
        move    x:(r5+n5),b
        move    #>7,x0
        and     x0,b
        move    #>1,x0
        sub     x0,b
        rep     #5
        asl     b                       ; class base $80/$a0/$c0/$e0
        move    #>ym_regdata+$80,x0
        add     x0,b
        add     a,b
        move    b1,r2
        nop
        move    x:(r2),a                ; raw rate register value
        move    x:(r5+n5),b
        jset    #2,b1,rt5_env_reload_release
        move    #>$1f,x0
        and     x0,a
        jeq     rt5_env_rate_select     ; a zero raw rate ignores KSR
        asl     a
        jmp     rt5_env_rate_ksr
rt5_env_reload_release:
        move    #>$0f,x0
        and     x0,a
        rep     #2
        asl     a
        move    #>2,x0
        add     x0,a
rt5_env_rate_ksr:
        move    a1,x:rt5_env_rate
        move    x:rt5_env_slot,b
        move    #>ym_regdata+$80,x0
        add     x0,b
        move    b1,r2
        nop
        move    x:(r2),b                ; the AR register carries KS
        rep     #6
        lsr     b
        move    #>3,a
        sub     b,a                     ; ksrval shift = 3 - KS
        move    x:rt5_env_current,b
        move    a1,y0
        move    #>7,x1
        and     x1,b
        move    #>ym_regdata+$28,x1
        add     x1,b
        move    b1,r2
        nop
        move    x:(r2),b                ; channel KC register
        rep     #2
        lsr     b
        move    #>$1f,x1
        and     x1,b                    ; keycode
        move    y0,a
        tst     a
        jeq     rt5_env_ksr_shifted
        rep     y0
        lsr     b
rt5_env_ksr_shifted:
        move    x:rt5_env_rate,a
        add     b,a
        move    #>63,x0
        cmp     x0,a
        jle     rt5_env_rate_select
        move    x0,a
rt5_env_rate_select:
        move    a1,x:rt5_env_rate
        move    x:rt5_env_current,a
        move    a1,n2
        move    x:(r5+n5),b
        jset    #2,b1,rt5_env_reload_decay
        jset    #1,b1,rt5_env_reload_decay
        move    x:rt5_env_rate,b
        move    #>rt5_attack_factor,x0
        add     x0,b
        move    b1,r3
        nop
        movem   p:(r3),a
        move    #0,r2
        nop
        move    a1,y:(r2+n2)
        move    #>$800000,x0
        add     x0,a                    ; multiplier - 1.0, a negative 0.23
        rep     #10
        asr     a                       ; rescaled to the 10.13 level domain
        move    #rt5_env_b,r2
        nop
        move    a1,y:(r2+n2)
        rts
rt5_env_reload_decay:
        ; a decay entry caches its sustain-level target so the per-block
        ; boundary check avoids this register and table walk
        move    x:(r5+n5),b
        move    #>7,x0
        and     x0,b
        move    #>2,x0
        cmp     x0,b
        jne     rt5_env_reload_decay_tables
        move    x:rt5_env_slot,b
        move    #>ym_regdata+$e0,x0
        add     x0,b
        move    b1,r2
        nop
        move    x:(r2),b
        rep     #4
        lsr     b
        move    #>$0f,x0
        and     x0,b
        move    #>rt5_env_sustain,x0
        add     x0,b
        move    b1,r3
        nop
        movem   p:(r3),a
        move    #rt5_env_target,r2
        nop
        move    a1,x:(r2+n2)
rt5_env_reload_decay_tables:
        move    x:rt5_env_rate,b
        move    #>rt5_decay_step,x0
        add     x0,b
        move    b1,r3
        move    #>$7fffff,a
        move    #0,r2
        nop
        move    a1,y:(r2+n2)
        movem   p:(r3),a
        move    #rt5_env_b,r2
        nop
        move    a1,y:(r2+n2)
        rts

; Append rt5_env_current to the active list unless its active bit is set.
rt5_env_activate_op:
        move    x:rt5_env_current,b
        move    b1,n5
        move    #rt5_env_state,r5
        nop
        move    x:(r5+n5),a
        jset    #3,a1,rt5_env_activate_done
        bset    #3,a1
        move    a1,x:(r5+n5)
        move    x:rt5_active_count,a
        move    a1,n0
        move    #rt5_active_list,r0
        nop
        move    b1,x:(r0+n0)
        move    #>1,x0
        add     x0,a
        move    a1,x:rt5_active_count
rt5_env_activate_done:
        rts

; Decoded key events: data bit 3+op keys logical operator `op` of the masked
; channel. A set edge restarts the operator's attack from its current level
; with a zeroed phase; a cleared edge moves it to release. Both edges
; activate the operator; writes without an edge are ignored.
rt5_env_key_event:
        move    y1,a
        move    #>7,x0
        and     x0,a
        move    a1,x:rt5_env_current    ; operator M1 of the channel
        rep     #2
        asl     a
        move    #>rt5_phase,x0
        add     x0,a
        move    a1,x:rt5_env_key_phase  ; channel-major phase pointer
        do      #4,rt5_env_key_ops_done
        jclr    #3,y1,rt5_env_key_off
        move    x:rt5_env_current,b
        move    b1,n5
        move    #rt5_env_state,r5
        nop
        move    x:(r5+n5),b
        jset    #4,b1,rt5_env_key_next  ; already keyed: not an edge
        bset    #4,b1
        bset    #0,b1
        bclr    #1,b1
        bclr    #2,b1                   ; keyed attack
        move    b1,x:(r5+n5)
        move    x:rt5_env_key_phase,r2
        clr     a
        move    a10,l:(r2)              ; key-on resets the operator phase
        jsr     rt5_env_activate_op
        jsr     rt5_env_reload_op
        move    x:rt5_env_rate,a
        move    #>62,x0
        cmp     x0,a
        jlt     rt5_env_key_next
        move    x:rt5_env_current,b     ; instant attack at rates 62-63
        move    b1,n1
        move    #rt5_envelope_level,r1
        nop
        clr     a
        move    a1,x:(r1+n1)
        jmp     rt5_env_key_next
rt5_env_key_off:
        move    x:rt5_env_current,b
        move    b1,n5
        move    #rt5_env_state,r5
        nop
        move    x:(r5+n5),b
        jclr    #4,b1,rt5_env_key_next  ; not keyed: not an edge
        bclr    #4,b1
        bset    #2,b1
        bclr    #0,b1
        bclr    #1,b1                   ; released
        move    b1,x:(r5+n5)
        jsr     rt5_env_activate_op
        jsr     rt5_env_reload_op
rt5_env_key_next:
        move    x:rt5_env_current,a
        move    #>8,x0
        add     x0,a
        move    a1,x:rt5_env_current
        move    x:rt5_env_key_phase,a
        move    #>1,x0
        add     x0,a
        move    a1,x:rt5_env_key_phase
        move    y1,b
        lsr     b
        move    b1,y1
rt5_env_key_ops_done:
        rts

; Envelope rate classes $80-$ff: the register mirror is already updated, so
; translate the raw slot into the operator-major index and rebuild the live
; affine constants only when the write's class matches the operator's
; current ADSR state, reactivating a rate-frozen operator.
rt5_env_rate_event:
        move    n0,b
        move    #>7,x0
        and     x0,b
        move    n0,a
        jclr    #4,a1,rt5_env_rate_no_c1
        move    #>8,x0
        add     x0,b
rt5_env_rate_no_c1:
        jclr    #3,a1,rt5_env_rate_ready
        move    #>16,x0
        add     x0,b
rt5_env_rate_ready:
        move    b1,x:rt5_env_current
        move    b1,n5
        move    n0,a
        rep     #5
        lsr     a
        move    #>3,x0
        and     x0,a
        move    #>1,x0
        add     x0,a                    ; register class as ADSR state 1-4
        move    #rt5_env_state,r5
        nop
        move    x:(r5+n5),b
        move    #>7,x1
        and     x1,b
        cmp     b,a
        jeq     rt5_env_rate_reload
        ; a D1L rewrite during decay must refresh the cached sustain target
        move    #>4,x0
        cmp     x0,a
        jne     rt5_env_rate_done
        move    #>2,x0
        cmp     x0,b
        jne     rt5_env_rate_done
rt5_env_rate_reload:
        jsr     rt5_env_reload_op
        jsr     rt5_env_activate_op
rt5_env_rate_done:
        rts

; Total-level writes decode the true 7-bit TL into a 0.23 amplitude base and
; rebuild the operator's gain pair through its current envelope level.
rt5_env_tl_event:
        move    n0,b
        move    #>7,x0
        and     x0,b
        move    n0,a
        jclr    #4,a1,rt5_env_tl_no_c1
        move    #>8,x0
        add     x0,b
rt5_env_tl_no_c1:
        jclr    #3,a1,rt5_env_tl_ready
        move    #>16,x0
        add     x0,b
rt5_env_tl_ready:
        move    b1,x:rt5_env_current
        move    b1,n1
        move    y1,a
        move    #>$7f,x0
        and     x0,a
        move    a1,b
        move    #>7,x0
        and     x0,a
        move    #>rt5_tl_fraction,x0
        add     x0,a
        move    a1,r3
        rep     #3
        lsr     b                       ; octave shift count
        movem   p:(r3),a
        tst     b
        jeq     rt5_env_tl_shifted
        move    b1,x0
        rep     x0
        asr     a
rt5_env_tl_shifted:
        move    #rt5_tl_base,r1
        nop
        move    a1,x:(r1+n1)
        ; while noise owns operator 31 its sine amplitude stays muted
        move    n1,a
        move    #>31,x0
        cmp     x0,a
        jne     rt5_env_tl_gain
        move    x:rt5_noise_threshold,a
        tst     a
        jeq     rt5_env_tl_gain
        clr     a
        move    a1,x:(r1+n1)
rt5_env_tl_gain:
        jsr     rt5_env_gain_op
        rts

        ; Generated program-memory noise jump tables and external-Y exact
        ; renderer reservations. No P code follows this include.
        include 'ymtables.inc'          ; DOS assembler requires an 8.3 name

; Uninitialized external X RAM does not consume TOS's converted .LOD budget.
; Each aligned buffer holds one interleaved 1007-frame stereo period. Modulo
; addressing loops the active block while the other is rendered and swapped.
        org     x:$1000
ssi_buffer_a:
        ds      2048

        org     x:$1800
ssi_buffer_b:
        ds      2048

        end
