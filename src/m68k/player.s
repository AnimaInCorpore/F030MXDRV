        include "xbios.i"
        include "verbose.i"
        include "protocol.i"

        global  player_parse_tail
        global  player_run
        global  player_selftest
        global  player_mdx_filename
        global  player_pdx_filename

PLAYER_MDX_CAPACITY     equ     65536
PLAYER_PDX_CAPACITY     equ     327680

PLAYER_SOUND_STEREO16  equ     1
PLAYER_SOUND_DSP_XMIT  equ     1
PLAYER_SOUND_DAC       equ     8
PLAYER_SOUND_CLK25M    equ     0
PLAYER_SOUND_CLK33K    equ     2
PLAYER_SOUND_CLK50K    equ     1
PLAYER_SOUND_NO_SHAKE  equ     1
PLAYER_SOUND_LTATTEN   equ     0
PLAYER_SOUND_RTATTEN   equ     1
PLAYER_SOUND_ADDERIN   equ     4
PLAYER_SOUND_INQUIRE   equ     -1
PLAYER_SOUND_FULL      equ     0
PLAYER_SOUND_MATRIXIN  equ     2       ; adder takes the matrix, not the A/D
PLAYER_SOUND_MONPAIR0  equ     0       ; DAC monitors frame slots 0 and 1
PLAYER_SOUND_DMA_STOP  equ     0
PLAYER_SNDSTAT_RESET   equ     1
PLAYER_SNDSTAT_INQUIRE equ     0
PLAYER_SNDSTAT_CLIPL   equ     4
PLAYER_SNDSTAT_CLIPR   equ     5
PLAYER_LOOP_BUDGET     equ     2
PLAYER_FADE_SPEED      equ     8
PLAYER_STAGE_LONGS     equ     2+DSP_RT_BATCH_MAX+DSP_RT_PCM_WORD_COUNT

        text

; Parse a TOS basepage command tail into one required MDX filename and one
; optional PDX filename. TOS paths cannot normally contain spaces, so the
; player deliberately keeps the grammar to two whitespace-delimited tokens.
; When the second token is absent, player_run resolves the PDX name embedded
; in the loaded MDX. in: a0=basepage+$80; out: d0=0 empty, 1 valid, -1 malformed
player_parse_tail:
        movem.l d1-d7/a0-a6,-(sp)
        clr.b   player_autoplay_tried
player_parse_restart:
        lea     player_mdx_filename,a1
        lea     player_pdx_filename,a2
        clr.b   (a1)
        clr.b   (a2)

        moveq   #0,d7
        move.b  (a0)+,d7
        cmpi.w  #127,d7
        bhi     player_parse_error
        tst.w   d7
        beq     player_parse_empty
        movea.l a0,a3
        lea     (a0,d7.w),a4

player_parse_skip_first:
        cmpa.l  a4,a3
        bcc     player_parse_empty
        moveq   #0,d0
        move.b  (a3),d0
        cmpi.b  #' ',d0
        beq     player_parse_advance_first
        cmpi.b  #9,d0
        beq     player_parse_advance_first
        cmpi.b  #13,d0
        beq     player_parse_empty
        bra     player_parse_copy_first
player_parse_advance_first:
        addq.l  #1,a3
        bra     player_parse_skip_first

player_parse_copy_first:
        cmpa.l  a4,a3
        bcc     player_parse_first_done
        moveq   #0,d0
        move.b  (a3),d0
        cmpi.b  #' ',d0
        beq     player_parse_first_done
        cmpi.b  #9,d0
        beq     player_parse_first_done
        cmpi.b  #13,d0
        beq     player_parse_first_done
        move.b  d0,(a1)+
        addq.l  #1,a3
        bra     player_parse_copy_first
player_parse_first_done:
        clr.b   (a1)

player_parse_skip_second:
        cmpa.l  a4,a3
        bcc     player_parse_one
        moveq   #0,d0
        move.b  (a3),d0
        cmpi.b  #' ',d0
        beq     player_parse_advance_second
        cmpi.b  #9,d0
        beq     player_parse_advance_second
        cmpi.b  #13,d0
        beq     player_parse_one
        bra     player_parse_copy_second
player_parse_advance_second:
        addq.l  #1,a3
        bra     player_parse_skip_second

