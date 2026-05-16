; ============================================================================
; kernel.asm - RLVAL OS kernel (16-bit real mode, VESA VBE 640x480x256)
; Windows 10 themed UI with mouse support and window interaction.
; ============================================================================

[BITS 16]
[ORG 0x0000]

KERNEL_START:
    mov ax, cs
    mov ds, ax
    mov es, ax

    ; --- Initialize VESA VBE Mode 0x101 (640x480x256) ---
    mov ax, 0x4F02
    mov bx, 0x101
    int 0x10
    cmp ax, 0x004F
    jne vesa_fail

    ; --- Initialize Palette ---
    call install_palette

    ; --- Fetch BIOS 8x8 font ---
    mov ax, 0x1130
    mov bh, 0x03
    int 0x10
    mov [font_ptr_seg], es
    mov [font_ptr_off], bp
    mov ax, cs
    mov es, ax

    ; --- Initialize Mouse ---
    call init_mouse

    ; ---- Boot screen (Windows 10 style) ----
    mov al, 0
    call clear_screen
    call draw_win_logo

    mov word [frame], 0
.spin_loop:
    mov ax, [frame]
    cmp ax, 40                      ; shorter boot for better feel
    jae .spin_done
    call draw_spinner
    call short_delay
    inc word [frame]
    jmp .spin_loop
.spin_done:
    call short_delay

    ; ---- Desktop Main Loop ----
main_loop:
    call draw_desktop
    call handle_interaction
    ; Simple VSync-ish delay to reduce flicker
    mov dx, 0x03DA
.v1: in al, dx
    test al, 8
    jnz .v1
.v2: in al, dx
    test al, 8
    jz .v2
    jmp main_loop

vesa_fail:
    mov ah, 0x0E
    mov al, 'V'
    int 0x10
    jmp $

; ============================================================================
; Drawing Primitives (VBE Bank Switching)
; ============================================================================

set_bank:
    pusha
    cmp dx, [cur_bank]
    je .done
    mov [cur_bank], dx
    mov ax, 0x4F05
    mov bx, 0x0000
    int 0x10
.done:
    popa
    ret

cur_bank dw -1

put_pixel:
    pusha
    ; offset = y * 640 + x
    mov ax, [ry]
    mov cx, 640
    mul cx
    add ax, [rx]
    adc dx, 0                       ; DX:AX = 32-bit offset
    
    call set_bank                   ; DX is bank number
    mov di, ax                      ; DI is offset in bank
    mov ax, 0xA000
    mov es, ax
    mov al, [rc]
    mov [es:di], al
    popa
    ret

clear_screen:
    pusha
    mov byte [rc], al
    mov word [rx], 0
    mov word [ry], 0
    mov word [rw], 640
    mov word [rh], 480
    call fill_rect
    popa
    ret

fill_rect:
    pusha
    mov cx, [ry]                    ; CX = current Y
    mov si, [rh]                    ; SI = rows left
    or si, si
    jz .done
.row_loop:
    push cx
    ; Calculate starting offset for the row
    mov ax, cx
    mov bx, 640
    mul bx                          ; DX:AX = y * 640
    add ax, [rx]
    adc dx, 0                       ; DX:AX = start offset
    
    mov bp, [rw]                    ; BP = pixels left in row
    or bp, bp
    jz .row_next
.pixel_loop:
    push dx
    call set_bank
    mov di, ax
    mov bx, 0xA000
    mov es, bx
    
    ; How many pixels can we draw in this bank?
    mov bx, 0xFFFF
    sub bx, ax
    inc bx                          ; BX = pixels until end of bank
    
    mov dx, bp
    cmp dx, bx
    jbe .do_chunk
    mov dx, bx                      ; DX = min(pixels_left, pixels_to_bank_end)

.do_chunk:
    mov bx, dx                      ; Store chunk size
    mov al, [rc]
    push cx
    mov cx, dx
    rep stosb
    pop cx
    
    pop dx
    add ax, bx
    adc dx, 0
    sub bp, bx
    jnz .pixel_loop
    
.row_next:
    pop cx
    inc cx
    dec si
    jnz .row_loop
.done:
    popa
    ret

; ============================================================================
; Font Renderer
; ============================================================================

