; F030MXDRV YM2151 DSP core
;
; The register, phase, envelope, algorithm, feedback, panning, and YM3012
; behavior here follows the vendored MAME/ymfm core. LFO, noise, timers, and
; continuous SSI output are layered on top of this command-clocked kernel.

        include 'ioequ.inc'
        include 'protocol.inc'

; -----------------------------------------------------------------------------
; Bootstrap vector
; -----------------------------------------------------------------------------

        org     p:$0
        jmp     start

; -----------------------------------------------------------------------------
; YM2151 state in X memory
; -----------------------------------------------------------------------------

        org     x:$200

ym_regdata:
        ds      256

last_command:
        dc      0

query_channel:
        dc      0
query_raw_operator:
        dc      0
query_block_freq:
        dc      0
query_block:
        dc      0
query_dtmul:
        dc      0
query_detune:
        dc      0

; Operator state uses logical per-channel order M1,C1,M2,C2. Phases are the
; native 10.10 ymfm values; modulo-24-bit storage preserves the low 10 waveform
; bits across wraparound.
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

ym_env_counter:
        dc      0
ym_env_tick:
        dc      0
ym_last_left:
        dc      0
ym_last_right:
        dc      0

; Scratch state. Keeping it explicit makes subroutine register clobbers safe
; and leaves the protocol probes useful while the real-time loop evolves.
synth_index:
        dc      0
synth_channel:
        dc      0
synth_operator:
        dc      0
synth_rate:
        dc      0
synth_increment:
        dc      0
synth_algorithm:
        dc      0
synth_result:
        dc      0
volume_phase:
        dc      0
volume_sign:
        dc      0
volume_envelope:
        dc      0
volume_sine:
        dc      0

synth_opout:
        ds      8

table_remaining:
        dc      0
table_packed:
        dc      0
table_slots:
        dc      0
table_current:
        dc      0

; -----------------------------------------------------------------------------
; Program
; -----------------------------------------------------------------------------

        org     p:$40

start:
        movep   #1,x:m_pbc              ; enable the Falcon host port
        move    #>-1,m0                 ; linear addressing for ym_regdata
        jsr     ym_expand_tables
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

        move    #>DSP_REPLY_ERROR,a
        jsr     send_reply
        jmp     command_loop

command_ping:
        move    #>DSP_REPLY_HELLO,a
        jsr     send_reply
        jmp     command_loop

command_write:
        jsr     ym_write_packed
        move    #>DSP_REPLY_OK,a
        jsr     send_reply
        jmp     command_loop

command_reset:
        jsr     ym_reset
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

; Send a single 24-bit reply from a1.
send_reply:
        jclr    #1,x:m_hsr,*            ; wait for host transmit data empty
        movep   a1,x:m_htx
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

        tst     a
        jeq     ym_query_raw_m1
        move    #>1,x0
        cmp     x0,a
        jeq     ym_query_raw_c1
        move    #>2,x0
        cmp     x0,a
        jeq     ym_query_raw_m2
        move    #>24,a
        jmp     ym_query_raw_add_channel
ym_query_raw_m1:
        clr     a
        jmp     ym_query_raw_add_channel
ym_query_raw_c1:
        move    #>16,a
        jmp     ym_query_raw_add_channel
ym_query_raw_m2:
        move    #>8,a
ym_query_raw_add_channel:
        move    x:query_channel,x0
        add     x0,a
        move    a1,x:query_raw_operator

        jmp     ym_compute_phase_step

; Common phase-step kernel. query_channel and query_raw_operator must already
; identify the selected logical operator.
ym_compute_phase_step:

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

        ; Preserve the octave/block for the table shift.
        rep     #10
        lsr     a
        move    #>7,y0
        and     y0,a1
        move    a1,x:query_block

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
        ; then add the coarse detune delta.
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

        ; With PM disabled, DT2 can overflow by at most one octave.
        move    #>768,x0
        cmp     x0,a
        jlt     ym_query_eff_ready
        sub     x0,a
        move    x:query_block,b
        move    #>7,x0
        cmp     x0,b
        jge     ym_query_phase_clamp
        move    #>1,x0
        add     x0,b
        move    b1,x:query_block

ym_query_eff_ready:
        move    a1,n1
        move    #opm_phase_step,r1
        nop
        move    y:(r1+n1),a

        ; Shift the base step down according to the octave: block XOR 7.
        move    #>7,b
        move    x:query_block,x0
        sub     x0,b
        tst     b
        jeq     ym_query_phase_shifted
        move    b1,x0
        do      x0,ym_query_phase_shift_loop
        lsr     a
