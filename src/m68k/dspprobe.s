; F030MXDRV physical-Falcon DSP bus probe
;
; Standalone hardware-validation program. It boots src/dsp/dspprobe.asm the
; same way the player boots its kernel (Dsp_ExecBoot, no TOS loader in the
; path), then reports what only the real machine can tell:
;
;   1. the Bus Control Register as that bootstrap path leaves it - the
;      DSP56001 resets it to $FFFF, fifteen wait states on every external
;      access, and Hatari ignores the register, so the emulator cannot show
;      whether anything ever cleared it;
;   2. the cost, in clocks per instruction, of a sixteen-word loop fetched
;      from internal P (the reference: exactly two clocks), the same loop
;      fetched from external P, and the same loop reading external X and Y
;      data - measured before and after the BCR is cleared to zero;
;   3. the external memory decode the code islands assume: a word written
;      through Y:$2000 must read back through P:$2000, a word written
;      through X:$2000 must read back through P:$6000, and neither write
;      may disturb the other.
;
; Each run is timed against the TOS 200 Hz tick; the loop count is chosen so
; a two-clock instruction takes half a second and a seventeen-clock one about
; four. Every line is printed as it is produced and the report is written to
; DSPPROBE.TXT twice - after the "before" section and at the end - so a
; machine that stalls once the BCR changes still leaves the first half.

        include "xbios.i"

        global  start

; Keep the command opcodes in sync with src/dsp/dspprobe.asm.
PB_CMD_PING       equ $010000
PB_CMD_READ_BCR   equ $020000
PB_CMD_WRITE_BCR  equ $030000
PB_CMD_RUN_INT    equ $040000
PB_CMD_RUN_EXT    equ $050000
PB_CMD_RUN_XDATA  equ $060000
PB_CMD_RUN_YDATA  equ $070000
PB_CMD_SET_ADDR   equ $100000
PB_CMD_READ_X     equ $110000
PB_CMD_READ_Y     equ $120000
PB_CMD_READ_P     equ $130000
PB_CMD_WRITE_X    equ $140000
PB_CMD_WRITE_Y    equ $150000
PB_CMD_WRITE_P    equ $160000
PB_REPLY_PING     equ $505242             ; "PRB"

DSP_ABILITY       equ 3
HZ200             equ $4ba                ; TOS 200 Hz tick (supervisor only)

; Outer loop count per timing run; each outer count executes 16,000 words.
PB_RUN_OUTER      equ 500
PB_RUN_WORDS      equ PB_RUN_OUTER*16000

; Decode probe patterns: the DSP expands aabb to $aabbaa.
PB_PATTERN_Y      equ $a5c3
PB_PATTERN_Y24    equ $a5c3a5
PB_PATTERN_X      equ $3c5a
PB_PATTERN_X24    equ $3c5a3c

; Append the NUL-terminated fragment to the line being built at (a0)+.
        macro   FSTR fragment
        lea     \1,a1
        bsr     fmt_string
        endm

        text

start:
        move.l  #results_buffer,results_ptr
        Cconws  banner

        Cconws  txt_reserve
        Dsp_Reserve #16,#16
        tst.l   d0
        bmi     reserve_failed
        Cconws  txt_ok

        Cconws  txt_boot
        Dsp_ExecBoot dspprobe_boot_image,#DSPPROBE_BOOT_WORDS,#DSP_ABILITY
        Cconws  txt_ok

        Cconws  txt_ping
        move.l  #PB_CMD_PING,d0
        bsr     dsp_exchange
        cmp.l   #PB_REPLY_PING,d0
        bne     ping_failed
        Cconws  txt_ok

        ; 1. the BCR as the bootstrap path leaves it
        move.l  #PB_CMD_READ_BCR,d0
        bsr     dsp_exchange
        move.l  d0,bcr_boot
        lea     line_buffer,a0
        FSTR    txt_bcr_boot
        move.l  bcr_boot,d0
        bsr     fmt_hex16
        bsr     line_done
        bsr     emit_line

        ; 2a. timing with the BCR as found
        lea     line_buffer,a0
        FSTR    txt_timing_before
        bsr     line_done
        bsr     emit_line
        lea     ticks_before,a5
        bsr     timing_section
        bsr     write_results

        ; 2b. clear the BCR and repeat
        move.l  #PB_CMD_WRITE_BCR,d0
        bsr     dsp_exchange
        move.l  d0,bcr_after
        lea     line_buffer,a0
        FSTR    txt_bcr_after
        move.l  bcr_after,d0
        bsr     fmt_hex16
        bsr     line_done
        bsr     emit_line
        lea     line_buffer,a0
        FSTR    txt_timing_after
        bsr     line_done
        bsr     emit_line
        lea     ticks_after,a5
        bsr     timing_section

        ; 3. memory decode
        bsr     decode_section

        ; verdict
        lea     line_buffer,a0
        tst.w   fail_count
        bne     summary_fail
        FSTR    txt_result_pass
        bra     summary_done
