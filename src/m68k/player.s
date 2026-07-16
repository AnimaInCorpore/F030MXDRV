        include "xbios.i"
        include "protocol.i"

        global  player_parse_tail
        global  player_run
        global  player_selftest
        global  player_mdx_filename
        global  player_pdx_filename

PLAYER_MDX_CAPACITY     equ     65536
PLAYER_PDX_CAPACITY     equ     319488

PLAYER_SOUND_STEREO16  equ     1
PLAYER_SOUND_DSP_XMIT  equ     1
PLAYER_SOUND_DAC       equ     8
PLAYER_SOUND_CLK25M    equ     0
PLAYER_SOUND_CLK50K    equ     1
PLAYER_SOUND_NO_SHAKE  equ     1
PLAYER_SOUND_LTATTEN   equ     0
PLAYER_SOUND_RTATTEN   equ     1
PLAYER_SOUND_INQUIRE   equ     -1
PLAYER_SOUND_FULL      equ     0
PLAYER_LOOP_BUDGET     equ     2
PLAYER_FADE_SPEED      equ     8

        text

; Parse a TOS basepage command tail into one required MDX filename and one
; optional PDX filename. TOS paths cannot normally contain spaces, so the
; initial player deliberately keeps the grammar to two whitespace-delimited
; tokens. in: a0=basepage+$80; out: d0=0 empty, 1 valid, -1 malformed
player_parse_tail:
        movem.l d1-d7/a0-a6,-(sp)
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
        clr.b   player_sound_owned
        clr.b   player_audio_started
        clr.b   player_fading
        Cconws  player_loading_text

        lea     player_mdx_filename,a0
        lea     mxdrv_mdx_buffer,a1
        move.l  #PLAYER_MDX_CAPACITY,d1
        moveq   #2,d2
        bsr     player_load_file
        tst.l   d0
        bne     player_mdx_error

        tst.b   player_pdx_filename
        beq     player_files_loaded
        lea     player_pdx_filename,a0
        lea     mxdrv_pdx_buffer,a1
        move.l  #PLAYER_PDX_CAPACITY,d1
        moveq   #3,d2
        bsr     player_load_file
        tst.l   d0
        bne     player_pdx_error

player_files_loaded:
        Locksnd
        cmpi.l  #1,d0
        bne     player_sound_error
        move.b  #1,player_sound_owned
        ; Falcon CODEC attenuation survives across programs. Preserve it,
        ; then explicitly unmute both DAC channels for this playback session.
        Soundcmd #PLAYER_SOUND_LTATTEN,#PLAYER_SOUND_INQUIRE
        move.w  d0,player_old_left_atten
        Soundcmd #PLAYER_SOUND_RTATTEN,#PLAYER_SOUND_INQUIRE
        move.w  d0,player_old_right_atten
        Soundcmd #PLAYER_SOUND_LTATTEN,#PLAYER_SOUND_FULL
        Soundcmd #PLAYER_SOUND_RTATTEN,#PLAYER_SOUND_FULL
        Setmode #PLAYER_SOUND_STEREO16
        Settracks #0,#0
        Dsptristate #1,#0
        Devconnect #PLAYER_SOUND_DSP_XMIT,#PLAYER_SOUND_DAC,#PLAYER_SOUND_CLK25M,#PLAYER_SOUND_CLK50K,#PLAYER_SOUND_NO_SHAKE

        moveq   #4,d0
        bsr     mxdrv_call
        tst.l   d0
        bne     player_play_error

        ; Prime the tracks before rendering the first block so their initial
        ; voices, notes, and PDX triggers are represented immediately.
        bsr     mxdrv_mdx_timer_service
        tst.w   d0
        beq     player_finished

        bsr     dsp_start_realtime_audio
        cmp.l   #DSP_REPLY_OK,d0
        bne     player_dsp_error
        move.b  #1,player_audio_started

        Cconws  player_playing_text
        Cconws  player_mdx_filename
        Cconws  player_playing_suffix
        tst.b   player_pdx_filename
        beq     player_loop
        Cconws  player_pdx_warning

player_loop:
        ; The blocking realtime refill is the playback cadence. Waiting for a
        ; VBL here would add 16.7 ms to every 20.8 ms audio period.
        bsr     mxdrv_mdx_clock_pump
        tst.w   d0
        beq     player_finished
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
        bne     player_stopped         ; a second key stops immediately
        bsr     player_arm_fade
        bra     player_refill

player_refill:
        bsr     dsp_refill_realtime_audio
        cmp.l   #DSP_REPLY_OK,d0
        bne     player_dsp_error
        bra     player_loop

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
        Soundcmd #PLAYER_SOUND_LTATTEN,player_old_left_atten
        Soundcmd #PLAYER_SOUND_RTATTEN,player_old_right_atten
        Unlocksnd
        clr.b   player_sound_owned
player_cleanup_return:
        move.l  d7,d0
        movem.l (sp)+,d1-d7/a0-a6
        rts

        data

player_loading_text:
        dc.b    'Loading MDX/PDX files...',13,10,0
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
player_mdx_error_text:
        dc.b    'Error: unable to load the MDX file (maximum 65536 bytes).',13,10,0
player_pdx_error_text:
        dc.b    'Error: unable to load the PDX file (maximum 319488 bytes).',13,10,0
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
player_test_mdx:
        dc.b    'TEST.MDX',0
player_test_pdx:
        dc.b    'TEST.PDX',0
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
player_old_left_atten:
        ds.w    1
player_old_right_atten:
        ds.w    1
        even

        end
