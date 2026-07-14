        global  mxdrv_pdx_lookup
        global  mxdrv_pdx_start
        global  mxdrv_pdx_decode
        global  mxdrv_pdx_reset
        global  mxdrv_pdx_voice_start
        global  mxdrv_pdx_voice_stop
        global  mxdrv_pdx_set_pan
        global  mxdrv_pdx_active_mask
        global  mxdrv_pdx_mix_frame

PDX_SAMPLE_COUNT        equ     96
PDX_TABLE_BYTES         equ     PDX_SAMPLE_COUNT*8

PDX_DECODER_POINTER     equ     0
PDX_DECODER_REMAINING   equ     4
PDX_DECODER_BYTE        equ     8
PDX_DECODER_NIBBLE      equ     9
PDX_DECODER_STEP        equ     10
PDX_DECODER_SIGNAL      equ     12
PDX_DECODER_BYTES       equ     14

PDX_VOICE_ACTIVE        equ     14
PDX_VOICE_RATE          equ     15
PDX_VOICE_VOLUME        equ     16
PDX_VOICE_PHASE         equ     18
PDX_VOICE_CURRENT       equ     20
PDX_VOICE_BYTES         equ     24
PDX_VOICE_COUNT         equ     8
PDX_RESAMPLE_DENOMINATOR equ    3021

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
        lea     pdx_adpcm_reference_state,a2
        bra     pdx_decoder_start

; Initialize the decoder state at a2 for one PDX entry.
pdx_decoder_start:
        bsr     mxdrv_pdx_lookup
        tst.l   d0
        ble     pdx_start_error
        move.l  a0,PDX_DECODER_POINTER(a2)
        move.l  d0,PDX_DECODER_REMAINING(a2)
        clr.b   PDX_DECODER_NIBBLE(a2)
        clr.b   PDX_DECODER_BYTE(a2)
        clr.w   PDX_DECODER_STEP(a2)
        move.w  #-2,PDX_DECODER_SIGNAL(a2)
        moveq   #0,d0
        rts

pdx_start_error:
        clr.l   PDX_DECODER_REMAINING(a2)
        moveq   #-1,d0
        rts

; Decode one MSM6258 output sample.
; out: d0.l = signed 16-bit sample, d1.l = 1 while a sample was produced
;      d0.l = 0, d1.l = 0 after the encoded entry has ended
mxdrv_pdx_decode:
        lea     pdx_adpcm_reference_state,a2

; Decode from the state at a2.
pdx_decoder_clock:
        tst.b   PDX_DECODER_NIBBLE(a2)
        bne     pdx_decode_high

        tst.l   PDX_DECODER_REMAINING(a2)
        beq     pdx_decode_end
        movea.l PDX_DECODER_POINTER(a2),a0
        moveq   #0,d0
        move.b  (a0)+,d0
        move.l  a0,PDX_DECODER_POINTER(a2)
        subq.l  #1,PDX_DECODER_REMAINING(a2)
        move.b  d0,PDX_DECODER_BYTE(a2)
        andi.w  #$000f,d0
        move.b  #1,PDX_DECODER_NIBBLE(a2)
        bra     pdx_decode_nibble

pdx_decode_high:
        moveq   #0,d0
        move.b  PDX_DECODER_BYTE(a2),d0
        lsr.w   #4,d0
        clr.b   PDX_DECODER_NIBBLE(a2)

pdx_decode_nibble:
        moveq   #0,d2
        move.w  PDX_DECODER_STEP(a2),d2
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
        move.w  PDX_DECODER_SIGNAL(a2),d5
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
        move.w  d5,PDX_DECODER_SIGNAL(a2)

        moveq   #0,d2
        move.b  d0,d2
        andi.w  #7,d2
        lea     pdx_adpcm_index_shift(pc),a0
        move.b  (a0,d2.w),d2
        ext.w   d2
        add.w   PDX_DECODER_STEP(a2),d2
        bpl     pdx_decode_clamp_step_high
        moveq   #0,d2
pdx_decode_clamp_step_high:
        cmpi.w  #48,d2
        ble     pdx_decode_store_step
        moveq   #48,d2
pdx_decode_store_step:
        move.w  d2,PDX_DECODER_STEP(a2)

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

; Reset decoder and all eight PCM8-style voice slots.
mxdrv_pdx_reset:
        lea     pdx_adpcm_reference_state,a0
        moveq   #0,d0
        moveq   #103,d1                ; 208 bytes, including pan/padding
pdx_reset_loop:
        move.w  d0,(a0)+
        dbra    d1,pdx_reset_loop
        rts

; Start one codec-rate PDX voice.
; in: d0.w=voice 0-7, d1.w=sample 0-95, d2.w=rate 0-4,
;     d3.w=pan 1 left/2 right/3 both, d4.w=volume 0-15 (2 dB steps)
; out: d0.l=0 on success, -1 on invalid/empty input
mxdrv_pdx_voice_start:
        moveq   #0,d5
        move.w  d0,d5
        cmpi.w  #PDX_VOICE_COUNT,d5
        bcc     pdx_voice_error
        cmpi.w  #4,d2
        bhi     pdx_voice_error
        cmpi.w  #1,d3
        bcs     pdx_voice_error
        cmpi.w  #3,d3
        bhi     pdx_voice_error
        cmpi.w  #15,d4
        bhi     pdx_voice_error

        mulu.w  #PDX_VOICE_BYTES,d5
        lea     pdx_voices,a2
        adda.l  d5,a2
        movem.l d2-d4,-(sp)
        move.w  d1,d0
        bsr     pdx_decoder_start
        movem.l (sp)+,d2-d4
        tst.l   d0
        bne     pdx_voice_state_error

        move.b  d2,PDX_VOICE_RATE(a2)
        move.b  d4,PDX_VOICE_VOLUME(a2)
        clr.w   PDX_VOICE_PHASE(a2)
        move.b  d3,pdx_pcm_pan
        bsr     pdx_decoder_clock
        tst.l   d1
        beq     pdx_voice_state_error
        move.w  d0,PDX_VOICE_CURRENT(a2)
        move.b  #1,PDX_VOICE_ACTIVE(a2)
        moveq   #0,d0
        rts

