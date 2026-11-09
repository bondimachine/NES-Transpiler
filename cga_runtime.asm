; ==============================================================================
; CGA_RUNTIME.ASM - Native x86 CGA Mode 4 Virtualization & HLE Engine
; Target: Intel 8088 / IBM PC / Toshiba T1000 (MS-DOS)
; ==============================================================================

section .text

; Tile address currently drawn in each of the 800 screen cells (+66 words of sprite overrun
; padding), kept in nes_ram_seg's otherwise unused 6502 RAM-mirror area ($1000..$16C3)
; because the CS segment is nearly full for large ROMs.
SCREEN_TILE equ 1000h
CGA_TILE_OFFSETS equ 0800h  ; 800 words: CGA even-bank offset of each screen cell

; ------------------------------------------------------------------------------
; SYSTEM INITIALIZATION & CLEANUP
; ------------------------------------------------------------------------------
runtime_init:
    push cs
    pop ds
    push cs
    pop es

    ; Shrink initial .COM memory block to 64KB (1000h paragraphs)
    mov bx, 1000h
    mov ah, 4Ah
    int 21h

    ; Allocate NES 64KB Address Space Segment (1000h paragraphs = 64KB)
    ; 0000h..07FFh = 2KB NES RAM (Zero Page, Stack, RAM)
    ; 2000h..3FFFh = 8KB Raw CHR-ROM (for $2007 CHR reads like SMB title screen)
    ; 8000h..FFFFh = 32KB PRG-ROM
    mov bx, 1000h
    mov ah, 48h
    int 21h
    jc .alloc_fail
    mov [cs:nes_ram_seg], ax

    ; Allocate 64KB Address Translation Segment (1000h paragraphs = 64KB)
    ; Maps (addr6502 << 1) -> x86 native code offset in O(1) time
    mov bx, 1000h
    mov ah, 48h
    int 21h
    jnc short .alloc_ok

.alloc_fail:
    push cs
    pop ds
    mov ah, 09h
    lea dx, [msg_mem_err]
    int 21h
    mov ax, 4C01h
    int 21h

.alloc_ok:
    mov [cs:xlate_seg], ax

    ; Sprite save-under buffer (SAVE_MAX blocks of 18 bytes)
    mov bx, 100h
    mov ah, 48h
    int 21h
    jc .alloc_fail
    mov [cs:save_seg], ax
%ifdef BENCH
    ; Profiler histogram: one word per (even) code offset in CS; word 0 counts samples
    ; taken outside our code segment (BIOS/DOS)
    mov bx, 1000h
    mov ah, 48h
    int 21h
    jc .alloc_fail
    mov [cs:prof_seg], ax
    mov es, ax
    xor di, di
    xor ax, ax
    mov cx, 32768
    rep stosw
%endif

    ; Initialize NES 64KB segment to 0
    mov es, [cs:nes_ram_seg]
    xor di, di
    xor ax, ax
    mov cx, 32768
    rep stosw

    ; Initialize xlate_seg (32768 words) to loc_unhandled
    mov es, [cs:xlate_seg]
    xor di, di
    lea ax, [loc_unhandled]
    mov cx, 32768
    rep stosw

    ; Populate xlate_seg from indirect_jump_table
    push cs
    pop ds
    lea si, [indirect_jump_table]
    mov cx, [indirect_jump_count]
    jcxz .xlate_done
.fill_xlate:
    lodsw                   ; AX = 6502 address ($8000..$FFFF)
    shl ax, 1               ; AX = (addr6502 & 7FFFh) * 2
    mov di, ax
    lodsw                   ; AX = x86 native target (loc_XXXX)
    mov [es:di], ax
    loop .fill_xlate
.xlate_done:

    ; Load ROM & CHR data file (<game>.chr: 32KB PRG + 8KB raw CHR + 8KB CGA CHR)
    push cs
    pop ds
    mov ax, 3D00h           ; DOS Open File (read-only)
    lea dx, [rom_filename]
    int 21h
    jc .file_done
    mov bp, ax              ; BP = file handle

    ; 1. Read 32KB PRG-ROM into nes_ram_seg:8000h
    mov ds, [cs:nes_ram_seg]
    mov bx, bp
    mov dx, 8000h
    mov cx, 8000h
    mov ah, 3Fh
    int 21h

    ; 2. Read 8KB Raw CHR-ROM into nes_ram_seg:2000h
    mov bx, bp
    mov dx, 2000h
    mov cx, 2000h
    mov ah, 3Fh
    int 21h

    ; 3. Read 8KB Pre-converted CGA CHR into nes_ram_seg:4000h
    mov bx, bp
    mov dx, 4000h
    mov cx, 2000h
    mov ah, 3Fh
    int 21h

    ; Close file
    mov bx, bp
    mov ah, 3Eh
    int 21h
.file_done:

    ; 4. Build Horizontally-Flipped CGA CHR at nes_ram_seg:6000h from 4000h (4096 words)
    mov ds, [cs:nes_ram_seg]
    mov es, [cs:nes_ram_seg]
    mov si, 4000h
    mov di, 6000h
    mov cx, 4096
.hflip_loop:
    lodsw
    xor dx, dx
    mov bl, 8
.hflip_pix:
    shl dx, 1
    shl dx, 1
    mov bh, al
    and bh, 3
    or dl, bh
    shr ax, 1
    shr ax, 1
    dec bl
    jnz short .hflip_pix
    mov ax, dx
    stosw
    loop .hflip_loop

    ; Precompute CGA tile offsets (800 tiles: 25 rows of 32 tiles)
    push cs
    pop ds
    mov es, [cs:nes_ram_seg]
    mov di, CGA_TILE_OFFSETS
    xor bx, bx              ; BX = tile index (0..799)
.calc_offsets:
    mov ax, bx
    mov cl, 5
    shr ax, cl              ; AX = tile_y = bx / 32 (0..24)

    ; row_even = tile_y * 4 * 80 = tile_y * 320
    mov cx, 320
    mul cx                  ; DX:AX = tile_y * 320 (note: mul clobbers DX!)

    ; col_offset = (tile_x + 4) * 2
    mov dx, bx
    and dx, 31              ; DX = tile_x = bx % 32 (0..31)
    add dx, 4
    shl dx, 1
    add ax, dx              ; AX = DI in CGA even bank
    stosw
    inc bx
    cmp bx, 800
    jb .calc_offsets

    ; Save original INT 08h (Timer) and INT 09h (Keyboard)
    mov ax, 3508h
    int 21h
    mov [cs:old_int08_off], bx
    mov [cs:old_int08_seg], es

    mov ax, 3509h
    int 21h
    mov [cs:old_int09_off], bx
    mov [cs:old_int09_seg], es

    ; Install INT 08h handler
    push cs
    pop ds
    lea dx, [int08_handler]
    mov ax, 2508h
    int 21h

    ; Install INT 09h handler
    lea dx, [int09_handler]
    mov ax, 2509h
    int 21h

    ; Reprogram 8253 PIT Channel 0 for 60 Hz:
    ; Divisor = 1193182 / 60 = 19886 = 4DAEh
%ifdef BENCH
    mov al, 34h             ; Channel 0, lobyte/hibyte, mode 2 (linear countdown for timestamps)
    mov byte [cs:test_mode], 1
%else
    mov al, 36h             ; Channel 0, lobyte/hibyte, mode 3
%endif
    out 43h, al
    mov al, 0AEh            ; Low byte
    out 40h, al
    mov al, 4Dh             ; High byte
    out 40h, al

    ; Switch to CGA Mode 4 (320x200 4-color graphics)
    mov ax, 0004h
    int 10h

    ; Set CGA Palette (Palette 1: Cyan / Magenta / White)
    mov ah, 0Bh
    mov bh, 01h
    mov bl, 01h
    int 10h

    ; Clear CGA screen (16KB)
    mov es, [cs:cga_seg]
    xor di, di
    xor ax, ax
    mov cx, 8192
    rep stosw

    ; Invalidate the on-screen tile shadow (nothing drawn yet)
    mov es, [cs:nes_ram_seg]
    mov di, SCREEN_TILE
    mov cx, 800 + 66
    mov ax, 0FFFFh
    rep stosw

    ; Mark all nametable tiles as dirty
    push cs
    pop es
    lea di, [dirty_grid]
    mov cx, 1984
    mov al, 1
    rep stosb
    mov word [cs:dirty_count], 800

    ; Parse DOS command-line tail at CS:80h (space-separated tokens)
    ; - "--nosound" / "-nosound" / "/nosound": disable PC speaker output & overhead
    ; - "--invert"  / "-invert"  / "/invert" : start with inverted colours (key I toggles)
    ; - "T": run the automated test & dump VRAM to <GAME>.DMP
    mov cl, [cs:80h]
    xor ch, ch
    jcxz .cmd_done
    mov si, 81h
.cmd_scan:
    mov al, [cs:si]
    cmp al, '-'
    je short .cmd_option
    cmp al, '/'
    je short .cmd_option
    cmp al, 'T'
    je short .cmd_test
    cmp al, 't'
    je short .cmd_test
    jmp short .cmd_next
.cmd_option:
    inc si                  ; Skip the '-', '--' or '/' prefix
    dec cx
    jz short .cmd_done
    mov al, [cs:si]
    cmp al, '-'
    je short .cmd_option
    or al, 20h              ; Lower case
    cmp al, 'n'
    jne short .cmd_not_nosound
    mov byte [cs:sound_enabled], 0
.cmd_not_nosound:
    cmp al, 'i'
    jne short .cmd_skip_word
    mov byte [cs:invert_request], 1
.cmd_skip_word:             ; Consume the rest of the option word
    inc si
    dec cx
    jz short .cmd_done
    cmp byte [cs:si], ' '
    jne short .cmd_skip_word
    jmp short .cmd_scan
.cmd_test:
    mov byte [cs:test_mode], 1
.cmd_next:
    inc si
    loop .cmd_scan
.cmd_done:

    ret

runtime_shutdown:
    cli
    ; Stop the APU synthesis first: the DOS calls below can re-enable interrupts while
    ; our INT 08h is still installed, and a tick would otherwise turn the speaker back on
    mov byte [cs:sound_enabled], 0
    ; Silence PC Speaker (clear gate bits 0..1 of port 61h)
    in al, 61h
    and al, 0FCh
    out 61h, al

    ; Restore 8253 PIT Channel 0 to 18.2 Hz (divisor 0 = 65536)
    mov al, 36h
    out 43h, al
    xor al, al
    out 40h, al
    out 40h, al

    ; Restore INT 08h
    mov dx, [cs:old_int08_off]
    mov ds, [cs:old_int08_seg]
    mov ax, 2508h
    int 21h

    ; Restore INT 09h
    mov dx, [cs:old_int09_off]
    mov ds, [cs:old_int09_seg]
    mov ax, 2509h
    int 21h
    sti

    ; If invoked with "T" test flag (e.g. "GAME.COM T"), dump VRAM before text mode
    cmp byte [cs:test_mode], 0
    je short .no_dump
    push dx
    call cga_linearize
    pop dx
    push cs
    pop ds
    mov ah, 3Ch
    xor cx, cx
    lea dx, [dump_filename]
    int 21h
    jc short .no_dump
    mov bp, ax
    mov bx, bp
    lea dx, [vram_nametable]
    mov cx, 1024
    mov ah, 40h
    int 21h
    mov bx, bp
    lea dx, [oam_ram]
    mov cx, 256
    mov ah, 40h
    int 21h
    mov ds, [cs:cga_seg]
    mov bx, bp
    xor dx, dx
    mov cx, 16384
    mov ah, 40h
    int 21h
    mov ds, [cs:nes_ram_seg]
    mov bx, bp
    xor dx, dx
    mov cx, 2048
    mov ah, 40h
    int 21h
    mov bx, bp
    mov ah, 3Eh
    int 21h
%ifdef BENCH
    call bench_write
%endif
.no_dump:

    ; Switch back to 80x25 text mode (Mode 3)
    mov ax, 0003h
    int 10h

    push cs
    pop ds
    mov ah, 09h
    lea dx, [msg_shutdown]
    int 21h

    ; Make sure the speaker is still off (belt and braces after the DOS calls)
    in al, 61h
    and al, 0FCh
    out 61h, al

    ; Exit to DOS
    mov ax, 4C00h
    int 21h

