; F030MXDRV YM2151 DSP scaffold
;
; This first program establishes the transport, MAME-aligned register behavior,
; and the exact OPM phase-step calculation. Envelope/operator synthesis and SSI
; output are intentionally staged next.

        include 'ioequ.inc'
        include 'protocol.inc'
        include 'ymtables.inc'          ; DOS assembler requires an 8.3 name

; -----------------------------------------------------------------------------
; Bootstrap vector
; -----------------------------------------------------------------------------

        org     p:$0
        jmp     start

; -----------------------------------------------------------------------------
; YM2151 state in X memory
; -----------------------------------------------------------------------------

        org     x:$0

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

; -----------------------------------------------------------------------------
; Program
; -----------------------------------------------------------------------------

        org     p:$40

start:
        movep   #1,x:m_pbc              ; enable the Falcon host port
        move    #>-1,m0                 ; linear addressing for ym_regdata
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

        move    #>DSP_CMD_QUERY_PHASE,x0
        cmp     x0,a
        jeq     command_query_phase

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

command_query_phase:
        jsr     ym_query_phase_step
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

ym_write_done:
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

        end
