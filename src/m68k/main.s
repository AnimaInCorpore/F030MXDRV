        include "xbios.i"
        include "protocol.i"
        include "ym2151_reference.i"
        include "pdx_adpcm_reference.i"

        global  start

DSP_X_WORDS     equ     8192
DSP_Y_WORDS     equ     8192
DSP_ABILITY     equ     3

SOUND_STEREO16  equ     1
SOUND_DSP_XMIT  equ     1
SOUND_DAC       equ     8
SOUND_CLK25M    equ     0
SOUND_CLK50K    equ     1
SOUND_NO_SHAKE  equ     1

        text

start:
        Cconws  banner

        movea.l 4(sp),a0              ; TOS basepage pointer at process entry
        lea     $80(a0),a0            ; length-prefixed command tail
        bsr     player_parse_tail
        move.l  d0,player_mode
        bmi     usage_failed

        Dsp_Reserve #DSP_X_WORDS,#DSP_Y_WORDS
        tst.l   d0
        bmi     reserve_failed

        ; XBIOS can boot at most 512 contiguous internal-P words. Install the
        ; embedded loader there, then stream the complete sparse program as
        ; unpacked 24-bit words. The loader acknowledges only after every
        ; section is resident and immediately enters the final reset vector.
        Dsp_ExecBoot dsp_bootstrap_image,#DSP_BOOT_WORDS,#DSP_ABILITY
        clr.l   dsp_stage2_reply
        Dsp_BlkUnpacked dsp_program_image,#DSP_STAGE2_TRANSFER_WORDS,dsp_stage2_reply,#1
        move.l  dsp_stage2_reply,d0
        cmp.l   #DSP_STAGE2_REPLY_OK,d0
        bne     load_failed

        move.l  #DSP_CMD_PING,d0
        bsr     dsp_exchange
        cmp.l   #DSP_REPLY_HELLO,d0
        bne     protocol_failed

        ; TOS's Dsp_BlkUnpacked handshakes only its first word, so ask for
        ; the DSP's parked-receiver token before releasing the table block.
        move.l  #DSP_CMD_LOAD_TABLES,d0
        bsr     dsp_exchange
        cmp.l   #DSP_REPLY_BLOCK_READY,d0
        bne     protocol_failed
        clr.l   dsp_table_reply
        Dsp_BlkUnpacked ym2151_table_upload+4,#YM_TABLE_UPLOAD_WORDS-1,dsp_table_reply,#1
        move.l  dsp_table_reply,d0
        cmp.l   #DSP_REPLY_OK,d0
        bne     protocol_failed

        moveq   #0,d0                  ; MXDRV call $00: reset
        bsr     mxdrv_call
        cmp.l   #DSP_REPLY_OK,d0
        bne     protocol_failed

        tst.l   player_mode
        beq     run_conformance
        bsr     player_run
        bra     clean_exit

run_conformance:
        bsr     player_selftest
        tst.l   d0
        bne     protocol_failed

        ; Load a standard 96-entry PDX bank through MXDRV call $03, validate
        ; its table, then decode one entry against the vendored MSM6258 oracle.
        moveq   #3,d0
        move.l  #pdx_test_bank_end-pdx_test_bank,d1
        lea     pdx_test_bank(pc),a1
        bsr     mxdrv_call
        tst.l   d0
        bne     protocol_failed

        moveq   #0,d0
        bsr     mxdrv_pdx_lookup
        cmpi.l  #8,d0
        bne     protocol_failed
        cmpi.b  #$70,(a0)
        bne     protocol_failed
        cmpi.b  #$ef,7(a0)
        bne     protocol_failed

        moveq   #1,d0                  ; empty entry
        bsr     mxdrv_pdx_lookup
        tst.l   d0
        bne     protocol_failed
        move.l  a0,d0
        bne     protocol_failed

        moveq   #2,d0                  ; nonempty data overlaps the table
        bsr     mxdrv_pdx_lookup
        cmpi.l  #-1,d0
        bne     protocol_failed

        moveq   #3,d0                  ; range extends beyond the copied bank
        bsr     mxdrv_pdx_lookup
        cmpi.l  #-1,d0
        bne     protocol_failed

        moveq   #96,d0                 ; sample number is outside 0-95
        bsr     mxdrv_pdx_lookup
        cmpi.l  #-1,d0
        bne     protocol_failed

        moveq   #0,d0
        bsr     mxdrv_pdx_start
        tst.l   d0
        bne     protocol_failed
        lea     pdx_adpcm_references(pc),a3
        moveq   #PDX_REF_ADPCM_COUNT-1,d6
.decode_pdx_sample:
        bsr     mxdrv_pdx_decode
        cmpi.l  #1,d1
        bne     protocol_failed
        cmp.l   (a3)+,d0
        bne     protocol_failed
        dbra    d6,.decode_pdx_sample

        bsr     mxdrv_pdx_decode        ; exactly two samples per encoded byte
        tst.l   d1
        bne     protocol_failed
        tst.l   d0
        bne     protocol_failed

        ; Start two independent PCM8-style voices over the same PDX entry.
        ; Their exact rational codec phases and 2 dB volume gains are compared
        ; against the generated host mixer oracle for twenty stereo frames.
        moveq   #0,d0                  ; voice 0
        moveq   #0,d1                  ; sample 0
        moveq   #4,d2                  ; 15.625 kHz
        moveq   #3,d3                  ; both outputs
        moveq   #8,d4                  ; unity gain
        bsr     mxdrv_pdx_voice_start
        tst.l   d0
        bne     protocol_failed

        moveq   #1,d0                  ; voice 1
        moveq   #0,d1
        moveq   #0,d2                  ; 3.90625 kHz
        moveq   #3,d3
        moveq   #0,d4                  ; -16 dB
        bsr     mxdrv_pdx_voice_start
        tst.l   d0
        bne     protocol_failed

        bsr     mxdrv_pdx_active_mask
        cmpi.l  #3,d0
        bne     protocol_failed

        moveq   #0,d0
        bsr     mxdrv_pdx_voice_volume
        cmpi.l  #8,d0
        bne     protocol_failed
        moveq   #1,d0
        bsr     mxdrv_pdx_voice_volume
        tst.l   d0
        bne     protocol_failed
        moveq   #1,d0
        moveq   #8,d1
        bsr     mxdrv_pdx_voice_set_volume
        tst.l   d0
        bne     protocol_failed
        moveq   #1,d0
        bsr     mxdrv_pdx_voice_volume
        cmpi.l  #8,d0
        bne     protocol_failed
        moveq   #1,d0
        moveq   #0,d1
        bsr     mxdrv_pdx_voice_set_volume
        tst.l   d0
        bne     protocol_failed

        lea     pdx_mix_references(pc),a3
        lea     pdx_mix_references_end(pc),a4
