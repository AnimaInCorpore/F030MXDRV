; F030MXDRV physical-Falcon DSP bus probe
;
; Standalone Dsp_ExecBoot image for release/dspprobe.tos. It answers the
; questions Hatari cannot: what the Bus Control Register holds after the
; player's own bootstrap path (reset leaves $FFFF - fifteen wait states on
; every external access - and the emulator ignores the register), how many
; clocks an instruction fetched from external P, or a data word read from
; external X or Y, really costs before and after the BCR is cleared, and
; whether the external memory decode matches the model the code islands
; assume (Y:$2000 aliases P:$2000; X:$2000 lives at P:$6000).
;
; Everything runs from the 512-word internal window except the external
; fetch loop, which startup copies to P:$0200 and re-targets. No interrupts
; are used, so IPR and the mode register keep their reset state.
;
; Command words carry an opcode in the top byte and a 16-bit argument in the
; low bits; every command is answered with one reply word. Keep them in sync
; with src/m68k/dspprobe.s.

        include 'ioequ.inc'

PB_CMD_PING       equ     $01
PB_CMD_READ_BCR   equ     $02
PB_CMD_WRITE_BCR  equ     $03    ; arg = new BCR, reply = readback
PB_CMD_RUN_INT    equ     $04    ; arg = outer count; loop fetched from internal P
PB_CMD_RUN_EXT    equ     $05    ; arg = outer count; loop fetched from P:$0200
PB_CMD_RUN_XDATA  equ     $06    ; arg = outer count; internal loop reading X:$2000
PB_CMD_RUN_YDATA  equ     $07    ; arg = outer count; internal loop reading Y:$2000
PB_CMD_SET_ADDR   equ     $10    ; arg = probe address for the accesses below
PB_CMD_READ_X     equ     $11
PB_CMD_READ_Y     equ     $12
PB_CMD_READ_P     equ     $13
PB_CMD_WRITE_X    equ     $14    ; arg aabb writes $aabbaa
PB_CMD_WRITE_Y    equ     $15
PB_CMD_WRITE_P    equ     $16
PB_REPLY_PING     equ     $505242         ; "PRB"
PB_REPLY_ERROR    equ     $ffffff

PB_EXT_LOOP       equ     $0200   ; external P home of the fetch-timing loop
PB_EXT_DATA       equ     $2000   ; external X/Y word the data loops read
PB_INNER          equ     1000    ; inner iterations per outer count: each
                                  ; outer count executes 16*PB_INNER words

        org     p:$0000
        jmp     probe_start

; Code lives above the interrupt vectors, as the stage-two loader does.
        org     p:$0040

; The fetch-timing loop: sixteen one-word instructions under a hardware DO,
; which refetches every word each iteration (REP would fetch once). It is
; assembled here in internal P and copied verbatim to P:$0200, where only
; the DO's loop-end address is re-targeted, so both copies execute the same
; words and differ only in where they are fetched from.
probe_loop_int:
        do      #PB_INNER,probe_loop_int_done
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
probe_loop_int_done:
        rts
probe_loop_int_end:
PB_LOOP_WORDS     equ     probe_loop_int_end-probe_loop_int
PB_EXT_LOOP_LAST  equ     PB_EXT_LOOP+probe_loop_int_done-1-probe_loop_int

probe_start:
        movep   #1,x:m_pbc              ; enable the Falcon host port
        move    #>-1,m0
        move    #>-1,m1

        ; place the external copy of the fetch loop and patch its DO target
        move    #probe_loop_int,r0
        move    #>PB_EXT_LOOP,r1
        do      #PB_LOOP_WORDS,probe_copy_done
        movem   p:(r0)+,a
        movem   a1,p:(r1)+
        nop                             ; keep MOVEM off the loop-end word
probe_copy_done:
        move    #>PB_EXT_LOOP+1,r1
        move    #>PB_EXT_LOOP_LAST,a
        nop                             ; address-register pipeline interlock
        movem   a1,p:(r1)
        move    #>PB_EXT_DATA,r1        ; default probe address

; One-word host commands, each acknowledged with one reply word.
probe_host:
        jclr    #0,x:m_hsr,probe_host   ; HRDF: a command word arrived
        movep   x:m_hrx,a
        move    a1,b
        rep     #16
        lsr     b                       ; b1 = opcode
        move    #>$00ffff,x0
        and     x0,a                    ; a1 = argument
        move    a1,x0
        move    #>PB_CMD_PING,y0
        cmp     y0,b
        jeq     probe_cmd_ping
        move    #>PB_CMD_READ_BCR,y0
        cmp     y0,b
        jeq     probe_cmd_read_bcr
        move    #>PB_CMD_WRITE_BCR,y0
        cmp     y0,b
        jeq     probe_cmd_write_bcr
        move    #>PB_CMD_RUN_INT,y0
        cmp     y0,b
        jeq     probe_cmd_run_int
        move    #>PB_CMD_RUN_EXT,y0
        cmp     y0,b
        jeq     probe_cmd_run_ext
        move    #>PB_CMD_RUN_XDATA,y0
        cmp     y0,b
        jeq     probe_cmd_run_xdata
        move    #>PB_CMD_RUN_YDATA,y0
        cmp     y0,b
        jeq     probe_cmd_run_ydata
        move    #>PB_CMD_SET_ADDR,y0
        cmp     y0,b
        jeq     probe_cmd_set_addr
        move    #>PB_CMD_READ_X,y0
        cmp     y0,b
        jeq     probe_cmd_read_x
        move    #>PB_CMD_READ_Y,y0
        cmp     y0,b
        jeq     probe_cmd_read_y
        move    #>PB_CMD_READ_P,y0
        cmp     y0,b
        jeq     probe_cmd_read_p
        move    #>PB_CMD_WRITE_X,y0
        cmp     y0,b
        jeq     probe_cmd_write_x
        move    #>PB_CMD_WRITE_Y,y0
        cmp     y0,b
        jeq     probe_cmd_write_y
        move    #>PB_CMD_WRITE_P,y0
        cmp     y0,b
        jeq     probe_cmd_write_p
