; F030MXDRV physical-Falcon SSI rate measurement
;
; Standalone hardware-validation program. It boots a tiny polled DSP frame
; counter (src/dsp/ratetest.asm), routes the DSP transmitter to the DAC, and
; measures the delivered SSI frame rate against the TOS 200 Hz system tick
; for crossbar prescales 3, 1, and 2. Each window opens and closes on a
; fresh tick edge, so the resolution is limited by XBIOS call jitter, not by
; the 5 ms tick period.
;
; This measures exactly what Hatari approximates: whether the crossbar
; clocks the SSI at all at each prescale, and whether the delivered rate
; matches the 25,175,000 / 256 / (prescale+1) Hz model the production
; player assumes (24,584.9609375 Hz at prescale 3).
;
; The first run on a physical Falcon030 (2026-09-02) counted no frames at
; any prescale with the bare bring-up (Locksnd, Setmode, Settracks,
; Dsptristate, Devconnect), while the production player plays through the
; same route. The player differs in five things: it stops inherited DMA
; playback, resets the converters, selects the matrix as the adder input,
; pins the monitor track pair, and only arms its transmitter after
; Devconnect. So before measuring, this program now bisects the bring-up:
; it applies those steps one at a time, cumulatively, and probes each state
; for one second at prescale 3, printing the DSP's counters and status
; register and the crossbar registers as TOS left them. The first state that
; delivers a clock is the one the measurements then run in. Under Hatari the
; bare state already clocks, so the emulator gate is unchanged.
;
; Results are printed as deterministic PASS/FAIL lines and duplicated in
; RATETEST.TXT beside the program, so a real-Falcon run can be reported as
; one file or photo.

        include "xbios.i"

        global  start

; Keep the command words in sync with src/dsp/ratetest.asm.
RT_CMD_PING        equ $010000
RT_CMD_READ_FRAMES equ $020000
RT_CMD_READ_UNDER  equ $030000
RT_CMD_RESET       equ $040000
RT_CMD_READ_WORDS  equ $050000
RT_CMD_SSI_RESTART equ $060000
RT_CMD_READ_SR     equ $070000
RT_REPLY_PING      equ $524154            ; "RAT"

SOUND_STEREO16  equ 1
SOUND_DSP_XMIT  equ 1
SOUND_DAC       equ 8
SOUND_CLK25M    equ 0
SOUND_NO_SHAKE  equ 1
SOUND_LTATTEN   equ 0
SOUND_RTATTEN   equ 1
SOUND_ADDERIN   equ 4
SOUND_MATRIXIN  equ 2
SOUND_MONPAIR0  equ 0
SOUND_DMA_STOP  equ 0
SNDSTAT_RESET   equ 1
DSP_ABILITY     equ 3

HZ200           equ $4ba                  ; TOS 200 Hz tick (supervisor only)

; Measurement window per prescale. Keep the "(10 s)" console text in sync
; with RATE_MEASURE_TICKS.
RATE_SETTLE_TICKS  equ 40                 ; 200 ms after each Devconnect
RATE_MEASURE_TICKS equ 2000               ; 10 s
RATE_PROBE_TICKS   equ 200                ; 1 s per bring-up phase

; Append the NUL-terminated fragment to the line being built at (a0)+.
        macro   FSTR fragment
        lea     \1,a1
        bsr     fmt_string
        endm

        text