player_parse_copy_second:
        cmpa.l  a4,a3
        bcc     player_parse_second_done
        moveq   #0,d0
        move.b  (a3),d0
        cmpi.b  #' ',d0
        beq     player_parse_second_done
        cmpi.b  #9,d0
        beq     player_parse_second_done
        cmpi.b  #13,d0
        beq     player_parse_second_done
        move.b  d0,(a2)+
        addq.l  #1,a3
        bra     player_parse_copy_second
player_parse_second_done:
        clr.b   (a2)

player_parse_skip_extra:
        cmpa.l  a4,a3
        bcc     player_parse_two
        moveq   #0,d0
        move.b  (a3)+,d0
        cmpi.b  #' ',d0
        beq     player_parse_skip_extra
        cmpi.b  #9,d0
        beq     player_parse_skip_extra
        cmpi.b  #13,d0
        beq     player_parse_two
        bra     player_parse_error

player_parse_one:
        moveq   #1,d0
        bra     player_parse_return
player_parse_two:
        moveq   #1,d0
        bra     player_parse_return
player_parse_empty:
        ifd     PLAYER_DEFAULT_XEVIOUS
        ; The dedicated xevious.tos build behaves like a normal explicit
        ; two-file command tail when launched from the Desktop. Keep command
        ; line arguments authoritative; this fallback is reached only for an
        ; empty tail and leaves the general AUTOPLAY.INF build unchanged.
        tst.b   player_autoplay_tried
        bne     player_parse_none
        move.b  #1,player_autoplay_tried
        lea     player_xevious_tail,a0
        bra     player_parse_restart
        endc

        ; No command tail: an AUTOPLAY.INF beside the program supplies the
        ; same MDX-plus-optional-PDX grammar, so desktop launches and
        ; unattended test runs start playback without arguments. Control
        ; bytes and line endings read as separators before the reparse.
        tst.b   player_autoplay_tried
        bne     player_parse_none
        move.b  #1,player_autoplay_tried
        Fopen   player_autoplay_name,#0
        tst.l   d0
        bmi     player_parse_none
        move.w  d0,d3
        Fread   d3,#127,player_autoplay_text
        move.l  d0,d4
        Fclose  d3
        tst.l   d4
        ble     player_parse_none
        cmpi.l  #127,d4
        bhi     player_parse_none
        lea     player_autoplay_text,a3
        move.l  d4,d0
player_autoplay_sanitize:
        cmpi.b  #33,(a3)
        bcc     player_autoplay_keep
        move.b  #' ',(a3)
player_autoplay_keep:
        addq.l  #1,a3
        subq.l  #1,d0
        bne     player_autoplay_sanitize
        lea     player_autoplay_buffer,a0
        move.b  d4,(a0)
        bra     player_parse_restart
player_parse_none:
        moveq   #0,d0
        bra     player_parse_return
player_parse_error:
        clr.b   player_mdx_filename
        clr.b   player_pdx_filename
        moveq   #-1,d0
player_parse_return:
        movem.l (sp)+,d1-d7/a0-a6
        rts