draw_char:
    pusha
    push fs
    mov ax, [font_ptr_seg]
    mov fs, ax
    mov si, [font_ptr_off]
    xor ah, ah
    mov al, [char]
    shl ax, 3                       ; char * 8
    add si, ax                      ; SI points to char bitmap (8 bytes)
    
    mov cx, 8                       ; 8 rows
.row:
    push cx
    mov al, [fs:si]                 ; AL = bit pattern for this row
    inc si
    mov bl, al
    mov cx, 8                       ; 8 bits
.bit:
    push cx
    test bl, 0x80
    jz .skip
    call put_pixel
.skip:
    shl bl, 1
    inc word [rx]
    pop cx
    loop .bit
    
    sub word [rx], 8
    inc word [ry]
    pop cx
    loop .row
    pop fs
    popa
    ret

draw_string:
    pusha
    mov si, bx
.next:
    lodsb
    or al, al
    jz .done
    mov [char], al
    call draw_char
    add word [rx], 8
    jmp .next
.done:
    popa
    ret

char db 0

; ============================================================================
; Mouse Driver (PS/2)
; ============================================================================

init_mouse:
    pusha
    ; Enable mouse port
    mov ax, 0xC200
    mov bh, 0x01
    int 0x15
    
    ; Set resolution
    mov ax, 0xC203
    mov bh, 0x03
    int 0x15
    
    ; Set sample rate
    mov ax, 0xC202
    mov bh, 0x06
    int 0x15
    
    ; Set callback
    mov ax, 0xC207
    mov bx, cs
    mov es, bx
    mov bx, mouse_callback
    int 0x15
    
    ; Enable mouse
    mov ax, 0xC200
    mov bh, 0x01
    int 0x15
    popa
    ret

mouse_callback:
    push bp
    mov bp, sp
    pusha
    push ds
    mov ax, cs
    mov ds, ax

    ; [bp+12] status
    ; [bp+10] X movement
    ; [bp+8]  Y movement
    
    mov ax, [bp+12]
    and al, 7                       ; lower 3 bits are buttons (L, R, M)
    mov [mouse_btn], al
    
    mov al, [bp+10]                 ; dx (signed byte)
    cbw
    test byte [bp+12], 0x10         ; x sign bit
    jz .x_ext
    mov ah, 0xFF
.x_ext:
    add [mouse_x], ax
    
    mov al, [bp+8]                  ; dy (signed byte)
    cbw
    test byte [bp+12], 0x20         ; y sign bit
    jz .y_ext
    mov ah, 0xFF
.y_ext:
    sub [mouse_y], ax               ; PS/2 Y is bottom-up

    ; Clamp mouse_x
    cmp word [mouse_x], 0
    jge .x_max
    mov word [mouse_x], 0
.x_max:
    cmp word [mouse_x], 639
    jle .y_min
    mov word [mouse_x], 639

.y_min:
    ; Clamp mouse_y
    cmp word [mouse_y], 0
    jge .y_max
    mov word [mouse_y], 0
.y_max:
    cmp word [mouse_y], 479
    jle .done
    mov word [mouse_y], 479

.done:
    pop ds
    popa
    pop bp
    retf

; ============================================================================
; Interaction Logic
; ============================================================================

handle_interaction:
    pusha
    mov al, [mouse_btn]
    test al, 1                      ; Left button
    jz .not_clicking
    
    ; Was already dragging?
    cmp byte [is_dragging], 1
    je .do_drag
    
    ; Check if in window title bar
    cmp byte [win_visible], 0
    je .check_reboot
    
    ; Red close button check (win_x+180..win_x+195, win_y+4..win_y+16)
    mov ax, [mouse_x]
    mov bx, [win_x]
    add bx, 180
    cmp ax, bx
    jl .not_close
    add bx, 20
    cmp ax, bx
    jg .not_close
    mov bx, [win_y]
    add bx, 4
    cmp word [mouse_y], bx
    jl .not_close
    add bx, 16
    cmp word [mouse_y], bx
    jg .not_close
    mov byte [win_visible], 0
    jmp .done

.not_close:
    ; Title bar drag check
    mov ax, [mouse_x]
    cmp ax, [win_x]
    jl .check_reboot
    mov bx, [win_x]
    add bx, 200
    cmp ax, bx
    jg .check_reboot
    
    mov ax, [mouse_y]
    cmp ax, [win_y]
    jl .check_reboot
    mov bx, [win_y]
    add bx, 20
    cmp ax, bx
    jg .check_reboot
    
    ; Start dragging
    mov byte [is_dragging], 1
    mov ax, [mouse_x]
    sub ax, [win_x]
    mov [drag_offset_x], ax
    mov ax, [mouse_y]
    sub ax, [win_y]
    mov [drag_offset_y], ax
    jmp .done

