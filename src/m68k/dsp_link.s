        include "xbios.i"
        include "verbose.i"
        include "protocol.i"

        global  dsp_exchange
        global  dsp_queue_write
        global  dsp_start_mixed_audio
        global  dsp_refill_mixed_audio
        global  dsp_start_realtime_audio
        global  dsp_refill_realtime_audio
        global  dsp_rt_submit
        global  dsp_rt_submit_poll
        global  dsp_rt_submit_poll_irq
        global  dsp_rt_submit_wait
        global  dsp_stage_reply

DSP_MIX_TRANSFER_WORDS equ   1+DSP_MIX_FRAME_COUNT*2

; Falcon DSP host interface. ISR bit 0 = RXDF, bit 1 = TXDE; the 24-bit
; data word lives in three byte registers, and the low byte carries the
; transfer strobe in both directions.
DSP_HOST_ISR equ $ffffa202
DSP_HOST_DATA equ $ffffa204

        text

; Send a payload with every word paced on TXDE, then collect the single
; reply word. TOS's Dsp_BlkUnpacked polls TXDE only for its first word and
; blasts the rest blind, which outruns a receive loop in external DSP P RAM
; and drops words on real TOS 4.02 hardware. Pacing each word costs well
; under a millisecond per 524-word refill against the 20.8 ms period. The
; host port is supervisor-only, so the two halves run under Supexec - two
; XBIOS traps per block instead of one per word - split so the verbose
; marker between payload and reply keeps separating "stopped consuming
; mid-block" from "took the block and never replied".
; in:  a3 = payload (packed 24-bit words), d3.l = word count
; out: d0.l = reply
dsp_blast_paced:
        move.l  a3,dsp_blast_ptr
        move.l  d3,dsp_blast_count
        Supexec dsp_blast_send_super
        VB      vb_txt_payloadsent
        Supexec dsp_blast_recv_super
        move.l  dsp_blast_reply,d0
        rts

dsp_blast_send_super:
        movem.l d3/a3,-(sp)
        ; A 1,024 Hz MFP Timer-A tick inside this short critical stream
        ; otherwise leaves the DSP parked at HRDF long enough to turn
        ; an isolated voice-load burst into a full repeated audio period.
        ; Preserve the caller's mask and defer that tick until all payload
        ; words have reached the DSP; no interrupt is discarded.
        move.w  sr,-(sp)
        ori.w   #$0700,sr
        move.l  dsp_blast_ptr,a3
        move.l  dsp_blast_count,d3
dsp_blast_send_word:
        btst    #1,DSP_HOST_ISR
        beq.s   dsp_blast_send_word
        ; Each payload slot is already a zero-padded 24-bit word.  A long
        ; write covers TX0:TXH:TXM:TXL and the low-byte access still strobes
        ; the transfer, but the 68030 pays for one host-port transaction
        ; instead of three separately wait-stated byte writes.
        move.l  (a3)+,DSP_HOST_DATA
        subq.l  #1,d3
        bne.s   dsp_blast_send_word
        move.w  (sp)+,sr
        movem.l (sp)+,d3/a3
        rts

; The low data byte must be read last: reading it clears RXDF.
dsp_blast_recv_super:
        btst    #0,DSP_HOST_ISR
        beq.s   dsp_blast_recv_super
        moveq   #0,d0
        move.b  DSP_HOST_DATA+1,d0
        lsl.l   #8,d0
        move.b  DSP_HOST_DATA+2,d0
        lsl.l   #8,d0
        move.b  DSP_HOST_DATA+3,d0
        move.l  d0,dsp_blast_reply
        rts

; Staged realtime submission. The production player keeps one complete refill
; payload ANNOUNCED to the DSP (its command longword parked in the host
; receive register until the stream loop reads it after a buffer handoff and
; answers READY) and up to one more finished payload QUEUED behind it, while
; a third is being prepared. dsp_rt_submit_poll notices the READY reply from
; inside the producer - between sequencer ticks and PDX mix passes - releases
; the announced block at once, and immediately announces the queued one, so a
; finished payload is always parked ahead of the handoff that consumes it.
; A period whose preparation overruns its slot therefore borrows idle time
; from up to two neighbouring periods instead of pushing already-finished
; payloads past the DSP's render deadline. Exactly one command is ever in
; flight, and every other exchange the player performs is preceded by a
; dsp_rt_submit_wait drain.