; Exercise command-tail boundaries in the no-argument conformance path.
player_selftest:
        lea     player_test_tail,a0
        bsr     player_parse_tail
        cmpi.l  #1,d0
        bne     player_selftest_error
        lea     player_mdx_filename,a0
        lea     player_test_mdx,a1
        bsr     player_compare_string
        tst.l   d0
        bne     player_selftest_error
        lea     player_pdx_filename,a0
        lea     player_test_pdx,a1
        bsr     player_compare_string
        tst.l   d0
        bne     player_selftest_error

        lea     player_test_extra_tail,a0
        bsr     player_parse_tail
        cmpi.l  #-1,d0
        bne     player_selftest_error
        lea     player_test_empty_tail,a0
        bsr     player_parse_tail
        tst.l   d0
        bne     player_selftest_error

        ; Verify the one-token path that production playback uses: read the
        ; PDX name from the loaded MDX, preserve the MDX directory, and add
        ; the conventional extension omitted by many standard headers.
        lea     player_test_auto_tail,a0
        bsr     player_parse_tail
        cmpi.l  #1,d0
        bne     player_selftest_error
        lea     player_test_auto_mdx,a1
        moveq   #2,d0
        move.l  #player_test_auto_mdx_end-player_test_auto_mdx,d1
        bsr     mxdrv_call
        tst.l   d0
        bne     player_selftest_error
        bsr     player_resolve_embedded_pdx
        tst.l   d0
        bne     player_selftest_error
        lea     player_pdx_filename,a0
        lea     player_test_auto_pdx,a1
        bsr     player_compare_string
        tst.l   d0
        bne     player_selftest_error

        ; An empty embedded name is a valid MDX header and must not turn into
        ; a spurious directory/.PDX lookup.
        lea     player_test_no_pdx_mdx,a1
        moveq   #2,d0
        move.l  #player_test_no_pdx_mdx_end-player_test_no_pdx_mdx,d1
        bsr     mxdrv_call
        tst.l   d0
        bne     player_selftest_error
        clr.b   player_pdx_filename
        bsr     player_resolve_embedded_pdx
        tst.l   d0
        bne     player_selftest_error
        tst.b   player_pdx_filename
        bne     player_selftest_error

        ; Reopen the emitted DSP reference image through the exact player file
        ; path. Runtime bootstrap is embedded, but this artifact is small enough
        ; for the MDX buffer and keeps GEMDOS seek/read coverage in conformance
        ; mode. Reset discards it before the fixture song is installed.
        lea     player_test_filename,a0
        lea     mxdrv_mdx_buffer,a1
        move.l  #PLAYER_MDX_CAPACITY,d1
        moveq   #2,d2
        bsr     player_load_file
        tst.l   d0
        bne     player_selftest_error
        tst.l   mxdrv_mdx_size
        beq     player_selftest_error
        moveq   #0,d0
        bsr     mxdrv_call
        tst.l   d0
        bne     player_selftest_error
        moveq   #0,d0
        rts
player_selftest_error:
        moveq   #0,d0
        bsr     mxdrv_call
        moveq   #-1,d0
        rts

player_compare_string:
        moveq   #0,d0
player_compare_string_loop:
        move.b  (a0)+,d0
        cmp.b   (a1)+,d0
        bne     player_compare_string_error
        tst.b   d0
        bne     player_compare_string_loop
        moveq   #0,d0
        rts
player_compare_string_error:
        moveq   #-1,d0
        rts

; Select the PDX named by the loaded MDX when the command tail did not provide
; an override. MXDRV call $09 returns the MDX's NUL-terminated name. Standard
; files commonly omit the .PDX suffix, so add it when the name has no suffix.
; A basename-only embedded name is looked up beside the MDX path; embedded
; names that already contain a path are used as-is. in: player_mdx_filename
; and mxdrv_mdx_buffer are populated; out: d0=0 on success/no PDX, -1 bad
player_resolve_embedded_pdx:
        movem.l d1-d7/a0-a6,-(sp)
        moveq   #9,d0
        bsr     mxdrv_call
        tst.l   d0
        beq     player_resolve_pdx_none
        move.l  d0,d7

        ; Scan the returned name inside the owned MDX image. Besides keeping
        ; the copy bounded, this rejects a truncated MDX before the string
        ; scan can run into unrelated BSS.
        movea.l d0,a1
        lea     mxdrv_mdx_buffer,a2
        move.l  mxdrv_mdx_size,d4
        adda.l  d4,a2
        moveq   #0,d5
        moveq   #0,d6                  ; bit 0: path, bit 1: basename suffix
player_resolve_pdx_scan:
        cmpa.l  a2,a1
        bcc     player_resolve_pdx_error
        moveq   #0,d0
        move.b  (a1)+,d0
        beq     player_resolve_pdx_scanned
        addq.l  #1,d5
        cmpi.l  #127,d5
        bhi     player_resolve_pdx_error
        cmpi.b  #$5c,d0               ; '\\'
        beq     player_resolve_pdx_separator
        cmpi.b  #$2f,d0               ; '/'
        beq     player_resolve_pdx_separator
        cmpi.b  #$3a,d0               ; ':' (drive-qualified path)
        beq     player_resolve_pdx_separator
        cmpi.b  #'.',d0
        beq     player_resolve_pdx_suffix
        bra     player_resolve_pdx_scan
player_resolve_pdx_separator:
        ori.w   #1,d6
        andi.w  #$fffd,d6
        bra     player_resolve_pdx_scan
player_resolve_pdx_suffix:
        ori.w   #2,d6
        bra     player_resolve_pdx_scan