.do_drag:
    mov ax, [mouse_x]
    sub ax, [drag_offset_x]
    mov [win_x], ax
    mov ax, [mouse_y]
    sub ax, [drag_offset_y]
    mov [win_y], ax
    jmp .done

.not_clicking:
    mov byte [is_dragging], 0

.check_reboot:
    ; Any key to reboot
    mov ah, 0x01
    int 0x16
    jz .done
    mov ah, 0
    int 0x16
    int 0x19

.done:
    popa
    ret

; ============================================================================
; UI Elements
; ============================================================================

draw_win_logo:
    pusha
    mov byte [rc], 3                ; Win 10 blue
    mov word [rx], 280
    mov word [ry], 140
    mov word [rw], 36
    mov word [rh], 36
    call fill_rect
    mov word [rx], 324
    call fill_rect
    mov word [rx], 280
    mov word [ry], 184
    call fill_rect
    mov word [rx], 324
    call fill_rect
    popa
    ret

draw_spinner:
    pusha
    ; Clear area
    mov word [rx], 280
    mov word [ry], 260
    mov word [rw], 80
    mov word [rh], 80
    mov byte [rc], 0
    call fill_rect

    mov ax, [frame]
    xor dx, dx
    mov bx, 12
    div bx
    mov [head], dl

    mov cx, 12
    mov bx, 0
.dot_loop:
    push cx
    xor ah, ah
    mov al, [head]
    sub ax, bx
    jge .pos
    add ax, 12
.pos:
    cmp ax, 6
    jbe .have_idx
    mov ax, 6
.have_idx:
    mov si, brightness_table
    add si, ax
    mov al, [si]
    mov [rc], al

    mov si, dot_offsets_640
    mov ax, bx
    shl ax, 1
    add si, ax

    mov al, [si]
    cbw
    add ax, 320
    dec ax
    mov [rx], ax
    mov al, [si+1]
    cbw
    add ax, 300
    dec ax
    mov [ry], ax
    mov word [rw], 5
    mov word [rh], 5
    call fill_rect
    inc bx
    pop cx
    loop .dot_loop
    popa
    ret

dot_offsets_640:
    db   0, -28
    db  14, -24
    db  24, -14
    db  28,   0
    db  24,  14
    db  14,  24
    db   0,  28
    db -14,  24
    db -24,  14
    db -28,   0
    db -24, -14
    db -14, -24

draw_desktop:
    pusha
    ; Wallpaper
    mov al, 10
    call clear_screen
    
    ; Rays
    mov byte [rc], 11
    mov cx, 60
    mov word [_ray_x], 120
    mov word [_ray_y], 0
.r1:
    mov ax, [_ray_x]
    mov [rx], ax
    mov ax, [_ray_y]
    mov [ry], ax
    mov word [rw], 60
    mov word [rh], 8
    call fill_rect
    add word [_ray_x], 8
    add word [_ray_y], 8
    loop .r1

    ; Taskbar
    mov word [rx], 0
    mov word [ry], 440
    mov word [rw], 640
    mov word [rh], 40
    mov byte [rc], 5
    call fill_rect

    ; Start Button
    mov byte [rc], 3
    mov word [rx], 10
    mov word [ry], 448
    mov word [rw], 10
    mov word [rh], 10
    call fill_rect
    mov word [rx], 22
    call fill_rect
    mov word [rx], 10
    mov word [ry], 460
    call fill_rect
    mov word [rx], 22
    call fill_rect

    ; Search box
    mov word [rx], 50
    mov word [ry], 448
    mov word [rw], 150
    mov word [rh], 24
    mov byte [rc], 14
    call fill_rect
    
    mov byte [rc], 8
    mov word [rx], 60
    mov word [ry], 456
    mov bx, str_search
    call draw_string

    ; Clock
    mov word [rx], 580
    mov word [ry], 456
    mov bx, str_clock
    call draw_string

    ; Window
    cmp byte [win_visible], 0
    je .no_win
    
    mov ax, [win_x]
    mov [rx], ax
    mov ax, [win_y]
    mov [ry], ax
    mov word [rw], 200
    mov word [rh], 150
    mov byte [rc], 6
    call fill_rect
    
    ; Title bar
    mov byte [rc], 15
    mov word [rh], 20
    call fill_rect
    
    mov byte [rc], 8
    mov ax, [win_x]
    add ax, 10
    mov [rx], ax
    mov ax, [win_y]
    add ax, 6
    mov [ry], ax
    mov bx, str_window_title
    call draw_string
    
    ; Close button
    mov byte [rc], 9
    mov ax, [win_x]
    add ax, 180
    mov [rx], ax
    mov ax, [win_y]
    add ax, 4
    mov [ry], ax
    mov word [rw], 15
    mov word [rh], 12
    call fill_rect

    ; Welcome text
    mov byte [rc], 0
    mov ax, [win_x]
    add ax, 10
    mov [rx], ax
    mov ax, [win_y]
    add ax, 40
    mov [ry], ax
    mov bx, str_welcome1
    call draw_string
    add word [ry], 16
    mov bx, str_welcome2
    call draw_string
    add word [ry], 16
    mov bx, str_welcome3
    call draw_string
    add word [ry], 32
    mov bx, str_press_key
    call draw_string

