; F030MXDRV SSI rate-measurement DSP program
;
; Standalone Dsp_ExecBoot image for release/ratetest.tos. The 68030 owns the
; crossbar routing; this program only keeps the SSI transmitter fed with
; silence, counts transmit frame syncs, and reports its counters over the
; host port. A frame counter that never advances therefore means the crossbar
; delivers no SSI clock at the connected prescale - the exact real-hardware
; question the polled design isolates from the production kernel.
;
; The whole program stays inside the 512-word Dsp_ExecBoot window and uses no
; interrupts, so the reset state of IPR and the mode register is left alone.
;
; Keep the command words in sync with src/m68k/ratetest.s.

        include 'ioequ.inc'

RT_CMD_PING        equ     $010000
RT_CMD_READ_FRAMES equ     $020000
RT_CMD_READ_UNDER  equ     $030000
RT_CMD_RESET       equ     $040000
RT_REPLY_PING      equ     $524154         ; "RAT"
RT_REPLY_ERROR     equ     $ffffff

; Internal X scratch. A ds block inside an X org would emit an empty _DATA
; record that the boot-image converter rejects, so plain equates name the
; three words instead.
RT_FRAME_COUNT     equ     $0000
RT_UNDER_COUNT     equ     $0001
RT_STATUS_COPY     equ     $0002

        org     p:$0000
        jmp     rate_start

rate_start:
        movep   #1,x:m_pbc              ; enable the Falcon host port
        movep   #$1f8,x:m_pcc           ; Port C pins to SSI function; they
                                        ; reset to GPIO, leaving the slave
                                        ; SSI clockless on real hardware
        movep   #0,x:m_crb
        movep   #$4100,x:m_cra          ; 16-bit, two-word network frame
        clr     a
        move    a1,x:RT_FRAME_COUNT
        move    a1,x:RT_UNDER_COUNT
        move    #>1,x1                  ; counter increment
        move    #>0,y0                  ; silence sample for TX
        movep   #$1a00,x:m_crb          ; network transmit enabled, polled:
                                        ; the production $5a00 without TIE

; Service the transmitter first. SSISR is snapshotted because reading it and
; then writing TX is also the TUE-clearing sequence. TFS marks exactly one
; TDE service per stereo frame, so counting TFS-flagged services counts
; frames; TUE-flagged services mean this loop missed a word slot and the
; host-side report flags the run as suspect.
rate_loop:
        jclr    #6,x:m_sr,rate_host     ; TDE: a word slot wants data
        movep   x:m_sr,x:RT_STATUS_COPY
        movep   y0,x:m_tx
        jclr    #2,x:RT_STATUS_COPY,rate_slot_counted
        move    x:RT_FRAME_COUNT,a
        add     x1,a
        move    a1,x:RT_FRAME_COUNT
rate_slot_counted:
        jclr    #4,x:RT_STATUS_COPY,rate_host
        move    x:RT_UNDER_COUNT,a
        add     x1,a
        move    a1,x:RT_UNDER_COUNT

; One-word host commands, each acknowledged with one reply word. The reply
; wait cannot stall the transmitter: HTDE is only clear while the host still
; owns the previous reply, and the host reads every reply immediately.
rate_host:
        jclr    #0,x:m_hsr,rate_loop    ; HRDF: a command word arrived
        movep   x:m_hrx,a
        move    #>RT_CMD_PING,x0
        cmp     x0,a
        jeq     rate_cmd_ping
        move    #>RT_CMD_READ_FRAMES,x0
        cmp     x0,a
        jeq     rate_cmd_frames
        move    #>RT_CMD_READ_UNDER,x0
        cmp     x0,a
        jeq     rate_cmd_under
        move    #>RT_CMD_RESET,x0
        cmp     x0,a
        jeq     rate_cmd_reset
        move    #>RT_REPLY_ERROR,a
        jmp     rate_reply

rate_cmd_ping:
        move    #>RT_REPLY_PING,a
        jmp     rate_reply
rate_cmd_frames:
        move    x:RT_FRAME_COUNT,a
        jmp     rate_reply
rate_cmd_under:
        move    x:RT_UNDER_COUNT,a
        jmp     rate_reply
rate_cmd_reset:
        clr     a
        move    a1,x:RT_FRAME_COUNT
        move    a1,x:RT_UNDER_COUNT
rate_reply:
        jclr    #1,x:m_hsr,*            ; HTDE: host consumed the last reply
        movep   a1,x:m_htx
        jmp     rate_loop

        end