.mix_pdx_frame:
        bsr     mxdrv_pdx_mix_frame
        cmp.l   (a3)+,d0
        bne     protocol_failed
        cmp.l   d0,d1                  ; pan 3 sends the mono mix to both sides
        bne     protocol_failed
        cmpa.l  a4,a3
        bcs     .mix_pdx_frame

        moveq   #1,d0                  ; PCM8 pan is global: left only
        bsr     mxdrv_pdx_set_pan
        tst.l   d0
        bne     protocol_failed
        bsr     mxdrv_pdx_mix_frame
        cmpi.l  #PDX_REF_MIX_PAN_LEFT,d0
        bne     protocol_failed
        tst.l   d1
        bne     protocol_failed

        moveq   #0,d0
        bsr     mxdrv_pdx_voice_stop
        tst.l   d0
        bne     protocol_failed
        bsr     mxdrv_pdx_active_mask
        cmpi.l  #2,d0
        bne     protocol_failed

        moveq   #1,d0
        bsr     mxdrv_pdx_voice_stop
        tst.l   d0
        bne     protocol_failed
        bsr     mxdrv_pdx_active_mask
        tst.l   d0
        bne     protocol_failed

        moveq   #8,d0                  ; reject a ninth voice
        moveq   #0,d1
        moveq   #0,d2
        moveq   #3,d3
        moveq   #8,d4
        bsr     mxdrv_pdx_voice_start
        cmpi.l  #-1,d0
        bne     protocol_failed

        moveq   #0,d0                  ; pan 0 is stop, not an output position
        bsr     mxdrv_pdx_set_pan
        cmpi.l  #-1,d0
        bne     protocol_failed

        ; Copy and start a bounded MDX image through calls $02/$04. Track 0
        ; executes raw OPM/tempo commands and an FM note; track 8 triggers PDX
        ; entry 0. Track 1 proves F6/F5 looping and F4 final-pass escape.
        moveq   #2,d0
        move.l  #mdx_test_song_end-mdx_test_song,d1
        lea     mdx_test_song(pc),a1
        bsr     mxdrv_call
        tst.l   d0
        bne     protocol_failed

        moveq   #8,d0                  ; raw MDX title is ABI-visible
        bsr     mxdrv_call
        move.l  d0,a0
        cmpi.b  #'M',(a0)
        bne     protocol_failed

        moveq   #4,d0
        bsr     mxdrv_call
        tst.l   d0
        bne     protocol_failed
        bsr     mxdrv_mdx_active_mask
        cmpi.l  #$ffff,d0
        bne     protocol_failed
        bsr     mxdrv_mdx_timer_period
        cmpi.l  #896,d0                ; ($100-$c8)*16 native samples
        bne     protocol_failed

        bsr     mxdrv_mdx_timer_service
        cmpi.l  #$0103,d0
        bne     protocol_failed
        bsr     mxdrv_mdx_timer_period
        cmpi.l  #1472,d0               ; FF $a4: ($100-$a4)*16
        bne     protocol_failed
        lea     mxdrv_mdx_buffer,a0
        cmpi.b  #2,mdx_test_repeat_work-mdx_test_song(a0)
        bne     protocol_failed
        moveq   #$10,d0                ; raw FE, FF, KF/KC and key-on landed
        bsr     mxdrv_call
        move.l  d0,a0
        cmpi.b  #$5a,$1b(a0)
        bne     protocol_failed
        cmpi.b  #$a4,$12(a0)
        bne     protocol_failed
        cmpi.b  #$14,$30(a0)
        bne     protocol_failed
        cmpi.b  #$00,$28(a0)
        bne     protocol_failed
        cmpi.b  #$78,$08(a0)
        bne     protocol_failed
        cmpi.b  #$c0,$20(a0)           ; FD voice 1, pan 3, algorithm 0
        bne     protocol_failed
        cmpi.b  #$01,$40(a0)
        bne     protocol_failed
        cmpi.b  #$01,$60(a0)           ; modulators retain their base TL
        bne     protocol_failed
        cmpi.b  #$02,$68(a0)
        bne     protocol_failed
        cmpi.b  #$03,$70(a0)
        bne     protocol_failed
        cmpi.b  #$06,$78(a0)           ; carrier base 4 + volume-15 offset 2
        bne     protocol_failed
        cmpi.b  #$1f,$80(a0)
        bne     protocol_failed
        bsr     mxdrv_pdx_active_mask
        cmpi.l  #1,d0
        bne     protocol_failed

        bsr     mxdrv_mdx_timer_service
        cmpi.l  #$0102,d0
        bne     protocol_failed
        lea     mxdrv_mdx_buffer,a0
        cmpi.b  #1,mdx_test_repeat_work-mdx_test_song(a0)
        bne     protocol_failed
        moveq   #$10,d0
        bsr     mxdrv_call
        move.l  d0,a0
        tst.b   $08(a0)                ; FM duration expired and keyed off
        bne     protocol_failed
        cmpi.b  #$11,$1a(a0)           ; second pass returned to loop body
        bne     protocol_failed

        bsr     mxdrv_mdx_timer_service
        tst.l   d0
        bne     protocol_failed
        bsr     mxdrv_pdx_active_mask
        tst.l   d0
        bne     protocol_failed
        tst.b   mxdrv_mdx_error
        bne     protocol_failed
        moveq   #$10,d0
        bsr     mxdrv_call
        move.l  d0,a0
        cmpi.b  #$33,$1a(a0)           ; F4 skipped F5 on the last pass
        bne     protocol_failed
        moveq   #$12,d0                ; stopped: paused=$01, playing=$00
        bsr     mxdrv_call
        cmpi.l  #$0100,d0
        bne     protocol_failed
        bsr     mxdrv_mdx_timer_ticks
        cmpi.l  #3,d0
        bne     protocol_failed
        bsr     mxdrv_mdx_timer_service ; stopped service calls do not advance
        tst.l   d0
        bne     protocol_failed
        bsr     mxdrv_mdx_timer_ticks
        cmpi.l  #3,d0
        bne     protocol_failed

        ; Normal and direct FM volume encodings rewrite only algorithm-0's C2
        ; carrier. FA/F9 step raw attenuation in the opposite byte direction
        ; from indexed volume, and $ff remains saturated at silence.
        moveq   #2,d0
        move.l  #mdx_volume_song_end-mdx_volume_song,d1
        lea     mdx_volume_song(pc),a1
        bsr     mxdrv_call
        tst.l   d0
        bne     protocol_failed
        moveq   #4,d0
        bsr     mxdrv_call
        tst.l   d0
        bne     protocol_failed

        bsr     mxdrv_mdx_timer_service
        cmpi.l  #1,d0
        bne     protocol_failed
        moveq   #$10,d0
        bsr     mxdrv_call
        move.l  d0,a0
        cmpi.b  #4,$78(a0)             ; direct $80 means +0 attenuation
        bne     protocol_failed

        bsr     mxdrv_mdx_timer_service
        cmpi.l  #1,d0
        bne     protocol_failed
        moveq   #$10,d0
        bsr     mxdrv_call
        move.l  d0,a0
        cmpi.b  #5,$78(a0)             ; FA: $80 -> $81
        bne     protocol_failed

        bsr     mxdrv_mdx_timer_service
        cmpi.l  #1,d0
        bne     protocol_failed
        moveq   #$10,d0
        bsr     mxdrv_call
        move.l  d0,a0
        cmpi.b  #4,$78(a0)             ; F9: $81 -> $80
        bne     protocol_failed

        bsr     mxdrv_mdx_timer_service
        cmpi.l  #1,d0
        bne     protocol_failed
        moveq   #$10,d0
        bsr     mxdrv_call
        move.l  d0,a0
        cmpi.b  #$7f,$78(a0)           ; base 4 + direct 127 saturates
        bne     protocol_failed

        bsr     mxdrv_mdx_timer_service
        cmpi.l  #1,d0
        bne     protocol_failed
        moveq   #$10,d0
        bsr     mxdrv_call
        move.l  d0,a0
        cmpi.b  #$7f,$78(a0)           ; FA clamps at direct $ff
        bne     protocol_failed
        bsr     mxdrv_mdx_timer_service
        tst.l   d0
        bne     protocol_failed
        tst.b   mxdrv_mdx_error
        bne     protocol_failed

        ; A syntactically valid MDX whose F5 target leaves the copied image
        ; must retire safely instead of decrementing arbitrary host memory.
        moveq   #2,d0
        move.l  #mdx_bad_repeat_song_end-mdx_bad_repeat_song,d1
        lea     mdx_bad_repeat_song(pc),a1
        bsr     mxdrv_call
        tst.l   d0
        bne     protocol_failed
        moveq   #4,d0
        bsr     mxdrv_call
        tst.l   d0
        bne     protocol_failed
        bsr     mxdrv_mdx_timer_service
        tst.l   d0
        bne     protocol_failed
        tst.b   mxdrv_mdx_error
        beq     protocol_failed

        ; Public play now claims idle MFP Timer A at 1024 Hz. Its IRQ may only
        ; accumulate pending Timer-B boundaries; foreground pumping performs
        ; the sequencer's XBIOS/DSP traffic. Three VBLs guarantee at least one
        ; pending tick at the default $c8 tempo without assuming exact phase.
        moveq   #2,d0
        move.l  #mdx_clock_song_end-mdx_clock_song,d1
        lea     mdx_clock_song(pc),a1
        bsr     mxdrv_call
        tst.l   d0
        bne     protocol_failed
        moveq   #4,d0
        bsr     mxdrv_call
        tst.l   d0
        bne     protocol_failed
        bsr     mxdrv_mdx_clock_installed
        cmpi.l  #1,d0
        bne     protocol_failed

        moveq   #2,d5
