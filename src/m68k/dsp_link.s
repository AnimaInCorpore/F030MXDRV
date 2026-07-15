        include "xbios.i"
        include "protocol.i"

        global  dsp_exchange
        global  dsp_queue_write
        global  dsp_start_mixed_audio
        global  dsp_refill_mixed_audio
        global  dsp_start_realtime_audio
        global  dsp_refill_realtime_audio

DSP_MIX_TRANSFER_WORDS equ   1+DSP_MIX_FRAME_COUNT*2
DSP_RT_MIX_TRANSFER_WORDS equ 1+DSP_RT_MIX_FRAME_COUNT*2

        text

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
        Dsp_BlkUnpacked dsp_queue_words,#2,dsp_queue_reply,#1
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

; Start/refill the codec-rate 64-frame-block renderer. Its 1024-frame period
; is exactly sixteen synthesis blocks and uses the same interleaved host PCM
; input shape as the exact/conformance transport.
dsp_start_realtime_audio:
        move.l  #DSP_CMD_START_RT_MIXED,d0
        move.w  #DSP_RT_MIX_FRAME_COUNT-1,d4
        bra     dsp_render_mixed_audio

dsp_refill_realtime_audio:
        move.l  #DSP_CMD_REFILL_RT_MIXED,d0
        move.w  #DSP_RT_MIX_FRAME_COUNT-1,d4

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
        cmpi.l  #DSP_CMD_START_RT_MIXED,d0
        beq     dsp_send_realtime_block
        cmpi.l  #DSP_CMD_REFILL_RT_MIXED,d0
        beq     dsp_send_realtime_block
        Dsp_BlkUnpacked dsp_mixed_words+4,#DSP_MIX_TRANSFER_WORDS-1,dsp_mixed_reply,#1
        bra     dsp_send_mixed_reply
dsp_send_realtime_block:
        Dsp_BlkUnpacked dsp_mixed_words+4,#DSP_RT_MIX_TRANSFER_WORDS-1,dsp_mixed_reply,#1
dsp_send_mixed_reply:
        move.l  dsp_mixed_reply,d0
dsp_send_mixed_done:
        rts

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
        ds.l    DSP_RT_MIX_TRANSFER_WORDS
dsp_mixed_words_end:
dsp_mixed_reply:
        ds.l    1

        end