summary_fail:
        FSTR    txt_result_fail
        moveq   #0,d0
        move.w  fail_count,d0
        bsr     fmt_u32
        FSTR    txt_failed_suffix
summary_done:
        bsr     line_done
        bsr     emit_line
        bsr     write_results

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
        addq.w  #1,fail_count
        bra     exit_with_dsp

; Run the four timing loops and print one line each. a5 -> four longwords
; that receive the tick counts (internal, external P, X data, Y data). The
; internal-P run is the reference: its words cost two clocks by definition,
; so every other cost is 2 * ticks / ticks_internal, independent of the
; exact DSP crystal.
timing_section:
        movem.l d0-d7/a0-a4,-(sp)
        lea     timing_table,a4
        moveq   #0,d7                     ; index
.run:
        move.l  (a4)+,d6                  ; command, or 0 terminator
        beq     .done
        move.l  (a4)+,a3                  ; label text
        addi.l  #PB_RUN_OUTER,d6          ; argument in the low 16 bits
        bsr     wait_tick_edge
        move.l  d0,d4
        move.l  d6,d0
        bsr     dsp_exchange
        tst.l   d0
        bne     .dsp_refused
        bsr     get_ticks
        sub.l   d4,d0
        move.l  d0,(a5,d7.w*4)
        lea     line_buffer,a0
        FSTR    txt_indent
        movea.l a3,a1
        bsr     fmt_string
        FSTR    txt_ticks
        move.l  (a5,d7.w*4),d0
        bsr     fmt_u32
        FSTR    txt_clocks
        ; clocks per word * 100 = 200 * ticks / ticks_internal
        move.l  (a5,d7.w*4),d0
        mulu.l  #200,d0
        move.l  (a5),d1
        beq     .no_reference
        divu.l  d1,d0
        bsr     fmt_hundredths
        FSTR    txt_clocks_unit
        bra     .lined
.no_reference:
        FSTR    txt_no_reference
.lined:
        bsr     line_done
        bsr     emit_line
        addq.w  #1,d7
        bra     .run
.dsp_refused:
        addq.w  #1,fail_count
        lea     line_buffer,a0
        FSTR    txt_indent
        movea.l a3,a1
        bsr     fmt_string
        FSTR    txt_refused
        bsr     line_done
        bsr     emit_line
        addq.w  #1,d7
        bra     .run
.done:
        ; the internal reference must have taken measurable time, and every
        ; loop must cost two clocks per word once the BCR is clear
        cmpa.l  #ticks_after,a5
        bne     .checked
        move.l  (a5),d1
        beq     .fail
        moveq   #1,d7
.bound:
        move.l  (a5,d7.w*4),d0
        mulu.l  #200,d0
        divu.l  d1,d0                     ; hundredths of a clock per word
        cmpi.l  #180,d0
        bcs     .fail
        cmpi.l  #220,d0
        bhi     .fail
        addq.w  #1,d7
        cmpi.w  #4,d7
        bcs     .bound
        bra     .checked
.fail:
        addq.w  #1,fail_count
        lea     line_buffer,a0
        FSTR    txt_after_fail
        bsr     line_done
        bsr     emit_line
.checked:
        movem.l (sp)+,d0-d7/a0-a4
        rts

