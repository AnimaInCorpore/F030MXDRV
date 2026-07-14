        global  mxdrv_call
        global  mxdrv_mdx_buffer
        global  mxdrv_mdx_size
        global  mxdrv_pdx_buffer
        global  mxdrv_pdx_size
        global  mxdrv_channel_mask
        global  mxdrv_playing
        global  mxdrv_paused

MXDRV_MDX_CAPACITY      equ     65536
MXDRV_PDX_CAPACITY      equ     319488

        text

; Resident-trap-independent MXDRV 2.06+17 API dispatcher. The public call
; numbers and register convention match the original 32-entry table; playback
; parsing/timer service is filled in behind these stable entries in stages.
; in:  d0.b = call number, other arguments follow the original MXDRV ABI
; out: d0.l = call result
mxdrv_call:
        movem.l d1-d7/a0-a6,-(sp)      ; Trap #4 preserves every register but d0
        andi.l  #$ff,d0
        cmpi.l  #32,d0
        bcc     mxdrv_call_error
        add.w   d0,d0
        move.w  mxdrv_api_table(pc,d0.w),d0
        jsr     mxdrv_api_table(pc,d0.w)
        movem.l (sp)+,d1-d7/a0-a6
        rts
mxdrv_call_error:
        moveq   #-1,d0
        movem.l (sp)+,d1-d7/a0-a6
        rts

mxdrv_api_table:
        dc.w    mxdrv_api_reset-mxdrv_api_table
        dc.w    mxdrv_api_error-mxdrv_api_table
        dc.w    mxdrv_api_set_mdx-mxdrv_api_table
        dc.w    mxdrv_api_set_pdx-mxdrv_api_table
        dc.w    mxdrv_api_play-mxdrv_api_table
        dc.w    mxdrv_api_stop-mxdrv_api_table
        dc.w    mxdrv_api_pause-mxdrv_api_table
        dc.w    mxdrv_api_continue-mxdrv_api_table
        dc.w    mxdrv_api_get_mdx_title-mxdrv_api_table
        dc.w    mxdrv_api_get_pdx_name-mxdrv_api_table
        dc.w    mxdrv_api_set_fade_offset-mxdrv_api_table
        dc.w    mxdrv_api_set_fade_wait-mxdrv_api_table
        dc.w    mxdrv_api_fadeout-mxdrv_api_table
        dc.w    mxdrv_api_error-mxdrv_api_table
        dc.w    mxdrv_api_set_channel_mask-mxdrv_api_table
        dc.w    mxdrv_api_play_masked-mxdrv_api_table
        dc.w    mxdrv_api_get_opm_buffer-mxdrv_api_table
        dc.w    mxdrv_api_option_11-mxdrv_api_table
        dc.w    mxdrv_api_get_flags-mxdrv_api_table
        dc.w    mxdrv_api_set_ignore_keys-mxdrv_api_table
        dc.w    mxdrv_api_get_active_mask-mxdrv_api_table
        dc.w    mxdrv_api_option_15-mxdrv_api_table
        dc.w    mxdrv_api_stop_mode-mxdrv_api_table
        dc.w    mxdrv_api_error-mxdrv_api_table
        dc.w    mxdrv_api_get_pcm_buffer-mxdrv_api_table
        dc.w    mxdrv_api_get_pcm_work-mxdrv_api_table
        dc.w    mxdrv_api_error-mxdrv_api_table
        dc.w    mxdrv_api_error-mxdrv_api_table
        dc.w    mxdrv_api_error-mxdrv_api_table
        dc.w    mxdrv_api_error-mxdrv_api_table
        dc.w    mxdrv_api_error-mxdrv_api_table
        dc.w    mxdrv_api_error-mxdrv_api_table