player_resolve_pdx_scanned:
        tst.l   d5
        beq     player_resolve_pdx_none
        lea     player_pdx_filename,a2
        lea     player_pdx_filename+128,a5
        btst    #0,d6
        bne     player_resolve_pdx_copy_name

        ; No path in the MDX header: retain the directory component of the
        ; command-line MDX path so "MUSIC\\SONG.MDX" finds "MUSIC\\SONG.PDX".
        lea     player_mdx_filename,a1
        movea.l a1,a4
player_resolve_mdx_path_scan:
        moveq   #0,d0
        move.b  (a1)+,d0
        beq     player_resolve_mdx_path_copy
        cmpi.b  #$5c,d0
        beq     player_resolve_mdx_path_mark
        cmpi.b  #$2f,d0
        beq     player_resolve_mdx_path_mark
        cmpi.b  #$3a,d0
        bne     player_resolve_mdx_path_scan
player_resolve_mdx_path_mark:
        movea.l a1,a4
        bra     player_resolve_mdx_path_scan
player_resolve_mdx_path_copy:
        lea     player_mdx_filename,a1
player_resolve_mdx_path_copy_loop:
        cmpa.l  a4,a1
        bcc     player_resolve_pdx_copy_name
        cmpa.l  a5,a2
        bcc     player_resolve_pdx_error
        move.b  (a1)+,(a2)+
        bra     player_resolve_mdx_path_copy_loop

player_resolve_pdx_copy_name:
        movea.l d7,a1
player_resolve_pdx_copy_loop:
        moveq   #0,d0
        move.b  (a1)+,d0
        beq     player_resolve_pdx_copy_done
        cmpa.l  a5,a2
        bcc     player_resolve_pdx_error
        move.b  d0,(a2)+
        bra     player_resolve_pdx_copy_loop

player_resolve_pdx_copy_done:
        btst    #1,d6
        bne     player_resolve_pdx_finish
        ; Five bytes are needed for ".PDX" plus the terminator.
        movea.l a2,a3
        adda.l  #5,a3
        cmpa.l  a5,a3
        bhi     player_resolve_pdx_error
        move.b  #'.',(a2)+
        move.b  #'P',(a2)+
        move.b  #'D',(a2)+
        move.b  #'X',(a2)+
player_resolve_pdx_finish:
        clr.b   (a2)
        moveq   #0,d0
        bra     player_resolve_pdx_return

player_resolve_pdx_none:
        moveq   #0,d0
        bra     player_resolve_pdx_return
player_resolve_pdx_error:
        clr.b   player_pdx_filename
        moveq   #-1,d0
player_resolve_pdx_return:
        movem.l (sp)+,d1-d7/a0-a6
        rts

; Load an exact regular file into an MXDRV-owned buffer and publish it through
; the compatible copy-in API. in: a0=name, a1=buffer, d1=capacity, d2=call
; out: d0=0 on success, -1 on open/seek/size/read/API failure
player_load_file:
        movem.l d1-d7/a0-a6,-(sp)
        movea.l a0,a4
        movea.l a1,a5
        move.l  d1,d6
        move.l  d2,d5

        Fopen   (a4),#0
        tst.l   d0
        bmi     player_load_error
        move.w  d0,d7

        Fseek   #0,d7,#2
        tst.l   d0
        ble     player_load_close_error
        cmp.l   d6,d0
        bhi     player_load_close_error
        move.l  d0,d6

        Fseek   #0,d7,#0
        tst.l   d0
        bmi     player_load_close_error
        Fread   d7,d6,(a5)
        cmp.l   d6,d0
        bne     player_load_close_error
        Fclose  d7

        move.l  d5,d0
        move.l  d6,d1
        movea.l a5,a1
        bsr     mxdrv_call
        bra     player_load_return

player_load_close_error:
        Fclose  d7
player_load_error:
        moveq   #-1,d0
player_load_return:
        movem.l (sp)+,d1-d7/a0-a6
        rts

