; ==============================================================================
; CGA_RUNTIME.ASM - Native x86 CGA Mode 4 Virtualization & HLE Engine
; Target: Intel 8088 / IBM PC / Toshiba T1000 (MS-DOS)
; ==============================================================================

section .text

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
    push cs
    pop es
    lea di, [cga_tile_offsets]
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
    mov al, 36h             ; Channel 0, lobyte/hibyte, mode 3
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

    ; Mark all nametable tiles as dirty
    push cs
    pop es
    lea di, [dirty_grid]
    mov cx, 1984
    mov al, 1
    rep stosb
    mov word [cs:dirty_count], 800

    ; Parse DOS command-line tail at CS:80h
    ; - "--nosound" / "-nosound" / "/nosound": disable PC speaker output & overhead
    ; - "T": run 240-tick automated test & dump VRAM to <GAME>.DMP
    mov cl, [cs:80h]
    xor ch, ch
    jcxz .cmd_done
    mov si, 81h
.cmd_scan:
    mov al, [cs:si]
    cmp al, ' '
    je short .cmd_next
    cmp al, '-'
    je short .cmd_nosound
    cmp al, '/'
    je short .cmd_nosound
    cmp al, 'T'
    je short .cmd_test
    cmp al, 't'
    je short .cmd_test
    jmp short .cmd_next
.cmd_nosound:
    mov byte [cs:sound_enabled], 0
    jmp short .cmd_done
.cmd_test:
    mov byte [cs:test_mode], 1
.cmd_next:
    inc si
    loop .cmd_scan
.cmd_done:

    ret

runtime_shutdown:
    cli
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
.no_dump:

    ; Switch back to 80x25 text mode (Mode 3)
    mov ax, 0003h
    int 10h

    push cs
    pop ds
    mov ah, 09h
    lea dx, [msg_shutdown]
    int 21h

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

    ; Expire temporary frameskip HUD after 1 second (60 ticks)
    cmp byte [ hud_timer ], 0
    je short .no_hud_expire
    dec byte [ hud_timer ]
    jnz short .no_hud_expire
    call clear_fskip_hud
.no_hud_expire:

    ; Re-entrancy guard for video flush & NMI dispatch
    cmp byte [ in_timer_isr ], 0
    jne .skip_isr
    mov byte [ in_timer_isr ], 1
    sti

    ; Update PC Speaker APU synthesis at 60Hz (no-op if --nosound)
    call apu_update_60hz

    ; Flush dirty background tiles and draw sprites every [frameskip_max] ticks
    inc byte [ frame_div ]
    mov al, [ frame_div ]
    cmp al, [ frameskip_max ]
    jb short .no_vflush
    mov byte [ frame_div ], 0
    call flush_dirty_tiles
    call draw_sprites
    cmp byte [ cs:test_mode ], 0
    je short .no_vflush
    cmp word [ cs:tick_total ], 240
    jae .auto_exit
.no_vflush:

    ; Execute NMI if enabled by 6502 code ($2000 bit 7)
    test byte [ ppu_ctrl ], 80h
    jz short .nmi_done

    mov bp, sp
    mov ax, [ bp + 16 ]
    mov bx, [ bp + 14 ]
    mov di, [ bp + 6 ]
    mov ds, [ cs:nes_ram_seg ]
    mov es, [ cs:xlate_seg ]
    xor dh, dh
    call nmi_vector_dispatch

.nmi_done:
    cli
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

; Input: DL = zp offset. Output: SI = (DL + BL) & 0FFh. Preserves ALL flags!
ea_zpx:
    push ax
    lahf
    add dl, bl
    xor dh, dh
    mov si, dx
    sahf
    pop ax
    ret

; Input: DL = zp offset. Output: SI = (DL + BH) & 0FFh. Preserves ALL flags!
ea_zpy:
    push ax
    lahf
    add dl, bh
    xor dh, dh
    mov si, dx
    sahf
    pop ax
    ret

; Input: DL = zp offset. Output: SI = word [(DL + BL) & 0FFh]. Preserves ALL flags!
ea_izx:
    push ax
    lahf
    add dl, bl
    xor dh, dh
    mov si, dx
    mov si, [si]
    sahf
    pop ax
    ret