.wait_mdx_clock:
        Vsync
        dbra    d5,.wait_mdx_clock
        bsr     mxdrv_mdx_clock_pending
        tst.l   d0
        beq     protocol_failed
        bsr     mxdrv_mdx_clock_pump
        cmpi.l  #1,d0                  ; only the long-rest track remains
        bne     protocol_failed
        move.l  d1,d4
        beq     protocol_failed
        bsr     mxdrv_mdx_timer_ticks
        cmp.l   d4,d0
        bne     protocol_failed

        moveq   #5,d0                  ; stop restores Timer A/vector ownership
        bsr     mxdrv_call
        tst.l   d0
        bne     protocol_failed
        bsr     mxdrv_mdx_clock_installed
        tst.l   d0
        bne     protocol_failed

        move.l  #DSP_CMD_PING+$d10c,d0
        bsr     dsp_exchange
        cmp.l   #DSP_REPLY_HELLO,d0
        bne     protocol_failed

        move.l  #DSP_CMD_PING+$d009,d0
        bsr     dsp_exchange
        cmp.l   #DSP_REPLY_HELLO,d0
        bne     protocol_failed

        move.l  #DSP_CMD_PING+$ad18,d0
        bsr     dsp_exchange
        cmp.l   #DSP_REPLY_HELLO,d0
        bne     protocol_failed

        moveq   #3,d0                  ; an undersized bank has no valid table
        move.l  #767,d1
        lea     pdx_test_bank(pc),a1
        bsr     mxdrv_call
        tst.l   d0
        bne     protocol_failed
        moveq   #0,d0
        bsr     mxdrv_pdx_lookup
        cmpi.l  #-1,d0
        bne     protocol_failed

        ; Unique completion marker for the PDX lookup/decode integration gate.
        move.l  #DSP_CMD_PING+$ad0c,d0
        bsr     dsp_exchange
        cmp.l   #DSP_REPLY_HELLO,d0
        bne     protocol_failed

        moveq   #$1b,d1                ; exercise the MXDRV WriteOPM seam
        moveq   #0,d2
        bsr     mxdrv_write_ym2151
        cmp.l   #DSP_REPLY_OK,d0
        bne     protocol_failed

        bsr     mxdrv_query_status
        cmpi.l  #$80,d0                ; every register write is busy for 64 clocks
        bne     protocol_failed
        moveq   #1,d3
        bsr     clock_samples
        bsr     mxdrv_query_status
        tst.l   d0
        bne     protocol_failed

        ; Drive the saw LFO across its first phase boundary. At rate $ff the
        ; fifth sample advances phase to 1; AM depth $7f yields $fc.
        bsr     mxdrv_reset
        tst.l   d0
        bne     protocol_failed
        moveq   #$18,d1
        moveq   #-$01,d2               ; $ff
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     protocol_failed
        moveq   #$19,d1
        moveq   #$7f,d2
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     protocol_failed
        moveq   #5,d3
        bsr     clock_samples
        bsr     mxdrv_query_lfo
        cmpi.l  #$01fc00,d0
        bne     protocol_failed

        bsr     mxdrv_reset
        tst.l   d0
        bne     protocol_failed

        ; Configure the exact MAME oracle tuple: channel 0, note C4,
        ; DT1=0, MUL=1, DT2=0. Then compare the DSP's phase step.
        moveq   #$28,d1
        moveq   #$4c,d2
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     protocol_failed

        moveq   #$30,d1
        moveq   #0,d2
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     protocol_failed

        moveq   #$40,d1
        moveq   #1,d2
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     protocol_failed

        moveq   #-$40,d1               ; low byte is register $c0
        moveq   #0,d2
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     protocol_failed

        moveq   #0,d1
        moveq   #0,d2
        bsr     mxdrv_query_phase_step
        cmp.l   #YM_REF_PHASE_CH0_OP0,d0
        bne     protocol_failed

        ; Replay the oracle's all-carriers attack setup through the real
        ; MXDRV WriteOPM seam, then compare DSP samples at four boundaries.
        bsr     mxdrv_reset
        tst.l   d0
        bne     protocol_failed
        lea     attack_trace(pc),a3
        moveq   #27,d3
.write_attack_trace:
        moveq   #0,d1
        moveq   #0,d2
        move.b  (a3)+,d1
        move.b  (a3)+,d2
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     protocol_failed
        dbra    d3,.write_attack_trace

        ; Call $10 from the ported 32-entry dispatcher exposes OPMBuf.
        moveq   #$10,d0
        bsr     mxdrv_call
        move.l  d0,a0
        cmpi.b  #$78,$08(a0)
        bne     protocol_failed

        moveq   #3,d3                  ; samples 0..2
        bsr     clock_samples
        move.l  d0,d4
        moveq   #0,d1
        bsr     mxdrv_query_envelope
        cmpi.l  #$1ff,d0
        bne     protocol_failed
        move.l  d4,d0
        cmp.l   #YM_REF_ATTACK_2_LEFT,d0
        bne     protocol_failed
        bsr     mxdrv_query_right
        cmp.l   #YM_REF_ATTACK_2_RIGHT,d0
        bne     protocol_failed

        moveq   #12,d3                 ; samples 3..14
        bsr     clock_samples
        cmp.l   #YM_REF_ATTACK_14_LEFT,d0
        bne     protocol_failed
        bsr     mxdrv_query_right
        cmp.l   #YM_REF_ATTACK_14_RIGHT,d0
        bne     protocol_failed

        moveq   #26,d3                 ; samples 15..40
        bsr     clock_samples
        cmp.l   #YM_REF_ATTACK_40_LEFT,d0
        bne     protocol_failed
        bsr     mxdrv_query_right
        cmp.l   #YM_REF_ATTACK_40_RIGHT,d0
        bne     protocol_failed

        moveq   #23,d3                 ; samples 41..63
        bsr     clock_samples
        cmp.l   #YM_REF_ATTACK_63_LEFT,d0
        bne     protocol_failed
        bsr     mxdrv_query_right
        cmp.l   #YM_REF_ATTACK_63_RIGHT,d0
        bne     protocol_failed

        ; Reset and replay the same voice through every connection algorithm,
        ; now with operator-1 feedback level 4. The generated table contains
        ; exact ymfm sample-63 results for left and right.
        lea     algorithm_references(pc),a4
        moveq   #0,d5