pdx_voice_state_error:
        clr.b   PDX_VOICE_ACTIVE(a2)
pdx_voice_error:
        moveq   #-1,d0
        rts

; Stop one PDX voice.
; in: d0.w=voice 0-7
mxdrv_pdx_voice_stop:
        moveq   #0,d1
        move.w  d0,d1
        cmpi.w  #PDX_VOICE_COUNT,d1
        bcc     pdx_voice_error
        mulu.w  #PDX_VOICE_BYTES,d1
        lea     pdx_voices,a0
        adda.l  d1,a0
        clr.b   PDX_VOICE_ACTIVE(a0)
        clr.w   PDX_VOICE_CURRENT(a0)
        moveq   #0,d0
        rts

; PCM8's hardware pan is common to all channels.
; in: d0.w=1 left, 2 right, 3 both
mxdrv_pdx_set_pan:
        cmpi.w  #1,d0
        bcs     pdx_voice_error
        cmpi.w  #3,d0
        bhi     pdx_voice_error
        move.b  d0,pdx_pcm_pan
        moveq   #0,d0
        rts

; Return one bit per active PDX voice.
mxdrv_pdx_active_mask:
        lea     pdx_voices,a0
        moveq   #0,d0
        moveq   #1,d1
        moveq   #PDX_VOICE_COUNT-1,d2
pdx_active_mask_loop:
        tst.b   PDX_VOICE_ACTIVE(a0)
        beq     pdx_active_mask_next
        or.w    d1,d0
pdx_active_mask_next:
        lsl.w   #1,d1
        lea     PDX_VOICE_BYTES(a0),a0
        dbra    d2,pdx_active_mask_loop
        rts

; Mix one Falcon codec frame from all active voices. Each voice uses exact
; zero-order rate conversion with a common denominator of 3021 codec phases.
; out: d0.l=left signed 16-bit sample, d1.l=right signed 16-bit sample
mxdrv_pdx_mix_frame:
        moveq   #0,d6                  ; mono accumulator before hardware pan
        lea     pdx_voices,a2
        moveq   #PDX_VOICE_COUNT-1,d7
pdx_mix_voice_loop:
        tst.b   PDX_VOICE_ACTIVE(a2)
        beq     pdx_mix_next_voice

        moveq   #0,d0
        move.w  PDX_VOICE_CURRENT(a2),d0
        ext.l   d0
        moveq   #0,d1
        move.b  PDX_VOICE_VOLUME(a2),d1
        add.w   d1,d1
        lea     pdx_volume_q12(pc),a0
        muls.w  (a0,d1.w),d0
        asr.l   #8,d0
        asr.l   #4,d0
        add.l   d0,d6

        moveq   #0,d2
        move.w  PDX_VOICE_PHASE(a2),d2
        moveq   #0,d1
        move.b  PDX_VOICE_RATE(a2),d1
        add.w   d1,d1
        lea     pdx_rate_phase(pc),a0
        add.w   (a0,d1.w),d2
        cmpi.w  #PDX_RESAMPLE_DENOMINATOR,d2
        bcs     pdx_mix_store_phase
        subi.w  #PDX_RESAMPLE_DENOMINATOR,d2
        move.w  d2,PDX_VOICE_PHASE(a2)
        bsr     pdx_decoder_clock
        tst.l   d1
        beq     pdx_mix_end_voice
        move.w  d0,PDX_VOICE_CURRENT(a2)
        bra     pdx_mix_next_voice

pdx_mix_store_phase:
        move.w  d2,PDX_VOICE_PHASE(a2)
        bra     pdx_mix_next_voice

pdx_mix_end_voice:
        clr.b   PDX_VOICE_ACTIVE(a2)
        clr.w   PDX_VOICE_CURRENT(a2)

pdx_mix_next_voice:
        lea     PDX_VOICE_BYTES(a2),a2
        dbra    d7,pdx_mix_voice_loop

        cmpi.l  #32767,d6
        ble     pdx_mix_clamp_low
        move.l  #32767,d6
pdx_mix_clamp_low:
        cmpi.l  #-32768,d6
        bge     pdx_mix_pan
        move.l  #-32768,d6

pdx_mix_pan:
        moveq   #0,d0
        moveq   #0,d1
        moveq   #0,d2
        move.b  pdx_pcm_pan,d2
        btst    #0,d2
        beq     pdx_mix_right
        move.l  d6,d0
pdx_mix_right:
        btst    #1,d2
        beq     pdx_mix_done
        move.l  d6,d1
pdx_mix_done:
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

; Input samples per Falcon codec frame, all expressed over denominator 3021.
pdx_rate_phase:
        dc.w    240,320,480,640,960

; PCM8 volume codes 0-15 are -16 dB through +14 dB in 2 dB steps. These
; signed Q12 gains make code 8 exactly unity.
pdx_volume_q12:
        dc.w    649,817,1029,1295,1631,2053,2584,3254
        dc.w    4096,5157,6492,8173,10289,12953,16306,20529

        bss

pdx_adpcm_reference_state:
        ds.b    PDX_DECODER_BYTES
pdx_voices:
        ds.b    PDX_VOICE_COUNT*PDX_VOICE_BYTES
pdx_pcm_pan:
        ds.b    1
        ds.b    1                       ; keep reset span word-aligned
        even

        end