; Run the foreground player loop. MDX/PDX state advances on the 68030, then
; each completed host PCM block is uploaded to the inactive DSP buffer and
; combined with the matching FM period before an interrupt-fed SSI switch.
; out: d0=0 after natural/user stop, -1 after a reported setup failure
player_run:
        movem.l d1-d7/a0-a6,-(sp)
        bsr     mxdrv_ym_batch_disable
        clr.b   player_sound_owned
        clr.b   player_audio_started
        clr.b   player_fading
        Cconws  player_loading_text
        VB      vb_txt_run

        VB      vb_txt_loadmdx
        lea     player_mdx_filename,a0
        lea     mxdrv_mdx_buffer,a1
        move.l  #PLAYER_MDX_CAPACITY,d1
        moveq   #2,d2
        bsr     player_load_file
        VBH
        tst.l   d0
        bne     player_mdx_error

        tst.b   player_pdx_filename
        bne     player_explicit_pdx
        bsr     player_resolve_embedded_pdx
        tst.l   d0
        bne     player_pdx_error
        tst.b   player_pdx_filename
        beq     player_files_loaded
player_explicit_pdx:
        VB      vb_txt_loadpdx
        lea     player_pdx_filename,a0
        lea     mxdrv_pdx_buffer,a1
        move.l  #PLAYER_PDX_CAPACITY,d1
        moveq   #3,d2
        bsr     player_load_file
        VBH
        tst.l   d0
        bne     player_pdx_error

player_files_loaded:
        VB      vb_txt_locksnd
        Locksnd
        VBH
        cmpi.l  #1,d0
        bne     player_sound_error
        move.b  #1,player_sound_owned
        ; Falcon CODEC attenuation survives across programs. Preserve it,
        ; then explicitly unmute both DAC channels for this playback session.
        Soundcmd #PLAYER_SOUND_LTATTEN,#PLAYER_SOUND_INQUIRE
        move.w  d0,player_old_left_atten
        Soundcmd #PLAYER_SOUND_RTATTEN,#PLAYER_SOUND_INQUIRE
        move.w  d0,player_old_right_atten
        ; The rest of the matrix also survives across programs, and TOS does
        ; not reset it for a new Devconnect. Stop any inherited DMA playback
        ; that would contend for the same DAC, reinitialize the converters,
        ; and pin every route this player depends on instead of inheriting it.
        ; None of this can be exercised under Hatari, which starts clean.
        VB      vb_txt_sndreset
        Buffoper #PLAYER_SOUND_DMA_STOP
        Sndstatus #PLAYER_SNDSTAT_RESET
        Soundcmd #PLAYER_SOUND_LTATTEN,#PLAYER_SOUND_FULL
        Soundcmd #PLAYER_SOUND_RTATTEN,#PLAYER_SOUND_FULL
        Soundcmd #PLAYER_SOUND_ADDERIN,#PLAYER_SOUND_MATRIXIN
        VB      vb_txt_setmode
        Setmode #PLAYER_SOUND_STEREO16
        VB      vb_txt_settracks
        Settracks #0,#0
        ; The DSP fills frame slots 0 and 1; a stale monitor pair points the
        ; DAC at slots this player never writes.
        Setmontracks #PLAYER_SOUND_MONPAIR0
        VB      vb_txt_tristate
        Dsptristate #1,#0
        ifd     FORCE_CLK50K
        ; Bring-up A/B only: reconnect at 49.17 kHz while the production
        ; engine still assumes 32.780 kHz. Playback therefore runs at the
        ; wrong pitch and tempo; this build only isolates SSI clocking.
        VB      vb_txt_devconnect50
        Devconnect #PLAYER_SOUND_DSP_XMIT,#PLAYER_SOUND_DAC,#PLAYER_SOUND_CLK25M,#PLAYER_SOUND_CLK50K,#PLAYER_SOUND_NO_SHAKE
        else
        VB      vb_txt_devconnect
        Devconnect #PLAYER_SOUND_DSP_XMIT,#PLAYER_SOUND_DAC,#PLAYER_SOUND_CLK25M,#PLAYER_SOUND_CLK33K,#PLAYER_SOUND_NO_SHAKE
        endc
        VB      vb_txt_sounddone

        VB      vb_txt_mdxplay
        moveq   #4,d0
        bsr     mxdrv_call
        VBH
        tst.l   d0
        bne     player_play_error

        ; Prime the tracks before rendering the first block so their initial
        ; voices, notes, and PDX triggers populate the exact register mirror
        ; before the realtime decoder initializes from it.
        VB      vb_txt_prime
        bsr     mxdrv_mdx_timer_service
        VBH
        tst.w   d0
        beq     player_finished

        ; Console output can consume multiple VBLs on a stock machine. Finish
        ; it before SSI starts so it cannot delay the first pipelined refill.
        Cconws  player_playing_text
        Cconws  player_mdx_filename
        Cconws  player_playing_suffix
        tst.b   player_pdx_filename
        beq     player_start_audio
        Cconws  player_pdx_warning