.algorithm_loop:
        bsr     mxdrv_reset
        tst.l   d0
        bne     protocol_failed
        lea     attack_trace(pc),a3
        moveq   #27,d3
.write_algorithm_trace:
        moveq   #0,d1
        moveq   #0,d2
        move.b  (a3)+,d1
        move.b  (a3)+,d2
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     protocol_failed
        dbra    d3,.write_algorithm_trace

        moveq   #$20,d1
        moveq   #-$20,d2               ; $e0: both pans, feedback level 4
        or.b    d5,d2
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     protocol_failed

        moveq   #64,d3
        bsr     clock_samples
        cmp.l   (a4)+,d0
        bne     protocol_failed
        bsr     mxdrv_query_right
        cmp.l   (a4)+,d0
        bne     protocol_failed

        addq.b  #1,d5
        cmpi.b  #8,d5
        bcs     .algorithm_loop

        ; Channel 7 replaces operator 4's sine output with the noise LFSR.
        ; Replay the fastest-rate oracle trace and compare sample 63.
        bsr     mxdrv_reset
        tst.l   d0
        bne     protocol_failed
        lea     noise_trace(pc),a3
        moveq   #10,d3
.write_noise_trace:
        moveq   #0,d1
        moveq   #0,d2
        move.b  (a3)+,d1
        move.b  (a3)+,d2
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     protocol_failed
        dbra    d3,.write_noise_trace
        moveq   #64,d3
        bsr     clock_samples
        cmp.l   #YM_REF_NOISE_63_LEFT,d0
        bne     protocol_failed
        bsr     mxdrv_query_right
        cmp.l   #YM_REF_NOISE_63_RIGHT,d0
        bne     protocol_failed

        ; Maximum-rate saw vibrato with PMS 7 drives the dynamic PM phase
        ; path. Compare sample 63 against the exact ymfm result.
        bsr     mxdrv_reset
        tst.l   d0
        bne     protocol_failed
        lea     vibrato_trace(pc),a3
        moveq   #30,d3
.write_vibrato_trace:
        moveq   #0,d1
        moveq   #0,d2
        move.b  (a3)+,d1
        move.b  (a3)+,d2
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     protocol_failed
        dbra    d3,.write_vibrato_trace
        moveq   #64,d3
        bsr     clock_samples
        cmp.l   #YM_REF_VIBRATO_63_LEFT,d0
        bne     protocol_failed
        bsr     mxdrv_query_right
        cmp.l   #YM_REF_VIBRATO_63_RIGHT,d0
        bne     protocol_failed

        ; Timer A uses its 10-bit latch directly in native sample units.
        ; Value $3fe therefore expires after two clock commands.
        bsr     mxdrv_reset
        tst.l   d0
        bne     protocol_failed
        moveq   #$10,d1
        moveq   #-$01,d2               ; timer A high = $ff
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     protocol_failed
        moveq   #$11,d1
        moveq   #2,d2                  ; timer A low = 2, value = $3fe
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     protocol_failed
        moveq   #$14,d1
        moveq   #5,d2                  ; enable A + load A
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     protocol_failed

        moveq   #1,d3
        bsr     clock_samples
        bsr     mxdrv_query_status
        tst.l   d0
        bne     protocol_failed
        moveq   #1,d3
        bsr     clock_samples
        bsr     mxdrv_query_status
        cmpi.l  #1,d0
        bne     protocol_failed

        moveq   #$14,d1
        moveq   #$15,d2                ; reset A without restarting loaded timer
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     protocol_failed
        bsr     mxdrv_query_status
        cmpi.l  #$80,d0
        bne     protocol_failed
        moveq   #1,d3
        bsr     clock_samples
        bsr     mxdrv_query_status
        tst.l   d0
        bne     protocol_failed
        moveq   #1,d3
        bsr     clock_samples
        bsr     mxdrv_query_status
        cmpi.l  #1,d0
        bne     protocol_failed

        moveq   #$14,d1
        moveq   #$14,d2                ; reset A + clear load cancels it
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     protocol_failed
        moveq   #3,d3
        bsr     clock_samples
        bsr     mxdrv_query_status
        tst.l   d0
        bne     protocol_failed

        ; Timer B's $ff latch has a 16-sample period.
        bsr     mxdrv_reset
        tst.l   d0
        bne     protocol_failed
        moveq   #$12,d1
        moveq   #-$01,d2
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     protocol_failed
        moveq   #$14,d1
        moveq   #$0a,d2                ; enable B + load B
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     protocol_failed
        moveq   #15,d3
        bsr     clock_samples
        bsr     mxdrv_query_status
        tst.l   d0
        bne     protocol_failed
        moveq   #1,d3
        bsr     clock_samples
        bsr     mxdrv_query_status
        cmpi.l  #2,d0
        bne     protocol_failed
        moveq   #$14,d1
        moveq   #$28,d2                ; reset B + clear load
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     protocol_failed
        moveq   #17,d3
        bsr     clock_samples
        bsr     mxdrv_query_status
        tst.l   d0
        bne     protocol_failed

        ; The divide-by-16 source is free-running. Loading B five samples
        ; after reset shortens this first $ff period from 16 to 11 samples.
        bsr     mxdrv_reset
        tst.l   d0
        bne     protocol_failed
        moveq   #5,d3
        bsr     clock_samples
        moveq   #$12,d1
        moveq   #-$01,d2
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     protocol_failed
        moveq   #$14,d1
        moveq   #$0a,d2
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     protocol_failed
        moveq   #10,d3
        bsr     clock_samples
        bsr     mxdrv_query_status
        tst.l   d0
        bne     protocol_failed
        moveq   #1,d3
        bsr     clock_samples
        bsr     mxdrv_query_status
        cmpi.l  #2,d0
        bne     protocol_failed

        ; With timer-A status disabled, its two-sample expiration still raises
        ; the all-operator CSM key input for sample 2.
        bsr     mxdrv_reset
        tst.l   d0
        bne     protocol_failed
        lea     csm_trace(pc),a3
        moveq   #11,d3
.write_csm_trace:
        moveq   #0,d1
        moveq   #0,d2
        move.b  (a3)+,d1
        move.b  (a3)+,d2
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     protocol_failed
        dbra    d3,.write_csm_trace

        moveq   #2,d3                  ; samples 0..1: timer has not keyed yet
        bsr     clock_samples
        tst.l   d0
        bne     protocol_failed
        bsr     mxdrv_query_right
        tst.l   d0
        bne     protocol_failed
        bsr     mxdrv_query_status      ; enable-A is clear, so no status flag
        tst.l   d0
        bne     protocol_failed
        moveq   #1,d3                  ; sample 2 consumes the CSM key input
        bsr     clock_samples
        cmp.l   #YM_REF_CSM_2_LEFT,d0
        bne     protocol_failed
        bsr     mxdrv_query_right
        cmp.l   #YM_REF_CSM_2_RIGHT,d0
        bne     protocol_failed
        moveq   #0,d1
        bsr     mxdrv_query_envelope
        tst.l   d0
        bne     protocol_failed

        ; Install the same sustained four-operator algorithm-7 voice on all
        ; eight channels. The unique ping immediately before command 0b lets
        ; Hatari's DSP profiler arm on a deterministic full-load render using
        ; the cached no-PM phase path. The command sequence itself also runs
        ; unchanged on a real Falcon.
        bsr     mxdrv_reset
        tst.l   d0
        bne     protocol_failed
        moveq   #0,d5
.profile_channel:
        lea     attack_trace(pc),a3
        moveq   #27,d3