; Write patterns through one space and read them back through the aliases
; the code islands rely on.
decode_section:
        movem.l d0-d7/a0-a4,-(sp)
        lea     line_buffer,a0
        FSTR    txt_decode_head
        bsr     line_done
        bsr     emit_line

        ; Y:$2000 <- $a5c3a5: P:$2000 must show it (the islands sit in that
        ; window), and X:$2000 <- $3c5a3c must land at P:$6000 without
        ; touching the Y/P word. The $6000 shadows are reported, not judged.
        move.l  #PB_CMD_SET_ADDR+$2000,d0
        bsr     dsp_exchange
        move.l  #PB_CMD_WRITE_Y+PB_PATTERN_Y,d0
        bsr     dsp_exchange
        move.l  #PB_CMD_WRITE_X+PB_PATTERN_X,d0
        bsr     dsp_exchange
        move.l  #PB_CMD_READ_Y,d0
        bsr     dsp_exchange
        move.l  d0,probe_y2000
        move.l  #PB_CMD_READ_P,d0
        bsr     dsp_exchange
        move.l  d0,probe_p2000
        move.l  #PB_CMD_READ_X,d0
        bsr     dsp_exchange
        move.l  d0,probe_x2000
        move.l  #PB_CMD_SET_ADDR+$6000,d0
        bsr     dsp_exchange
        move.l  #PB_CMD_READ_P,d0
        bsr     dsp_exchange
        move.l  d0,probe_p6000
        move.l  #PB_CMD_READ_X,d0
        bsr     dsp_exchange
        move.l  d0,probe_x6000
        move.l  #PB_CMD_READ_Y,d0
        bsr     dsp_exchange
        move.l  d0,probe_y6000

        lea     line_buffer,a0
        FSTR    txt_decode_y
        move.l  probe_y2000,d0
        bsr     fmt_hex24
        FSTR    txt_decode_p2000
        move.l  probe_p2000,d0
        bsr     fmt_hex24
        bsr     line_done
        bsr     emit_line

        lea     line_buffer,a0
        FSTR    txt_decode_x
        move.l  probe_x2000,d0
        bsr     fmt_hex24
        FSTR    txt_decode_p6000
        move.l  probe_p6000,d0
        bsr     fmt_hex24
        bsr     line_done
        bsr     emit_line

        lea     line_buffer,a0
        FSTR    txt_decode_shadow
        move.l  probe_x6000,d0
        bsr     fmt_hex24
        FSTR    txt_decode_y6000
        move.l  probe_y6000,d0
        bsr     fmt_hex24
        bsr     line_done
        bsr     emit_line

        lea     line_buffer,a0
        cmpi.l  #PB_PATTERN_Y24,probe_y2000
        bne     .mismatch
        cmpi.l  #PB_PATTERN_Y24,probe_p2000
        bne     .mismatch
        cmpi.l  #PB_PATTERN_X24,probe_x2000
        bne     .mismatch
        cmpi.l  #PB_PATTERN_X24,probe_p6000
        bne     .mismatch
        FSTR    txt_decode_ok
        bra     .verdict
.mismatch:
        addq.w  #1,fail_count
        FSTR    txt_decode_bad
.verdict:
        bsr     line_done
        bsr     emit_line
        movem.l (sp)+,d0-d7/a0-a4
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

; Append the NUL-terminated fragment at a1 to (a0)+; the NUL is not copied.
fmt_string:
.copy:
        move.b  (a1)+,(a0)+
        bne     .copy
        subq.l  #1,a0
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

; Append d0.l hundredths as "N.NN" at (a0)+.
fmt_hundredths:
        movem.l d0-d1,-(sp)
        moveq   #0,d1
        divu.l  #100,d1:d0
        bsr     fmt_u32
        move.b  #'.',(a0)+
        move.l  d1,d0
        divu.w  #10,d0
        move.b  d0,d1
        addi.b  #'0',d1
        move.b  d1,(a0)+
        swap    d0
        addi.b  #'0',d0
        move.b  d0,(a0)+
        movem.l (sp)+,d0-d1
        rts