; ------------------------------------------------------------------------------
; TIMER INTERRUPT (INT 08h - 8253 PIT @ 60 Hz)
; ------------------------------------------------------------------------------
int08_handler:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push bp
    push ds
    push es

    push cs
    pop ds

    ; Always send EOI to 8259 PIC and set VBlank flag on every 60Hz tick
    ; so PIC never locks up and polling loops inside NMI see VBlank!
    mov al, 20h
    out 20h, al

    inc byte [ tick_60hz ]
    inc word [ tick_total ]
    or byte [ ppu_status ], 80h
%ifdef BENCH
    call bench_input
    call bench_sample
%endif

    ; Expire temporary frameskip HUD after 1 second (60 ticks)
    cmp byte [ hud_timer ], 0
    je short .no_hud_expire
    dec byte [ hud_timer ]
    jnz short .no_hud_expire
    call clear_fskip_hud
.no_hud_expire:

    ; Re-entrancy guard for video flush & NMI dispatch
    cmp byte [ in_timer_isr ], 0
%ifdef BENCH
    je short .isr_free
    inc word [ bench_lost ]
    mov byte [ ticks_dropped ], 1
    mov byte [ nmi_pending ], 1
    jmp .skip_isr
.isr_free:
    mov byte [ in_timer_isr ], 1
    call bench_now
    mov [ bench_isr_t0 ], ax
    mov [ bench_isr_t0 + 2 ], dx
%else
    je short .isr_free
    mov byte [ ticks_dropped ], 1   ; Previous tick's work is still running
    mov byte [ nmi_pending ], 1     ; ...so that tick's NMI runs as soon as it finishes
    jmp .skip_isr
.isr_free:
    mov byte [ in_timer_isr ], 1
%endif
    sti

    ; Update PC Speaker APU synthesis at 60Hz (no-op if --nosound)
    call apu_update_60hz

    ; Flush dirty background tiles and draw sprites every [frameskip_cur] ticks.
    ; Adaptive frameskip: frameskip_max (keys 1-9) is the minimum; if ticks were dropped
    ; since the last render (game + render overrun the 60 Hz budget), render less often
    ; (up to every FRAMESKIP_LIMIT ticks) to give the game more CPU; after
    ; FRAMESKIP_CALM clean renders, step back towards the minimum.
    inc byte [ frame_div ]
    mov al, [ frame_div ]
    cmp al, [ frameskip_cur ]
    jb .no_vflush
    mov byte [ frame_div ], 0
    mov al, [ frameskip_cur ]
    cmp byte [ ticks_dropped ], 0
    je short .skip_calm
    mov byte [ ticks_dropped ], 0
    mov byte [ skip_calm ], 0
    cmp al, FRAMESKIP_LIMIT
    jae short .skip_set
    inc al
    jmp short .skip_set
.skip_calm:
    inc byte [ skip_calm ]
    cmp byte [ skip_calm ], FRAMESKIP_CALM
    jb short .skip_set
    mov byte [ skip_calm ], 0
    dec al
.skip_set:
    cmp al, [ frameskip_max ]
    jae short .skip_store
    mov al, [ frameskip_max ]
.skip_store:
    mov [ frameskip_cur ], al
%ifdef BENCH
    inc word [ bench_flush ]
    call bench_now
    push dx
    push ax
%endif
    call apply_invert_request
    call flush_dirty_tiles
    call draw_sprites
%ifdef BENCH
    call bench_now
    pop cx
    sub ax, cx
    pop cx
    sbb dx, cx
    add [ bench_render_time ], ax
    adc [ bench_render_time + 2 ], dx
%else
    cmp byte [ cs:test_mode ], 0
    je short .no_vflush
    cmp word [ cs:tick_total ], 240
    jae .auto_exit
%endif
.no_vflush:

    mov byte [ catchup_left ], NMI_CATCHUP_MAX
    ; Execute NMI if enabled by 6502 code ($2000 bit 7), unless it was only just enabled
    cmp byte [ nmi_holdoff ], 0
    je short .nmi_check
    mov byte [ nmi_holdoff ], 0
    jmp short .nmi_done
.nmi_check:
    test byte [ ppu_ctrl ], 80h
    jz short .nmi_done

    mov bp, sp
    mov ax, [ bp + 16 ]
    mov bx, [ bp + 14 ]
    mov cx, [ bp + 12 ]
    xor bh, bh              ; Restore the BH = CH = 0 invariants in case the tick
    xor ch, ch              ; interrupted a runtime helper that was using BX/CX
    mov di, [ bp + 6 ]
    mov ds, [ cs:nes_ram_seg ]
    mov es, [ cs:xlate_seg ]
    xor dh, dh
    call nmi_vector_dispatch
%ifdef BENCH
    inc word [ cs:bench_nmi ]
%ifdef BENCH_NMI_FRAMES
    inc word [ cs:bench_frames ] ; Game never strobes $4016: count completed NMIs
%endif
%endif
    ; NMI catch-up: if a tick arrived (and was dropped) while this frame's work was still
    ; running, start the next NMI right away instead of idling until the next tick. The
    ; game still gets at most one NMI per 60 Hz tick, but no longer loses the rest of a
    ; tick whenever a frame overruns (a 1.3-tick frame used to cost 2 whole ticks).
    ; Bounded to NMI_CATCHUP_MAX extra NMIs per tick so rendering (and the rest of the
    ; tick handler) still runs when every frame overruns.
    cli
    cmp byte [ cs:nmi_pending ], 0
    je short .nmi_done
    cmp byte [ cs:catchup_left ], 0
    je short .nmi_done
%ifdef BENCH
    cmp word [ cs:bench_frames ], BENCH_FRAMES  ; Stop exactly at the target frame count
    jae short .nmi_done
%endif
    dec byte [ cs:catchup_left ]
    mov byte [ cs:nmi_pending ], 0
    or byte [ cs:ppu_status ], 80h
    push cs
    pop ds
    sti
    jmp .nmi_check

.nmi_done:
    cli
    mov byte [ cs:nmi_pending ], 0
%ifdef BENCH
    call bench_isr_end
%endif
    mov byte [ cs:in_timer_isr ], 0

.skip_isr:
    pop es
    pop ds
    pop bp
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    iret

.auto_exit:
    call flush_dirty_tiles
    call draw_sprites
    jmp runtime_shutdown

nmi_vector_dispatch:
    ret

%ifdef BENCH
; ------------------------------------------------------------------------------
; BENCHMARK INSTRUMENTATION (only assembled with `aot_transpiler.js --bench`)
; Timestamps are in PIT units (1/1193182 s) since startup; PIT ch0 runs in mode 2.
; ------------------------------------------------------------------------------
PIT_DIV equ 19886

; Returns DX:AX = timestamp. Preserves all other registers and flags.
bench_now:
    pushf
    push cx
    push bx
    cli
    xor al, al
    out 43h, al             ; Latch counter 0
    in al, 40h
    mov cl, al
    in al, 40h
    mov ch, al              ; CX = remaining count (PIT_DIV..1)
    mov bx, [cs:tick_total]
    mov al, 0Ah
    out 20h, al             ; Read PIC IRR
    in al, 20h
    test al, 1
    jz short .no_pending
    cmp cx, PIT_DIV / 2     ; Counter already reloaded but tick not yet serviced
    jb short .no_pending
    inc bx
.no_pending:
    mov ax, PIT_DIV
    mul bx
    sub cx, PIT_DIV
    neg cx
    add ax, cx
    adc dx, 0
    pop bx
    pop cx
    popf
    ret

; Scripted joypad input, timed in game frames (joypad strobes) so every build sees the
; same input on the same game frame regardless of speed. Called from INT 08h with DS = CS.
; bench_script entries: dw first_frame, end_frame; db buttons, period_mask, on_frames
; (buttons apply while first <= frame < end and (frame & period_mask) < on_frames)
bench_input:
    push si
    mov ax, [bench_frames]
    xor bl, bl
    lea si, [bench_script]
.next:
    cmp word [si], 0FFFFh
    je short .set
    cmp ax, [si]
    jb short .skip
    cmp ax, [si + 2]
    jae short .skip
    mov cl, al
    and cl, [si + 5]
    cmp cl, [si + 6]
    jae short .skip
    or bl, [si + 4]
.skip:
    add si, 7
    jmp short .next
.set:
    mov [key_state], bl
    pop si
    ret

; Called at the end of a non-nested INT 08h body (interrupts disabled)
bench_isr_end:
    push ax
    push dx
    call bench_now
    sub ax, [cs:bench_isr_t0]
    sbb dx, [cs:bench_isr_t0 + 2]
    add [cs:bench_isr_time], ax
    adc [cs:bench_isr_time + 2], dx
    cmp word [cs:bench_frames], BENCH_FRAMES
    jae short .finish
    cmp word [cs:tick_total], BENCH_MAX_TICKS
    jae short .finish
    pop dx
    pop ax
    ret
.finish:
    call bench_idle_close
    call bench_now
    mov [cs:bench_total_time], ax
    mov [cs:bench_total_time + 2], dx
    mov ax, [cs:tick_total]
    mov [cs:bench_ticks], ax

    ; Render consistency check: render the final state incrementally (as the game would),
    ; stash that frame in nes_ram_seg:8000h (PRG copy is no longer needed), then force a
    ; full repaint of the same state. bench_write appends the stashed frame to the dump.
    push cs
    pop ds
    call flush_dirty_tiles
    call draw_sprites
    push dx
    call cga_linearize      ; Also leaves the linear frame at nes_ram_seg:8000h
    mov word [cs:save_count], 0 ; (saved offsets refer to the old origin)
    pop dx
    mov es, [cs:cga_seg]    ; Full repaint starts from a blank screen
    xor di, di
    mov ax, [cs:invert_word]
    mov cx, 8192
    rep stosw
    mov es, [cs:nes_ram_seg]
    mov di, SCREEN_TILE
    mov cx, 800 + 66
    mov ax, 0FFFFh
    rep stosw
    push cs
    pop ds
    call mark_all_dirty
    call flush_dirty_tiles
    call draw_sprites
    jmp runtime_shutdown

; Entered at the head of every detected 6502 idle (wait-for-frame) loop. Preserves everything.
bench_idle_enter:
    pushf
    cli
    cmp byte [cs:bench_in_idle], 0
    jne short .done
    push ax
    push dx
    mov byte [cs:bench_in_idle], 1
    call bench_now
    mov [cs:bench_idle_t0], ax
    mov [cs:bench_idle_t0 + 2], dx
    mov ax, [cs:bench_isr_time]
    mov [cs:bench_idle_isr0], ax
    mov ax, [cs:bench_isr_time + 2]
    mov [cs:bench_idle_isr0 + 2], ax
    pop dx
    pop ax
.done:
    popf
    ret

; Executed when an idle loop falls through. Preserves everything.
bench_idle_exit:
    pushf
    cli
    cmp byte [cs:bench_in_idle], 0
    je short .done
    call bench_idle_close
.done:
    popf
    ret

; Closes an open idle interval: idle += elapsed - ISR time spent inside it
bench_idle_close:
    cmp byte [cs:bench_in_idle], 0
    je short .done
    push ax
    push dx
    mov byte [cs:bench_in_idle], 0
    call bench_now
    sub ax, [cs:bench_idle_t0]
    sbb dx, [cs:bench_idle_t0 + 2]
    add [cs:bench_idle_time], ax
    adc [cs:bench_idle_time + 2], dx
    mov ax, [cs:bench_isr_time]
    mov dx, [cs:bench_isr_time + 2]
    sub ax, [cs:bench_idle_isr0]
    sbb dx, [cs:bench_idle_isr0 + 2]
    sub [cs:bench_idle_time], ax
    sbb [cs:bench_idle_time + 2], dx
    pop dx
    pop ax
.done:
    ret

; Writes bench_stats to <GAME>.BEN (called from runtime_shutdown)
; Sampling profiler: count the code address this tick interrupted (DS = CS)
bench_sample:
    push bp
    mov bp, sp              ; [bp+4..] = INT 08h pushes (9 words), then IP, CS, FLAGS
    mov ax, [bp + 24]
    mov bx, [bp + 22]
    push es
    mov es, [prof_seg]
    mov dx, cs
    cmp ax, dx
    je short .ours
    xor bx, bx              ; Foreign code segment -> bucket 0
.ours:
    and bx, 0FFFEh
    inc word [es:bx]
    jnz short .no_sat
    dec word [es:bx]
.no_sat:
    pop es
    pop bp
    ret