mxdrv_api_reset:
        bsr     mxdrv_mdx_clock_stop
        clr.l   mxdrv_mdx_size
        clr.l   mxdrv_pdx_size
        clr.w   mxdrv_channel_mask
        clr.b   mxdrv_playing
        move.b  #1,mxdrv_paused
        clr.b   mxdrv_fade_offset
        clr.b   mxdrv_fade_wait
        clr.b   mxdrv_fade_active
        clr.b   mxdrv_ignore_keys
        clr.b   mxdrv_option_11
        clr.b   mxdrv_option_15
        clr.b   mxdrv_stop_mode
        bsr     mxdrv_mdx_reset
        bsr     mxdrv_pdx_reset
        bra     mxdrv_reset

; Calls $02/$03 retain the original copy-in ownership model.
mxdrv_api_set_mdx:
        tst.l   d1
        bmi     mxdrv_api_error
        cmpi.l  #MXDRV_MDX_CAPACITY,d1
        bhi     mxdrv_api_error
        lea     mxdrv_mdx_buffer,a0
        move.l  a0,a2
        move.l  d1,d2
        bsr     mxdrv_copy_data
        move.l  d1,mxdrv_mdx_size
        moveq   #0,d0
        rts

mxdrv_api_set_pdx:
        tst.l   d1
        bmi     mxdrv_api_error
        cmpi.l  #MXDRV_PDX_CAPACITY,d1
        bhi     mxdrv_api_error
        lea     mxdrv_pdx_buffer,a0
        move.l  a0,a2
        move.l  d1,d2
        bsr     mxdrv_copy_data
        move.l  d1,mxdrv_pdx_size
        moveq   #0,d0
        rts

; a1=source, a2=destination, d2=byte count
mxdrv_copy_data:
        tst.l   d2
        beq     mxdrv_copy_done
mxdrv_copy_loop:
        move.b  (a1)+,(a2)+
        subq.l  #1,d2
        bne     mxdrv_copy_loop
mxdrv_copy_done:
        rts

mxdrv_api_play:
        clr.w   mxdrv_channel_mask
        tst.l   mxdrv_mdx_size
        beq     mxdrv_api_error
mxdrv_start_play:
        bsr     mxdrv_api_stop
        bsr     mxdrv_mdx_start
        tst.l   d0
        bne     mxdrv_api_error
        move.b  #1,mxdrv_playing
        clr.b   mxdrv_paused
        bsr     mxdrv_mdx_clock_start
        tst.l   d0
        bne     mxdrv_start_clock_error
        moveq   #0,d0
        rts

mxdrv_start_clock_error:
        clr.b   mxdrv_playing
        move.b  #1,mxdrv_paused
        bsr     mxdrv_mdx_reset
        bsr     mxdrv_pdx_reset
        moveq   #-1,d0
        rts

mxdrv_api_play_masked:
        move.w  d1,mxdrv_channel_mask
        tst.l   mxdrv_mdx_size
        bne     mxdrv_start_play
        bra     mxdrv_api_error

mxdrv_api_stop:
        bsr     mxdrv_mdx_clock_stop
        clr.b   mxdrv_playing
        move.b  #1,mxdrv_paused
        bsr     mxdrv_mdx_reset
        bsr     mxdrv_pdx_reset
        moveq   #0,d3
mxdrv_stop_keyoff_loop:
        moveq   #$08,d1
        move.b  d3,d2
        bsr     mxdrv_write_ym2151
        addq.b  #1,d3
        cmpi.b  #8,d3
        bcs     mxdrv_stop_keyoff_loop
        moveq   #0,d0
        rts

mxdrv_api_pause:
        move.b  #1,mxdrv_paused
        moveq   #0,d0
        rts

mxdrv_api_continue:
        tst.b   mxdrv_playing
        beq     mxdrv_api_error
        clr.b   mxdrv_paused
        moveq   #0,d0
        rts

; MDX/PDX headers store the first title/name displacement at byte 6.
mxdrv_api_get_mdx_title:
        move.l  mxdrv_mdx_size,d2
        cmpi.l  #8,d2
        bcs     mxdrv_api_null
        lea     mxdrv_mdx_buffer,a0
        bra     mxdrv_api_header_string

