        include "xbios.i"
        include "protocol.i"

        global  dsp_exchange
        global  dsp_queue_write

        text

; Exchange one packed 24-bit protocol word with the DSP.
; in:  d0.l = command (low 24 bits)
; out: d0.l = reply   (low 24 bits)
dsp_exchange:
        move.l  d0,dsp_tx_word
        clr.l   dsp_rx_word
        Dsp_BlkUnpacked dsp_tx_word,#1,dsp_rx_word,#1
        move.l  dsp_rx_word,d0
        rts

; Queue one YM2151 write at an exact native-sample offset in the next bounded
; render. The DSP transaction is a timestamp header followed by a normal packed
; write word.
; in:  d0.w = timestamp (0-1279), d1.b = register, d2.b = data
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

        bss

dsp_tx_word:
        ds.l    1
dsp_rx_word:
        ds.l    1
dsp_queue_words:
        ds.l    2
dsp_queue_reply:
        ds.l    1

        end