bench_write:
    push cs
    pop ds
    mov ah, 3Ch
    xor cx, cx
    lea dx, [bench_filename]
    int 21h
    jc short .done
    mov bx, ax
    lea dx, [bench_stats]
    mov cx, bench_stats_end - bench_stats
    mov ah, 40h
    int 21h
    mov ds, [cs:nes_ram_seg]   ; Incrementally rendered final frame (see bench_isr_end)
    mov dx, 8000h
    mov cx, 16384
    mov ah, 40h
    int 21h
    mov ds, [cs:prof_seg]      ; Profiler histogram (64 KB in two halves)
    xor dx, dx
    mov cx, 8000h
    mov ah, 40h
    int 21h
    mov dx, 8000h
    mov cx, 8000h
    mov ah, 40h
    int 21h
    push cs
    pop ds
    mov ah, 3Eh
    int 21h
.done:
    ret

bench_filename:     db 'BENCH.BEN', 0
prof_seg:           dw 0
bench_script:       dw 0FFFFh
bench_in_idle:      db 0
bench_isr_t0:       dd 0
bench_idle_t0:      dd 0
bench_idle_isr0:    dd 0
bench_stats:
bench_ticks:        dw 0
bench_nmi:          dw 0
bench_lost:         dw 0
bench_flush:        dw 0
bench_frames:       dw 0
bench_total_time:   dd 0
bench_isr_time:     dd 0
bench_render_time:  dd 0
bench_idle_time:    dd 0
bench_hw_steps:     dw 0       ; Hardware scroll steps taken
bench_full_redraws: dw 0       ; Full repaints (dense passes)
bench_stats_end:
%endif

; ------------------------------------------------------------------------------
; 6502 CONTROL FLOW & EFFECTIVE ADDRESS HELPERS
; ------------------------------------------------------------------------------
; 6502 JSR helper: called via `call hle_jsr` followed by `dw ret6502, loc_target`
; Pushes ret6502 (pc + 2) onto 6502 stack [DI] and jumps to loc_target. Preserves ALL flags!
hle_jsr:
    pop si
    lea di, [di - 2]
    mov dx, [cs:si]
    mov [di + 1], dx
    mov dh, 0
    jmp word [cs:si + 2]

; 6502 RTS: pops (ret_addr - 1) from 6502 stack [DI], jumps to native code for ret_addr
hle_rts:
    pushf
    mov si, [di + 1]
    lea di, [di + 2]
    inc si
    shl si, 1
    popf
    jmp word [es:si]

; 6502 JMP ($xxxx): SI = 6502 target address
dispatch_indirect:
    pushf
    shl si, 1
    popf
    jmp word [es:si]

; 6502 BIT instruction helper. Input: DL = memory operand, AL = 6502 A.
; Sets ZF = ((AL & DL) == 0), SF = DL bit 7, OF = DL bit 6, preserves CF & AL!
hle_bit_2002:
    call hle_read_2002_dl
hle_bit:
    push ax
    push cx
    pushf
    pop cx
    and cx, ~(08C0h)        ; Clear OF (0800h), SF (0080h), ZF (0040h)
    mov ah, dl
    and ah, 80h             ; SF = DL bit 7
    test al, dl
    jnz short .bit_nz
    or ah, 40h              ; ZF = 1 if (AL & DL) == 0
.bit_nz:
    or cl, ah
    test dl, 40h
    jz short .bit_nv
    or ch, 08h              ; OF = DL bit 6
.bit_nv:
    push cx
    popf
    pop cx
    pop ax
    ret

; ------------------------------------------------------------------------------
; KEYBOARD INTERRUPT (INT 09h)
; ------------------------------------------------------------------------------
int09_handler:
    push ax
    push bx
    push ds
    push cs
    pop ds

    in al, 60h              ; Read keyboard scancode
    cmp al, 0E0h            ; Ignore extended scancode prefix
    je .k_ack

    mov bl, al
    and bl, 7Fh             ; BL = base scancode
    test al, 80h            ; AL bit 7 set = key release
    jnz .key_up

.key_down:
    ; Up: 48h (Up Arrow) or 11h (W)
    cmp bl, 48h
    je short .press_up
    cmp bl, 11h
    je short .press_up
    ; Down: 50h (Down Arrow) or 1Fh (S)
    cmp bl, 50h
    je short .press_down
    cmp bl, 1Fh
    je short .press_down
    ; Left: 4Bh (Left Arrow) or 1Eh (A)
    cmp bl, 4Bh
    je short .press_left
    cmp bl, 1Eh
    je short .press_left
    ; Right: 4Dh (Right Arrow) or 20h (D)
    cmp bl, 4Dh
    je short .press_right
    cmp bl, 20h
    je short .press_right
    ; A button: 2Ch (Z) or 24h (J)
    cmp bl, 2Ch
    je short .press_a
    cmp bl, 24h
    je short .press_a
    ; B button: 2Dh (X) or 25h (K)
    cmp bl, 2Dh
    je short .press_b
    cmp bl, 25h
    je short .press_b
    ; Select: 0Fh (Tab) or 2Eh (C) or 2Ah (LShift)
    cmp bl, 0Fh
    je short .press_sel
    cmp bl, 2Eh
    je short .press_sel
    cmp bl, 2Ah
    je short .press_sel
    ; Start: 1Ch (Enter) or 39h (Space)
    cmp bl, 1Ch
    je short .press_start
    cmp bl, 39h
    je short .press_start
    ; Keys 1-9 (scancodes 02h..0Ah): set frameskip divisor (1=60fps .. 9=6.7fps)
    cmp bl, 02h
    jb short .check_esc
    cmp bl, 0Ah
    jbe short .set_fskip
    ; Key I (scancode 17h): toggle inverted colours (for low-contrast LCDs)
    cmp bl, 17h
    je .press_invert
    ; Key 0 (scancode 0Bh): toggle PC speaker sound mute
    cmp bl, 0Bh
    je short .toggle_mute
.check_esc:
    ; ESC: 01h (Exit)
    cmp bl, 01h
    je short .press_esc
    jmp .k_ack

.press_up:
    or byte [key_state], 10h
    jmp .k_ack
.press_down:
    or byte [key_state], 20h
    jmp .k_ack
.press_left:
    or byte [key_state], 40h
    jmp .k_ack
.press_right:
    or byte [key_state], 80h
    jmp .k_ack
.press_a:
    or byte [key_state], 01h
    jmp .k_ack
.press_b:
    or byte [key_state], 02h
    jmp .k_ack
.press_sel:
    or byte [key_state], 04h
    jmp .k_ack
.press_start:
    or byte [key_state], 08h
    jmp .k_ack
.set_fskip:
    dec bl
    mov [frameskip_max], bl
    mov [frameskip_cur], bl
    mov byte [frame_div], 0
    mov byte [hud_timer], 60
    call draw_fskip_hud
    jmp .k_ack
.press_invert:
    mov byte [invert_request], 1
    jmp .k_ack
.toggle_mute:
    xor byte [sound_enabled], 1
    jnz .k_ack
    mov word [apu_last_period], 0
    in al, 61h
    and al, 0FCh
    out 61h, al
    jmp .k_ack

.press_esc:
    ; Acknowledge keyboard controller (XT style)
    in al, 61h
    mov ah, al
    or al, 80h
    out 61h, al
    mov al, ah
    out 61h, al
    ; Send EOI to PIC
    mov al, 20h
    out 20h, al
    jmp runtime_shutdown

.key_up:
    cmp bl, 48h
    je short .rel_up
    cmp bl, 11h
    je short .rel_up
    cmp bl, 50h
    je short .rel_down
    cmp bl, 1Fh
    je short .rel_down
    cmp bl, 4Bh
    je short .rel_left
    cmp bl, 1Eh
    je short .rel_left
    cmp bl, 4Dh
    je short .rel_right
    cmp bl, 20h
    je short .rel_right
    cmp bl, 2Ch
    je short .rel_a
    cmp bl, 24h
    je short .rel_a
    cmp bl, 2Dh
    je short .rel_b
    cmp bl, 25h
    je short .rel_b
    cmp bl, 0Fh
    je short .rel_sel
    cmp bl, 2Eh
    je short .rel_sel
    cmp bl, 2Ah
    je short .rel_sel
    cmp bl, 1Ch
    je short .rel_start
    cmp bl, 39h
    je short .rel_start
    jmp short .k_ack

.rel_a:
    and byte [key_state], ~01h
    jmp short .k_ack
.rel_b:
    and byte [key_state], ~02h
    jmp short .k_ack
.rel_sel:
    and byte [key_state], ~04h
    jmp short .k_ack
.rel_start:
    and byte [key_state], ~08h
    jmp short .k_ack
.rel_up:
    and byte [key_state], ~10h
    jmp short .k_ack
.rel_down:
    and byte [key_state], ~20h
    jmp short .k_ack
.rel_left:
    and byte [key_state], ~40h
    jmp short .k_ack
.rel_right:
    and byte [key_state], ~80h
    jmp short .k_ack

.k_ack:
    ; Acknowledge keyboard controller (XT style)
    in al, 61h
    mov ah, al
    or al, 80h
    out 61h, al
    mov al, ah
    out 61h, al

    ; Send EOI to PIC
    mov al, 20h
    out 20h, al

    pop ds
    pop bx
    pop ax
    iret

; ------------------------------------------------------------------------------
; PPU & IO HLE TRAP ROUTINES (All preserve 6502 flags & registers!)
; ------------------------------------------------------------------------------
hle_write_2000:
    pushf
    push ax
    mov ah, [cs:ppu_ctrl]
    mov [cs:ppu_ctrl], al
    xor ah, al
    ; NMI enable rising edge: like real hardware (first NMI at the *next* vblank), give
    ; the game at least one full tick before the first NMI. Without this, a tick landing
    ; right after `STA $2000` runs the NMI before the game has stored its PPUCTRL shadow
    ; (e.g. Urban Champion), which can disable NMIs for good.
    test ah, 80h
    jz short .no_nmi_edge
    test al, 80h
    jz short .no_nmi_edge
    mov byte [cs:nmi_holdoff], 1
.no_nmi_edge:
    mov byte [cs:ppu_inc], 1
    test al, 04h
    jz short .inc_ok
    mov byte [cs:ppu_inc], 32
.inc_ok:
    ; Pattern-table / sprite-size / nametable bits are compared at render time
    ; (flush_dirty_tiles), so mid-frame toggles that are undone before the next render
    ; (split-screen tricks) cost nothing
    pop ax
    popf
    ret

; The background is always drawn (the CGA screen is never blanked), so toggling the
; BG-enable bit needs no repaint. Many games switch rendering off and on around their
; VRAM updates every NMI; repainting on each toggle forced a full redraw every frame.
hle_write_2001:
    mov [cs:ppu_mask], al
    ret

; Programs the 6845 display start address from scr_origin (bytes -> words)
cga_set_origin:
    push ax
    push bx
    push dx
    mov bx, [cs:scr_origin]
    shr bx, 1
    mov dx, 3D4h
    mov al, 0Ch
    out dx, al
    inc dx
    mov al, bh
    out dx, al
    dec dx
    mov al, 0Dh
    out dx, al
    inc dx
    mov al, bl
    out dx, al
    pop dx
    pop bx
    pop ax
    ret

; Fills a CX-word-wide vertical strip at byte offset BX of every scanline (both banks,
; origin-relative, wrapping in the bank ring) with the background colour.
cga_clear_strip:
    push ax
    push cx
    push dx
    push si
    push di
    push es
    mov es, [cs:cga_seg]
    mov ax, [cs:invert_word]
    mov dx, cx
    mov si, [cs:scr_origin]
    add si, bx              ; SI = origin-relative start of the strip on line 0
    mov bx, 100
.line:
    mov cx, dx
    mov di, si
.word:
    and di, 1FFFh
    mov [es:di], ax
    mov [es:di + 2000h], ax
    add di, 2
    loop .word
    add si, 80
    dec bx
    jnz .line
    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop ax
    ret

; Fills CX whole scanlines per bank (origin-relative lines BX.., 80 bytes each, wrapping
; in the bank ring) with the background colour.
cga_clear_lines:
    push ax
    push bx
    push cx
    push dx
    push di
    push es
    mov es, [cs:cga_seg]
    mov ax, [cs:invert_word]
    mov dx, cx
    mov di, bx
    shl di, 1
    shl di, 1
    shl di, 1
    shl di, 1               ; line * 16
    mov bx, di
    shl di, 1
    shl di, 1               ; line * 64
    add di, bx              ; line * 80
    add di, [cs:scr_origin]
.line:
    mov cx, 40
