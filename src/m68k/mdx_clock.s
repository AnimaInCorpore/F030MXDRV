        include "xbios.i"

        global  mxdrv_mdx_clock_start
        global  mxdrv_mdx_clock_stop
        global  mxdrv_mdx_clock_pump
        global  mxdrv_mdx_clock_pending
        global  mxdrv_mdx_clock_installed
        global  mxdrv_mdx_clock_resync

MFP_IERA                equ     $fffffa07
MFP_IPRA                equ     $fffffa0b
MFP_ISRA                equ     $fffffa0f
MFP_IMRA                equ     $fffffa13
MFP_TACR                equ     $fffffa19
MFP_TADR                equ     $fffffa1f
MFP_TIMER_A_VECTOR      equ     $00000134

MFP_TIMER_A_BIT         equ     5
MFP_TIMER_A_CLEAR       equ     $df
MFP_TIMER_A_CONTROL     equ     7       ; 2.4576 MHz / 200
MFP_TIMER_A_DATA        equ     12      ; / 12 = 1024 IRQs/second

; At 1024 IRQs/second, one interrupt represents exactly
; 62500/1024 native samples. In 16.16 this is 62500*64 = 4,000,000.
MDX_CLOCK_PHASE_STEP    equ     4000000

        text

; Claim MFP Timer A if it is completely idle. The supervisor routine installs
; the vector and register state atomically; active Timer-A users are never
; displaced. out: d0.l=0 on success, -1 when Timer A is already in use
mxdrv_mdx_clock_start:
        movem.l d1-d7/a0-a6,-(sp)
        tst.b   mdx_clock_installed_flag
        bne     mdx_clock_start_ok
        clr.l   mdx_clock_phase
        clr.w   mdx_clock_pending_ticks
        Supexec mdx_clock_install_super
        movem.l (sp)+,d1-d7/a0-a6
        rts
mdx_clock_start_ok:
        moveq   #0,d0
        movem.l (sp)+,d1-d7/a0-a6
        rts

mxdrv_mdx_clock_stop:
        movem.l d1-d7/a0-a6,-(sp)
        tst.b   mdx_clock_installed_flag
        beq     mdx_clock_stop_ok
        Supexec mdx_clock_remove_super
        movem.l (sp)+,d1-d7/a0-a6
        rts
mdx_clock_stop_ok:
        moveq   #0,d0
        movem.l (sp)+,d1-d7/a0-a6
        rts

; Drain timer expirations in foreground context. The MFP handler never calls
; XBIOS or touches the DSP; all sequencer/DSP work stays on this legal side of
; the interrupt boundary.
; out: d0.w=active track mask, d1.l=number of ticks drained
mxdrv_mdx_clock_pump:
        movem.l d2-d7/a0-a6,-(sp)
        moveq   #0,d6
        tst.b   mxdrv_paused
        bne     mdx_clock_pump_done
mdx_clock_pump_loop:
        tst.w   mdx_clock_pending_ticks
        beq     mdx_clock_pump_done
        subq.w  #1,mdx_clock_pending_ticks
        bsr     mxdrv_mdx_timer_service
        addq.l  #1,d6
        tst.b   mxdrv_playing
        bne     mdx_clock_pump_loop
        clr.w   mdx_clock_pending_ticks

mdx_clock_pump_done:
        tst.b   mxdrv_playing
        bne     mdx_clock_pump_active
        bsr     mxdrv_mdx_clock_stop
mdx_clock_pump_active:
        bsr     mxdrv_mdx_active_mask
        move.l  d6,d1
        movem.l (sp)+,d2-d7/a0-a6
        rts

mxdrv_mdx_clock_pending:
        moveq   #0,d0
        move.w  mdx_clock_pending_ticks,d0
        rts

mxdrv_mdx_clock_installed:
        moveq   #0,d0
        move.b  mdx_clock_installed_flag,d0
        rts

; Discard setup-time Timer-A backlog immediately after the first audio block is
; accepted. No audio has played yet, so carrying loader/render latency into the
; first foreground pump would only repeat the opening block while catching up.
mxdrv_mdx_clock_resync:
        movem.l d1-d7/a0-a6,-(sp)
        Supexec mdx_clock_resync_super
        movem.l (sp)+,d1-d7/a0-a6
        rts

mdx_clock_resync_super:
        move.w  sr,-(sp)
        move.w  #$2700,sr
        clr.l   mdx_clock_phase
        clr.w   mdx_clock_pending_ticks
        moveq   #0,d0
        move.w  (sp)+,sr
        rts