start:
        move.l  #results_buffer,results_ptr
        Cconws  banner

        ; Every blocking bring-up step prints its label first, so a hang on
        ; real hardware leaves a dangling label naming the call.
        Cconws  txt_reserve
        Dsp_Reserve #16,#16
        tst.l   d0
        bmi     reserve_failed
        Cconws  txt_ok

        Cconws  txt_boot
        Dsp_ExecBoot ratetest_boot_image,#RATETEST_BOOT_WORDS,#DSP_ABILITY
        Cconws  txt_ok

        Cconws  txt_ping
        move.l  #RT_CMD_PING,d0
        bsr     dsp_exchange
        cmp.l   #RT_REPLY_PING,d0
        bne     ping_failed
        Cconws  txt_ok

        Cconws  txt_sound
        Locksnd
        cmpi.l  #1,d0
        bne     sound_failed
        Cconws  txt_ok

        lea     line_buffer,a0
        FSTR    txt_header1
        bsr     line_done
        bsr     emit_line
        lea     line_buffer,a0
        FSTR    txt_header2
        bsr     line_done
        bsr     emit_line
        lea     line_buffer,a0
        FSTR    txt_header3
        bsr     line_done
        bsr     emit_line

        ; the sound matrix as this program inherits it, before it touches
        ; anything: what the desktop and the previous program left behind
        Supexec read_regs
        lea     line_buffer,a0
        FSTR    txt_inherited
        bsr     fmt_regs
        bsr     line_done
        bsr     emit_line

        ; bisect the bring-up: every phase adds one step to the state the
        ; previous phases left, then probes prescale 3 for one second
        clr.w   restart_flag
        clr.w   tristate_rec
        clr.w   phase_found
        lea     phase_table,a6
phase_loop:
        move.l  (a6)+,d0               ; phase routine, or 0 terminator
        beq     phases_done
        movea.l d0,a4
        movea.l (a6)+,a3               ; phase name
        move.l  (a6)+,d0
        or.w    d0,restart_flag        ; steps accumulate
        move.l  (a6)+,d0
        or.w    d0,tristate_rec
        bsr     probe_phase
        tst.l   d0
        beq     phase_loop
        move.w  #1,phase_found
phases_done:
        tst.w   phase_found
        beq     no_clock_at_all

        ; measure in the state the first clocking phase left behind
        lea     run_table,a6
run_loop:
        move.l  (a6)+,d7               ; prescale, or -1 terminator
        bmi     runs_done
        move.l  (a6)+,d6               ; expected rate in mHz
        bsr     measure_one
        bra     run_loop
runs_done:
        bra     summary

no_clock_at_all:
        addq.w  #1,fail_count
        lea     line_buffer,a0
        FSTR    txt_no_phase
        bsr     line_done
        bsr     emit_line

summary:
        lea     line_buffer,a0
        tst.w   fail_count
        bne     summary_fail
        FSTR    txt_result_pass
        moveq   #0,d0
        move.w  run_count,d0
        bsr     fmt_u32
        FSTR    txt_runs_suffix
        bra     summary_done
summary_fail:
        FSTR    txt_result_fail
        moveq   #0,d0
        move.w  fail_count,d0
        bsr     fmt_u32
        FSTR    txt_of
        moveq   #0,d0
        move.w  run_count,d0
        bsr     fmt_u32
        FSTR    txt_failed_suffix
summary_done:
        bsr     line_done
        bsr     emit_line

        bsr     write_results

        Dsptristate #0,#0
        Unlocksnd
exit_with_dsp:
        Dsp_Unlock
        bsr     wait_exit_key
        Pterm0

reserve_failed:
        Cconws  txt_failedline
        bsr     wait_exit_key
        Pterm0

ping_failed:
        Cconws  txt_failedline
        bra     exit_with_dsp

sound_failed:
        Cconws  txt_failedline
        bra     exit_with_dsp

; ---------------------------------------------------------------------------
; Bring-up phases. Each routine applies one more step; the connection itself
; (Dsptristate, Devconnect, optional transmitter re-arm) is shared and driven
; by the flags the phase table sets.
; ---------------------------------------------------------------------------

; A: the bare sequence the first hardware run used
phase_bare:
        Setmode #SOUND_STEREO16
        Settracks #0,#0
        rts

; B: re-arm the DSP transmitter after Devconnect (flag only)
; C: connect the DSP receiver as well (flag only)
phase_flag_only:
        rts