ym_query_phase_shift_loop:
        jmp     ym_query_phase_shifted

ym_query_phase_clamp:
        move    #opm_phase_step+767,r1
        nop
        move    y:(r1),a

ym_query_phase_shifted:
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
        move    #opm_detune_adjustment,r1
        nop
        move    y:(r1+n1),x0

        ; DT1 bit 2 selects negative detune.
        move    x:query_detune,b
        jclr    #2,b1,ym_query_detune_positive
        move    x0,b
        neg     b
        move    b1,x0
ym_query_detune_positive:
        add     x0,a

        ; The multiplier is stored as x.1: zero means 0.5, otherwise MUL*1.
        move    x:query_dtmul,b
        move    #>$0f,y0
        and     y0,b1
        tst     b
        jeq     ym_query_multiple_half
        asl     b
        move    b1,y0
        jmp     ym_query_apply_multiple
ym_query_multiple_half:
        move    #>1,y0

ym_query_apply_multiple:
        move    a1,x0
        clr     b
        do      y0,ym_query_multiple_loop
        add     x0,b
ym_query_multiple_loop:
        lsr     b
        move    b1,a
        rts

ym_query_error:
        move    #>DSP_REPLY_ERROR,a
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
        move    #>6,a
        move    a1,x:table_slots
ym_expand_phase_nibble:
        move    x:table_remaining,a
        tst     a
        jeq     ym_expand_envelope_start
        move    x:table_packed,a
        move    #>$0f,y0
        and     y0,a1
        rep     #5
        asl     a
        move    x:table_current,x0
        add     x0,a
        move    a1,x:table_current
        move    a1,y:(r0)+

        move    x:table_packed,a
        rep     #4
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
        jeq     ym_expand_done
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
        jeq     ym_expand_done
        move    x:table_slots,a
        move    #>1,x0
        sub     x0,a
        move    a1,x:table_slots
        jne     ym_expand_envelope_nibble
        jmp     ym_expand_envelope_word
ym_expand_done:
        rts

; Convert synth_index (channel*4 + logical operator) to the channel and raw OPM
; register slot used by ymfm: M1,C1,M2,C2 = +0,+16,+8,+24.
ym_select_operator:
        move    x:synth_index,a
        move    a1,b
        rep     #2
        lsr     a
        move    a1,x:query_channel
        move    a1,x:synth_channel

        move    b1,a
        move    #>3,y0
        and     y0,a1
        move    a1,x:synth_operator
        tst     a
        jeq     ym_select_m1
        move    #>1,x0
        cmp     x0,a
        jeq     ym_select_c1
        move    #>2,x0
        cmp     x0,a
        jeq     ym_select_m2
        move    #>24,a
        jmp     ym_select_add_channel
ym_select_m1:
        clr     a
        jmp     ym_select_add_channel
ym_select_c1:
        move    #>16,a
        jmp     ym_select_add_channel
ym_select_m2:
        move    #>8,a
ym_select_add_channel:
        move    x:query_channel,x0
        add     x0,a
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
        do      x0,ym_rate_ksr_shift
        lsr     a
ym_rate_ksr_shift:
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
        do      x0,ym_env_mask_shift
        asl     a
ym_env_mask_shift:
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
        do      x0,ym_env_index_shift
        lsr     a
ym_env_index_shift:
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
        tst     b
        jeq     ym_env_done

        move    #ym_envelope,r0
        nop
        move    x:(r0+n0),a
        not     a
        move    a1,x0
        clr     a
        move    b1,y0
        do      y0,ym_env_attack_multiply
        add     x0,a
ym_env_attack_multiply:
        rep     #4
        asr     a
        move    x:(r0+n0),b
        move    b1,y1
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
        do      y0,ym_volume_power_shift
        lsr     a
ym_volume_power_shift:
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
ym_output_channel:
        move    x:synth_channel,a
        rep     #2
        asl     a
        move    a1,x:synth_index

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
        do      y0,ym_output_feedback_shift
        asr     a
ym_output_feedback_shift:
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
        jsr     ym_compute_volume
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
        do      y0,ym_roundtrip_mask_shift
        asl     a
ym_roundtrip_mask_shift:
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
        clr     a
        move    a1,x:synth_index
ym_clock_phase_loop:
        jsr     ym_select_operator
        jsr     ym_compute_phase_step
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
        rts

        include 'ymtables.inc'          ; DOS assembler requires an 8.3 name

        end