; XBIOS Supexec callback. Timer A is also used by Falcon DMA sound, so any
; existing control, enable, or mask state makes this a non-destructive failure.
mdx_clock_install_super:
        move.w  sr,-(sp)
        move.w  #$2700,sr
        tst.b   MFP_TACR
        bne     mdx_clock_install_busy
        btst    #MFP_TIMER_A_BIT,MFP_IERA
        bne     mdx_clock_install_busy
        btst    #MFP_TIMER_A_BIT,MFP_IMRA
        bne     mdx_clock_install_busy

        move.l  MFP_TIMER_A_VECTOR,mdx_clock_old_vector
        move.b  MFP_TACR,mdx_clock_old_tacr
        move.b  MFP_TADR,mdx_clock_old_tadr
        bclr    #MFP_TIMER_A_BIT,MFP_IERA
        bclr    #MFP_TIMER_A_BIT,MFP_IMRA
        clr.b   MFP_TACR
        move.b  #MFP_TIMER_A_CLEAR,MFP_IPRA
        move.b  #MFP_TIMER_A_CLEAR,MFP_ISRA
        move.l  #mdx_clock_timer_a_irq,MFP_TIMER_A_VECTOR
        move.b  #MFP_TIMER_A_DATA,MFP_TADR
        move.b  #MFP_TIMER_A_CONTROL,MFP_TACR
        bset    #MFP_TIMER_A_BIT,MFP_IERA
        bset    #MFP_TIMER_A_BIT,MFP_IMRA
        move.b  #1,mdx_clock_installed_flag
        moveq   #0,d0
        bra     mdx_clock_install_return

mdx_clock_install_busy:
        moveq   #-1,d0
mdx_clock_install_return:
        move.w  (sp)+,sr
        rts

mdx_clock_remove_super:
        move.w  sr,-(sp)
        move.w  #$2700,sr
        bclr    #MFP_TIMER_A_BIT,MFP_IERA
        bclr    #MFP_TIMER_A_BIT,MFP_IMRA
        clr.b   MFP_TACR
        move.b  #MFP_TIMER_A_CLEAR,MFP_IPRA
        move.b  #MFP_TIMER_A_CLEAR,MFP_ISRA
        move.l  mdx_clock_old_vector,MFP_TIMER_A_VECTOR
        move.b  mdx_clock_old_tadr,MFP_TADR
        move.b  mdx_clock_old_tacr,MFP_TACR
        clr.b   mdx_clock_installed_flag
        clr.l   mdx_clock_phase
        clr.w   mdx_clock_pending_ticks
        moveq   #0,d0
        move.w  (sp)+,sr
        rts

; Level-6 MFP interrupt: accumulate elapsed 62.5 kHz samples in 16.16 and
; enqueue every crossed Timer-B boundary. No OS or DSP service is called here.
mdx_clock_timer_a_irq:
        movem.l d0-d2,-(sp)
        tst.b   mxdrv_playing
        beq     mdx_clock_irq_ack
        tst.b   mxdrv_paused
        bne     mdx_clock_irq_ack

        move.l  mdx_clock_phase,d0
        add.l   #MDX_CLOCK_PHASE_STEP,d0
        moveq   #0,d1
        move.b  mxdrv_mdx_tempo,d1
        neg.w   d1
        addi.w  #256,d1
        lsl.l   #4,d1                  ; Timer-B period in native samples
        swap    d1                     ; convert to unsigned 16.16
mdx_clock_irq_period:
        cmp.l   d1,d0
        bcs     mdx_clock_irq_store
        sub.l   d1,d0
        cmpi.w  #$ffff,mdx_clock_pending_ticks
        beq     mdx_clock_irq_period
        addq.w  #1,mdx_clock_pending_ticks
        bra     mdx_clock_irq_period
mdx_clock_irq_store:
        move.l  d0,mdx_clock_phase

mdx_clock_irq_ack:
        move.b  #MFP_TIMER_A_CLEAR,MFP_ISRA
        movem.l (sp)+,d0-d2
        rte

        bss

mdx_clock_phase:
        ds.l    1
mdx_clock_pending_ticks:
        ds.w    1
mdx_clock_installed_flag:
        ds.b    1
mdx_clock_old_tacr:
        ds.b    1
mdx_clock_old_tadr:
        ds.b    1
        even
mdx_clock_old_vector:
        ds.l    1

        end