.profile_write:
        moveq   #0,d1
        moveq   #0,d2
        move.b  (a3)+,d1
        move.b  (a3)+,d2
        cmpi.b  #$08,d1
        beq     .profile_key_on
        or.b    d5,d1                 ; channel occupies register bits 0-2
        bra     .profile_send
.profile_key_on:
        or.b    d5,d2                 ; key-on data selects the channel
.profile_send:
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     protocol_failed
        dbra    d3,.profile_write
        addq.w  #1,d5
        cmpi.w  #8,d5
        bcs     .profile_channel

        move.l  #DSP_CMD_PING+$c1c0,d0
        bsr     dsp_exchange
        cmp.l   #DSP_REPLY_HELLO,d0
        bne     protocol_failed

        move.l  #DSP_CMD_START_AUDIO,d0
        bsr     dsp_exchange
        cmp.l   #DSP_REPLY_OK,d0
        bne     protocol_failed
        move.l  #DSP_CMD_STOP_AUDIO,d0
        bsr     dsp_exchange
        cmp.l   #DSP_REPLY_OK,d0
        bne     protocol_failed
        move.l  #DSP_CMD_QUERY_AUDIO,d0
        bsr     dsp_exchange
        cmpi.l  #DSP_MIX_FRAME_COUNT,d0
        bne     protocol_failed
        move.l  #DSP_CMD_QUERY_TIME,d0
        bsr     dsp_exchange
        cmpi.l  #1280,d0
        bne     protocol_failed

        ; Run the isolated codec-rate four-operator lower-bound kernel. Its
        ; unique marker gives the Hatari cycle profiler a stable arming point.
        move.l  #DSP_CMD_PING+$c2c0,d0
        bsr     dsp_exchange
        cmp.l   #DSP_REPLY_HELLO,d0
        bne     protocol_failed
        move.l  #DSP_CMD_PROFILE_RT,d0
        bsr     dsp_exchange
        cmpi.l  #DSP_RT_PROFILE_CHECKSUM,d0
        bne     protocol_failed

        ; Unique completion marker for the non-interactive Hatari trace gate.
        move.l  #DSP_CMD_PING+$c0de,d0
        bsr     dsp_exchange
        cmp.l   #DSP_REPLY_HELLO,d0
        bne     protocol_failed

        ; Run the block-oriented algorithm-0 channel spike behind its own
        ; profiler arming marker, then check its deterministic checksum.
        move.l  #DSP_CMD_PING+$c3c0,d0
        bsr     dsp_exchange
        cmp.l   #DSP_REPLY_HELLO,d0
        bne     protocol_failed
        move.l  #DSP_CMD_PROFILE_RT2,d0
        bsr     dsp_exchange
        cmpi.l  #DSP_RT2_PROFILE_CHECKSUM,d0
        bne     protocol_failed
        move.l  #DSP_CMD_PING+$c3de,d0
        bsr     dsp_exchange
        cmp.l   #DSP_REPLY_HELLO,d0
        bne     protocol_failed

        ; Run the carrier-specialized algorithm-7-shaped block spike. It
        ; shares command $14's oscillator/ROM setup but uses direct carrier
        ; phase masks and a four-carrier accumulation ring.
        move.l  #DSP_CMD_PING+$c4c0,d0
        bsr     dsp_exchange
        cmp.l   #DSP_REPLY_HELLO,d0
        bne     protocol_failed
        move.l  #DSP_CMD_PROFILE_RT3,d0
        bsr     dsp_exchange
        cmpi.l  #DSP_RT3_PROFILE_CHECKSUM,d0
        bne     protocol_failed
        move.l  #DSP_CMD_PING+$c4de,d0
        bsr     dsp_exchange
        cmp.l   #DSP_REPLY_HELLO,d0
        bne     protocol_failed

        ; Exercise algorithms 1-6 through their shared mixed-topology block
        ; command. Each arming marker is unique so the Hatari profiler can
        ; capture one topology without changing the Falcon test executable.
        move.l  #DSP_CMD_PROFILE_RT4,d0 ; selector zero is outside 1-6
        bsr     dsp_exchange
        cmp.l   #DSP_REPLY_ERROR,d0
        bne     protocol_failed
        moveq   #1,d5
        lea     rt4_algorithm_checksums(pc),a3
.profile_mixed_algorithm:
        move.l  #DSP_CMD_PING+$c500,d0
        add.l   d5,d0
        bsr     dsp_exchange
        cmp.l   #DSP_REPLY_HELLO,d0
        bne     protocol_failed
        move.l  #DSP_CMD_PROFILE_RT4,d0
        or.b    d5,d0
        bsr     dsp_exchange
        move.l  (a3)+,d1
        cmp.l   d1,d0
        bne     protocol_failed
        addq.w  #1,d5
        cmpi.w  #7,d5
        bcs     .profile_mixed_algorithm
        move.l  #DSP_CMD_PING+$c5de,d0
        bsr     dsp_exchange
        cmp.l   #DSP_REPLY_HELLO,d0
        bne     protocol_failed

        ; Run the live-SSI eight-channel fully decoded control gate. Its
        ; measured window includes real transmit interrupts plus decoded
        ; envelope/LFO/noise/timer/event block service, with hot phases,
        ; feedback, and the carrier sum in overlaid internal memory while
        ; SSI consumes the active external audio buffer. The fixture begins
        ; with algorithms 0-7 on channels 0-7, then applies decoded
        ; algorithm/pan changes, four-band TL rebuilds, KC/KF pitch rebuilds
        ; from the exact phase-step table, key on/off, all four
        ; envelope-rate groups, LFO rate/depth/waveform, and both timers,
        ; beside block-held AM/PM, planar PDX input, and final limiting.
        move.l  #DSP_CMD_PING+$c6c0,d0
        bsr     dsp_exchange
        cmp.l   #DSP_REPLY_HELLO,d0
        bne     protocol_failed
        move.l  #DSP_CMD_PROFILE_RT5,d0
        bsr     dsp_exchange
        cmpi.l  #DSP_RT5_PROFILE_CHECKSUM,d0
        bne     protocol_failed
        move.l  #DSP_CMD_PING+$c6de,d0
        bsr     dsp_exchange
        cmp.l   #DSP_REPLY_HELLO,d0
        bne     protocol_failed

        ; Reload the valid bank after the malformed-bank checks, then prove
        ; that a host-rendered PDX period reaches the DSP-owned SSI path. Keep
        ; FM silent so the first nonzero stereo probe sums the exact second
        ; ADPCM sample from both channels.
        bsr     mxdrv_reset
        tst.l   d0
        bne     protocol_failed

        moveq   #3,d0
        move.l  #pdx_test_bank_end-pdx_test_bank,d1
        lea     pdx_test_bank(pc),a1
        bsr     mxdrv_call
        tst.l   d0
        bne     protocol_failed

        moveq   #0,d0                  ; voice 0, sample 0
        moveq   #0,d1
        moveq   #4,d2                  ; 15.625 kHz
        moveq   #3,d3                  ; both outputs
        moveq   #8,d4                  ; unity gain
        bsr     mxdrv_pdx_voice_start
        tst.l   d0
        bne     protocol_failed

        Locksnd
        cmpi.l  #1,d0
        bne     sound_failed
        Setmode #SOUND_STEREO16
        Settracks #0,#0
        Dsptristate #1,#0
        Devconnect #SOUND_DSP_XMIT,#SOUND_DAC,#SOUND_CLK25M,#SOUND_CLK50K,#SOUND_NO_SHAKE

        bsr     dsp_start_mixed_audio
        cmp.l   #DSP_REPLY_OK,d0
        bne     audio_protocol_failed

        bsr     mxdrv_pdx_active_mask   ; the short test entry was exhausted
        tst.l   d0
        bne     audio_protocol_failed

        move.l  #DSP_CMD_STOP_AUDIO,d0
        bsr     dsp_exchange
        cmp.l   #DSP_REPLY_OK,d0
        bne     audio_protocol_failed

        move.l  #DSP_CMD_QUERY_MIX,d0   ; first nonzero left+right probe
        bsr     dsp_exchange
        cmpi.l  #PDX_REF_ADPCM_01*2,d0
        bne     audio_protocol_failed

        move.l  #DSP_CMD_PING+$cd09,d0  ; mixed PDX/FM transport marker
        bsr     dsp_exchange
        cmp.l   #DSP_REPLY_HELLO,d0
        bne     audio_protocol_failed

        ; Feed a known sustained voice into the first end-to-end DSP SSI path.
        bsr     mxdrv_reset
        tst.l   d0
        bne     protocol_failed
        lea     attack_trace(pc),a3
        moveq   #27,d3