player_start_audio:
        VB      vb_txt_audiostart
        bsr     dsp_start_realtime_audio
        VBH
        cmp.l   #DSP_REPLY_OK,d0
        bne     player_dsp_error
        ; Opt into the DSP's boundary-wait host service: production refills
        ; become resident before the handoff that frees their target buffer.
        ; Conformance and capture flows never enable it, so their command
        ; timing stays exactly as scored.
        move.l  #DSP_CMD_EARLY_ACCEPT,d0
        bsr     dsp_exchange
        cmp.l   #DSP_REPLY_OK,d0
        bne     player_dsp_error
        bsr     mxdrv_mdx_clock_resync
        move.b  #1,player_audio_started
        VB      vb_txt_looping
        ; Once SSI is live, ordered pump writes ride with the PCM refill that
        ; consumes them, avoiding dozens of per-write XBIOS handshakes.
        bsr     mxdrv_ym_batch_enable
        clr.w   player_stage_next

player_loop:
        ; The delivery wait below is the playback cadence: one announced
        ; payload is consumed per SSI buffer handoff. Each iteration first
        ; PREPARES the following period, so a dense drain or mix borrows the
        ; idle time this loop previously spent parked inside the blocking
        ; refill exchange; the already-finished payload still leaves through
        ; the producer seams (dsp_rt_submit_poll) the moment the DSP frees a
        ; buffer. See docs/hatari-timing.md.
        bsr     mxdrv_mdx_clock_pump
        tst.w   d0
        beq     player_finish_drain
        ; After the loop budget the song eases out instead of repeating
        ; forever; the fade retires playback and the pump returns zero.
        tst.b   player_fading
        bne     player_check_key
        moveq   #$12,d0
        bsr     mxdrv_call             ; playback flags; loops in the top word
        swap    d0
        cmpi.w  #PLAYER_LOOP_BUDGET,d0
        bcs     player_check_key
        bsr     player_arm_fade
player_check_key:
        Cconis
        tst.l   d0
        beq     player_refill
        Cconin
        tst.b   player_fading
        bne     player_stop_drain      ; a second key stops immediately
        bsr     player_arm_fade
        bra     player_refill

player_refill:
        bsr     player_stage_payload
        tst.l   d0
        bne     player_error_drain
        bsr     player_post_staged     ; blocks only while the pipeline is full
        ; Deliveries complete asynchronously at the producer seams, so a
        ; protocol failure surfaces on the following iteration's check.
        cmp.l   #DSP_REPLY_OK,d0
        bne     player_dsp_error
        bra     player_loop

; Assemble the next realtime refill payload in the idle staging buffer: the
; command word, the coalesced YM burst, then the mixed PCM period. The PDX
; mix polls the pending delivery at its internal seams.
; out: d0.l = 0, or -1 after a batch overflow report
player_stage_payload:
        moveq   #0,d0
        move.w  player_stage_next,d0
        mulu.w  #PLAYER_STAGE_LONGS*4,d0
        lea     player_stages,a3
        adda.l  d0,a3
        move.l  a3,player_stage_base
        move.l  #DSP_CMD_REFILL_RT_MIXED,(a3)+
        bsr     mxdrv_ym_batch_copy
        tst.l   d0
        bne     player_stage_return
        move.l  d5,-(sp)
        bsr     mxdrv_pdx_mix_block
        move.l  (sp)+,d5
        addi.l  #DSP_RT_PCM_WORD_COUNT,d5
        move.l  d5,player_stage_count
        moveq   #0,d0
player_stage_return:
        rts

; Hand the staged payload to the submission pipeline and rotate to the next
; of the three staging buffers: one announced, one queued, one being built.
; out: d0.l = most recent delivery reply
player_post_staged:
        movem.l d3/a3,-(sp)
        movea.l player_stage_base,a3
        move.l  player_stage_count,d3
        bsr     dsp_rt_submit
        movem.l (sp)+,d3/a3
        addq.w  #1,player_stage_next
        cmpi.w  #3,player_stage_next
        bne     player_post_rotated
        clr.w   player_stage_next
player_post_rotated:
        move.l  dsp_stage_reply,d0
        rts