; Input: SI = word [zp]. Output: SI = SI + BH. Preserves ALL flags!
ea_izy:
    push ax
    lahf
    mov dl, bh
    xor dh, dh
    add si, dx
    sahf
    pop ax
    ret

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
    mov byte [frame_div], 0
    mov byte [hud_timer], 60
    call draw_fskip_hud
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
    test ah, 33h            ; Did BG/Spr mode or H/V nametable bits change?
    jz short .w2000_done
    call mark_all_dirty
.w2000_done:
    pop ax
    popf
    ret

hle_write_2001:
    pushf
    push ax
    mov ah, [cs:ppu_mask]
    mov [cs:ppu_mask], al
    xor ah, al
    test ah, 08h            ; Did BG enable bit change?
    jz short .w2001_done
    call mark_all_dirty
.w2001_done:
    pop ax
    popf
    ret

mark_all_dirty:
    push es
    push di
    push cx
    push ax
    push cs
    pop es
    lea di, [dirty_grid]
    mov cx, 992
    mov ax, 0101h
    rep stosw
    mov word [cs:dirty_count], 800
    pop ax
    pop cx
    pop di
    pop es
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
    push ax
    push bx
    mov bh, [cs:ppu_addr_hi]
    mov bl, [cs:ppu_addr_lo]
    and bh, 3Fh

    cmp bx, 3F00h
    jae short .write_pal

    cmp bx, 2000h
    jb short .advance_addr

.write_nt:
    push dx
    mov dh, bh
    and bx, 03FFh
    cmp bx, 960
    jae short .nt_skip_attr
    test dh, 0Ch
    jz short .nt_w0
    add bx, 960
.nt_w0:
    mov [cs:vram_nametable + bx], al
    mov byte [cs:dirty_grid + bx], 1
    inc word [cs:dirty_count]
.nt_skip_attr:
    pop dx
    jmp short .advance_addr

.write_pal:
    and bx, 1Fh
    mov [cs:palette_ram + bx], al

.advance_addr:
    test byte [cs:ppu_ctrl], 04h
    jnz short .inc_32
    inc byte [cs:ppu_addr_lo]
    jnz short .w_done
    inc byte [cs:ppu_addr_hi]
.w_done:
    pop bx
    pop ax
    popf
    ret
.inc_32:
    add byte [cs:ppu_addr_lo], 32
    adc byte [cs:ppu_addr_hi], 0
    pop bx
    pop ax
    popf
    ret

hle_read_2007:
    pushf
    push bx
    push dx
    mov bh, [cs:ppu_addr_hi]
    mov bl, [cs:ppu_addr_lo]
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
    test byte [cs:ppu_ctrl], 04h
    jnz short .r_inc_32
    inc byte [cs:ppu_addr_lo]
    jnz short .r_done
    inc byte [cs:ppu_addr_hi]
.r_done:
    pop dx
    pop bx
    popf
    ret
.r_inc_32:
    add byte [cs:ppu_addr_lo], 32
    adc byte [cs:ppu_addr_hi], 0
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
    cmp bl, 0
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

; STA ($xx),Y helper (SI = word [zp], BH = Y, AL = value)
hle_sta_izy:
    pushf
    mov dl, bh
    xor dh, dh
    add si, dx
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
    je short .scroll_unchanged
.scroll_changed:
    mov [prev_scroll_x_cols], dl
    mov [prev_nt_base], ax
    call mark_all_dirty
.scroll_unchanged:

    mov bx, [active_nt_base]
    xor cx, cx              ; 800 visible tiles (25 rows x 32 cols)

.tile_scan_loop:
    cmp byte [scroll_x_cols], 0
    je short .check_dirty
    cmp cx, 64
    jae short .calc_hscroll_bx
    mov bx, cx
    add bx, 64              ; Keep top 2 HUD rows fixed at Nametable 0 rows 2..3
    jmp short .check_dirty
.calc_hscroll_bx:
    mov ax, cx
    and ax, 03E0h
    add ax, [active_nt_base]
    mov dl, cl
    and dl, 31
    add dl, [scroll_x_cols]
    and dl, 63
    xor dh, dh
    cmp dl, 32
    jb short .h_nt0
    add dx, 928             ; 960 - 32 for second nametable
.h_nt0:
    add ax, dx
    mov bx, ax

