        global  mxdrv_pdx_lookup
        global  mxdrv_pdx_start
        global  mxdrv_pdx_decode

PDX_SAMPLE_COUNT        equ     96
PDX_TABLE_BYTES         equ     PDX_SAMPLE_COUNT*8

        text

; Resolve one standard PDX table entry against the copied bank.
; in:  d0.w = sample number (0-95)
; out: d0.l = encoded byte length, a0 = first ADPCM byte
;      d0.l = 0 and a0 = 0 for an empty entry
;      d0.l = -1 and a0 = 0 for an invalid index/bank/entry
mxdrv_pdx_lookup:
        moveq   #0,d1
        move.w  d0,d1
        cmpi.w  #PDX_SAMPLE_COUNT,d1
        bcc     pdx_lookup_error

        move.l  mxdrv_pdx_size,d2
        cmpi.l  #PDX_TABLE_BYTES,d2
        bcs     pdx_lookup_error

        lsl.w   #3,d1
        lea     mxdrv_pdx_buffer,a0
        lea     (a0,d1.w),a1
        move.l  4(a1),d0
        beq     pdx_lookup_empty

        move.l  (a1),d3
        cmpi.l  #PDX_TABLE_BYTES,d3
        bcs     pdx_lookup_error
        cmp.l   d2,d3
        bhi     pdx_lookup_error

        move.l  d2,d1
        sub.l   d3,d1
        cmp.l   d1,d0
        bhi     pdx_lookup_error

        lea     mxdrv_pdx_buffer,a0
        adda.l  d3,a0
        rts

pdx_lookup_empty:
        suba.l  a0,a0
        moveq   #0,d0
        rts

pdx_lookup_error:
        suba.l  a0,a0
        moveq   #-1,d0
        rts

; Start the single-voice reference decoder for one PDX entry. The MSM6258
; begins playback with signal=-2 and step=0 and consumes each byte low nibble
; first, matching MAME's X68000 device configuration.
; in:  d0.w = sample number
; out: d0.l = 0 on start, -1 for empty/invalid entries
mxdrv_pdx_start:
        bsr     mxdrv_pdx_lookup
        tst.l   d0
        ble     pdx_start_error
        move.l  a0,pdx_adpcm_pointer
        move.l  d0,pdx_adpcm_remaining
        clr.b   pdx_adpcm_nibble
        clr.b   pdx_adpcm_byte
        clr.w   pdx_adpcm_step
        move.w  #-2,pdx_adpcm_signal
        moveq   #0,d0
        rts

pdx_start_error:
        clr.l   pdx_adpcm_remaining
        moveq   #-1,d0
        rts

; Decode one MSM6258 output sample.
; out: d0.l = signed 16-bit sample, d1.l = 1 while a sample was produced
;      d0.l = 0, d1.l = 0 after the encoded entry has ended
mxdrv_pdx_decode:
        tst.b   pdx_adpcm_nibble
        bne     pdx_decode_high

        tst.l   pdx_adpcm_remaining
        beq     pdx_decode_end
        movea.l pdx_adpcm_pointer,a0
        moveq   #0,d0
        move.b  (a0)+,d0
        move.l  a0,pdx_adpcm_pointer
        subq.l  #1,pdx_adpcm_remaining
        move.b  d0,pdx_adpcm_byte
        andi.w  #$000f,d0
        move.b  #1,pdx_adpcm_nibble
        bra     pdx_decode_nibble

pdx_decode_high:
        moveq   #0,d0
        move.b  pdx_adpcm_byte,d0
        lsr.w   #4,d0
        clr.b   pdx_adpcm_nibble

pdx_decode_nibble:
        moveq   #0,d2
        move.w  pdx_adpcm_step,d2
        add.w   d2,d2
        lea     pdx_adpcm_steps(pc),a0
        move.w  (a0,d2.w),d3

        move.w  d3,d4
        lsr.w   #3,d4
        btst    #0,d0
        beq     pdx_decode_bit1
        move.w  d3,d5
        lsr.w   #2,d5
        add.w   d5,d4
pdx_decode_bit1:
        btst    #1,d0
        beq     pdx_decode_bit2
        move.w  d3,d5
        lsr.w   #1,d5
        add.w   d5,d4
pdx_decode_bit2:
        btst    #2,d0
        beq     pdx_decode_apply
        add.w   d3,d4

pdx_decode_apply:
        move.w  pdx_adpcm_signal,d5
        btst    #3,d0
        bne     pdx_decode_negative
        add.w   d4,d5
        bra     pdx_decode_clamp_high
pdx_decode_negative:
        sub.w   d4,d5

pdx_decode_clamp_high:
        cmpi.w  #511,d5
        ble     pdx_decode_clamp_low
        move.w  #511,d5
pdx_decode_clamp_low:
        cmpi.w  #-512,d5
        bge     pdx_decode_store_signal
        move.w  #-512,d5
pdx_decode_store_signal:
        move.w  d5,pdx_adpcm_signal

        moveq   #0,d2
        move.b  d0,d2
        andi.w  #7,d2
        lea     pdx_adpcm_index_shift(pc),a0
        move.b  (a0,d2.w),d2
        ext.w   d2
        add.w   pdx_adpcm_step,d2
        bpl     pdx_decode_clamp_step_high
        moveq   #0,d2
pdx_decode_clamp_step_high:
        cmpi.w  #48,d2
        ble     pdx_decode_store_step
        moveq   #48,d2
pdx_decode_store_step:
        move.w  d2,pdx_adpcm_step

        moveq   #0,d0
        move.w  d5,d0
        ext.l   d0
        lsl.l   #4,d0
        moveq   #1,d1
        rts

pdx_decode_end:
        moveq   #0,d0
        moveq   #0,d1
        rts

; floor(16 * 1.1^step), step 0-48, from MAME's OKIM6258 decoder.
pdx_adpcm_steps:
        dc.w    16,17,19,21,23,25,28,31,34,37,41,45,50,55,60,66,73
        dc.w    80,88,97,107,118,130,143,157,173,190,209,230,253,279
        dc.w    307,337,371,408,449,494,544,598,658,724,796,876,963
        dc.w    1060,1166,1282,1411,1552

pdx_adpcm_index_shift:
        dc.b    -1,-1,-1,-1,2,4,6,8
        even

        bss

pdx_adpcm_pointer:
        ds.l    1
pdx_adpcm_remaining:
        ds.l    1
pdx_adpcm_byte:
        ds.b    1
pdx_adpcm_nibble:
        ds.b    1
pdx_adpcm_step:
        ds.w    1
pdx_adpcm_signal:
        ds.w    1
        even

        end
