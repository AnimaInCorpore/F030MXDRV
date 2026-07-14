        include "protocol.i"

        global  mxdrv_reset
        global  mxdrv_write_ym2151
        global  mxdrv_query_phase_step
        global  mxdrv_clock_sample
        global  mxdrv_query_right
        global  mxdrv_query_envelope
        global  mxdrv_query_status
        global  mxdrv_query_lfo
        global  mxdrv_opm_buffer

        text

; Reset the DSP-owned YM2151 core.
; out: d0.l = DSP reply
mxdrv_reset:
        lea     mxdrv_opm_buffer,a0
        moveq   #0,d0
        move.w  #255,d3
.clear_opm:
        move.b  d0,(a0)+
        dbra    d3,.clear_opm
        move.l  #DSP_CMD_RESET,d0
        bra     dsp_exchange

; Porting seam for mxdrv17.s:WriteOPM.
; in:  d1.b = YM2151 register, d2.b = data (original MXDRV convention)
; out: d0.l = DSP reply
;
mxdrv_write_ym2151:
        moveq   #0,d0
        move.b  d1,d0
        lea     mxdrv_opm_buffer,a0
        move.b  d2,(a0,d0.w)           ; MXDRV call $10-compatible mirror
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

; Advance the DSP-owned YM2151 by one native 62.5 kHz sample.
; out: d0.l = signed left sample in the low 24 bits
mxdrv_clock_sample:
        move.l  #DSP_CMD_CLOCK,d0
        bra     dsp_exchange

; Fetch the right half of the most recently generated sample.
; out: d0.l = signed right sample in the low 24 bits
mxdrv_query_right:
        move.l  #DSP_CMD_QUERY_RIGHT,d0
        bra     dsp_exchange

; Fetch one logical operator's native envelope attenuation (0-1023).
; in:  d1.b = logical operator index (channel*4 + operator)
mxdrv_query_envelope:
        moveq   #0,d0
        move.b  d1,d0
        ori.l   #DSP_CMD_QUERY_ENV,d0
        bra     dsp_exchange

; Fetch the YM2151 status byte (timer flags plus bit 7 while write-busy).
mxdrv_query_status:
        move.l  #DSP_CMD_QUERY_STATUS,d0
        bra     dsp_exchange

; Fetch phase:AM:PM as three packed bytes for conformance tests.
mxdrv_query_lfo:
        move.l  #DSP_CMD_QUERY_LFO,d0
        bra     dsp_exchange

        bss

mxdrv_opm_buffer:
        ds.b    256

        end