; D: pin the DAC monitor pair to frame slots 0 and 1
phase_montracks:
        Setmontracks #SOUND_MONPAIR0
        rts

; E: the adder takes the matrix, not the A/D converter
phase_adderin:
        Soundcmd #SOUND_ADDERIN,#SOUND_MATRIXIN
        rts

; F: stop inherited DMA playback
phase_buffoper:
        Buffoper #SOUND_DMA_STOP
        rts

; G: the production player's full pinning: reset the converters, unmute,
; and restate the mode, tracks and monitor pair on top of it
phase_sndreset:
        Sndstatus #SNDSTAT_RESET
        Soundcmd #SOUND_LTATTEN,#0
        Soundcmd #SOUND_RTATTEN,#0
        Setmode #SOUND_STEREO16
        Settracks #0,#0
        Setmontracks #SOUND_MONPAIR0
        rts

; Connect the DSP transmitter to the DAC at the prescale in d7, honouring
; the accumulated flags.
route_connect:
        Dsptristate #1,tristate_rec
        Devconnect #SOUND_DSP_XMIT,#SOUND_DAC,#SOUND_CLK25M,d7,#SOUND_NO_SHAKE
        tst.w   restart_flag
        beq     .done
        move.l  #RT_CMD_SSI_RESTART,d0
        bsr     dsp_exchange
.done:
        rts

; Probe one bring-up phase for RATE_PROBE_TICKS at prescale 3.
; in:  a4 = phase routine, a3 = phase name, flags set
; out: d0.l = frames counted in the window (0 = no clock)
probe_phase:
        jsr     (a4)
        moveq   #3,d7
        bsr     route_connect
        move.l  #RT_CMD_RESET,d0
        bsr     dsp_exchange
        bsr     settle
        bsr     wait_tick_edge
        move.l  d0,meas_t0
        lea     meas_c0,a5
        bsr     read_counters
.window:
        bsr     get_ticks
        sub.l   meas_t0,d0
        cmpi.l  #RATE_PROBE_TICKS,d0
        bcs     .window
        lea     meas_c1,a5
        bsr     read_counters
        move.l  #RT_CMD_READ_SR,d0
        bsr     dsp_exchange
        move.l  d0,meas_sr
        Supexec read_regs
        bsr     counter_deltas

        lea     line_buffer,a0
        FSTR    txt_phase
        movea.l a3,a1
        bsr     fmt_string
        FSTR    txt_frames
        move.l  meas_frames,d0
        bsr     fmt_u32
        FSTR    txt_words
        move.l  meas_words,d0
        bsr     fmt_u32
        FSTR    txt_ssisr
        move.l  meas_sr,d0
        bsr     fmt_hex8
        tst.l   meas_frames
        beq     .dead
        FSTR    txt_clock_present
        bra     .lined
.dead:
        FSTR    txt_no_clock
.lined:
        bsr     line_done
        bsr     emit_line

        lea     line_buffer,a0
        FSTR    txt_regs
        bsr     fmt_regs
        bsr     line_done
        bsr     emit_line

        move.l  meas_frames,d0
        rts

; Measure one crossbar prescale.
; in: d7.l = prescale, d6.l = expected rate in mHz
measure_one:
        addq.w  #1,run_count

        ; console-only progress marker; the window itself is silent
        lea     line_buffer,a0
        FSTR    txt_measuring
        move.l  d7,d0
        bsr     fmt_u32
        FSTR    txt_measuring2
        bsr     line_done
        Cconws  line_buffer

        bsr     route_connect
        move.l  #RT_CMD_RESET,d0
        bsr     dsp_exchange
        bsr     settle

        ; open the window on a fresh tick edge, then snapshot the DSP
        ; counters; the snapshot latency is identical at open and close, so
        ; it cancels out of the rate
        bsr     wait_tick_edge
        move.l  d0,meas_t0
        lea     meas_c0,a5
        bsr     read_counters