; Hand a completed realtime payload to the pipeline. (a3) holds the command
; longword and d3.l payload words follow it; the buffer stays owned by the
; pipeline until delivery. Announces directly when the port is free, queues
; behind the announced payload otherwise, and when both slots are busy blocks
; until the next handoff frees one - that block is the loop's normal pacing.
; in: a3 = command+payload base, d3.l = payload word count after the command
dsp_rt_submit:
        movem.l d0-d2/a0-a2,-(sp)
        tst.b   dsp_stage_posted
        beq.s   dsp_rt_submit_announce
dsp_rt_submit_full:
        tst.b   dsp_stage_queued
        beq.s   dsp_rt_submit_enqueue
        Supexec dsp_stage_poll_super
        tst.b   dsp_stage_posted
        beq.s   dsp_rt_submit_announce
        bra.s   dsp_rt_submit_full
dsp_rt_submit_enqueue:
        move.l  a3,dsp_stage_qbase
        move.l  d3,dsp_stage_qcount
        move.b  #1,dsp_stage_queued
        movem.l (sp)+,d0-d2/a0-a2
        rts
dsp_rt_submit_announce:
        move.l  a3,dsp_stage_base
        move.l  d3,dsp_stage_count
        Supexec dsp_stage_post_super
        move.b  #1,dsp_stage_posted
        ; An empty pipeline usually means the DSP is parked at its stream
        ; loop (song start, or just after a drain), and an idle DSP answers a
        ; command within microseconds. One immediate poll delivers in that
        ; case instead of leaving the payload to a later seam or timer tick;
        ; a busy DSP simply leaves it announced.
        Supexec dsp_stage_poll_super
        movem.l (sp)+,d0-d2/a0-a2
        rts

dsp_stage_post_super:
        movea.l dsp_stage_base,a0
dsp_stage_post_txde:
        btst    #1,DSP_HOST_ISR
        beq.s   dsp_stage_post_txde
        move.l  (a0),DSP_HOST_DATA
        rts

; Deliver the announced payload if the DSP has just answered its command
; word. Safe at any producer seam: every register is preserved and the
; routine is a two-instruction fall-through while nothing is announced.
dsp_rt_submit_poll:
        tst.b   dsp_stage_posted
        beq.s   dsp_rt_submit_poll_idle
        movem.l d0-d2/a0-a2,-(sp)
        Supexec dsp_stage_poll_super
        movem.l (sp)+,d0-d2/a0-a2
dsp_rt_submit_poll_idle:
        rts

; Block until every announced and queued payload has been delivered.
; out: d0.l = final DSP reply for the most recently delivered payload;
;             DSP_REPLY_OK when nothing was ever posted
dsp_rt_submit_wait:
        tst.b   dsp_stage_posted
        beq.s   dsp_rt_submit_wait_done
        movem.l d1-d2/a0-a2,-(sp)
dsp_rt_submit_wait_loop:
        Supexec dsp_stage_poll_super
        tst.b   dsp_stage_posted
        bne.s   dsp_rt_submit_wait_loop
        movem.l (sp)+,d1-d2/a0-a2
dsp_rt_submit_wait_done:
        move.l  dsp_stage_reply,d0
        rts

; MFP Timer-A entry: the sequencer's 1,024 Hz interrupt bounds delivery
; latency to about one tick even while the foreground is deep inside a dense
; drain or mix. Runs at interrupt level, so the foreground body below cannot
; be executing (it masks to level 7 for its whole duration); pure hardware
; access, no OS service. Clobbers d0-d1/a0 only - the handler saves them.
dsp_rt_submit_poll_irq:
        tst.b   dsp_stage_posted
        beq.s   dsp_rt_submit_poll_irq_idle
        bsr.s   dsp_stage_poll_body
dsp_rt_submit_poll_irq_idle:
        rts

; Foreground (Supexec) wrapper. The whole body runs masked so the Timer-A
; delivery above can never interleave with a half-read reply or half-sent
; block; the mask also keeps the paced send free of mid-stream interrupt
; gaps that would leave the DSP parked at HRDF across a period boundary
; (see dsp_blast_send_super). No interrupt is discarded, only deferred.
dsp_stage_poll_super:
        move.w  sr,-(sp)
        ori.w   #$0700,sr
        bsr.s   dsp_stage_poll_body
        move.w  (sp)+,sr
        rts

