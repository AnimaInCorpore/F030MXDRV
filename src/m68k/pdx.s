        include "protocol.i"
        include "xbios.i"
        include "verbose.i"

        global  mxdrv_pdx_lookup
        global  mxdrv_pdx_start
        global  mxdrv_pdx_decode
        global  mxdrv_pdx_reset
        global  mxdrv_pdx_precache
        global  mxdrv_pdx_voice_start
        global  mxdrv_pdx_voice_stop
        global  mxdrv_pdx_voice_set_volume
        global  mxdrv_pdx_voice_volume
        global  mxdrv_pdx_set_pan
        global  mxdrv_pdx_active_mask
        global  mxdrv_pdx_mix_frame
        global  mxdrv_pdx_mix_block

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
PDX_VOICE_NEXT_VALID    equ     17
PDX_VOICE_PHASE         equ     18
PDX_VOICE_CURRENT       equ     20
PDX_VOICE_NEXT          equ     22
PDX_VOICE_SCALED_CURRENT equ    24
PDX_VOICE_SCALED_NEXT   equ     28
PDX_VOICE_CACHE_PTR     equ     32
PDX_VOICE_CACHE_LEFT    equ     36
PDX_VOICE_BYTES         equ     40
PDX_VOICE_COUNT         equ     8
PDX_RESAMPLE_DENOMINATOR equ    3021
PDX_MIX_BLOCK_FRAMES    equ     DSP_RT_MIX_FRAME_COUNT

; Bytes left untouched below the TPA ceiling for the supervisor/user stack
; TOS parked there at process entry. The driver's call depth is shallow, so
; this is generous rather than measured.
PDX_STACK_MARGIN        equ     65536

; Basepage fields used to locate the free TPA tail.
PDX_BP_HITPA            equ     $04
PDX_BP_BSSBASE          equ     $18
PDX_BP_BSSLEN           equ     $1c


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

; Decode from the state at a2. The step arithmetic scratches d3-d5, which
; callers legitimately hold across per-frame mixing — the PCM staging fill
; keeps its frame counter in d4, and an unsaved clobber here once let that
; loop run past its buffer into the MXDRV state block.
pdx_decoder_clock:
        movem.l d3-d5,-(sp)
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
        movem.l (sp)+,d3-d5
        rts

pdx_decode_end:
        moveq   #0,d0
        moveq   #0,d1
        movem.l (sp)+,d3-d5
        rts

; Reset decoder and all eight PCM8-style voice slots.
mxdrv_pdx_reset:
        lea     pdx_adpcm_reference_state,a0
        moveq   #0,d0
        move.w  #167,d1                ; 336 bytes, including pan/padding
pdx_reset_loop:
        move.w  d0,(a0)+
        dbra    d1,pdx_reset_loop
        rts