mxdrv_api_get_pdx_name:
        move.l  mxdrv_pdx_size,d2
        cmpi.l  #8,d2
        bcs     mxdrv_api_null
        lea     mxdrv_pdx_buffer,a0
mxdrv_api_header_string:
        moveq   #0,d0
        move.w  6(a0),d0
        cmp.l   d2,d0
        bcc     mxdrv_api_null
        add.l   a0,d0
        rts

mxdrv_api_null:
        moveq   #0,d0
        rts

mxdrv_api_set_fade_offset:
        move.b  d1,mxdrv_fade_offset
        moveq   #0,d0
        rts

mxdrv_api_set_fade_wait:
        move.b  d1,mxdrv_fade_wait
        moveq   #0,d0
        rts

mxdrv_api_fadeout:
        move.b  d1,mxdrv_fade_wait
        move.b  #1,mxdrv_fade_active
        moveq   #0,d0
        rts

mxdrv_api_set_channel_mask:
        move.w  d1,mxdrv_channel_mask
        moveq   #0,d0
        rts

mxdrv_api_get_opm_buffer:
        lea     mxdrv_opm_buffer,a0
        move.l  a0,d0
        rts

mxdrv_api_option_11:
        tst.l   d1
        bmi     mxdrv_option_11_get
        move.b  d1,mxdrv_option_11
        moveq   #0,d0
        rts
mxdrv_option_11_get:
        moveq   #0,d0
        move.b  mxdrv_option_11,d0
        rts

mxdrv_api_get_flags:
        moveq   #0,d0
        move.b  mxdrv_paused,d0
        lsl.w   #8,d0
        move.b  mxdrv_playing,d0
        rts

mxdrv_api_set_ignore_keys:
        moveq   #0,d0
        move.b  mxdrv_ignore_keys,d0
        move.b  d1,mxdrv_ignore_keys
        rts

mxdrv_api_get_active_mask:
        bsr     mxdrv_mdx_active_mask
        moveq   #0,d1
        move.w  mxdrv_channel_mask,d1
        not.w   d1
        and.w   d1,d0
        rts

mxdrv_api_option_15:
        moveq   #0,d0
        move.b  mxdrv_option_15,d0
        move.b  d1,mxdrv_option_15
        rts

mxdrv_api_stop_mode:
        moveq   #0,d4
        move.b  mxdrv_stop_mode,d4
        move.b  d1,mxdrv_stop_mode
        bsr     mxdrv_api_stop
        move.l  d4,d0
        rts

mxdrv_api_get_pcm_buffer:
        lea     mxdrv_pcm_buffer,a0
        move.l  a0,d0
        rts

mxdrv_api_get_pcm_work:
        lea     mxdrv_pcm_work,a0
        move.l  a0,d0
        rts

mxdrv_api_error:
        moveq   #-1,d0
        rts

        bss

mxdrv_mdx_size:
        ds.l    1
mxdrv_pdx_size:
        ds.l    1
mxdrv_channel_mask:
        ds.w    1
mxdrv_playing:
        ds.b    1
mxdrv_paused:
        ds.b    1
mxdrv_fade_offset:
        ds.b    1
mxdrv_fade_wait:
        ds.b    1
mxdrv_fade_active:
        ds.b    1
mxdrv_ignore_keys:
        ds.b    1
mxdrv_option_11:
        ds.b    1
mxdrv_option_15:
        ds.b    1
mxdrv_stop_mode:
        ds.b    1
        even

mxdrv_pcm_work:
        ds.b    16
mxdrv_mdx_buffer:
        ds.b    MXDRV_MDX_CAPACITY
mxdrv_pdx_buffer:
mxdrv_pcm_buffer:
        ds.b    MXDRV_PDX_CAPACITY

        end