.write_audio_trace:
        moveq   #0,d1
        moveq   #0,d2
        move.b  (a3)+,d1
        move.b  (a3)+,d2
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     protocol_failed
        dbra    d3,.write_audio_trace

        ; Exercise the timestamped DSP FIFO with two frequency writes. Move the
        ; channel away from the oracle note first, then restore it at native
        ; samples 0 and 64 of the upcoming render.
        moveq   #$28,d1
        moveq   #$4a,d2
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     protocol_failed

        moveq   #0,d0
        moveq   #$28,d1
        moveq   #$4b,d2
        bsr     dsp_queue_write
        tst.l   d0
        bne     protocol_failed

        moveq   #64,d0
        moveq   #$28,d1
        moveq   #$4c,d2
        bsr     dsp_queue_write
        tst.l   d0
        bne     protocol_failed

        move.l  #DSP_CMD_START_AUDIO,d0
        bsr     dsp_exchange
        cmp.l   #DSP_REPLY_OK,d0
        bne     audio_protocol_failed

        ; The first render advances the rolling native clock by exactly 1280
        ; samples. Query it while the interrupt-fed SSI stream is active.
        move.l  #DSP_CMD_QUERY_TIME,d0
        bsr     dsp_exchange
        cmpi.l  #1280,d0
        bne     audio_protocol_failed

        ; Prove that the normal MXDRV WriteOPM seam remains serviced while SSI
        ; is active. This changes DSP state for the next render; the current
        ; first block was deliberately rendered before transmit started.
        moveq   #$7e,d1
        moveq   #$5a,d2
        bsr     mxdrv_write_ym2151
        cmp.l   #DSP_REPLY_OK,d0
        bne     audio_protocol_failed

        ; Queue two rolling-clock events while SSI is active. The next render
        ; will consume them at absolute native times 1280 and 1344.
        move.l  #1280,d0
        moveq   #$28,d1
        moveq   #$4a,d2
        bsr     dsp_queue_write
        cmp.l   #DSP_REPLY_OK,d0
        bne     audio_protocol_failed

        move.l  #1344,d0
        moveq   #$28,d1
        moveq   #$4c,d2
        bsr     dsp_queue_write
        cmp.l   #DSP_REPLY_OK,d0
        bne     audio_protocol_failed

        ; Fill and switch to buffer B while the SSI interrupt continues to
        ; repeat the complete block in buffer A. The scheduled writes above
        ; must be consumed on the same rolling clock.
        bsr     dsp_refill_mixed_audio
        cmp.l   #DSP_REPLY_OK,d0
        bne     audio_protocol_failed

        move.l  #DSP_CMD_QUERY_TIME,d0
        bsr     dsp_exchange
        cmpi.l  #2560,d0
        bne     audio_protocol_failed

        ; Exercise the other half of the double buffer. These events land in
        ; buffer A while completed buffer B remains available to the ISR.
        moveq   #$28,d1
        moveq   #$4a,d2
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     audio_protocol_failed

        move.l  #2560,d0
        moveq   #$28,d1
        moveq   #$4b,d2
        bsr     dsp_queue_write
        tst.l   d0
        bne     audio_protocol_failed

        move.l  #2624,d0
        moveq   #$28,d1
        moveq   #$4c,d2
        bsr     dsp_queue_write
        tst.l   d0
        bne     audio_protocol_failed

        bsr     dsp_refill_mixed_audio
        cmp.l   #DSP_REPLY_OK,d0
        bne     audio_protocol_failed

        move.l  #DSP_CMD_QUERY_TIME,d0
        bsr     dsp_exchange
        cmpi.l  #3840,d0
        bne     audio_protocol_failed

        ; Leave SSI repeating the most recent complete block for three seconds
        ; to prove that host-side scheduling latency does not stop transport.
        Cconws  audio_text
        move.w  #149,d5
.audio_wait:
        Vsync
        dbra    d5,.audio_wait

        move.l  #DSP_CMD_STOP_AUDIO,d0
        bsr     dsp_exchange
        cmp.l   #DSP_REPLY_OK,d0
        bne     audio_protocol_failed

        move.l  #DSP_CMD_QUERY_AUDIO,d0
        bsr     dsp_exchange
        cmpi.l  #DSP_MIX_FRAME_COUNT*3,d0
        bne     audio_protocol_failed

        moveq   #0,d1
        moveq   #0,d2
        bsr     mxdrv_query_phase_step
        cmp.l   #YM_REF_PHASE_CH0_OP0,d0
        bne     audio_protocol_failed

        ; Unique completion marker for the interrupt/double-buffer gate.
        move.l  #DSP_CMD_PING+$db10,d0
        bsr     dsp_exchange
        cmp.l   #DSP_REPLY_HELLO,d0
        bne     audio_protocol_failed

        ; Promote the command-$17 block engine into its production-shaped
        ; 1024-frame A/B transport. Reset establishes native time zero, then
        ; the same sustained voice and rolling FIFO exercise both halves while
        ; SSI remains live. Sixteen 64-frame blocks advance each refill by
        ; 1301 or 1302 native samples under the exact 1280:1007 DDA.
        bsr     mxdrv_reset
        tst.l   d0
        bne     audio_protocol_failed
        lea     attack_trace(pc),a3
        moveq   #27,d3