; Decode every PDX table entry into a linear cache once, right after a bank
; loads through call $03. This removes MSM6258 nibble decode from the
; realtime mixing path entirely: voice start and per-frame advance become
; bump-pointer reads into already-decoded samples (pdx_cache_start/
; pdx_cache_advance below), while pdx_decoder_start/pdx_decoder_clock stay
; exactly as they were for the exact conformance API and for building this
; cache itself, so the decode algorithm is never duplicated or changed.
;
; The cache needs exactly twice the loaded bank's byte count in samples:
; one sample per nibble, and the 96 entries cannot span more encoded bytes
; in total than the bank itself holds.
;
; That workspace comes from this program's own TPA, not from GEMDOS. A
; static worst-case reservation does not fit — Hatari's loader refuses the
; program outright once BSS grows by about a megabyte — and Malloc cannot
; serve it either, because a TOS process owns its whole TPA until it calls
; Mshrink and this driver never does, so Malloc returns 0 (not a negative
; error). Pexec already handed us everything between the end of BSS and the
; stack at the TPA ceiling, so the cache is placed there directly.
;
; If the bank is empty or the tail is too small, pdx_decoded_cache_ptr stays
; zero and pdx_cache_start/pdx_cache_advance fall back to decoding live from
; each voice's own MSM6258 state, exactly as before this cache existed. The
; only cost of that path is the CPU time the cache was meant to save.
mxdrv_pdx_precache:
        clr.l   pdx_decoded_used
        clr.l   pdx_decoded_capacity
        clr.l   pdx_decoded_cache_ptr

        VBV     vb_txt_precache,mxdrv_pdx_size
        move.l  mxdrv_pdx_size,d0
        beq     pdx_precache_clear_index
        move.l  d0,d1
        lsl.l   #2,d1                   ; bytes needed = size * 2 samples * 2 bytes
        move.l  mxdrv_basepage,d2
        beq     pdx_precache_clear_index
        movea.l d2,a0
        move.l  PDX_BP_BSSBASE(a0),d2
        add.l   PDX_BP_BSSLEN(a0),d2    ; first byte past our BSS
        addq.l  #7,d2
        andi.l  #-8,d2                  ; longword-safe alignment
        move.l  PDX_BP_HITPA(a0),d3
        subi.l  #PDX_STACK_MARGIN,d3    ; keep clear of the entry stack
        cmp.l   d2,d3
        bls     pdx_precache_clear_index
        sub.l   d2,d3                   ; bytes actually available
        cmp.l   d1,d3
        bcs     pdx_precache_clear_index

        move.l  d2,pdx_decoded_cache_ptr
        move.l  mxdrv_pdx_size,d0
        add.l   d0,d0
        move.l  d0,pdx_decoded_capacity  ; capacity in samples (words)

        ifd     VERBOSE_BOOT
        VB      vb_txt_cache_ptr
        move.l  pdx_decoded_cache_ptr,d0
        VBH
        VB      vb_txt_cache_cap
        move.l  pdx_decoded_capacity,d0
        VBH
        endc

        movea.l pdx_decoded_cache_ptr,a5
        moveq   #0,d6
pdx_precache_index:
        move.l  d6,d0
        lsl.l   #2,d0
        lea     pdx_decoded_offset,a3
        adda.l  d0,a3
        lea     pdx_decoded_count,a4
        adda.l  d0,a4
        move.l  pdx_decoded_used,(a3)
        clr.l   (a4)

        lea     pdx_precache_state,a2
        move.w  d6,d0
        bsr     pdx_decoder_start
        tst.l   d0
        bne     pdx_precache_next

pdx_precache_decode:
        move.l  pdx_decoded_used,d0
        cmp.l   pdx_decoded_capacity,d0
        bcc     pdx_precache_done_entry
        bsr     pdx_decoder_clock
        tst.l   d1
        beq     pdx_precache_done_entry
        move.w  d0,(a5)+
        addq.l  #1,pdx_decoded_used
        bra     pdx_precache_decode

pdx_precache_done_entry:
        move.l  pdx_decoded_used,d0
        sub.l   (a3),d0
        move.l  d0,(a4)

pdx_precache_next:
        addq.l  #1,d6
        cmpi.l  #PDX_SAMPLE_COUNT,d6
        bcs     pdx_precache_index
        rts

; No bank loaded or the allocation failed: every entry decodes to nothing,
; which the realtime path already renders as silence.
pdx_precache_clear_index:
        VB      vb_txt_nocache
        lea     pdx_decoded_offset,a0
        moveq   #0,d0
        move.w  #PDX_SAMPLE_COUNT*2-1,d1
pdx_precache_clear_index_loop:
        move.l  d0,(a0)+
        dbra    d1,pdx_precache_clear_index_loop
        rts

; Drop-in replacements for pdx_decoder_start/pdx_decoder_clock that read the
; cache mxdrv_pdx_precache built instead of running the MSM6258 algorithm.
; Same calling convention as the routines they replace, so every caller below
; only had to change which subroutine it invokes. With no cache available
; they tail into those very routines, so the voice decodes live from its own
; embedded decoder state and behaviour is identical either way.
; in: a2 = voice struct, d0.w = sample number (0-95)
; out: d0.l = 0 on success, -1 for an empty/invalid entry
pdx_cache_start:
        tst.l   pdx_decoded_cache_ptr
        bne     pdx_cache_start_cached
        clr.l   PDX_VOICE_CACHE_PTR(a2) ; marks this voice as live-decoding
        bra     pdx_decoder_start