; Shared delivery body. RXDF after an announcement can only be the DSP's
; answer to the parked command: READY releases the announced block through
; the same TXDE-paced send as dsp_blast_send_super and collects the
; upload-owned acknowledgement, then immediately announces the queued
; payload so its command is parked well before the next handoff. Anything
; but READY is recorded as the delivery reply so the producer's OK check
; fails; the queued payload is dropped unannounced in that case.
dsp_stage_poll_body:
        btst    #0,DSP_HOST_ISR
        beq     dsp_stage_poll_done
        moveq   #0,d0
        move.b  DSP_HOST_DATA+1,d0
        lsl.l   #8,d0
        move.b  DSP_HOST_DATA+2,d0
        lsl.l   #8,d0
        move.b  DSP_HOST_DATA+3,d0
        cmpi.l  #DSP_REPLY_BLOCK_READY,d0
        bne.s   dsp_stage_poll_bad
        movea.l dsp_stage_base,a0
        addq.l  #4,a0
        move.l  dsp_stage_count,d1
dsp_stage_poll_send:
        btst    #1,DSP_HOST_ISR
        beq.s   dsp_stage_poll_send
        move.l  (a0)+,DSP_HOST_DATA
        subq.l  #1,d1
        bne.s   dsp_stage_poll_send
dsp_stage_poll_ack:
        btst    #0,DSP_HOST_ISR
        beq.s   dsp_stage_poll_ack
        moveq   #0,d0
        move.b  DSP_HOST_DATA+1,d0
        lsl.l   #8,d0
        move.b  DSP_HOST_DATA+2,d0
        lsl.l   #8,d0
        move.b  DSP_HOST_DATA+3,d0
        move.l  d0,dsp_stage_reply
        tst.b   dsp_stage_queued
        beq.s   dsp_stage_poll_drained
        move.l  dsp_stage_qbase,dsp_stage_base
        move.l  dsp_stage_qcount,dsp_stage_count
        clr.b   dsp_stage_queued
        movea.l dsp_stage_base,a0
dsp_stage_poll_next_txde:
        btst    #1,DSP_HOST_ISR
        beq.s   dsp_stage_poll_next_txde
        move.l  (a0),DSP_HOST_DATA
        rts
dsp_stage_poll_bad:
        move.l  d0,dsp_stage_reply
        clr.b   dsp_stage_queued
dsp_stage_poll_drained:
        clr.b   dsp_stage_posted
dsp_stage_poll_done:
        rts

; Exchange one packed 24-bit protocol word with the DSP.
; in:  d0.l = command (low 24 bits)
; out: d0.l = reply   (low 24 bits)
dsp_exchange:
        movem.l d1-d7/a0-a6,-(sp)
        move.l  d0,dsp_tx_word
        clr.l   dsp_rx_word
        Dsp_BlkUnpacked dsp_tx_word,#1,dsp_rx_word,#1
        move.l  dsp_rx_word,d0
        movem.l (sp)+,d1-d7/a0-a6
        rts

; Queue one YM2151 write at an absolute position on the rolling native-sample
; clock. The DSP transaction is a timestamp header followed by a normal packed
; write word.
; in:  d0.w = rolling timestamp, d1.b = register, d2.b = data
; out: d0.l = DSP reply
dsp_queue_write:
        move.l  d0,d3
        andi.l  #$0000ffff,d3
        ori.l   #DSP_CMD_QUEUE_WRITE,d3
        move.l  d3,dsp_queue_words

        moveq   #0,d3
        move.b  d1,d3
        lsl.l   #8,d3
        move.b  d2,d3
        ori.l   #DSP_CMD_WRITE_REG,d3
        move.l  d3,dsp_queue_words+4

        clr.l   dsp_queue_reply
        movem.l d3/a3,-(sp)
        lea     dsp_queue_words,a3
        moveq   #2,d3
        bsr     dsp_blast_paced
        move.l  d0,dsp_queue_reply
        movem.l (sp)+,d3/a3
        move.l  dsp_queue_reply,d0
        rts

; Render one exact Falcon codec-rate PDX period on the 68030, upload its
; interleaved signed stereo frames, and ask the DSP to combine them with a
; freshly rendered YM period before enabling SSI.
; out: d0.l = DSP reply
dsp_start_mixed_audio:
        move.l  #DSP_CMD_START_MIXED,d0
        move.w  #DSP_MIX_FRAME_COUNT-1,d4
        bra     dsp_render_mixed_audio

