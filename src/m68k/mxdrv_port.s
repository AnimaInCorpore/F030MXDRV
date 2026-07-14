        include "protocol.i"

        global  mxdrv_reset
        global  mxdrv_write_ym2151
        global  mxdrv_query_phase_step

        text

; Reset the DSP-owned YM2151 core.
; out: d0.l = DSP reply
mxdrv_reset:
        move.l  #DSP_CMD_RESET,d0
        bra     dsp_exchange

; Porting seam for mxdrv17.s:WriteOPM.
; in:  d1.b = YM2151 register, d2.b = data (original MXDRV convention)
; out: d0.l = DSP reply
;
; The original routine also mirrors into OPMBuf. The recreated driver should
; retain that mirror before calling here so MXDRV call $10 stays compatible.
mxdrv_write_ym2151:
        moveq   #0,d0
        move.b  d1,d0
        lsl.l   #8,d0
        move.b  d2,d0
        ori.l   #DSP_CMD_WRITE_REG,d0
        bra     dsp_exchange

; Development-time MAME conformance probe.
; in:  d1.b = channel (0-7), d2.b = logical operator (0-3)
; out: d0.l = current 20-bit phase step calculated by the DSP
mxdrv_query_phase_step:
        moveq   #0,d0
        move.b  d1,d0
        lsl.l   #8,d0
        move.b  d2,d0
        ori.l   #DSP_CMD_QUERY_PHASE,d0
        bra     dsp_exchange

        end