.write_realtime_trace:
        moveq   #0,d1
        moveq   #0,d2
        move.b  (a3)+,d1
        move.b  (a3)+,d2
        bsr     mxdrv_write_ym2151
        tst.l   d0
        bne     audio_protocol_failed
        dbra    d3,.write_realtime_trace

        moveq   #0,d0
        moveq   #$28,d1
        moveq   #$4b,d2
        bsr     dsp_queue_write
        tst.l   d0
        bne     audio_protocol_failed
        moveq   #64,d0
        moveq   #$28,d1
        moveq   #$4c,d2
        bsr     dsp_queue_write
        tst.l   d0
        bne     audio_protocol_failed

        bsr     dsp_start_realtime_audio
        cmp.l   #DSP_REPLY_OK,d0
        bne     audio_protocol_failed
        move.l  #DSP_CMD_QUERY_TIME,d0
        bsr     dsp_exchange
        cmpi.l  #1301,d0
        bne     audio_protocol_failed

        moveq   #$7f,d1                ; direct live TL write
        moveq   #$08,d2
        bsr     mxdrv_write_ym2151
        cmp.l   #DSP_REPLY_OK,d0
        bne     audio_protocol_failed
        moveq   #$40,d1                ; live operator multiplier rebuild
        moveq   #$02,d2
        bsr     mxdrv_write_ym2151
        cmp.l   #DSP_REPLY_OK,d0
        bne     audio_protocol_failed
        move.l  #1301,d0
        moveq   #$28,d1
        moveq   #$4a,d2
        bsr     dsp_queue_write
        tst.l   d0
        bne     audio_protocol_failed
        move.l  #1365,d0
        moveq   #$28,d1
        moveq   #$4c,d2
        bsr     dsp_queue_write
        tst.l   d0
        bne     audio_protocol_failed

        bsr     dsp_refill_realtime_audio
        cmp.l   #DSP_REPLY_OK,d0
        bne     audio_protocol_failed
        move.l  #DSP_CMD_QUERY_TIME,d0
        bsr     dsp_exchange
        cmpi.l  #2603,d0
        bne     audio_protocol_failed

        bsr     dsp_refill_realtime_audio
        cmp.l   #DSP_REPLY_OK,d0
        bne     audio_protocol_failed
        move.l  #DSP_CMD_QUERY_TIME,d0
        bsr     dsp_exchange
        cmpi.l  #3904,d0
        bne     audio_protocol_failed

        move.l  #DSP_CMD_STOP_AUDIO,d0
        bsr     dsp_exchange
        cmp.l   #DSP_REPLY_OK,d0
        bne     audio_protocol_failed
        move.l  #DSP_CMD_QUERY_AUDIO,d0
        bsr     dsp_exchange
        cmpi.l  #DSP_RT_MIX_FRAME_COUNT*3,d0
        bne     audio_protocol_failed
        move.l  #DSP_CMD_QUERY_MIX,d0
        bsr     dsp_exchange
        cmpi.l  #DSP_RT_MIX_CHECKSUM,d0
        bne     audio_protocol_failed
        move.l  #DSP_CMD_PING+$dc19,d0
        bsr     dsp_exchange
        cmp.l   #DSP_REPLY_HELLO,d0
        bne     audio_protocol_failed

        Dsptristate #0,#0
        Unlocksnd

        Cconws  ready_text
        bra     clean_exit

audio_protocol_failed:
        Dsptristate #0,#0
        Unlocksnd
        bra     protocol_failed

protocol_failed:
        Cconws  protocol_error_text
        Cconin
        bra     clean_exit

load_failed:
        Cconws  load_error_text
        Cconin
        bra     clean_exit

sound_failed:
        Cconws  sound_error_text
        Cconin
        bra     clean_exit

clean_exit:
        bsr     mxdrv_mdx_clock_stop
        Dsp_Unlock
        Pterm0

usage_failed:
        Cconws  usage_text
        Pterm0

reserve_failed:
        Cconws  reserve_error_text
        Cconin
        Pterm0

; Clock d3 samples and return the final left sample.
clock_samples:
        bsr     mxdrv_clock_sample
        subq.w  #1,d3
        bne     clock_samples
        rts

        data

banner:
        dc.b    27,'E','F030MXDRV DSP core',13,10
        dc.b    '68030 MXDRV host + DSP56001 YM2151',13,10,13,10,0

ready_text:
        dc.b    'MXDRV PDX ADPCM + DSP YM2151 oracle samples: OK',13,10
        dc.b    'Falcon DSP SSI/crossbar burst: OK',13,10,0

audio_text:
        dc.b    'Playing a three-second DSP YM2151 SSI burst...',13,10,0

usage_text:
        dc.b    'Usage: F030MXDRV.TTP song.mdx [bank.pdx]',13,10,0

reserve_error_text:
        dc.b    'Error: unable to reserve the Falcon DSP.',13,10
        dc.b    'Press a key to exit.',13,10,0

load_error_text:
        dc.b    'Error: unable to bootstrap the DSP program.',13,10
        dc.b    'Press a key to exit.',13,10,0

protocol_error_text:
        dc.b    'Error: DSP protocol mismatch.',13,10
        dc.b    'Press a key to exit.',13,10,0

sound_error_text:
        dc.b    'Error: unable to lock the Falcon sound system.',13,10
        dc.b    'Press a key to exit.',13,10,0

attack_trace:
        dc.b    $20,$c7,$28,$4c,$30,$00
        dc.b    $40,$01,$48,$01,$50,$01,$58,$01
        dc.b    $60,$00,$68,$00,$70,$00,$78,$00
        dc.b    $80,$1c,$88,$1c,$90,$1c,$98,$1c
        dc.b    $a0,$00,$a8,$00,$b0,$00,$b8,$00
        dc.b    $c0,$00,$c8,$00,$d0,$00,$d8,$00
        dc.b    $e0,$0f,$e8,$0f,$f0,$0f,$f8,$0f
        dc.b    $08,$78
        even

noise_trace:
        dc.b    $27,$c7,$2f,$4c,$37,$00
        dc.b    $5f,$01,$7f,$00,$9f,$1c,$bf,$00,$df,$00,$ff,$0f
        dc.b    $0f,$9f,$08,$47
        even

vibrato_trace:
        dc.b    $18,$ff,$19,$ff,$38,$70
        dc.b    $20,$c7,$28,$4c,$30,$00
        dc.b    $40,$01,$48,$01,$50,$01,$58,$01
        dc.b    $60,$00,$68,$00,$70,$00,$78,$00
        dc.b    $80,$1c,$88,$1c,$90,$1c,$98,$1c
        dc.b    $a0,$00,$a8,$00,$b0,$00,$b8,$00
        dc.b    $c0,$00,$c8,$00,$d0,$00,$d8,$00
        dc.b    $e0,$0f,$e8,$0f,$f0,$0f,$f8,$0f
        dc.b    $08,$78
        even

csm_trace:
        dc.b    $20,$c7,$28,$4c,$30,$00,$40,$01
        dc.b    $60,$00,$80,$ff,$a0,$00,$c0,$00,$e0,$0f
        dc.b    $10,$ff,$11,$02,$14,$81
        even

; Minimal raw MDX image. A standard title/PDX header precedes a sequence block
; containing the voice-table displacement and sixteen relative track pointers.
mdx_test_song:
        dc.b    'MDX executor smoke',13,10,$1a,0
mdx_test_sequence:
        dc.w    mdx_test_voice_table-mdx_test_sequence
        dc.w    mdx_test_fm_track-mdx_test_sequence
        dc.w    mdx_test_repeat_track-mdx_test_sequence
        dcb.w   6,mdx_test_end_track-mdx_test_sequence
        dc.w    mdx_test_pcm_track-mdx_test_sequence
        dcb.w   7,mdx_test_end_track-mdx_test_sequence
mdx_test_fm_track:
        dc.b    $fd,$01                ; select the standard voice record
        dc.b    $fb,$0f                ; loudest normal volume: +2 carrier TL
        dc.b    $fe,$1b,$5a            ; raw OPM write
        dc.b    $ff,$a4                ; tempo
        dc.b    $80,$00                ; note 0 for one tick
        dc.b    $f1,$00
mdx_test_repeat_track:
        dc.b    $f6,$02                ; two passes
mdx_test_repeat_work:
        dc.b    $00                    ; mutable in-stream counter
mdx_test_repeat_body:
        dc.b    $fe,$1a,$11
        dc.b    $00                    ; one-tick rest
        dc.b    $f4
        dc.w    mdx_test_repeat_end_offset-mdx_test_repeat_escape_after
mdx_test_repeat_escape_after:
        dc.b    $fe,$1a,$22            ; only the non-final pass executes this
        dc.b    $f5
mdx_test_repeat_end_offset:
        dc.w    mdx_test_repeat_body-mdx_test_repeat_after_end