; Refill the inactive DSP buffer while SSI continues replaying the current
; complete block. The DSP swaps only after rendering finishes.
dsp_refill_mixed_audio:
        move.l  #DSP_CMD_REFILL_MIXED,d0
        move.w  #DSP_MIX_FRAME_COUNT-1,d4
        bra     dsp_render_mixed_audio

; Start/refill the 32.780 kHz, 32-frame-block renderer. Its 512-frame period
; is exactly sixteen synthesis blocks. The production payload is one event
; count, the ordered packed writes accumulated by the sequencer pump, then a
; mono PCM pan header and 512 samples.
dsp_start_realtime_audio:
        move.l  d5,-(sp)
        move.l  #DSP_CMD_START_RT_MIXED,d0
        bra     dsp_render_realtime_audio

dsp_refill_realtime_audio:
        move.l  d5,-(sp)
        move.l  #DSP_CMD_REFILL_RT_MIXED,d0

dsp_render_realtime_audio:
        move.l  d0,dsp_mixed_words
        lea     dsp_mixed_words+4,a3
        bsr     mxdrv_ym_batch_copy
        tst.l   d0
        bne     dsp_send_realtime_done
        move.l  d5,-(sp)
        bsr     mxdrv_pdx_mix_block
        move.l  (sp)+,d5
        addi.l  #DSP_RT_PCM_WORD_COUNT,d5

        move.l  dsp_mixed_words,d0
        bsr     dsp_exchange
        VBH
        cmp.l   #DSP_REPLY_BLOCK_READY,d0
        bne     dsp_send_realtime_done
        clr.l   dsp_mixed_reply
        movem.l d3/a3,-(sp)
        VBV     vb_txt_blockwords,d5
        lea     dsp_mixed_words+4,a3
        move.l  d5,d3
        bsr     dsp_blast_paced
        move.l  d0,dsp_mixed_reply
        movem.l (sp)+,d3/a3
        move.l  dsp_mixed_reply,d0
dsp_send_realtime_done:
        move.l  (sp)+,d5
        rts

dsp_render_mixed_audio:
        move.l  d0,dsp_mixed_words
        lea     dsp_mixed_words+4,a3
dsp_render_mixed_loop:
        bsr     mxdrv_pdx_mix_frame
        move.l  d0,(a3)+
        move.l  d1,(a3)+
        dbra    d4,dsp_render_mixed_loop

        ; TOS's Dsp_BlkUnpacked handshakes only its first word: exchange the
        ; bare command for the DSP's parked-receiver token, then release the
        ; PCM block. A wrong token is returned for the caller's check.
        move.l  dsp_mixed_words,d0
        bsr     dsp_exchange
        cmp.l   #DSP_REPLY_BLOCK_READY,d0
        bne     dsp_send_mixed_done
        clr.l   dsp_mixed_reply
        move.l  dsp_mixed_words,d0
        movem.l d3/a3,-(sp)
        lea     dsp_mixed_words+4,a3
        move.l  #DSP_MIX_TRANSFER_WORDS-1,d3
        bsr     dsp_blast_paced
        move.l  d0,dsp_mixed_reply
        movem.l (sp)+,d3/a3
        bra     dsp_send_mixed_reply
dsp_send_mixed_reply:
        move.l  dsp_mixed_reply,d0
dsp_send_mixed_done:
        rts

        ifd     VERBOSE_BOOT
        data
vb_txt_blockwords:  dc.b 'block words      ',0
vb_txt_payloadsent: dc.b 'payload sent, awaiting reply',13,10,0
        even
        endc

        bss

dsp_tx_word:
        ds.l    1
dsp_rx_word:
        ds.l    1
dsp_queue_words:
        ds.l    2
dsp_queue_reply:
        ds.l    1
dsp_mixed_words:
        ds.l    DSP_MIX_TRANSFER_WORDS
dsp_mixed_words_end:
dsp_mixed_reply:
        ds.l    1
dsp_blast_ptr:
        ds.l    1
dsp_blast_count:
        ds.l    1
dsp_blast_reply:
        ds.l    1
dsp_stage_base:
        ds.l    1
dsp_stage_count:
        ds.l    1
dsp_stage_qbase:
        ds.l    1
dsp_stage_qcount:
        ds.l    1
dsp_stage_reply:
        ds.l    1                       ; loader-zeroed BSS = DSP_REPLY_OK
dsp_stage_posted:
        ds.b    1
dsp_stage_queued:
        ds.b    1
        even

        end