.window:
        bsr     get_ticks
        move.l  d0,d1
        sub.l   meas_t0,d1
        cmpi.l  #RATE_MEASURE_TICKS,d1
        bcs     .window
        move.l  d0,meas_t1
        lea     meas_c1,a5
        bsr     read_counters
        bsr     counter_deltas
        move.l  meas_t1,d3
        sub.l   meas_t0,d3
        move.l  d3,meas_ticks

        ; rate in mHz = frames * 1000 * 200 / ticks; the 64-bit product
        ; stays far below 2^63 and the quotient far below 2^32
        move.l  meas_frames,d0
        beq     .dead
        mulu.l  #200000,d1:d0
        divu.l  d3,d1:d0
        move.l  d0,meas_rate

        lea     line_buffer,a0
        FSTR    txt_prescale
        move.l  d7,d0
        bsr     fmt_u32
        FSTR    txt_frames
        move.l  meas_frames,d0
        bsr     fmt_u32
        FSTR    txt_ticks
        move.l  meas_ticks,d0
        bsr     fmt_u32
        FSTR    txt_measured
        move.l  meas_rate,d0
        bsr     fmt_millihertz
        FSTR    txt_expected
        move.l  d6,d0
        bsr     fmt_millihertz
        FSTR    txt_hz

        ; verdict: within 0.1 percent of the model and no missed word slots.
        ; The tolerance is wide against crystal variance (about 100 ppm) but
        ; narrow against every wrong-divider or wrong-clock-source outcome.
        move.l  meas_rate,d0
        sub.l   d6,d0
        bpl     .absdone
        neg.l   d0
.absdone:
        move.l  d6,d2
        moveq   #0,d1
        divu.l  #1000,d1:d2
        cmp.l   d2,d0
        bhi     .fail
        tst.l   meas_under
        bne     .fail
        FSTR    txt_pass
        bra     .lined
.fail:
        addq.w  #1,fail_count
        FSTR    txt_fail
.lined:
        bsr     line_done
        bsr     emit_line

        ; underruns are a distinct diagnostic: the polled DSP loop missed
        ; word slots, so the frame count itself is unreliable
        move.l  meas_under,d0
        beq     .no_underruns
        lea     line_buffer,a0
        FSTR    txt_underruns
        move.l  meas_under,d0
        bsr     fmt_u32
        bsr     line_done
        bsr     emit_line
.no_underruns:
        rts

.dead:
        addq.w  #1,fail_count
        lea     line_buffer,a0
        FSTR    txt_prescale
        move.l  d7,d0
        bsr     fmt_u32
        FSTR    txt_dead
        bsr     line_done
        bsr     emit_line
        rts

; Snapshot the three DSP counters into (a5)+: frames, underruns, words.
read_counters:
        move.l  #RT_CMD_READ_FRAMES,d0
        bsr     dsp_exchange
        move.l  d0,(a5)+
        move.l  #RT_CMD_READ_UNDER,d0
        bsr     dsp_exchange
        move.l  d0,(a5)+
        move.l  #RT_CMD_READ_WORDS,d0
        bsr     dsp_exchange
        move.l  d0,(a5)+
        rts

; 24-bit modular deltas of the two snapshots into meas_frames, meas_under
; and meas_words.
counter_deltas:
        move.l  meas_c1,d0
        sub.l   meas_c0,d0
        andi.l  #$00ffffff,d0
        move.l  d0,meas_frames
        move.l  meas_u1,d0
        sub.l   meas_u0,d0
        andi.l  #$00ffffff,d0
        move.l  d0,meas_under
        move.l  meas_w1,d0
        sub.l   meas_w0,d0
        andi.l  #$00ffffff,d0
        move.l  d0,meas_words
        rts

; Let a new connection settle before a window opens.
settle:
        movem.l d0/d3,-(sp)
        bsr     get_ticks
        move.l  d0,d3