mdx_test_repeat_after_end:
        dc.b    $fe,$1a,$33            ; final-pass escape resumes here
        dc.b    $f1,$00
mdx_test_pcm_track:
        dc.b    $fc,$03                ; both outputs
        dc.b    $fb,$08                ; unity PCM8 gain
        dc.b    $80,$01                ; PDX entry 0 for two ticks
        dc.b    $f1,$00
mdx_test_end_track:
        dc.b    $f1,$00
mdx_test_voice_table:
        dc.b    1,$00,$00               ; ID, algorithm 0, PMS/AMS 0
        dc.b    $01,$01,$01,$01         ; DT1/MUL
        dc.b    $01,$02,$03,$04         ; base TL (only C2 is a carrier)
        dc.b    $1f,$1f,$1f,$1f         ; KS/AR
        dc.b    $00,$00,$00,$00         ; AMS/D1R
        dc.b    $00,$00,$00,$00         ; DT2/D2R
        dc.b    $0f,$0f,$0f,$0f         ; D1L/RR
mdx_test_song_end:
        even

; All structural offsets are valid, but track 0's F5 branch target is not.
; The executor must catch it before touching the implied counter byte.
mdx_bad_repeat_song:
        dc.b    'Bad repeat',13,10,$1a,0
mdx_bad_repeat_sequence:
        dc.w    mdx_bad_repeat_voice-mdx_bad_repeat_sequence
        dc.w    mdx_bad_repeat_track-mdx_bad_repeat_sequence
        dcb.w   15,mdx_bad_repeat_end_track-mdx_bad_repeat_sequence
mdx_bad_repeat_track:
        dc.b    $f5,$80,$00
mdx_bad_repeat_end_track:
        dc.b    $f1,$00
mdx_bad_repeat_voice:
        dc.b    0
mdx_bad_repeat_song_end:
        even

; Long-rest song used to prove MFP accumulation plus foreground pumping.
mdx_clock_song:
        dc.b    'Clock pump',13,10,$1a,0
mdx_clock_sequence:
        dc.w    mdx_clock_voice-mdx_clock_sequence
        dc.w    mdx_clock_track-mdx_clock_sequence
        dcb.w   15,mdx_clock_end_track-mdx_clock_sequence
mdx_clock_track:
        dc.b    $7f,$f1,$00            ; remain active for 128 timer ticks
mdx_clock_end_track:
        dc.b    $f1,$00
mdx_clock_voice:
        dc.b    0
mdx_clock_song_end:
        even

; Algorithm-0 carrier-volume fixture. Modulators use base TL 1/2/3 and C2
; uses base TL 4, making each direct-attenuation transition observable at $78.
mdx_volume_song:
        dc.b    'FM volume',13,10,$1a,0
mdx_volume_sequence:
        dc.w    mdx_volume_voice-mdx_volume_sequence
        dc.w    mdx_volume_track-mdx_volume_sequence
        dcb.w   15,mdx_volume_end_track-mdx_volume_sequence
mdx_volume_track:
        dc.b    $fd,$01
        dc.b    $fb,$80                ; direct +0 attenuation
        dc.b    $80,$00                ; one-tick note
        dc.b    $fa,$00                ; direct +1, then one-tick rest
        dc.b    $f9,$00                ; direct -1, then one-tick rest
        dc.b    $fb,$ff,$80,$00        ; saturating direct attenuation
        dc.b    $fa,$00,$f1,$00        ; $ff clamp, rest, end
mdx_volume_end_track:
        dc.b    $f1,$00
mdx_volume_voice:
        dc.b    1,$00,$00
        dc.b    $01,$01,$01,$01
        dc.b    $01,$02,$03,$04
        dc.b    $1f,$1f,$1f,$1f
        dc.b    $00,$00,$00,$00
        dc.b    $00,$00,$00,$00
        dc.b    $0f,$0f,$0f,$0f
mdx_volume_song_end:
        even

; Standard PDX table: 96 big-endian offset/length pairs. Entry 0 is valid,
; entry 1 is empty, and entries 2/3 deliberately exercise validation errors.
pdx_test_bank:
        dc.l    768,8
        dc.l    0,0
        dc.l    764,4
        dc.l    774,8
        dcb.b   736,$00
        dc.b    $70,$f1,$27,$8e,$45,$ab,$cd,$ef
pdx_test_bank_end:
        even

pdx_adpcm_references:
        dc.l    PDX_REF_ADPCM_00,PDX_REF_ADPCM_01
        dc.l    PDX_REF_ADPCM_02,PDX_REF_ADPCM_03
        dc.l    PDX_REF_ADPCM_04,PDX_REF_ADPCM_05
        dc.l    PDX_REF_ADPCM_06,PDX_REF_ADPCM_07
        dc.l    PDX_REF_ADPCM_08,PDX_REF_ADPCM_09
        dc.l    PDX_REF_ADPCM_10,PDX_REF_ADPCM_11
        dc.l    PDX_REF_ADPCM_12,PDX_REF_ADPCM_13
        dc.l    PDX_REF_ADPCM_14,PDX_REF_ADPCM_15

pdx_mix_references:
        dc.l    PDX_REF_MIX_00,PDX_REF_MIX_01,PDX_REF_MIX_02,PDX_REF_MIX_03
        dc.l    PDX_REF_MIX_04,PDX_REF_MIX_05,PDX_REF_MIX_06,PDX_REF_MIX_07
        dc.l    PDX_REF_MIX_08,PDX_REF_MIX_09,PDX_REF_MIX_10,PDX_REF_MIX_11
        dc.l    PDX_REF_MIX_12,PDX_REF_MIX_13,PDX_REF_MIX_14,PDX_REF_MIX_15
        dc.l    PDX_REF_MIX_16,PDX_REF_MIX_17,PDX_REF_MIX_18,PDX_REF_MIX_19
pdx_mix_references_end:

algorithm_references:
        dc.l    YM_REF_ALGORITHM_0_LEFT,YM_REF_ALGORITHM_0_RIGHT
        dc.l    YM_REF_ALGORITHM_1_LEFT,YM_REF_ALGORITHM_1_RIGHT
        dc.l    YM_REF_ALGORITHM_2_LEFT,YM_REF_ALGORITHM_2_RIGHT
        dc.l    YM_REF_ALGORITHM_3_LEFT,YM_REF_ALGORITHM_3_RIGHT
        dc.l    YM_REF_ALGORITHM_4_LEFT,YM_REF_ALGORITHM_4_RIGHT
        dc.l    YM_REF_ALGORITHM_5_LEFT,YM_REF_ALGORITHM_5_RIGHT
        dc.l    YM_REF_ALGORITHM_6_LEFT,YM_REF_ALGORITHM_6_RIGHT
        dc.l    YM_REF_ALGORITHM_7_LEFT,YM_REF_ALGORITHM_7_RIGHT

rt4_algorithm_checksums:
        dc.l    DSP_RT4_ALG1_CHECKSUM,DSP_RT4_ALG2_CHECKSUM
        dc.l    DSP_RT4_ALG3_CHECKSUM,DSP_RT4_ALG4_CHECKSUM
        dc.l    DSP_RT4_ALG5_CHECKSUM,DSP_RT4_ALG6_CHECKSUM

; The two large generated blobs close the data section so every small data
; label above stays within 16-bit PC-relative reach of the code; both blobs
; are only referenced through pea/lea at bounded displacements.
        include "ym2151_host_tables.i"
        include "dsp_stage2_image.i"

        bss

dsp_stage2_reply:
        ds.l    1
dsp_table_reply:
        ds.l    1
player_mode:
        ds.l    1

        end