.word:
    and di, 1FFFh
    mov [es:di], ax
    mov [es:di + 2000h], ax
    add di, 2
    loop .word
    dec dx
    jnz .line
    pop es
    pop di
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; Background tile blit whose 4 even/4 odd rows wrap past the end of the 8 KB bank ring.
; DI = wrapped CGA offset, DS:SI = tile. Preserves everything but AX.
cga_tile_wrapped:
    push bx
    push cx
    push di
    mov bx, 0
    mov cx, 4
.row:
    and di, 1FFFh
    mov ax, [si + bx]
    xor ax, [cs:invert_word]
    mov [es:di], ax
    mov ax, [si + bx + 8]
    xor ax, [cs:invert_word]
    mov [es:di + 2000h], ax
    add di, 80
    add bx, 2
    loop .row
    pop di
    pop cx
    pop bx
    ret

; Sprite blit that wraps past the end of the bank ring (byte by byte). DI = wrapped CGA
; offset (may be odd), DS:SI = tile, CS:BX = row order table (8 source word offsets for
; even0, odd0, even1, odd1, ...). ORs (or AND-NOTs when inverted) non-zero pixels.
spr_wrapped:
    push ax
    push cx
    push dx
    push di
    mov cx, 8
.row:
    mov dx, di              ; DX = this row pair's line offset (even rows: CX even)
    push si
    add si, [cs:bx]
    mov ax, [si]            ; AL = left byte, AH = right byte
    pop si
    push di
    mov di, dx
    and di, 1FFFh
    test cl, 1
    jz short .bank_ok
    add di, 2000h
.bank_ok:
    call .put_byte
    mov al, ah
    mov di, dx
    inc di
    and di, 1FFFh
    test cl, 1
    jz short .bank_ok2
    add di, 2000h
.bank_ok2:
    call .put_byte
    pop di
    test cl, 1
    jz short .no_advance
    add di, 80              ; Next even/odd pair
.no_advance:
    add bx, 2
    loop .row
    pop di
    pop dx
    pop cx
    pop ax
    ret
.put_byte:
    cmp byte [cs:invert_on], 0
    jne short .put_inv
    or [es:di], al
    ret
.put_inv:
    not al
    and [es:di], al
    ret

spr_order_normal:   dw 0, 8, 2, 10, 4, 12, 6, 14
spr_order_vflip:    dw 14, 6, 12, 4, 10, 2, 8, 0

; Copies the visible CGA window (origin-relative ring) to a linear layout at origin 0,
; via nes_ram_seg:8000h, and resets the CRTC origin (used before dumps).
cga_linearize:
    push ax
    push cx
    push si
    push di
    push ds
    push es
    mov ds, [cs:cga_seg]
    mov es, [cs:nes_ram_seg]
    mov di, 8000h
    xor dx, dx              ; DX = bank base (0, 2000h)
.bank:
    mov si, [cs:scr_origin]
    mov cx, 8192
.byte:
    and si, 1FFFh
    push si
    add si, dx
    movsb
    pop si
    inc si
    loop .byte
    add dx, 2000h
    cmp dx, 4000h
    jb .bank
    mov ds, [cs:nes_ram_seg]
    mov es, [cs:cga_seg]
    mov si, 8000h
    xor di, di
    mov cx, 8192
    rep movsw
    mov word [cs:scr_origin], 0
    call cga_set_origin
    pop es
    pop ds
    pop di
    pop si
    pop cx
    pop ax
    ret

; Requests a full repaint on the next flush. The dense pass ignores dirty_grid (and clears
; it afterwards), so the grid itself does not need to be filled here.
; ------------------------------------------------------------------------------
; SPRITE SAVE-UNDER: each 8-line sprite block saves the 16 background bytes it covers
; (2 bytes x 8 scanlines) before being drawn; the next render restores them in reverse
; order before updating tiles. Entries: dw wrapped even-bank offset, 16 bytes.
; ------------------------------------------------------------------------------
; DI = origin-relative even-bank offset of the block. Preserves all registers.
save_block:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push ds
    push es
    mov bx, [cs:save_count]
    cmp bx, SAVE_MAX
    jae .done
    inc word [cs:save_count]
    mov ax, bx
    shl bx, 1
    shl bx, 1
    shl bx, 1
    shl bx, 1
    shl ax, 1
    add bx, ax              ; BX = entry * 18
    add di, [cs:scr_origin]
    and di, 1FFFh
    mov si, di              ; SI = wrapped even-bank offset of line 0
    mov di, bx
    mov ds, [cs:cga_seg]
    mov es, [cs:save_seg]
    mov ax, si
    cld
    stosw
    mov dx, 4               ; 4 line pairs (even + odd scanline)
.pair:
    mov bx, si
    and bx, 1FFFh
    mov al, [bx]
    mov ah, [bx + 2000h]
    stosw
    lea bx, [si + 1]
    and bx, 1FFFh
    mov al, [bx]
    mov ah, [bx + 2000h]
    stosw
    add si, 80
    dec dx
    jnz .pair
.done:
    pop es
    pop ds
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; Restores all saved blocks (newest first) and empties the list. Preserves registers.
sprite_restore:
    cmp word [cs:save_count], 0
    jne short .go
    ret
.go:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push ds
    push es
    mov ds, [cs:save_seg]
    mov es, [cs:cga_seg]
    mov cx, [cs:save_count]
.entry:
    dec cx
    mov si, cx
    shl si, 1
    shl si, 1
    shl si, 1
    shl si, 1
    mov ax, cx
    shl ax, 1
    add si, ax              ; SI = entry * 18
    cld
    lodsw
    mov di, ax              ; DI = wrapped even-bank offset of line 0
    mov dx, 4
.pair:
    lodsw
    mov bx, di
    and bx, 1FFFh
    mov [es:bx], al
    mov [es:bx + 2000h], ah
    lodsw
    lea bx, [di + 1]
    and bx, 1FFFh
    mov [es:bx], al
    mov [es:bx + 2000h], ah
    add di, 80
    dec dx
    jnz .pair
    test cx, cx
    jnz .entry
    mov word [cs:save_count], 0
    pop es
    pop ds
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; Applies a pending invert-colours toggle (from the I key) between renders: flips every
; pixel already on screen (colour c -> 3 - c), after which all drawing uses the inverted
; blitters, so the shadow of what is on screen stays valid.
apply_invert_request:
    cmp byte [cs:invert_request], 0
    jne short .apply
    ret
.apply:
    call sprite_restore     ; Saved backgrounds are in the old colours
    push ax
    push cx
    push di
    push es
    mov byte [cs:invert_request], 0
    xor byte [cs:invert_on], 1
    not word [cs:invert_word]
    mov es, [cs:cga_seg]
    xor di, di
    mov cx, 8192
.flip:
    not word [es:di]
    add di, 2
    loop .flip
    pop es
    pop di
    pop cx
    pop ax
    ret

mark_all_dirty:
    mov word [cs:dirty_count], 800
    mov byte [cs:full_redraw], 1
    ret

hle_read_2002:
    call hle_read_2002_dl
    mov al, dl
    ret

hle_read_2002_dl:
    pushf
    mov dl, [cs:ppu_status]
    and byte [cs:ppu_status], ~80h
    xor byte [cs:ppu_status], 40h   ; Toggle Sprite 0 Hit so wait loops complete
    mov byte [cs:ppu_latch], 0
    popf
    ret

hle_write_2003:
    mov [cs:oam_addr], al
    ret

hle_write_2004:
    pushf
    push bx
    mov bl, [cs:oam_addr]
    xor bh, bh
    mov [cs:oam_ram + bx], al
    inc byte [cs:oam_addr]
    pop bx
    popf
    ret

hle_read_2004:
    pushf
    push bx
    mov bl, [cs:oam_addr]
    xor bh, bh
    mov al, [cs:oam_ram + bx]
    pop bx
    popf
    ret

hle_write_2005:
    pushf
    test byte [cs:ppu_latch], 1
    jnz short .set_scroll_y
    mov [cs:ppu_scroll_x], al
    mov byte [cs:ppu_latch], 1
    inc word [cs:dirty_count]
    popf
    ret
.set_scroll_y:
    mov [cs:ppu_scroll_y], al
    mov byte [cs:ppu_latch], 0
    inc word [cs:dirty_count]
    popf
    ret

hle_write_2006:
    pushf
    test byte [cs:ppu_latch], 1
    jnz short .set_addr_lo
    mov [cs:ppu_addr_hi], al
    mov byte [cs:ppu_latch], 1
    popf
    ret
.set_addr_lo:
    mov [cs:ppu_addr_lo], al
    mov byte [cs:ppu_latch], 0
    popf
    ret

hle_write_2007:
    pushf
    push bx
    mov bx, [cs:ppu_addr_lo]
    and bh, 3Fh
    cmp bh, 3Fh
    jae short .write_pal
    cmp bh, 20h
    jb short .advance_addr
    test bh, 0Ch            ; Second nametable ($2400/$2800/$2C00) -> offset 960
    jnz short .nt1
    and bx, 03FFh
    cmp bx, 960
    jae short .advance_addr ; Attribute table: ignored
    mov [cs:vram_nametable + bx], al
    mov byte [cs:dirty_grid + bx], 1
    jmp short .marked
.nt1:
    and bx, 03FFh
    cmp bx, 960
    jae short .advance_addr
    mov [cs:vram_nametable + 960 + bx], al
    mov byte [cs:dirty_grid + 960 + bx], 1
.marked:
    inc word [cs:dirty_count]
.advance_addr:
    mov bx, [cs:ppu_inc]
    add [cs:ppu_addr_lo], bx
    pop bx
    popf
    ret
.write_pal:
    and bx, 1Fh
    mov [cs:palette_ram + bx], al
    jmp short .advance_addr

hle_read_2007:
    pushf
    push bx
    push dx
    mov bx, [cs:ppu_addr_lo]
    and bh, 3Fh

    cmp bx, 3F00h
    jae short .read_pal

    mov dl, [cs:ppu_read_buf]
    cmp bx, 2000h
    jb short .read_chr

    and bx, 03FFh
    mov dh, [cs:vram_nametable + bx]
    mov [cs:ppu_read_buf], dh
    mov al, dl
    jmp short .r_advance

.read_chr:
    ; Read from raw 8KB CHR-ROM stored at DS:2000h..3FFFh
    mov dh, [bx + 2000h]
    mov [cs:ppu_read_buf], dh
    mov al, dl
    jmp short .r_advance

.read_pal:
    and bx, 1Fh
    mov al, [cs:palette_ram + bx]

.r_advance:
    mov bx, [cs:ppu_inc]
    add [cs:ppu_addr_lo], bx
    pop dx
    pop bx
    popf
    ret

; OAM DMA ($4014)
hle_write_4014:
    pushf
    push ax
    push cx
    push si
    push di
    push ds
    push es

    mov ds, [cs:nes_ram_seg]
    push cs
    pop es

    mov ah, al
    xor al, al
    mov si, ax
    lea di, [oam_ram]
    mov cx, 128
    rep movsw

    pop es
    pop ds
    pop di
    pop si
    pop cx
    pop ax
    popf
    ret

; Joypad Strobe ($4016 Write)
hle_write_4016:
    pushf
%ifdef BENCH
%ifndef BENCH_NMI_FRAMES
    test al, 1
    jz short .no_strobe
    inc word [cs:bench_frames]  ; Joypad strobe (write of 1) = one game logic frame
.no_strobe:
%endif
%endif
    push ax
    mov al, [cs:key_state]
    mov [cs:joy_shift], al
    pop ax
    popf
    ret

; Joypad Data ($4016 Read)
hle_read_4016:
    pushf
    mov al, [cs:joy_shift]
    shr byte [cs:joy_shift], 1
    or  byte [cs:joy_shift], 80h
    and al, 1
    popf
    ret

; Indexed Joypad Read ($4016,X)
hle_read_4016_x:
    cmp REG_X, 0
    je hle_read_4016
    mov al, 0
    ret

; Indexed Joypad Read ($4016,Y)
hle_read_4016_y:
    cmp REG_Y, 0
    je hle_read_4016
    mov al, 0
    ret

; Dynamic I/O & RAM Write Helper (SI = effective address, AL = value)
hle_write_si:
    pushf
    cmp si, 2000h
    jb short .w_si_ram
    push bx
    mov bx, si
    call hle_write_dynamic
    pop bx
    popf
    ret
.w_si_ram:
    and si, 07FFh
    mov [si], al
    popf
    ret