.settle:
        bsr     get_ticks
        sub.l   d3,d0
        cmpi.l  #RATE_SETTLE_TICKS,d0
        bcs     .settle
        movem.l (sp)+,d0/d3
        rts

; Exchange one packed 24-bit word with the DSP.
; in:  d0.l = command   out: d0.l = reply
dsp_exchange:
        movem.l d1-d7/a0-a6,-(sp)
        move.l  d0,dsp_tx_word
        clr.l   dsp_rx_word
        Dsp_BlkUnpacked dsp_tx_word,#1,dsp_rx_word,#1
        move.l  dsp_rx_word,d0
        movem.l (sp)+,d1-d7/a0-a6
        rts

; Current 200 Hz tick in d0.l; the trap may clobber d1-d2/a0-a2.
get_ticks:
        Supexec read_hz200
        rts
read_hz200:
        move.l  HZ200.w,d0
        rts

; Snapshot the sound matrix registers into reg_buffer (supervisor only):
; DMA control, sound mode, source and destination routing, the two
; prescalers, and the record track / codec input selects.
read_regs:
        lea     reg_buffer,a0
        move.w  $ffff8900.w,(a0)+
        move.w  $ffff8920.w,(a0)+
        move.w  $ffff8930.w,(a0)+
        move.w  $ffff8932.w,(a0)+
        move.w  $ffff8934.w,(a0)+
        move.w  $ffff8936.w,(a0)+
        rts

; Spin until the tick advances; d0.l returns the fresh tick value.
wait_tick_edge:
        move.l  d3,-(sp)
        bsr     get_ticks
        move.l  d0,d3
.spin:
        bsr     get_ticks
        cmp.l   d3,d0
        beq     .spin
        move.l  (sp)+,d3
        rts

; Print the NUL-terminated line_buffer and append it to the results image.
emit_line:
        movem.l d0-d2/a0-a2,-(sp)
        Cconws  line_buffer
        lea     line_buffer,a1
        movea.l results_ptr,a0
.copy:
        move.b  (a1)+,d0
        beq     .done
        cmpa.l  #results_buffer_end,a0
        bcc     .done
        move.b  d0,(a0)+
        bra     .copy
.done:
        move.l  a0,results_ptr
        movem.l (sp)+,d0-d2/a0-a2
        rts

; Append the NUL-terminated fragment at a1 to (a0)+; the NUL is not copied
; and a1 is left just past it.
fmt_string:
.copy:
        move.b  (a1)+,(a0)+
        bne     .copy
        subq.l  #1,a0
        rts

; Append the register snapshot as " 8900=xxxx 8920=xxxx ..." at (a0)+.
fmt_regs:
        movem.l d0-d2/a1-a2,-(sp)
        lea     reg_buffer,a2
        lea     reg_names,a1
        moveq   #6-1,d2
.reg:
        move.b  #' ',(a0)+
        bsr     fmt_string
        moveq   #0,d0
        move.w  (a2)+,d0
        bsr     fmt_hex16
        dbf     d2,.reg
        movem.l (sp)+,d0-d2/a1-a2
        rts

; Append d0.l as unsigned decimal at (a0)+.
fmt_u32:
        movem.l d0-d2,-(sp)
        moveq   #0,d2
.digit:
        moveq   #0,d1
        divu.l  #10,d1:d0
        addq.w  #1,d2
        move.w  d1,-(sp)
        tst.l   d0
        bne     .digit
.emit:
        move.w  (sp)+,d1
        addi.b  #'0',d1
        move.b  d1,(a0)+
        subq.w  #1,d2
        bne     .emit
        movem.l (sp)+,d0-d2
        rts

; Append the low 16 bits of d0.l as four hex digits at (a0)+.
fmt_hex16:
        movem.l d0-d2,-(sp)
        moveq   #4,d2
        swap    d0
        bra     fmt_hex_digits