.no_win:
    ; Mouse cursor
    mov ax, [mouse_x]
    mov [rx], ax
    mov ax, [mouse_y]
    mov [ry], ax
    call draw_cursor
    
    popa
    ret

draw_cursor:
    pusha
    mov byte [rc], 8                ; white
    mov cx, 8
.c_loop:
    push cx
    mov ax, 9
    sub ax, cx                      ; 1, 2, 3...
    mov [rw], ax
    mov word [rh], 1
    call fill_rect
    inc word [ry]
    pop cx
    loop .c_loop
    ; tail
    sub word [ry], 3
    inc word [rx]
    mov word [rw], 2
    mov word [rh], 4
    call fill_rect
    popa
    ret

; ============================================================================
; Data & Globals
; ============================================================================

font_ptr_seg dw 0
font_ptr_off dw 0
rx dw 0
ry dw 0
rw dw 0
rh dw 0
rc db 0
frame dw 0
head db 0

mouse_x dw 320
mouse_y dw 240
mouse_btn db 0
win_x dw 220
win_y dw 150
win_visible db 1
is_dragging db 0
drag_offset_x dw 0
drag_offset_y dw 0

_ray_x dw 0
_ray_y dw 0

brightness_table:
    db 8, 4, 14, 15, 12, 13, 0

palette_data:
    db  0,  0,  0      ; 0  pure black
    db  7,  7, 11      ; 1
    db 10, 10, 15      ; 2
    db  0, 30, 54      ; 3  Win 10 blue
    db 56, 56, 60      ; 4  very light grey
    db  7,  7,  7      ; 5  taskbar very dark grey
    db 60, 60, 60      ; 6  window body
    db 48, 48, 48      ; 7
    db 63, 63, 63      ; 8  white
    db 58, 17, 20      ; 9  close-button red
    db  5, 25, 50      ; 10 wallpaper blue
    db 12, 35, 58      ; 11 wallpaper lighter ray
    db 24, 24, 28      ; 12 spinner dim
    db 14, 14, 18      ; 13 spinner very dim
    db 35, 35, 38      ; 14 button grey
    db 50, 50, 52      ; 15 title-bar light grey
    db 18, 42, 60      ; 16 wallpaper even lighter

install_palette:
    pusha
    mov dx, 0x03C8
    mov al, 0
    out dx, al
    inc dx
    mov si, palette_data
    mov cx, 17*3
.p_next:
    lodsb
    out dx, al
    loop .p_next
    popa
    ret

short_delay:
    pusha
    mov cx, 0x0020
    mov dx, 0xFFFF
.sd:
    dec dx
    jnz .sd
    dec cx
    jnz .sd
    popa
    ret

str_window_title db "Welcome - RLVAL OS",0
str_welcome1     db "Hello, world!",0
str_welcome2     db "RLVAL OS booted successfully.",0
str_welcome3     db "Windows 10 style UI.",0
str_press_key    db "[Press any key to reboot]",0
str_search       db "Type here to search",0
str_clock        db "12:34",0

; Pad to 64 sectors
times 32768-($-$$) db 0