.check_dirty:
    cmp byte [dirty_grid + bx], 0
    jz short .next_tile

    mov byte [dirty_grid + bx], 0

    mov al, [vram_nametable + bx]
    xor ah, ah
    shl ax, 1
    shl ax, 1
    shl ax, 1
    shl ax, 1
    add ax, bp
    add ax, 4000h
    mov si, ax

    mov di, cx
    shl di, 1
    mov di, [cga_tile_offsets + di]

    mov ds, [cs:nes_ram_seg]
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
    push cs
    pop ds

.next_tile:
    inc bx
    cmp bx, 1920
    jb short .bx_ok
    xor bx, bx
.bx_ok:
    inc cx
    cmp cx, 800
    jb .tile_scan_loop

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
    mov dl, [oam_ram + bx + 3] ; DL = x_nes (0..255)
    cmp dl, 248
    ja .spr_next

    ; Mark underlying background tiles dirty for next frame
    push bx
    mov al, dh
    sub al, [y_nes_min]
    shr al, 1
    shr al, 1
    shr al, 1               ; AL = visible_row (0..24)
    xor ah, ah
    shl ax, 1
    shl ax, 1
    shl ax, 1
    shl ax, 1
    shl ax, 1               ; AX = visible_row * 32
    add ax, [active_nt_base]
    mov bl, dl
    shr bl, 1
    shr bl, 1
    shr bl, 1               ; BL = nt_col (0..31)
    add bl, [scroll_x_cols]
    and bl, 63
    mov bh, bl
    and bh, 31
    cmp bh, 31
    jne short .spr_no_seam
    call mark_all_dirty
.spr_no_seam:
    xor bh, bh
    cmp bl, 32
    jb short .spr_h_nt0
    add bx, 928
.spr_h_nt0:
    add bx, ax              ; BX = nametable index
    cmp bx, 1920
    jb short .spr_dirty_ok
    sub bx, 1920
.spr_dirty_ok:
    mov byte [dirty_grid + bx], 1
    mov byte [dirty_grid + bx + 1], 1
    mov byte [dirty_grid + bx + 32], 1
    mov byte [dirty_grid + bx + 33], 1
    mov byte [dirty_grid + bx + 64], 1
    mov byte [dirty_grid + bx + 65], 1
    add word [dirty_count], 6
    pop bx

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
    shr al, 1
    mov ah, 80
    mul ah
    shr dl, 1
    shr dl, 1
    add dl, 8
    xor dh, dh
    add ax, dx
    mov di, ax

    mov ds, [cs:nes_ram_seg]
    test byte [cs:oam_ram + bx + 2], 80h
    jnz short .spr_vflip
    call .blit_spr_8x8
    test byte [cs:ppu_ctrl], 20h
    jz short .spr_next
    add si, 16
    add di, 320
    cmp di, 7760
    jae short .spr_next
    call .blit_spr_8x8
    jmp short .spr_next

.spr_vflip:
    test byte [cs:ppu_ctrl], 20h
    jz short .spr_vflip_8x8
    add si, 16
    call .blit_spr_8x8_vflip
    sub si, 16
    add di, 320
    cmp di, 7760
    jae short .spr_next
.spr_vflip_8x8:
    call .blit_spr_8x8_vflip

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
    ret

.blit_spr_8x8_vflip:
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
    xor di, di
    call .draw_char

    mov al, [cs:frameskip_max]
    add al, '0'
    mov di, 2
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
    ret

clear_fskip_hud:
    push ax
    push cx
    push di
    push es
    mov es, [cs:cga_seg]
    xor ax, ax
    xor di, di
    mov cx, 4
.clr_loop:
    mov [es:di], ax
    mov [es:di + 2], ax
    mov [es:di + 2000h], ax
    mov [es:di + 2002h], ax
    add di, 80
    loop .clr_loop
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
frameskip_max:      db 3
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
ppu_mask:           db 0
ppu_status:         db 0
oam_addr:           db 0
ppu_scroll_x:       db 0
ppu_scroll_y:       db 0
ppu_addr_hi:        db 0
ppu_addr_lo:        db 0
ppu_latch:          db 0
ppu_read_buf:       db 0

dirty_count:        dw 800
active_nt_base:     dw 64
prev_nt_base:       dw 64
scroll_x_cols:      db 0
prev_scroll_x_cols: db 0
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
cga_tile_offsets:   resw 800
vram_nametable:     resb 1984
dirty_grid:         resb 1984
palette_ram:        resb 32
oam_ram:            resb 256