; Append the low 8 bits of d0.l as two hex digits at (a0)+.
fmt_hex8:
        movem.l d0-d2,-(sp)
        moveq   #2,d2
        swap    d0
        rol.l   #8,d0
fmt_hex_digits:
        rol.l   #4,d0
        move.b  d0,d1
        andi.b  #$0f,d1
        cmpi.b  #10,d1
        bcs     .digit
        addi.b  #39,d1                   ; lowercase a-f
.digit:
        addi.b  #'0',d1
        move.b  d1,(a0)+
        subq.w  #1,d2
        bne     fmt_hex_digits
        movem.l (sp)+,d0-d2
        rts

; Append d0.l millihertz as "NNNNN.NNN" at (a0)+.
fmt_millihertz:
        movem.l d0-d1,-(sp)
        moveq   #0,d1
        divu.l  #1000,d1:d0
        bsr     fmt_u32
        move.b  #'.',(a0)+
        move.l  d1,d0
        bsr     fmt_u32_pad3
        movem.l (sp)+,d0-d1
        rts

; Append d0.l (0-999) as exactly three digits at (a0)+.
fmt_u32_pad3:
        movem.l d0-d1,-(sp)
        divu.w  #100,d0
        move.b  d0,d1
        addi.b  #'0',d1
        move.b  d1,(a0)+
        clr.w   d0
        swap    d0
        divu.w  #10,d0
        move.b  d0,d1
        addi.b  #'0',d1
        move.b  d1,(a0)+
        swap    d0
        move.b  d0,d1
        addi.b  #'0',d1
        move.b  d1,(a0)+
        movem.l (sp)+,d0-d1
        rts

; Terminate the line at (a0) with CRLF and NUL.
line_done:
        move.b  #13,(a0)+
        move.b  #10,(a0)+
        clr.b   (a0)
        rts

; Write the accumulated report beside the program.
write_results:
        movem.l d4-d5,-(sp)
        Fcreate txt_filename,#0
        tst.l   d0
        bmi     .done
        move.w  d0,d4
        move.l  results_ptr,d5
        sub.l   #results_buffer,d5
        Fwrite  d4,d5,results_buffer
        Fclose  d4
.done:
        movem.l (sp)+,d4-d5
        rts

; Discard any buffered key, then require a fresh keypress so the report
; stays visible on a real Falcon desktop.
wait_exit_key:
.drain:
        Cconis
        tst.l   d0
        beq     .wait
        Cconin
        bra     .drain
.wait:
        Cconws  txt_exit
        Cconin
        rts

        data

banner:
        dc.b    13,10,'F030MXDRV SSI rate test',13,10
        dc.b    '=======================',13,10,0
txt_reserve:       dc.b 'DSP reserve ..... ',0
txt_boot:          dc.b 'DSP boot ........ ',0
txt_ping:          dc.b 'DSP ping ........ ',0
txt_sound:         dc.b 'sound lock ...... ',0
txt_ok:            dc.b 'ok',13,10,0
txt_failedline:    dc.b 'FAILED',13,10,0
txt_header1:       dc.b 'timebase: TOS 200 Hz tick; 10 s window per prescale',0
txt_header2:       dc.b 'model: rate = 25175000 / 256 / (prescale+1) Hz',0
txt_header3:       dc.b 'bring-up phases: each adds one step, probed 1 s at prescale 3',0
txt_inherited:     dc.b 'inherited regs',0
txt_phase:         dc.b 'phase ',0
txt_words:         dc.b '  words ',0
txt_ssisr:         dc.b '  ssisr $',0
txt_clock_present: dc.b '  clock present',0
txt_no_clock:      dc.b '  no clock',0
txt_regs:          dc.b '  regs',0
txt_no_phase:      dc.b 'no bring-up phase delivered an SSI clock  FAIL',0
txt_measuring:     dc.b 'measuring prescale ',0
txt_measuring2:    dc.b ' (10 s) ...',0
txt_prescale:      dc.b 'prescale ',0
txt_frames:        dc.b ': frames ',0
txt_ticks:         dc.b '  ticks ',0
txt_measured:      dc.b '  measured ',0
txt_expected:      dc.b ' Hz  expected ',0
txt_hz:            dc.b ' Hz  ',0
txt_pass:          dc.b 'PASS',0
txt_fail:          dc.b 'FAIL',0
txt_dead:          dc.b ': no SSI frames in the window (crossbar clock dead)  FAIL',0
txt_underruns:     dc.b '  warning: DSP missed word slots, underruns ',0
txt_result_pass:   dc.b 'RESULT: PASS (',0
txt_runs_suffix:   dc.b ' runs)',0
txt_result_fail:   dc.b 'RESULT: FAIL (',0
txt_of:            dc.b ' of ',0
txt_failed_suffix: dc.b ' runs failed)',0
txt_filename:      dc.b 'RATETEST.TXT',0
txt_exit:          dc.b 13,10,'press any key to exit',13,10,0