probe_error:
        move    #>PB_REPLY_ERROR,a
        jmp     probe_reply

probe_cmd_ping:
        move    #>PB_REPLY_PING,a
        jmp     probe_reply
probe_cmd_read_bcr:
        movep   x:m_bcr,a
        jmp     probe_reply
probe_cmd_write_bcr:
        movep   a1,x:m_bcr
        movep   x:m_bcr,a
        jmp     probe_reply

; Timing runs: the argument is the outer count (a zero count would run the
; hardware loop 65,536 times, so it is refused). The reply is sent only
; after the last iteration, so the host's wall clock brackets the run.
probe_cmd_run_int:
        tst     a
        jeq     probe_error
        do      x0,probe_run_int_done
        jsr     probe_loop_int
        nop
probe_run_int_done:
        clr     a
        jmp     probe_reply
probe_cmd_run_ext:
        tst     a
        jeq     probe_error
        do      x0,probe_run_ext_done
        jsr     PB_EXT_LOOP
        nop
probe_run_ext_done:
        clr     a
        jmp     probe_reply

; Data-access runs: the same sixteen-word body fetched from internal P, each
; word reading one external data location, so the fetch is free and the
; measured cost is the data bus.
probe_cmd_run_xdata:
        tst     a
        jeq     probe_error
        move    #>PB_EXT_DATA,r0
        do      x0,probe_run_xdata_done
        do      #PB_INNER,probe_xdata_inner_done
        move    x:(r0),x1
        move    x:(r0),x1
        move    x:(r0),x1
        move    x:(r0),x1
        move    x:(r0),x1
        move    x:(r0),x1
        move    x:(r0),x1
        move    x:(r0),x1
        move    x:(r0),x1
        move    x:(r0),x1
        move    x:(r0),x1
        move    x:(r0),x1
        move    x:(r0),x1
        move    x:(r0),x1
        move    x:(r0),x1
        move    x:(r0),x1
probe_xdata_inner_done:
        nop
probe_run_xdata_done:
        clr     a
        jmp     probe_reply
probe_cmd_run_ydata:
        tst     a
        jeq     probe_error
        move    #>PB_EXT_DATA,r0
        do      x0,probe_run_ydata_done
        do      #PB_INNER,probe_ydata_inner_done
        move    y:(r0),x1
        move    y:(r0),x1
        move    y:(r0),x1
        move    y:(r0),x1
        move    y:(r0),x1
        move    y:(r0),x1
        move    y:(r0),x1
        move    y:(r0),x1
        move    y:(r0),x1
        move    y:(r0),x1
        move    y:(r0),x1
        move    y:(r0),x1
        move    y:(r0),x1
        move    y:(r0),x1
        move    y:(r0),x1
        move    y:(r0),x1
probe_ydata_inner_done:
        nop
probe_run_ydata_done:
        clr     a
        jmp     probe_reply

; Memory decode probe. r1 holds the probe address; writes expand the 16-bit
; argument aabb to the 24-bit pattern $aabbaa so every byte lane is covered.
probe_cmd_set_addr:
        move    a1,r1
        jmp     probe_reply
probe_cmd_read_x:
        move    x:(r1),a
        jmp     probe_reply
probe_cmd_read_y:
        move    y:(r1),a
        jmp     probe_reply
probe_cmd_read_p:
        movem   p:(r1),a
        jmp     probe_reply
probe_cmd_write_x:
        jsr     probe_pattern
        move    a1,x:(r1)
        jmp     probe_reply
probe_cmd_write_y:
        jsr     probe_pattern
        move    a1,y:(r1)
        jmp     probe_reply
probe_cmd_write_p:
        jsr     probe_pattern
        movem   a1,p:(r1)
        jmp     probe_reply

probe_pattern:
        move    x0,b
        rep     #8
        lsr     b                       ; b1 = aa
        rep     #8
        lsl     a                       ; a1 = aabb00
        move    b1,x1
        or      x1,a                    ; a1 = aabbaa
        rts

probe_reply:
        jclr    #1,x:m_hsr,*            ; HTDE: host consumed the last reply
        movep   a1,x:m_htx
        jmp     probe_host

        end