pdx_cache_start_cached:
        moveq   #0,d1
        move.w  d0,d1
        lsl.l   #2,d1
        lea     pdx_decoded_count,a0
        move.l  (a0,d1.l),d0
        tst.l   d0
        beq     pdx_cache_start_error
        move.l  d0,PDX_VOICE_CACHE_LEFT(a2)
        lea     pdx_decoded_offset,a0
        move.l  (a0,d1.l),d0
        add.l   d0,d0
        movea.l pdx_decoded_cache_ptr,a0
        adda.l  d0,a0
        move.l  a0,PDX_VOICE_CACHE_PTR(a2)
        moveq   #0,d0
        rts
pdx_cache_start_error:
        moveq   #-1,d0
        rts

; in: a2 = voice struct
; out: d0.l = signed 16-bit sample, d1.l = 1 while produced, 0 when exhausted
pdx_cache_advance:
        tst.l   PDX_VOICE_CACHE_PTR(a2)
        beq     pdx_decoder_clock       ; live-decoding voice
        tst.l   PDX_VOICE_CACHE_LEFT(a2)
        beq     pdx_cache_advance_done
        movea.l PDX_VOICE_CACHE_PTR(a2),a0
        move.w  (a0)+,d0
        ext.l   d0
        move.l  a0,PDX_VOICE_CACHE_PTR(a2)
        subq.l  #1,PDX_VOICE_CACHE_LEFT(a2)
        moveq   #1,d1
        rts
pdx_cache_advance_done:
        moveq   #0,d0
        moveq   #0,d1
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
        bsr     pdx_cache_start
        movem.l (sp)+,d2-d4
        tst.l   d0
        bne     pdx_voice_state_error

        move.b  d2,PDX_VOICE_RATE(a2)
        move.b  d4,PDX_VOICE_VOLUME(a2)
        clr.w   PDX_VOICE_PHASE(a2)
        move.b  d3,pdx_pcm_pan
        bsr     pdx_cache_advance
        tst.l   d1
        beq     pdx_voice_state_error
        move.w  d0,PDX_VOICE_CURRENT(a2)
        bsr     pdx_cache_advance
        tst.l   d1
        beq     pdx_voice_single_sample
        move.w  d0,PDX_VOICE_NEXT(a2)
        move.b  #1,PDX_VOICE_NEXT_VALID(a2)
        bra     pdx_voice_started
pdx_voice_single_sample:
        move.w  PDX_VOICE_CURRENT(a2),PDX_VOICE_NEXT(a2)
        clr.b   PDX_VOICE_NEXT_VALID(a2)
pdx_voice_started:
        bsr     pdx_mix_rescale_voice
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
        clr.b   PDX_VOICE_NEXT_VALID(a0)
        clr.w   PDX_VOICE_CURRENT(a0)
        clr.w   PDX_VOICE_NEXT(a0)
        clr.l   PDX_VOICE_SCALED_CURRENT(a0)
        clr.l   PDX_VOICE_SCALED_NEXT(a0)
        clr.l   PDX_VOICE_CACHE_PTR(a0)
        clr.l   PDX_VOICE_CACHE_LEFT(a0)
        moveq   #0,d0
        rts

; Update/query one voice's PCM8 gain without restarting its ADPCM decoder.
; set in: d0.w=voice 0-7, d1.w=volume 0-15; out: d0.l=0/-1
mxdrv_pdx_voice_set_volume:
        moveq   #0,d2
        move.w  d0,d2
        cmpi.w  #PDX_VOICE_COUNT,d2
        bcc     pdx_voice_error
        cmpi.w  #15,d1
        bhi     pdx_voice_error
        mulu.w  #PDX_VOICE_BYTES,d2
        lea     pdx_voices,a0
        adda.l  d2,a0
        move.b  d1,PDX_VOICE_VOLUME(a0)
        movea.l a0,a2
        bsr     pdx_mix_rescale_voice
        moveq   #0,d0
        rts

; in: d0.w=voice 0-7; out: d0.l=volume 0-15, or -1
mxdrv_pdx_voice_volume:
        moveq   #0,d1
        move.w  d0,d1
        cmpi.w  #PDX_VOICE_COUNT,d1
        bcc     pdx_voice_error
        mulu.w  #PDX_VOICE_BYTES,d1
        lea     pdx_voices,a0
        adda.l  d1,a0
        moveq   #0,d0
        move.b  PDX_VOICE_VOLUME(a0),d0
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