; Register labels, in reg_buffer order; consumed by fmt_regs.
reg_names:
        dc.b    '8900=',0
        dc.b    '8920=',0
        dc.b    '8930=',0
        dc.b    '8932=',0
        dc.b    '8934=',0
        dc.b    '8936=',0

; Phase names, short enough for one line beside the counters.
name_bare:         dc.b 'A bare',0
name_restart:      dc.b 'B +tx re-arm after Devconnect',0
name_dsprec:       dc.b 'C +dsp receive connected',0
name_montracks:    dc.b 'D +Setmontracks 0',0
name_adderin:      dc.b 'E +adder input matrix',0
name_buffoper:     dc.b 'F +Buffoper 0',0
name_sndreset:     dc.b 'G +Sndstatus reset, full pin',0
        even

; Bring-up phases: routine, name, transmitter re-arm flag, DSP receive
; connect flag. Flags accumulate; the table ends with a 0 routine.
phase_table:
        dc.l    phase_bare,name_bare,0,0
        dc.l    phase_flag_only,name_restart,1,0
        dc.l    phase_flag_only,name_dsprec,0,1
        dc.l    phase_montracks,name_montracks,0,0
        dc.l    phase_adderin,name_adderin,0,0
        dc.l    phase_buffoper,name_buffoper,0,0
        dc.l    phase_sndreset,name_sndreset,0,0
        dc.l    0

; Prescale plus the expected rate in millihertz, -1 terminated. Prescale 3
; is the production connection; 1 and 2 prove the divider law with two more
; points and would each expose a wrong clock source immediately.
run_table:
        dc.l    3,24584961              ; 24,584.9609375 Hz
        dc.l    1,49169922              ; 49,169.921875 Hz
        dc.l    2,32779948              ; 32,779.9479166 Hz
        dc.l    -1

        include "ratetest_boot.i"

        bss

dsp_tx_word:       ds.l 1
dsp_rx_word:       ds.l 1
results_ptr:       ds.l 1
meas_t0:           ds.l 1
meas_t1:           ds.l 1
meas_c0:           ds.l 1                 ; frames, underruns, words: keep
meas_u0:           ds.l 1                 ; the two triples contiguous for
meas_w0:           ds.l 1                 ; read_counters
meas_c1:           ds.l 1
meas_u1:           ds.l 1
meas_w1:           ds.l 1
meas_frames:       ds.l 1
meas_ticks:        ds.l 1
meas_under:        ds.l 1
meas_words:        ds.l 1
meas_rate:         ds.l 1
meas_sr:           ds.l 1
reg_buffer:        ds.w 6
run_count:         ds.w 1
fail_count:        ds.w 1
restart_flag:      ds.w 1
tristate_rec:      ds.w 1
phase_found:       ds.w 1
line_buffer:       ds.b 160
results_buffer:    ds.b 4096
results_buffer_end:

        end