; STA ($xx),Y helper (SI = word [zp], REG_Y = Y, AL = value)
hle_sta_izy:
    pushf
    add si, REG_Y16         ; High byte of the Y register pair is always 0
    cmp si, 2000h
    jb short .izy_ram
    push bx
    mov bx, si
    call hle_write_dynamic
    pop bx
    popf
    ret
.izy_ram:
    and si, 07FFh
    mov [si], al
    popf
    ret

; Dynamic I/O Dispatch (BX = address, AL = value)
hle_write_dynamic:
    cmp bx, 2000h
    jb short .dyn_ram
    cmp bx, 4000h
    jae short .dyn_io
    and bx, 7
    shl bx, 1
    jmp [cs:.ppu_jmp_tbl + bx]

.dyn_ram:
    and bx, 07FFh
    mov [bx], al
    ret

.dyn_io:
    cmp bx, 4014h
    je hle_write_4014
    cmp bx, 4016h
    je hle_write_4016
    cmp byte [cs:sound_enabled], 0
    je short .dyn_io_ret
    cmp bx, 4015h
    ja short .dyn_io_ret
    sub bx, 4000h
    mov [cs:apu_regs + bx], al
    shl bx, 1
    jmp [cs:.apu_jmp_tbl + bx]
.dyn_io_ret:
    ret

.ppu_jmp_tbl:
    dw hle_write_2000, hle_write_2001, hle_ret_dummy,  hle_write_2003
    dw hle_write_2004, hle_write_2005, hle_write_2006, hle_write_2007
.apu_jmp_tbl:
    dw hle_ret_dummy,  hle_ret_dummy,  hle_write_4002, hle_write_4003
    dw hle_ret_dummy,  hle_ret_dummy,  hle_write_4006, hle_write_4007
    dw hle_ret_dummy,  hle_ret_dummy,  hle_write_400A, hle_write_400B
    dw hle_ret_dummy,  hle_ret_dummy,  hle_ret_dummy,  hle_write_400F
    dw hle_ret_dummy,  hle_ret_dummy,  hle_ret_dummy,  hle_ret_dummy
    dw hle_ret_dummy,  hle_write_4015
hle_ret_dummy:
    ret

; ------------------------------------------------------------------------------
; NES APU -> IBM PC SPEAKER HLE SYNTHESIS ENGINE (8253 PIT Channel 2 / Port 61h)
; ------------------------------------------------------------------------------
hle_write_4002:
    pushf
    mov [cs:apu_regs + 2], al
    cmp byte [cs:apu_len_p1], 2
    jae short .w4002_done
    mov byte [cs:apu_len_p1], 4
.w4002_done:
    popf
    ret

hle_write_4003:
    pushf
    push bx
    mov [cs:apu_regs + 3], al
    mov bl, al
    shr bl, 1
    shr bl, 1
    shr bl, 1
    xor bh, bh
    mov bl, [cs:apu_len_table + bx]
    test byte [cs:apu_regs + 0], 20h
    jz short .w4003_set
    test byte [cs:apu_regs + 0], 10h
    jnz short .w4003_set
    mov bl, [cs:apu_regs + 0]
    and bl, 0Fh
    inc bl
    shl bl, 1
.w4003_set:
    mov [cs:apu_len_p1], bl
    mov byte [cs:apu_sfx_prio], 6
    pop bx
    popf
    ret

hle_write_4006:
    pushf
    mov [cs:apu_regs + 6], al
    cmp byte [cs:apu_len_p2], 2
    jae short .w4006_done
    mov byte [cs:apu_len_p2], 4
.w4006_done:
    popf
    ret

hle_write_4007:
    pushf
    push bx
    mov [cs:apu_regs + 7], al
    mov bl, al
    shr bl, 1
    shr bl, 1
    shr bl, 1
    xor bh, bh
    mov bl, [cs:apu_len_table + bx]
    test byte [cs:apu_regs + 4], 20h
    jz short .w4007_set
    test byte [cs:apu_regs + 4], 10h
    jnz short .w4007_set
    mov bl, [cs:apu_regs + 4]
    and bl, 0Fh
    inc bl
    shl bl, 1
.w4007_set:
    mov [cs:apu_len_p2], bl
    pop bx
    popf
    ret

hle_write_400A:
    pushf
    mov [cs:apu_regs + 10], al
    cmp byte [cs:apu_len_tri], 2
    jae short .w400A_done
    mov byte [cs:apu_len_tri], 4
.w400A_done:
    popf
    ret

hle_write_400B:
    pushf
    push bx
    mov [cs:apu_regs + 11], al
    mov bl, al
    shr bl, 1
    shr bl, 1
    shr bl, 1
    xor bh, bh
    mov bl, [cs:apu_len_table + bx]
    mov [cs:apu_len_tri], bl
    pop bx
    popf
    ret

hle_write_400F:
    pushf
    push bx
    mov [cs:apu_regs + 15], al
    mov bl, al
    shr bl, 1
    shr bl, 1
    shr bl, 1
    xor bh, bh
    mov bl, [cs:apu_len_table + bx]
    cmp bl, 10
    jbe short .w400F_set
    mov bl, 10
.w400F_set:
    mov [cs:apu_len_noi], bl
    pop bx
    popf
    ret

hle_write_4015:
    pushf
    mov [cs:apu_regs + 21], al
    test al, 01h
    jnz short .c2
    mov byte [cs:apu_len_p1], 0
.c2:
    test al, 02h
    jnz short .c3
    mov byte [cs:apu_len_p2], 0
.c3:
    test al, 04h
    jnz short .c4
    mov byte [cs:apu_len_tri], 0
.c4:
    test al, 08h
    jnz short .c_done
    mov byte [cs:apu_len_noi], 0
.c_done:
    popf
    ret

; Called once per 60Hz tick in int08_handler
apu_update_60hz:
    cmp byte [cs:sound_enabled], 0
    jne short .run_apu
    ret
.run_apu:
    push ax
    push bx
    push cx
    push dx
    push ds
    push cs
    pop ds

    cmp byte [apu_sfx_prio], 0
    je short .no_prio_dec
    dec byte [apu_sfx_prio]
.no_prio_dec:
    xor cx, cx              ; CX = Pulse 1 period (0 = silent)
    xor dx, dx              ; DX = Pulse 2 period (0 = silent)

    ; --- 1. Evaluate Pulse 1 ($4000..$4003) ---
    test byte [apu_regs + 21], 01h
    jz short .chk_p2
    cmp byte [apu_len_p1], 0
    je short .chk_p2
    dec byte [apu_len_p1]
    mov al, [apu_regs + 0]
    test al, 10h
    jz short .p1_freq
    test al, 0Fh
    jz short .chk_p2
.p1_freq:
    mov ah, [apu_regs + 3]
    and ah, 07h
    mov al, [apu_regs + 2]
    cmp ax, 8
    jb short .chk_p2
    cmp ax, 07F0h
    jae short .chk_p2
    mov cx, ax

    ; --- 2. Evaluate Pulse 2 ($4004..$4007) ---
.chk_p2:
    test byte [apu_regs + 21], 02h
    jz short .mix_pulse
    cmp byte [apu_len_p2], 0
    je short .mix_pulse
    dec byte [apu_len_p2]
    mov al, [apu_regs + 4]
    test al, 10h
    jz short .p2_freq
    test al, 0Fh
    jz short .mix_pulse
.p2_freq:
    mov ah, [apu_regs + 7]
    and ah, 07h
    mov al, [apu_regs + 6]
    cmp ax, 8
    jb short .mix_pulse
    cmp ax, 07F0h
    jae short .mix_pulse
    mov dx, ax

.mix_pulse:
    mov ax, cx
    or ax, ax
    jz short .use_p2
    or dx, dx
    jz .have_voice
    ; Both Pulse 1 & Pulse 2 active: prioritize fresh SFX or multiplex every 2 ticks
    cmp byte [apu_sfx_prio], 0
    jne .have_voice
    test byte [tick_60hz], 2
    jz .have_voice
.use_p2:
    mov ax, dx
    or ax, ax
    jnz .have_voice

    ; --- 3. Evaluate Triangle ($4008..$400B) ---
    test byte [apu_regs + 21], 04h
    jz short .chk_noise
    cmp byte [apu_len_tri], 0
    je short .chk_noise
    dec byte [apu_len_tri]
    test byte [apu_regs + 8], 7Fh
    jz short .chk_noise
    mov ah, [apu_regs + 11]
    and ah, 07h
    mov al, [apu_regs + 10]
    cmp ax, 4
    jb short .chk_noise
    cmp ax, 07F0h
    jae short .chk_noise
    shl ax, 1               ; Triangle is 1 octave lower than Pulse for same timer T
    jmp short .have_voice

    ; --- 4. Evaluate Noise ($400C..$400F) ---
.chk_noise:
    test byte [apu_regs + 21], 08h
    jz short .silence
    cmp byte [apu_len_noi], 0
    je short .silence
    dec byte [apu_len_noi]
    mov al, [apu_regs + 12]
    test al, 10h
    jz short .noi_freq
    test al, 0Fh
    jz short .silence
.noi_freq:
    mov al, [apu_regs + 14]
    and al, 0Fh
    add al, 4
    xor ah, ah
    mov cl, 5
    shl ax, cl
    mov bx, [tick_total]
    mov cl, 3
    rol bx, cl
    xor bx, [apu_last_period]
    and bx, 01FFh
    xor ax, bx
    jmp short .have_voice

.silence:
    cmp word [apu_last_period], 0
    je short .apu_ret
    mov word [apu_last_period], 0
    in al, 61h
    and al, 0FCh
    out 61h, al
.apu_ret:
    pop ds
    pop dx
    pop cx
    pop bx
    pop ax
    ret

.have_voice:
    cmp ax, [apu_last_period]
    je short .apu_ret
    mov [apu_last_period], ax

    ; Fast 8088 conversion: D_PC = T * 10.625 (approx 1193182 * 16 / 1789773)
    mov bx, ax
    shl ax, 1               ; T * 2
    mov cx, ax
    shl ax, 1
    shl ax, 1               ; T * 8
    add ax, cx              ; T * 10
    shr bx, 1               ; T * 0.5
    add ax, bx              ; T * 10.5
    shr bx, 1
    shr bx, 1               ; T * 0.125
    add ax, bx              ; T * 10.625

    mov cx, ax
    mov al, 0B6h            ; PIT Channel 2, lobyte/hibyte, mode 3 square wave
    out 43h, al
    mov al, cl
    out 42h, al
    mov al, ch
    out 42h, al
    in al, 61h
    or al, 03h              ; Enable PC speaker gate
    out 61h, al
    jmp short .apu_ret

; ------------------------------------------------------------------------------
; DIRTY-TILE VIDEO BLITTER (CGA MODE 4)
; ------------------------------------------------------------------------------
flush_dirty_tiles:
    call sprite_restore     ; Undo last frame's sprites before any tile update
    cmp word [cs:dirty_count], 0
    jne short .do_flush
    ret

.do_flush:
    push ds
    push es
    push si
    push di
    push bp
    push bx
    push cx
    push dx

    mov es, [cs:cga_seg]
    push cs
    pop ds

    xor bp, bp
    test byte [ppu_ctrl], 10h
    jz short .bg_pat_0
    mov bp, 4096
.bg_pat_0:

    ; BG pattern table or sprite size (row offset) differ from the last render: repaint all
    mov al, [ppu_ctrl]
    and al, 30h
    cmp al, [prev_ctrl_bits]
    je short .ctrl_same
    mov [prev_ctrl_bits], al
    call mark_all_dirty
.ctrl_same:

    ; Compute horizontal scroll in columns (0..63)
    mov al, [ppu_scroll_x]
    shr al, 1
    shr al, 1
    shr al, 1
    test byte [ppu_ctrl], 01h
    jz short .hx_ok
    xor al, 32
.hx_ok:
    mov [scroll_x_cols], al

    ; Compute vertical starting row (row 3 for 8x16 sprite games like Battle City, row 2 otherwise)
    mov byte [y_nes_min], 16
    mov ah, 2
    test byte [ppu_ctrl], 20h
    jz short .v_row2
    mov byte [y_nes_min], 24
    mov ah, 3
.v_row2:
    mov al, [ppu_scroll_y]
    shr al, 1
    shr al, 1
    shr al, 1
    cmp al, 30
    jb short .scroll_ok
    xor al, al
.scroll_ok:
    add al, ah
    test byte [ppu_ctrl], 02h
    jz short .nt_base_0
    add al, 30
.nt_base_0:
    cmp al, 60
    jb short .row_ok
    sub al, 60