; Mix one Falcon codec frame from all active voices. Each voice holds its
; cached MSM6258 point while the exact source clocks remain governed by the
; common 3021-phase rate accumulator. Production adds the two-tap FIR on DSP.
; out: d0.l=left signed 16-bit sample, d1.l=right signed 16-bit sample
mxdrv_pdx_mix_frame:
        moveq   #0,d6                  ; mono accumulator before hardware pan
        lea     pdx_voices,a2
        moveq   #PDX_VOICE_COUNT-1,d7
pdx_mix_voice_loop:
        tst.b   PDX_VOICE_ACTIVE(a2)
        beq     pdx_mix_next_voice

        moveq   #0,d2
        move.w  PDX_VOICE_PHASE(a2),d2
        bsr     pdx_mix_scaled_current
        add.l   d0,d6

        moveq   #0,d1
        move.b  PDX_VOICE_RATE(a2),d1
        add.w   d1,d1
        lea     pdx_rate_phase(pc),a0
        add.w   (a0,d1.w),d2
        cmpi.w  #PDX_RESAMPLE_DENOMINATOR,d2
        bcs     pdx_mix_store_phase
        subi.w  #PDX_RESAMPLE_DENOMINATOR,d2
        move.w  d2,PDX_VOICE_PHASE(a2)
        bsr     pdx_mix_advance_source
        tst.l   d1
        beq     pdx_mix_end_voice
        bra     pdx_mix_next_voice

pdx_mix_store_phase:
        move.w  d2,PDX_VOICE_PHASE(a2)
        bra     pdx_mix_next_voice

pdx_mix_end_voice:
        clr.b   PDX_VOICE_ACTIVE(a2)
        clr.b   PDX_VOICE_NEXT_VALID(a2)
        clr.w   PDX_VOICE_CURRENT(a2)
        clr.w   PDX_VOICE_NEXT(a2)
        clr.l   PDX_VOICE_SCALED_CURRENT(a2)
        clr.l   PDX_VOICE_SCALED_NEXT(a2)
        clr.l   PDX_VOICE_CACHE_PTR(a2)
        clr.l   PDX_VOICE_CACHE_LEFT(a2)

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

; Render one complete production PCM period into the host-port staging area.
; The PCM8 pan register is global, so the realtime wire format carries it once
; followed by 512 mono samples instead of expanding every frame to left/right
; on the 68030. Walking voices outside frames also avoids seven inactive-slot
; tests per frame. The stream remains exact-clock zero-order PCM; the DSP-side
; receive filter suppresses its strongest images without taxing the 68030.
; in: a3 = longword-aligned destination
; out: [a3] = pan (0-3), followed by DSP_RT_MIX_FRAME_COUNT signed samples
mxdrv_pdx_mix_block:
        moveq   #0,d0
        move.b  pdx_pcm_pan,d0
        move.l  d0,(a3)+

        ; When no PCM voice is sounding — every period of an FM-only song, and
        ; the common case between drum hits otherwise — emit the silent period
        ; directly and skip the clear, mix, and saturating-store passes over
        ; 512 frames.
        lea     pdx_voices,a2
        moveq   #PDX_VOICE_COUNT-1,d1
pdx_mix_block_silence_test:
        tst.b   PDX_VOICE_ACTIVE(a2)
        bne     pdx_mix_block_render
        lea     PDX_VOICE_BYTES(a2),a2
        dbra    d1,pdx_mix_block_silence_test
        moveq   #0,d0
        move.w  #PDX_MIX_BLOCK_FRAMES-1,d4
pdx_mix_block_silence:
        move.l  d0,(a3)+
        dbra    d4,pdx_mix_block_silence
        rts

pdx_mix_block_render:
        ; Eight zeroed registers per movem clear 32 bytes/instruction instead
        ; of one longword each; 512 frames divides the 8-register span evenly.
        ; d4 is dead here — the per-voice loop below sets it fresh before its
        ; first read — so all eight of d0-d7 are free for the broadcast.
        moveq   #0,d0
        move.l  d0,d1
        move.l  d0,d2
        move.l  d0,d3
        move.l  d0,d4
        move.l  d0,d5
        move.l  d0,d6
        move.l  d0,d7
        lea     pdx_mix_block_buffer,a1
        lea     pdx_mix_block_buffer+PDX_MIX_BLOCK_FRAMES*4,a0