; Every exit owes the DSP the payload that is still announced: it will be
; consumed at the next handoff regardless, and the stop/cleanup exchanges
; below must not interleave their command words into its block transfer.
player_finish_drain:
        bsr     dsp_rt_submit_wait
        bra     player_finished
player_stop_drain:
        bsr     dsp_rt_submit_wait
        bra     player_stopped
player_error_drain:
        bsr     dsp_rt_submit_wait
        bra     player_dsp_error

player_arm_fade:
        move.b  #1,player_fading
        moveq   #PLAYER_FADE_SPEED,d1
        moveq   #$0c,d0
        bra     mxdrv_call

player_finished:
        Cconws  player_finished_text
        bra     player_cleanup_success
player_stopped:
        Cconws  player_stopped_text
player_cleanup_success:
        moveq   #0,d7
        bra     player_cleanup

player_mdx_error:
        Cconws  player_mdx_error_text
        bra     player_cleanup_error
player_pdx_error:
        Cconws  player_pdx_error_text
        bra     player_cleanup_error
player_sound_error:
        Cconws  player_sound_error_text
        bra     player_cleanup_error
player_dsp_error:
        Cconws  player_dsp_error_text
        bra     player_cleanup_error
player_play_error:
        Cconws  player_play_error_text
player_cleanup_error:
        moveq   #-1,d7

player_cleanup:
        bsr     mxdrv_ym_batch_disable
        moveq   #5,d0
        bsr     mxdrv_call
        tst.b   player_audio_started
        beq     player_cleanup_sound
        move.l  #DSP_CMD_STOP_AUDIO,d0
        bsr     dsp_exchange
        clr.b   player_audio_started
player_cleanup_sound:
        tst.b   player_sound_owned
        beq     player_cleanup_return
        Dsptristate #0,#0
        bsr     player_report_clipping
        Soundcmd #PLAYER_SOUND_LTATTEN,player_old_left_atten
        Soundcmd #PLAYER_SOUND_RTATTEN,player_old_right_atten
        Unlocksnd
        clr.b   player_sound_owned
player_cleanup_return:
        move.l  d7,d0
        movem.l (sp)+,d1-d7/a0-a6
        rts

; The codec latches left and right clipping in bits 4 and 5 of the sound
; status; the setup path cleared them with Sndstatus reset. This is the one
; headroom check the emulation gates cannot make for us, because it measures
; the analog converter rather than the mix that fed it, so report it on every
; exit rather than only on failure. Each channel gets its own message so the
; report survives a GEMDOS console call that does not preserve data registers.
player_report_clipping:
        Sndstatus #PLAYER_SNDSTAT_INQUIRE
        move.w  d0,d1
        andi.w  #(1<<PLAYER_SNDSTAT_CLIPL)|(1<<PLAYER_SNDSTAT_CLIPR),d1
        beq.s   player_clip_none
        cmpi.w  #(1<<PLAYER_SNDSTAT_CLIPL),d1
        beq.s   player_clip_left_only
        cmpi.w  #(1<<PLAYER_SNDSTAT_CLIPR),d1
        beq.s   player_clip_right_only
        Cconws  player_clip_both_text
        rts
player_clip_left_only:
        Cconws  player_clip_left_text
        rts
player_clip_right_only:
        Cconws  player_clip_right_text
player_clip_none:
        rts

        data

        ifd     VERBOSE_BOOT
vb_txt_run:        dc.b 'player_run entered',13,10,0
vb_txt_loadmdx:    dc.b 'load MDX         ',0
vb_txt_loadpdx:    dc.b 'load PDX (call 3)',0
vb_txt_locksnd:    dc.b 'Locksnd          ',0
vb_txt_sndreset:   dc.b 'Buffoper/Sndstatus reset',13,10,0
vb_txt_setmode:    dc.b 'Setmode',13,10,0
vb_txt_settracks:  dc.b 'Settracks',13,10,0
vb_txt_tristate:   dc.b 'Dsptristate',13,10,0
vb_txt_devconnect: dc.b 'Devconnect 32.780k (prescale 2)',13,10,0
vb_txt_devconnect50: dc.b 'Devconnect 49.17k (prescale 1) A/B',13,10,0
vb_txt_sounddone:  dc.b 'sound path ready',13,10,0
vb_txt_mdxplay:    dc.b 'MDX play (call 4)',0
vb_txt_prime:      dc.b 'prime tracks     ',0
vb_txt_audiostart: dc.b 'start realtime   ',0
vb_txt_looping:    dc.b 'entering play loop',13,10,0
        even
        endc

