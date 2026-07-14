        include "xbios.i"

        global  dsp_exchange

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

        bss

dsp_tx_word:
        ds.l    1
dsp_rx_word:
        ds.l    1

        end