pdx_mix_block_clear:
        movem.l d0-d7,(a1)
        adda.l  #32,a1
        cmpa.l  a0,a1
        bne     pdx_mix_block_clear

        lea     pdx_voices,a2
        moveq   #PDX_VOICE_COUNT-1,d7
pdx_mix_block_voice:
        tst.b   PDX_VOICE_ACTIVE(a2)
        beq     pdx_mix_block_next_voice

        lea     pdx_mix_block_buffer,a1
        move.w  #PDX_MIX_BLOCK_FRAMES-1,d4
        moveq   #0,d2
        move.w  PDX_VOICE_PHASE(a2),d2
        moveq   #0,d3
        move.b  PDX_VOICE_RATE(a2),d3
        add.w   d3,d3
        lea     pdx_rate_phase(pc),a0
        move.w  (a0,d3.w),d3
        move.l  PDX_VOICE_SCALED_CURRENT(a2),d6

pdx_mix_block_frame:
        move.l  (a1),d0
        add.l   d6,d0
        move.l  d0,(a1)+
        add.w   d3,d2
        cmpi.w  #PDX_RESAMPLE_DENOMINATOR,d2
        bcs     pdx_mix_block_frame_next
        subi.w  #PDX_RESAMPLE_DENOMINATOR,d2
        move.w  d2,PDX_VOICE_PHASE(a2)
        bsr     pdx_mix_advance_source
        tst.l   d1
        beq     pdx_mix_block_end_voice
        move.l  PDX_VOICE_SCALED_CURRENT(a2),d6
        moveq   #0,d2
        move.w  PDX_VOICE_PHASE(a2),d2
pdx_mix_block_frame_next:
        dbra    d4,pdx_mix_block_frame
        move.w  d2,PDX_VOICE_PHASE(a2)
        bra     pdx_mix_block_next_voice

pdx_mix_block_end_voice:
        clr.b   PDX_VOICE_ACTIVE(a2)
        clr.b   PDX_VOICE_NEXT_VALID(a2)
        clr.w   PDX_VOICE_CURRENT(a2)
        clr.w   PDX_VOICE_NEXT(a2)
        clr.l   PDX_VOICE_SCALED_CURRENT(a2)
        clr.l   PDX_VOICE_SCALED_NEXT(a2)
        clr.l   PDX_VOICE_CACHE_PTR(a2)
        clr.l   PDX_VOICE_CACHE_LEFT(a2)

pdx_mix_block_next_voice:
        lea     PDX_VOICE_BYTES(a2),a2
        dbra    d7,pdx_mix_block_voice

        ; Saturate only after all voices have accumulated, matching the scalar
        ; mixer, then leave panning to the DSP-side planar expansion.
        lea     pdx_mix_block_buffer,a1
        move.w  #PDX_MIX_BLOCK_FRAMES-1,d4
pdx_mix_block_store:
        move.l  (a1)+,d0
        cmpi.l  #32767,d0
        ble     pdx_mix_block_clamp_low
        move.l  #32767,d0
pdx_mix_block_clamp_low:
        cmpi.l  #-32768,d0
        bge     pdx_mix_block_sample_ready
        move.l  #-32768,d0
pdx_mix_block_sample_ready:
        move.l  d0,(a3)+
        dbra    d4,pdx_mix_block_store
        rts

; Return the cached volume-scaled source point. Reconstruction filtering is
; performed while the DSP expands this stream, leaving the stock 16 MHz 68030
; staging loop with no per-frame interpolation arithmetic.
pdx_mix_scaled_current:
        move.l  PDX_VOICE_SCALED_CURRENT(a2),d0
        rts

; Refresh the cached Q12-scaled endpoints after start or a live volume change.
pdx_mix_rescale_voice:
        moveq   #0,d0
        move.w  PDX_VOICE_CURRENT(a2),d0
        ext.l   d0
        bsr     pdx_mix_scale_sample
        move.l  d0,PDX_VOICE_SCALED_CURRENT(a2)
        moveq   #0,d0
        move.w  PDX_VOICE_NEXT(a2),d0
        ext.l   d0
        bsr     pdx_mix_scale_sample
        move.l  d0,PDX_VOICE_SCALED_NEXT(a2)
        rts