.row_ok:
    xor ah, ah
    mov cl, 5
    shl ax, cl
    mov [active_nt_base], ax

    ; If rendered horizontal or vertical scroll tile offset changed, mark all dirty
    mov dl, [scroll_x_cols]
    cmp dl, [prev_scroll_x_cols]
    jne short .scroll_changed
    cmp ax, [prev_nt_base]
    jne short .scroll_changed
    jmp .scroll_unchanged
.scroll_changed:
    ; Horizontal-only scroll by a few columns with a scrolled HUD split on both sides:
    ; move the CGA display start address instead of repainting the whole screen
    cmp ax, [prev_nt_base]
    jne .try_vscroll
    mov dh, [prev_scroll_x_cols]
    test dl, dl
    jz short .scroll_full
    test dh, dh
    jz short .scroll_full
    cmp byte [full_redraw], 0
    jne short .scroll_full
    mov bl, dl
    sub bl, dh
    and bl, 63              ; d = (new - old) mod 64, as -32..31
    cmp bl, 32
    jb short .d_pos
    sub bl, 64
.d_pos:
    mov al, bl
    cbw                     ; AX = d
    cmp ax, HW_SCROLL_MAX
    jg short .scroll_full_ax
    cmp ax, -HW_SCROLL_MAX
    jl short .scroll_full_ax
    mov [prev_scroll_x_cols], dl
%ifdef BENCH
    inc word [bench_hw_steps]
%endif
    call .hw_scroll_step
    jmp .scroll_unchanged
.scroll_full_ax:
    mov ax, [active_nt_base]
    jmp short .scroll_full
.try_vscroll:
    ; Vertical-only scroll by a few tile rows (no horizontal scroll, so no fixed HUD
    ; rows): move the display origin by whole tile rows instead of repainting
    test dl, dl
    jnz short .scroll_full
    cmp dl, [prev_scroll_x_cols]
    jne short .scroll_full
    cmp byte [full_redraw], 0
    jne short .scroll_full
    mov bx, ax
    sub bx, [prev_nt_base]
    mov cl, 5
    sar bx, cl              ; BX = row delta, -59..59
    cmp bx, 30
    jl short .k_lo
    sub bx, 60
.k_lo:
    cmp bx, -30
    jge short .k_ok
    add bx, 60
.k_ok:
    cmp bx, VSCROLL_MAX
    jg short .scroll_full
    cmp bx, -VSCROLL_MAX
    jl short .scroll_full
    mov [prev_nt_base], ax
%ifdef BENCH
    inc word [bench_hw_steps]
%endif
    mov ax, bx
    call .hw_vscroll_step
    jmp .scroll_unchanged
.scroll_full:
    mov [prev_scroll_x_cols], dl
    mov [prev_nt_base], ax
    call mark_all_dirty
.scroll_unchanged:
    ; Scan the screen row by row. Each visible row maps to at most two contiguous spans
    ; of dirty_grid (split at the horizontal nametable seam); clean cells are skipped
    ; with REPE SCASB instead of being tested one by one.
    push cs
    pop es                  ; ES = CS while scanning dirty_grid


    mov word [flush_span_fn], .scan_span
    cmp byte [full_redraw], 0
    je short .span_fn_ok
%ifdef BENCH
    inc word [bench_full_redraws]
%endif
    mov word [flush_span_fn], .dense_span   ; Everything is dirty: blit without checks
    cmp byte [invert_on], 0
    je short .span_fn_ok
    mov word [flush_span_fn], .dense_span_inv
.span_fn_ok:
    xor dx, dx              ; DX = screen cell index at start of row (0, 32, ..., 768)
.row_loop:
    mov al, [scroll_x_cols]
    mov bx, [active_nt_base]
    add bx, dx
    test al, al
    jz short .row_wrap
    cmp dx, 64
    jae short .row_wrap
    mov bx, dx              ; Top 2 HUD rows stay fixed at Nametable 0 rows 2..3
    add bx, 64
    xor al, al
    jmp short .row_base_ok
.row_wrap:
    cmp bx, 1920
    jb short .row_base_ok
    sub bx, 1920
.row_base_ok:
    mov [flush_rowbase], bx
    mov [flush_sx], al
    mov ah, al
    and ah, 31              ; AH = first column within its nametable

    ; Span 1: columns SX..end of that nametable row -> screen columns 0..(31-AH)
    mov si, bx
    mov cl, ah
    xor ch, ch
    add si, cx
    test al, 32
    jz short .s1_nt
    add si, 960
.s1_nt:
    cmp si, 1920
    jb short .s1_ok
    sub si, 1920
.s1_ok:
    mov [flush_cell], dx
    mov cx, 32
    sub cl, ah
    call [flush_span_fn]

    ; Span 2: columns 0..AH-1 of the other nametable -> screen columns (32-AH)..31
    mov al, [flush_sx]
    mov ah, al
    and ah, 31
    jz short .row_next
    mov si, [flush_rowbase]
    test al, 32
    jnz short .s2_nt
    add si, 960
.s2_nt:
    cmp si, 1920
    jb short .s2_ok
    sub si, 1920
.s2_ok:
    mov cl, ah
    xor ch, ch
    mov bx, dx
    add bx, 32
    sub bx, cx
    mov [flush_cell], bx
    call [flush_span_fn]

.row_next:
    add dx, 32
    cmp dx, 800
    jb .row_loop
    cmp byte [full_redraw], 0
    je short .no_grid_clear
    mov byte [full_redraw], 0
    lea di, [dirty_grid]    ; Dense pass skipped per-cell clears: clear the whole grid
    mov cx, 992
    xor ax, ax
    rep stosw
.no_grid_clear:
    mov word [dirty_count], 0

    pop dx
    pop cx
    pop bx
    pop bp
    pop di
    pop si
    pop es
    pop ds
    ret

; Input: SI = dirty_grid index of span start, CX = span length, [flush_cell] = screen
; cell of span start. Blits every dirty cell in the span. Preserves DX, BP.
.scan_span:
    jcxz .ss_ret
    lea di, [dirty_grid + si]
    mov [flush_span_di], di
.ss_loop:
    xor al, al
    repe scasb
    je short .ss_ret        ; Rest of span is clean
    mov byte [es:di - 1], 0
    push cx
    push di
    lea bx, [di - 1]
    mov ax, bx
    sub ax, [flush_span_di]
    add ax, [flush_cell]    ; AX = screen cell index
    sub bx, dirty_grid      ; BX = nametable index
    call .blit_cell
    pop di
    pop cx
    jcxz .ss_ret
    jmp short .ss_loop
.ss_ret:
    ret

; Same contract as .scan_span, for full redraws: blits every cell of the span.
; Runs with DS = nes_ram_seg and ES = CGA; restores DS = ES = CS.
.ds_empty:
    ret
.dense_span:
    jcxz .ds_empty
    push dx
    push bp
    add bp, 4000h           ; BP = pre-converted tile base in nes_ram_seg
    mov bx, si              ; BX = nametable index
    mov dx, [flush_cell]
    shl dx, 1               ; DX = cga_tile_offsets index
    mov es, [cs:cga_seg]
    mov ds, [cs:nes_ram_seg]
.ds_loop:
    mov al, [cs:vram_nametable + bx]
    xor ah, ah
    shl ax, 1
    shl ax, 1
    shl ax, 1
    shl ax, 1
    add ax, bp
    mov si, ax
    mov di, dx
    cmp si, [SCREEN_TILE + di]
    je short .ds_next       ; Cell already shows this tile
    mov [SCREEN_TILE + di], si
    mov di, [CGA_TILE_OFFSETS + di]
    add di, [cs:scr_origin]
    and di, 1FFFh
    cmp di, 8192 - 241
    jb short .ds_fast
    call cga_tile_wrapped   ; Tile straddles the end of the bank ring
    jmp .ds_next
.ds_fast:
    mov ax, [si]
    mov [es:di], ax
    mov ax, [si + 2]
    mov [es:di + 80], ax
    mov ax, [si + 4]
    mov [es:di + 160], ax
    mov ax, [si + 6]
    mov [es:di + 240], ax
    mov ax, [si + 8]
    mov [es:di + 2000h], ax
    mov ax, [si + 10]
    mov [es:di + 2000h + 80], ax
    mov ax, [si + 12]
    mov [es:di + 2000h + 160], ax
    mov ax, [si + 14]
    mov [es:di + 2000h + 240], ax
.ds_next:
    inc bx
    add dx, 2
    dec cx
    jz short .ds_done
    jmp .ds_loop
.ds_done:
    push cs
    pop ds
    push cs
    pop es
    pop bp
    pop dx
.ds_ret:
    ret

; Hardware horizontal scroll by AX = d columns (-HW_SCROLL_MAX..HW_SCROLL_MAX, not 0):
; moves the display origin by 2*d bytes, shifts the on-screen tile shadow with it, clears
; the strips that slid into the borders and draws the newly exposed columns and the fixed
; HUD rows. Runs with DS = CS, BP = pattern base; clobbers AX, BX, CX, SI, DI.
.hw_scroll_step:
    push dx
    push es
    mov [hw_d], ax
    shl ax, 1
    add ax, [scr_origin]
    and ax, 1FFFh
    mov [scr_origin], ax
    call cga_set_origin

    ; Shift the shadow: cell c now shows what cell c + d showed
    mov ax, [hw_d]
    call .shadow_shift

    ; Clear the border strips (|d| words wide) on every scanline of both banks
    mov ax, [hw_d]
    test ax, ax
    js short .hw_strips_left
    mov cx, ax              ; Content moved left: strip left of the playfield and at the
    mov bx, 8               ; far right edge
    sub bx, ax
    sub bx, ax
    call cga_clear_strip
    mov bx, 80
    sub bx, ax
    sub bx, ax
    call cga_clear_strip
    jmp short .hw_strips_done
.hw_strips_left:
    neg ax
    mov cx, ax              ; Content moved right: strip right of the playfield and at
    mov bx, 72              ; the far left edge
    call cga_clear_strip
    xor bx, bx
    call cga_clear_strip
.hw_strips_done:

    ; Draw the newly exposed columns (all rows; the HUD rows are redrawn below anyway)
    mov ax, [hw_d]
    xor bx, bx              ; BX = first new column
    mov cx, ax              ; CX = number of new columns
    test ax, ax
    js short .hw_cols_left
    mov bx, 32
    sub bx, ax
    jmp short .hw_cols_ok
.hw_cols_left:
    neg cx
.hw_cols_ok:
    mov [hw_col], bx
    mov [hw_ncols], cx
    mov word [hw_cell], 64  ; Rows 2..24 (rows 0..1 are the HUD, below)
.hw_col_row:
    mov cx, [hw_ncols]
    mov ax, [hw_cell]
    add ax, [hw_col]
.hw_col_cell:
    push cx
    push ax
    call .force_cell
    pop ax
    pop cx
    inc ax
    loop .hw_col_cell
    add word [hw_cell], 32
    cmp word [hw_cell], 800
    jb .hw_col_row

    ; The HUD rows are fixed on the NES but moved with the CGA origin: redraw them
    xor ax, ax
.hw_hud:
    push ax
    call .force_cell
    pop ax
    inc ax
    cmp ax, 64
    jb .hw_hud

    pop es
    pop dx
    ret

; Shifts the on-screen tile shadow so cell c takes the entry of cell c + AX (AX signed,
; |AX| < 800). Entries shifted in from outside are stale and must be repainted by the
; caller. Preserves DS; clobbers AX, CX, SI, DI, ES.
.shadow_shift:
    push ds
    mov es, [cs:nes_ram_seg]
    mov ds, [cs:nes_ram_seg]
    test ax, ax
    js short .ss_right
    mov cx, 800
    sub cx, ax
    shl ax, 1
    mov si, SCREEN_TILE
    add si, ax
    mov di, SCREEN_TILE
    cld
    rep movsw
    jmp short .ss_done
.ss_right:
    neg ax
    mov cx, 800
    sub cx, ax
    shl ax, 1
    mov di, SCREEN_TILE + 2 * 799
    mov si, di
    sub si, ax
    std
    rep movsw
    cld
.ss_done:
    pop ds
    ret

