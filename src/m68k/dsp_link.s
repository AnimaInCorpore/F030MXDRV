        include "xbios.i"
        include "verbose.i"
        include "protocol.i"

        global  dsp_exchange
        global  dsp_queue_write
        global  dsp_start_mixed_audio
        global  dsp_refill_mixed_audio
        global  dsp_start_realtime_audio
        global  dsp_refill_realtime_audio

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
        move.l  dsp_blast_ptr,a3
        move.l  dsp_blast_count,d3
dsp_blast_send_word:
        btst    #1,DSP_HOST_ISR
        beq.s   dsp_blast_send_word
        move.b  1(a3),DSP_HOST_DATA+1
        move.b  2(a3),DSP_HOST_DATA+2
        move.b  3(a3),DSP_HOST_DATA+3
        addq.l  #4,a3
        subq.l  #1,d3
        bne.s   dsp_blast_send_word
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

; Start/refill the 24.585 kHz, 32-frame-block renderer. Its 512-frame period
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

        end