; Append the low 24 bits of d0.l as "$xxxxxx" at (a0)+.
fmt_hex24:
        movem.l d0-d2,-(sp)
        move.b  #'$',(a0)+
        moveq   #6,d2
        rol.l   #8,d0
        bra     fmt_hex_digits
; Append the low 16 bits of d0.l as "$xxxx" at (a0)+.
fmt_hex16:
        movem.l d0-d2,-(sp)
        move.b  #'$',(a0)+
        moveq   #4,d2
        swap    d0
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
        dc.b    13,10,'F030MXDRV DSP bus probe',13,10
        dc.b    '=======================',13,10,0
txt_reserve:       dc.b 'DSP reserve ..... ',0
txt_boot:          dc.b 'DSP boot ........ ',0
txt_ping:          dc.b 'DSP ping ........ ',0
txt_ok:            dc.b 'ok',13,10,0
txt_failedline:    dc.b 'FAILED',13,10,0
txt_bcr_boot:      dc.b 'BCR after Dsp_ExecBoot: ',0
txt_bcr_after:     dc.b 'BCR after clearing:     ',0
txt_timing_before: dc.b 'timing with BCR as found (8,000,000 words per run, TOS 200 Hz ticks):',0
txt_timing_after:  dc.b 'timing with BCR cleared:',0
txt_indent:        dc.b '  ',0
txt_ticks:         dc.b ': ticks ',0
txt_clocks:        dc.b '  = ',0
txt_clocks_unit:   dc.b ' clocks/word',0
txt_no_reference:  dc.b '  (no internal reference)',0
txt_refused:       dc.b ': DSP refused the run  FAIL',0
txt_after_fail:    dc.b 'FAIL: with BCR cleared, external words do not cost 2 clocks',0
txt_lbl_int:       dc.b 'fetch from internal P ',0
txt_lbl_ext:       dc.b 'fetch from external P ',0
txt_lbl_xdata:     dc.b 'read external X data  ',0
txt_lbl_ydata:     dc.b 'read external Y data  ',0
txt_decode_head:   dc.b 'memory decode (model: Y:$2000 = P:$2000, X:$2000 = P:$6000):',0
txt_decode_y:      dc.b '  Y:$2000 <- $a5c3a5  reads Y:$2000=',0
txt_decode_p2000:  dc.b ' P:$2000=',0
txt_decode_x:      dc.b '  X:$2000 <- $3c5a3c  reads X:$2000=',0
txt_decode_p6000:  dc.b ' P:$6000=',0
txt_decode_shadow: dc.b '  shadows (information only): X:$6000=',0
txt_decode_y6000:  dc.b ' Y:$6000=',0
txt_decode_ok:     dc.b '  decode matches the model  PASS',0
txt_decode_bad:    dc.b '  decode differs from the model  FAIL',0
txt_result_pass:   dc.b 'RESULT: PASS',0
txt_result_fail:   dc.b 'RESULT: FAIL (',0
txt_failed_suffix: dc.b ' checks failed)',0
txt_filename:      dc.b 'DSPPROBE.TXT',0
txt_exit:          dc.b 13,10,'press any key to exit',13,10,0
        even

; Timing runs: command word, label. The internal-P run must come first
; because it is the reference for the others.
timing_table:
        dc.l    PB_CMD_RUN_INT,txt_lbl_int
        dc.l    PB_CMD_RUN_EXT,txt_lbl_ext
        dc.l    PB_CMD_RUN_XDATA,txt_lbl_xdata
        dc.l    PB_CMD_RUN_YDATA,txt_lbl_ydata
        dc.l    0

        include "dspprobe_boot.i"

        bss

dsp_tx_word:       ds.l 1
dsp_rx_word:       ds.l 1
results_ptr:       ds.l 1
bcr_boot:          ds.l 1
bcr_after:         ds.l 1
ticks_before:      ds.l 4
ticks_after:       ds.l 4
probe_y2000:       ds.l 1
probe_p2000:       ds.l 1
probe_x6000:       ds.l 1
probe_x2000:       ds.l 1
probe_p6000:       ds.l 1
probe_y6000:       ds.l 1
fail_count:        ds.w 1
line_buffer:       ds.b 160
results_buffer:    ds.b 4096
results_buffer_end:

        end