; Hardware vertical scroll by AX = k tile rows (-VSCROLL_MAX..VSCROLL_MAX, not 0): moves
; the display origin by k * 320 bytes (4 scanlines per bank per tile row), shifts the
; shadow by 32 * k cells, blanks the newly exposed scanlines and draws the new rows.
; Runs with DS = CS, BP = pattern base; clobbers AX, BX, CX, SI, DI.
.hw_vscroll_step:
    push dx
    push es
    mov [hw_d], ax
    mov bx, ax
    mov cl, 8
    shl bx, cl              ; k * 256
    mov cl, 6
    shl ax, cl              ; k * 64
    add ax, bx              ; k * 320
    add ax, [scr_origin]
    and ax, 1FFFh
    mov [scr_origin], ax
    call cga_set_origin

    mov ax, [hw_d]
    mov cl, 5
    shl ax, cl              ; 32 * k cells
    call .shadow_shift

    ; New rows: bottom k rows when scrolling down, top |k| rows when scrolling up
    mov ax, [hw_d]
    test ax, ax
    js short .vs_up
    mov bx, 25
    sub bx, ax              ; First new row
    mov cx, ax
    jmp short .vs_rows
.vs_up:
    xor bx, bx
    mov cx, ax
    neg cx
.vs_rows:
    mov [hw_col], bx        ; (reused) first new row
    mov [hw_ncols], cx      ; (reused) number of new rows
    ; Blank their scanlines first: they hold whatever scrolled off or was off-screen
    shl bx, 1
    shl bx, 1               ; First line (4 lines per tile row in each bank)
    shl cx, 1
    shl cx, 1
    call cga_clear_lines
    ; Draw the 32 cells of each new row
    mov ax, [hw_col]
    mov cl, 5
    shl ax, cl              ; First cell
    mov cx, [hw_ncols]
    shl cx, cl              ; Number of cells
.vs_cell:
    push cx
    push ax
    call .force_cell
    pop ax
    pop cx
    inc ax
    loop .vs_cell

    pop es
    pop dx
    ret

; Repaints screen cell AX unconditionally (DS = CS on entry and exit, BP = pattern base)
.force_cell:
    push ds
    mov ds, [cs:nes_ram_seg]
    mov di, ax
    shl di, 1
    mov word [SCREEN_TILE + di], 0FFFFh
    pop ds
    call .cell_to_nt
    jmp .blit_cell

; Maps screen cell AX (0..799) to its dirty_grid/vram_nametable index in BX, using the
; same layout as the row scan. Preserves all other registers. Needs DS = CS.
.cell_to_nt:
    push cx
    push dx
    mov bx, ax
    and bx, 31              ; BX = screen column
    mov dx, ax
    and dx, 03E0h           ; DX = screen row * 32
    mov cl, [scroll_x_cols]
    test cl, cl
    jz short .cn_scrolled
    cmp dx, 64
    jae short .cn_scrolled
    add bx, dx              ; Top 2 HUD rows stay fixed at Nametable 0 rows 2..3
    add bx, 64
    pop dx
    pop cx
    ret
.cn_scrolled:
    add dx, [active_nt_base]
    cmp dx, 1920
    jb short .cn_row_ok
    sub dx, 1920
.cn_row_ok:
    add bl, cl
    and bl, 63
    cmp bl, 32
    jb short .cn_nt0
    add bx, 928
.cn_nt0:
    add bx, dx
    cmp bx, 1920
    jb short .cn_ok
    sub bx, 1920
.cn_ok:
    pop dx
    pop cx
    ret

; Inverted-colours variant of .dense_span (see toggle in apply_invert_request)
.dense_span_inv:
    test cx, cx
    jnz short .ds_go_inv
    ret
.ds_go_inv:
    push dx
    push bp
    add bp, 4000h           ; BP = pre-converted tile base in nes_ram_seg
    mov bx, si              ; BX = nametable index
    mov dx, [flush_cell]
    shl dx, 1               ; DX = cga_tile_offsets index
    mov es, [cs:cga_seg]
    mov ds, [cs:nes_ram_seg]
.ds_loop_inv:
    mov al, [cs:vram_nametable + bx]
    xor ah, ah
    shl ax, 1
    shl ax, 1
    shl ax, 1
    shl ax, 1
    add ax, bp
    mov si, ax
    mov di, dx
    cmp si, [SCREEN_TILE + di]
    je short .ds_next_inv       ; Cell already shows this tile
    mov [SCREEN_TILE + di], si
    mov di, [CGA_TILE_OFFSETS + di]
    add di, [cs:scr_origin]
    and di, 1FFFh
    cmp di, 8192 - 241
    jb short .ds_fast_inv
    call cga_tile_wrapped   ; Tile straddles the end of the bank ring
    jmp .ds_next_inv
.ds_fast_inv:
    mov ax, [si]
    not ax
    mov [es:di], ax
    mov ax, [si + 2]
    not ax
    mov [es:di + 80], ax
    mov ax, [si + 4]
    not ax
    mov [es:di + 160], ax
    mov ax, [si + 6]
    not ax
    mov [es:di + 240], ax
    mov ax, [si + 8]
    not ax
    mov [es:di + 2000h], ax
    mov ax, [si + 10]
    not ax
    mov [es:di + 2000h + 80], ax
    mov ax, [si + 12]
    not ax
    mov [es:di + 2000h + 160], ax
    mov ax, [si + 14]
    not ax
    mov [es:di + 2000h + 240], ax
.ds_next_inv:
    inc bx
    add dx, 2
    dec cx
    jz short .ds_done_inv
    jmp .ds_loop_inv
.ds_done_inv:
    push cs
    pop ds
    push cs
    pop es
    pop bp
    pop dx
.ds_ret_inv:
    ret

; Inverted-colours tail of .blit_cell
.bc_inverted:
    mov ax, [si]
    not ax
    mov [es:di], ax
    mov ax, [si + 2]
    not ax
    mov [es:di + 80], ax
    mov ax, [si + 4]
    not ax
    mov [es:di + 160], ax
    mov ax, [si + 6]
    not ax
    mov [es:di + 240], ax
    mov ax, [si + 8]
    not ax
    mov [es:di + 2000h], ax
    mov ax, [si + 10]
    not ax
    mov [es:di + 2000h + 80], ax
    mov ax, [si + 12]
    not ax
    mov [es:di + 2000h + 160], ax
    mov ax, [si + 14]
    not ax
    mov [es:di + 2000h + 240], ax
    jmp .bc_written

; Input: BX = nametable index, AX = screen cell index, BP = pattern table base.
; Clobbers AX, CX, SI, DI. Returns with DS = ES = CS.
.blit_cell:
    mov di, ax
    shl di, 1
    mov al, [vram_nametable + bx]
    xor ah, ah
    mov cl, 4
    shl ax, cl
    add ax, bp
    add ax, 4000h
    mov si, ax
    mov ds, [cs:nes_ram_seg]
    cmp si, [SCREEN_TILE + di]
    je short .bc_same       ; Cell already shows this tile
    mov [SCREEN_TILE + di], si
    mov di, [CGA_TILE_OFFSETS + di]
    mov es, [cs:cga_seg]
    add di, [cs:scr_origin]
    and di, 1FFFh
    cmp di, 8192 - 241
    jb short .bc_fast
    call cga_tile_wrapped   ; Tile straddles the end of the bank ring
    jmp .bc_written
.bc_fast:
    cmp byte [cs:invert_on], 0
    je short .bc_normal
    jmp .bc_inverted
.bc_normal:
    mov ax, [si]
    mov [es:di], ax
    mov ax, [si + 2]
    mov [es:di + 80], ax
    mov ax, [si + 4]
    mov [es:di + 160], ax
    mov ax, [si + 6]
    mov [es:di + 240], ax
    mov ax, [si + 8]
    mov [es:di + 2000h], ax
    mov ax, [si + 10]
    mov [es:di + 2000h + 80], ax
    mov ax, [si + 12]
    mov [es:di + 2000h + 160], ax
    mov ax, [si + 14]
    mov [es:di + 2000h + 240], ax
.bc_written:
    push cs
    pop es
.bc_same:
    push cs
    pop ds
    ret

; ------------------------------------------------------------------------------
; SPRITE RENDERER (CGA MODE 4)
; ------------------------------------------------------------------------------
draw_sprites:
    test byte [cs:ppu_mask], 10h
    jnz short .do_sprites
    ret
.do_sprites:
    push ds
    push es
    push si
    push di
    push bp
    push bx
    push cx
    push dx

    mov es, [cs:cga_seg]
    push cs
    pop ds

    ; Pick the sprite blitters for the current colour mode
    mov word [spr_blit_spr_8x8_fn], .blit_spr_8x8
    mov word [spr_blit_spr_8x8_vflip_fn], .blit_spr_8x8_vflip
    cmp byte [invert_on], 0
    je short .spr_fns_ok
    mov word [spr_blit_spr_8x8_fn], .blit_spr_8x8_inv
    mov word [spr_blit_spr_8x8_vflip_fn], .blit_spr_8x8_vflip_inv
.spr_fns_ok:

    xor bp, bp
    test byte [ppu_ctrl], 08h
    jz short .spr_pat_0
    mov bp, 4096
.spr_pat_0:

    mov cx, 63

.spr_loop:
    mov bx, cx
    shl bx, 1
    shl bx, 1               ; BX = sprite_index * 4 (preserved across loop!)

    mov al, [oam_ram + bx]
    test byte [ppu_ctrl], 20h
    jnz short .spr_y_8x16
    inc al
.spr_y_8x16:
    cmp al, [y_nes_min]
    jb .spr_next
    mov ah, [y_nes_min]
    add ah, 192
    cmp al, ah
    ja .spr_next

    mov dh, al              ; DH = y_nes
    mov [spr_y_save], al
    mov dl, [oam_ram + bx + 3] ; DL = x_nes (0..255)
    cmp dl, 248
    ja .spr_next


    ; Compute SI = pre-converted CGA tile address in nes_ram_seg:4000h (or 6000h if H-flipped)
    mov al, [oam_ram + bx + 1]
    test byte [ppu_ctrl], 20h
    jz short .spr_calc_si
    xor bp, bp
    test al, 1
    jz short .spr_8x16_b0
    mov bp, 4096
.spr_8x16_b0:
    and al, 0FEh
.spr_calc_si:
    xor ah, ah
    shl ax, 1
    shl ax, 1
    shl ax, 1
    shl ax, 1
    add ax, bp
    add ax, 4000h
    test byte [oam_ram + bx + 2], 40h
    jz short .spr_no_hflip
    add ax, 2000h
.spr_no_hflip:
    mov si, ax

    ; Compute DI = CGA even-bank offset: ((y_nes - y_nes_min) >> 1) * 80 + (x_nes >> 2) + 8
    mov al, dh
    sub al, [y_nes_min]
    and al, 0FEh            ; (y >> 1) * 2 = word index into mul80_table
    xor ah, ah
    mov di, ax
    mov di, [mul80_table + di]
    shr dl, 1
    shr dl, 1
    add dl, 8
    xor dh, dh
    add di, dx

    mov ds, [cs:nes_ram_seg]
    test byte [cs:oam_ram + bx + 2], 80h
    jnz short .spr_vflip
    call save_block
    call [cs:spr_blit_spr_8x8_fn]
    test byte [cs:ppu_ctrl], 20h
    jz short .spr_next
    add si, 16
    add di, 320
    cmp di, 7760
    jae short .spr_next
    call save_block
    call [cs:spr_blit_spr_8x8_fn]
    jmp short .spr_next

.spr_vflip:
    test byte [cs:ppu_ctrl], 20h
    jz short .spr_vflip_8x8
    add si, 16
    call save_block
    call [cs:spr_blit_spr_8x8_vflip_fn]
    sub si, 16
    add di, 320
    cmp di, 7760
    jae short .spr_next
.spr_vflip_8x8:
    call save_block
    call [cs:spr_blit_spr_8x8_vflip_fn]

.spr_next:
    push cs
    pop ds
    dec cx
    jns .spr_loop

    pop dx
    pop cx
    pop bx
    pop bp
    pop di
    pop si
    pop es
    pop ds
    ret

.blit_spr_8x8:
    push di
    add di, [cs:scr_origin]
    and di, 1FFFh
    cmp di, 8192 - 242
    jb short .blit_spr_8x8_go
    push bx
    mov bx, spr_order_normal
    call spr_wrapped        ; Sprite straddles the end of the bank ring
    pop bx
    pop di
    ret
.blit_spr_8x8_go:
    mov ax, [si]
    or  ax, ax
    jz short .s_row1
    or  [es:di], ax
.s_row1:
    mov ax, [si + 8]
    or  ax, ax
    jz short .s_row2
    or  [es:di + 2000h], ax
.s_row2:
    mov ax, [si + 2]
    or  ax, ax
    jz short .s_row3
    or  [es:di + 80], ax