; Apply the current voice's PCM8 Q12 gain to signed d0.l.
pdx_mix_scale_sample:
        moveq   #0,d1
        move.b  PDX_VOICE_VOLUME(a2),d1
        add.w   d1,d1
        lea     pdx_volume_q12(pc),a0
        muls.w  (a0,d1.w),d0
        asr.l   #8,d0
        asr.l   #4,d0
        rts

; Advance to the prefetched source point after the exact rate accumulator
; crosses 3021. The final decoded point remains audible for one full source
; interval before the voice is retired.
; out: d1.l=1 while the voice still has a current point, 0 when complete
pdx_mix_advance_source:
        tst.b   PDX_VOICE_NEXT_VALID(a2)
        beq     pdx_mix_source_done
        move.w  PDX_VOICE_NEXT(a2),PDX_VOICE_CURRENT(a2)
        move.l  PDX_VOICE_SCALED_NEXT(a2),PDX_VOICE_SCALED_CURRENT(a2)
        bsr     pdx_cache_advance
        tst.l   d1
        beq     pdx_mix_source_tail
        move.w  d0,PDX_VOICE_NEXT(a2)
        bsr     pdx_mix_scale_sample
        move.l  d0,PDX_VOICE_SCALED_NEXT(a2)
        move.b  #1,PDX_VOICE_NEXT_VALID(a2)
        moveq   #1,d1
        rts
pdx_mix_source_tail:
        move.w  PDX_VOICE_CURRENT(a2),PDX_VOICE_NEXT(a2)
        move.l  PDX_VOICE_SCALED_CURRENT(a2),PDX_VOICE_SCALED_NEXT(a2)
        clr.b   PDX_VOICE_NEXT_VALID(a2)
        moveq   #1,d1
        rts
pdx_mix_source_done:
        moveq   #0,d1
        rts

        ifd     VERBOSE_BOOT
vb_txt_precache:  dc.b  'PDX bank bytes   ',0
vb_txt_cache_ptr: dc.b  'cache at         ',0
vb_txt_cache_cap: dc.b  'cache samples    ',0
vb_txt_nocache:   dc.b  'NO CACHE - decoding live',13,10,0
        even
        endc

; floor(16 * 1.1^step), step 0-48, from MAME's OKIM6258 decoder.
pdx_adpcm_steps:
        dc.w    16,17,19,21,23,25,28,31,34,37,41,45,50,55,60,66,73
        dc.w    80,88,97,107,118,130,143,157,173,190,209,230,253,279
        dc.w    307,337,371,408,449,494,544,598,658,724,796,876,963
        dc.w    1060,1166,1282,1411,1552

pdx_adpcm_index_shift:
        dc.b    -1,-1,-1,-1,2,4,6,8
        even

; Input samples per 24.585 kHz Falcon codec frame. The quality clock is exactly
; half the former 49.17 kHz rate, so doubling every numerator retains the same
; denominator and the exact five MSM6258 source clocks without drift.
pdx_rate_phase:
        dc.w    480,640,960,1280,1920

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
pdx_mix_block_buffer:
        ds.l    PDX_MIX_BLOCK_FRAMES
        even

; Precache state: rebuilt in full on every call $03, so none of this needs a
; place in mxdrv_pdx_reset's clear span. pdx_precache_state is a private
; decoder scratch, kept separate from pdx_adpcm_reference_state so building
; the cache never disturbs the exact conformance API's own decoder.
pdx_precache_state:
        ds.b    PDX_DECODER_BYTES
        even
pdx_decoded_used:
        ds.l    1
pdx_decoded_offset:
        ds.l    PDX_SAMPLE_COUNT
pdx_decoded_count:
        ds.l    PDX_SAMPLE_COUNT
; Malloc'd to exactly 2x the loaded bank's byte size by mxdrv_pdx_precache;
; zero when no bank has been cached (nothing allocated, or allocation
; failed).  pdx_decoded_capacity is the same size expressed in samples.
pdx_decoded_cache_ptr:
        ds.l    1
pdx_decoded_capacity:
        ds.l    1

        end