player_loading_text:
        dc.b    'Loading MDX/PDX files...',13,10,0
player_autoplay_name:
        dc.b    'AUTOPLAY.INF',0
        even
player_playing_text:
        dc.b    'Playing ',0
player_playing_suffix:
        dc.b    13,10,'Press any key to stop.',13,10
        dc.b    'Realtime FM/PDX SSI repeats the last complete block while refilling.',13,10,0
player_pdx_warning:
        dc.b    'PDX voices are mixed into each DSP refill block.',13,10,0
player_finished_text:
        dc.b    'Song finished.',13,10,0
player_stopped_text:
        dc.b    'Playback stopped.',13,10,0
player_clip_both_text:
        dc.b    'Warning: codec clipped both channels.',13,10,0
player_clip_left_text:
        dc.b    'Warning: codec clipped the left channel.',13,10,0
player_clip_right_text:
        dc.b    'Warning: codec clipped the right channel.',13,10,0
player_mdx_error_text:
        dc.b    'Error: unable to load the MDX file (maximum 65536 bytes).',13,10,0
player_pdx_error_text:
        dc.b    'Error: unable to load the PDX file (maximum 327680 bytes).',13,10,0
player_sound_error_text:
        dc.b    'Error: unable to lock the Falcon sound system.',13,10,0
player_dsp_error_text:
        dc.b    'Error: unable to start or refill DSP audio.',13,10,0
player_play_error_text:
        dc.b    'Error: malformed MDX or MFP Timer A is already in use.',13,10,0

player_test_tail:
        dc.b    player_test_tail_end-player_test_tail-1
        dc.b    '  TEST.MDX',9,'TEST.PDX  '
player_test_tail_end:
player_test_extra_tail:
        dc.b    player_test_extra_tail_end-player_test_extra_tail-1
        dc.b    'TEST.MDX TEST.PDX EXTRA'
player_test_extra_tail_end:
player_test_empty_tail:
        dc.b    0
player_test_auto_tail:
        dc.b    player_test_auto_tail_end-player_test_auto_tail-1
        dc.b    'MUSIC',$5c,'TEST.MDX'
player_test_auto_tail_end:
        ifd     PLAYER_DEFAULT_XEVIOUS
player_xevious_tail:
        dc.b    player_xevious_tail_end-player_xevious_tail-1
        dc.b    'XEVIOUS.MDX'
player_xevious_tail_end:
        endc
player_test_mdx:
        dc.b    'TEST.MDX',0
player_test_pdx:
        dc.b    'TEST.PDX',0
player_test_auto_pdx:
        dc.b    'MUSIC',$5c,'TEST.PDX',0
player_test_auto_mdx:
        dc.b    'MDX auto-load test',13,10,$1a,'TEST',0
player_test_auto_mdx_end:
player_test_no_pdx_mdx:
        dc.b    'MDX no PDX test',13,10,$1a,0
player_test_no_pdx_mdx_end:
player_test_filename:
        dc.b    'ym2151.lod',0
        even

        bss

player_mdx_filename:
        ds.b    128
player_pdx_filename:
        ds.b    128
player_sound_owned:
        ds.b    1
player_audio_started:
        ds.b    1
player_fading:
        ds.b    1
player_autoplay_tried:
        ds.b    1
player_autoplay_buffer:
        ds.b    1                       ; length byte ahead of the text
player_autoplay_text:
        ds.b    128
player_old_left_atten:
        ds.w    1
player_old_right_atten:
        ds.w    1
        even

; Triple-staged realtime payloads: command word, event count, up to
; DSP_RT_BATCH_MAX packed writes, pan word, and one 512-sample PCM period
; each. At any moment one buffer is announced to the DSP, one may be queued
; behind it, and one is being prepared.
player_stages:
        ds.l    3*PLAYER_STAGE_LONGS
player_stage_base:
        ds.l    1
player_stage_count:
        ds.l    1
player_stage_next:
        ds.w    1

; Silent DMA playback region. Nothing is connected to the DMA source, so this
; is never heard; it exists only so the sound engine that supplies the SSI
; clock has a defined buffer to cycle. BSS is zeroed by the loader, which is
; exactly the silence we want.
        even
        even

        end