.s_row3:
    mov ax, [si + 10]
    or  ax, ax
    jz short .s_row4
    or  [es:di + 2000h + 80], ax
.s_row4:
    mov ax, [si + 4]
    or  ax, ax
    jz short .s_row5
    or  [es:di + 160], ax
.s_row5:
    mov ax, [si + 12]
    or  ax, ax
    jz short .s_row6
    or  [es:di + 2000h + 160], ax
.s_row6:
    mov ax, [si + 6]
    or  ax, ax
    jz short .s_row7
    or  [es:di + 240], ax
.s_row7:
    mov ax, [si + 14]
    or  ax, ax
    jz short .s_row8
    or  [es:di + 2000h + 240], ax
.s_row8:
    pop di
    ret

.blit_spr_8x8_vflip:
    push di
    add di, [cs:scr_origin]
    and di, 1FFFh
    cmp di, 8192 - 242
    jb short .blit_spr_8x8_vflip_go
    push bx
    mov bx, spr_order_vflip
    call spr_wrapped        ; Sprite straddles the end of the bank ring
    pop bx
    pop di
    ret
.blit_spr_8x8_vflip_go:
    mov ax, [si + 14]
    or  ax, ax
    jz short .sv_row1
    or  [es:di], ax
.sv_row1:
    mov ax, [si + 6]
    or  ax, ax
    jz short .sv_row2
    or  [es:di + 2000h], ax
.sv_row2:
    mov ax, [si + 12]
    or  ax, ax
    jz short .sv_row3
    or  [es:di + 80], ax
.sv_row3:
    mov ax, [si + 4]
    or  ax, ax
    jz short .sv_row4
    or  [es:di + 2000h + 80], ax
.sv_row4:
    mov ax, [si + 10]
    or  ax, ax
    jz short .sv_row5
    or  [es:di + 160], ax
.sv_row5:
    mov ax, [si + 2]
    or  ax, ax
    jz short .sv_row6
    or  [es:di + 2000h + 160], ax
.sv_row6:
    mov ax, [si + 8]
    or  ax, ax
    jz short .sv_row7
    or  [es:di + 240], ax
.sv_row7:
    mov ax, [si]
    or  ax, ax
    jz short .sv_row8
    or  [es:di + 2000h + 240], ax
.sv_row8:
    pop di
    ret

; Inverted-colours variants
.blit_spr_8x8_inv:
    push di
    add di, [cs:scr_origin]
    and di, 1FFFh
    cmp di, 8192 - 242
    jb short .blit_spr_8x8_inv_go
    push bx
    mov bx, spr_order_normal
    call spr_wrapped        ; Sprite straddles the end of the bank ring
    pop bx
    pop di
    ret
.blit_spr_8x8_inv_go:
    mov ax, [si]
    or  ax, ax
    jz short .s_row1_inv
    not ax
    and [es:di], ax
.s_row1_inv:
    mov ax, [si + 8]
    or  ax, ax
    jz short .s_row2_inv
    not ax
    and [es:di + 2000h], ax
.s_row2_inv:
    mov ax, [si + 2]
    or  ax, ax
    jz short .s_row3_inv
    not ax
    and [es:di + 80], ax
.s_row3_inv:
    mov ax, [si + 10]
    or  ax, ax
    jz short .s_row4_inv
    not ax
    and [es:di + 2000h + 80], ax
.s_row4_inv:
    mov ax, [si + 4]
    or  ax, ax
    jz short .s_row5_inv
    not ax
    and [es:di + 160], ax
.s_row5_inv:
    mov ax, [si + 12]
    or  ax, ax
    jz short .s_row6_inv
    not ax
    and [es:di + 2000h + 160], ax
.s_row6_inv:
    mov ax, [si + 6]
    or  ax, ax
    jz short .s_row7_inv
    not ax
    and [es:di + 240], ax
.s_row7_inv:
    mov ax, [si + 14]
    or  ax, ax
    jz short .s_row8_inv
    not ax
    and [es:di + 2000h + 240], ax
.s_row8_inv:
    pop di
    ret

.blit_spr_8x8_vflip_inv:
    push di
    add di, [cs:scr_origin]
    and di, 1FFFh
    cmp di, 8192 - 242
    jb short .blit_spr_8x8_vflip_inv_go
    push bx
    mov bx, spr_order_vflip
    call spr_wrapped        ; Sprite straddles the end of the bank ring
    pop bx
    pop di
    ret
.blit_spr_8x8_vflip_inv_go:
    mov ax, [si + 14]
    or  ax, ax
    jz short .sv_row1_inv
    not ax
    and [es:di], ax
.sv_row1_inv:
    mov ax, [si + 6]
    or  ax, ax
    jz short .sv_row2_inv
    not ax
    and [es:di + 2000h], ax
.sv_row2_inv:
    mov ax, [si + 12]
    or  ax, ax
    jz short .sv_row3_inv
    not ax
    and [es:di + 80], ax
.sv_row3_inv:
    mov ax, [si + 4]
    or  ax, ax
    jz short .sv_row4_inv
    not ax
    and [es:di + 2000h + 80], ax
.sv_row4_inv:
    mov ax, [si + 10]
    or  ax, ax
    jz short .sv_row5_inv
    not ax
    and [es:di + 160], ax
.sv_row5_inv:
    mov ax, [si + 2]
    or  ax, ax
    jz short .sv_row6_inv
    not ax
    and [es:di + 2000h + 160], ax
.sv_row6_inv:
    mov ax, [si + 8]
    or  ax, ax
    jz short .sv_row7_inv
    not ax
    and [es:di + 240], ax
.sv_row7_inv:
    mov ax, [si]
    or  ax, ax
    jz short .sv_row8_inv
    not ax
    and [es:di + 2000h + 240], ax
.sv_row8_inv:
    pop di
    ret

; ------------------------------------------------------------------------------
; FRAMESKIP HUD INDICATOR (Top-Left Border: 'F1'..'F9' using BIOS 8x8 ROM Font)
; ------------------------------------------------------------------------------
draw_fskip_hud:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push ds
    push es
    cld

    mov es, [cs:cga_seg]
    mov ax, 0F000h
    mov ds, ax

    mov al, 'F'
    mov di, [cs:scr_origin]
    call .draw_char

    mov al, [cs:frameskip_max]
    add al, '0'
    mov di, [cs:scr_origin]
    add di, 2
    and di, 1FFFh
    call .draw_char

    pop es
    pop ds
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

.draw_char:
    xor ah, ah
    shl ax, 1
    shl ax, 1
    shl ax, 1
    add ax, 0FA6Eh
    mov si, ax
    mov cl, 4
.row_pair:
    lodsb
    call .expand_byte
    mov [es:di], ax
    lodsb
    call .expand_byte
    mov [es:di + 2000h], ax
    add di, 80
    and di, 1FFFh
    dec cl
    jnz short .row_pair
    ret

.expand_byte:
    mov dl, al
    xor ax, ax
    mov ch, 8
.pix:
    shl ax, 1
    shl ax, 1
    shl dl, 1
    jnc short .p0
    or al, 3
.p0:
    dec ch
    jnz short .pix
    xchg al, ah
    xor ax, [cs:invert_word]
    ret

clear_fskip_hud:
    push ax
    push cx
    push di
    push es
    mov es, [cs:cga_seg]
    mov ax, [cs:invert_word]    ; Background colour 0 (or 3 when inverted)
    push bx
    mov bx, [cs:scr_origin]
    mov cx, 4
.clr_loop:
    mov di, bx
    and di, 1FFFh
    mov [es:di], ax
    mov [es:di + 2000h], ax
    lea di, [bx + 2]
    and di, 1FFFh
    mov [es:di], ax
    mov [es:di + 2000h], ax
    add bx, 80
    loop .clr_loop
    pop bx
    pop es
    pop di
    pop cx
    pop ax
    ret

; ------------------------------------------------------------------------------
; RUNTIME DATA & BUFFERS
; ------------------------------------------------------------------------------
section .data
cga_seg:            dw 0B800h
nes_ram_seg:        dw 0
xlate_seg:          dw 0
old_int08_off:      dw 0
old_int08_seg:      dw 0
old_int09_off:      dw 0
old_int09_seg:      dw 0

tick_60hz:          db 0
tick_total:         dw 0
pending_ticks:      db 0
hud_timer:          db 0
frame_div:          db 0
mul80_table:        ; row * 80 for the 100 CGA even-bank rows (sprite placement, no MUL)
%assign r 0
%rep 100
                    dw r * 80
%assign r r + 1
%endrep
frameskip_max:      db 3       ; Minimum ticks per render (keys 1-9)
frameskip_cur:      db 3       ; Current (adaptive) ticks per render
ticks_dropped:      db 0
nmi_pending:        db 0       ; A tick was dropped while busy: run its NMI on completion
catchup_left:       db 0
NMI_CATCHUP_MAX     equ 1      ; Extra back-to-back NMIs allowed per tick (0 = off)
skip_calm:          db 0
FRAMESKIP_LIMIT     equ 8
FRAMESKIP_CALM      equ 4
exit_requested:     db 0
in_timer_isr:       db 0
dispatch_target:    dw 0

rom_filename:       db 'GAME.CHR', 0
dump_filename:      db 'DUMP.BIN', 0

indirect_jump_count: dw 0
indirect_jump_table: dw 0

key_state:          db 0
joy_shift:          db 0

ppu_ctrl:           db 0
nmi_holdoff:        db 0
ppu_mask:           db 0
ppu_status:         db 0
oam_addr:           db 0
ppu_scroll_x:       db 0
ppu_scroll_y:       db 0
ppu_addr_lo:        db 0       ; PPU address (word: lo, hi)
ppu_addr_hi:        db 0
ppu_inc:            dw 1       ; $2007 address increment: 1 or 32 ($2000 bit 2)
ppu_latch:          db 0
ppu_read_buf:       db 0

dirty_count:        dw 800
active_nt_base:     dw 64
prev_nt_base:       dw 64
scroll_x_cols:      db 0
prev_scroll_x_cols: db 0
flush_rowbase:      dw 0
flush_cell:         dw 0
flush_span_di:      dw 0
flush_sx:           db 0
flush_span_fn:      dw 0
full_redraw:        db 1
save_seg:           dw 0       ; Sprite save-under buffer segment
save_count:         dw 0       ; Saved 8-line blocks (restored on the next render)
SAVE_MAX            equ 128    ; 64 sprites x 2 halves (8x16)
prev_ctrl_bits:     db 0       ; PPUCTRL bits 4-5 used by the last render
scr_origin:         dw 0       ; CGA display origin in bytes (hardware horizontal scroll)
hw_d:               dw 0
hw_col:             dw 0
hw_ncols:           dw 0
hw_cell:            dw 0
HW_SCROLL_MAX       equ 4      ; Larger column jumps fall back to a full redraw
VSCROLL_MAX         equ 12     ; Larger row jumps fall back to a full redraw (0 = off)
invert_on:          db 0       ; Inverted colours active (colour c drawn as 3 - c)
invert_request:     db 0       ; Toggle requested (I key / --invert), applied by INT 08h
invert_word:        dw 0       ; 0FFFFh when inverted: XOR mask for colour-0 fills
spr_blit_spr_8x8_fn:       dw 0
spr_blit_spr_8x8_vflip_fn: dw 0
spr_y_save:         db 0
y_nes_min:          db 16

sound_enabled:      db 1
test_mode:          db 0
apu_len_p1:         db 0
apu_len_p2:         db 0
apu_len_tri:        db 0
apu_len_noi:        db 0
apu_sfx_prio:       db 0
apu_last_period:    dw 0
apu_regs:           times 21 db 0
                    db 0Fh          ; $4015 default channel enable mask
apu_len_table:      db 6, 90, 12, 6, 24, 6, 48, 6, 96, 8, 36, 10, 14, 12, 16, 14
                    db 12, 16, 24, 18, 48, 20, 96, 22, 96, 24, 36, 26, 16, 28, 32, 30

msg_banner:         db 'NES88 AOT Virtualizer (Intel 8088 / CGA Mode 4)', 13, 10
                    db 'Decoupled 60Hz Logic / 20FPS Dirty-Tile Video', 13, 10, '$'
msg_shutdown:       db 'EXIT: runtime_shutdown was called!', 13, 10, '$'
msg_mem_err:        db 'Error: Out of memory (need 192KB conventional RAM)!', 13, 10, '$'

section .bss
align 2
vram_nametable:     resb 1984
dirty_grid:         resb 1984
palette_ram:        resb 32
oam_ram:            resb 256
