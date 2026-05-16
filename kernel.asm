; ============================================================================
; kernel.asm - RLVAL OS kernel (16-bit real mode, VGA mode 13h)
; Windows 10 themed: black boot screen with 4-pane window logo + dot spinner,
; blue hero wallpaper, dark taskbar with Win-style start button.
;
; Assemble: nasm -f bin kernel.asm -o kernel.bin
; Loaded by boot.asm at 0x1000:0x0000.
; ============================================================================

[BITS 16]
[ORG 0x0000]

KERNEL_START:
    mov ax, cs
    mov ds, ax
    mov es, ax

    mov ax, 0x0013                  ; VGA mode 13h: 320x200x256 @ 0xA0000
    int 0x10

    call install_palette

    ; ---- Boot screen (Windows 10 style) ----
    mov al, 0                       ; pure black
    call clear_screen

    ; Draw the Windows-style 4-pane logo, centered horizontally, upper area.
    ; Logo top-left at (140, 60); each pane is 18x18 with a 4 px gap.
    call draw_win_logo

    ; ---- Spinner animation (Win 10 style: ring of small dots, comet trail) ----
    mov word [frame], 0
.spin_loop:
    mov ax, [frame]
    cmp ax, 96
    jae .spin_done

    call draw_spinner
    call short_delay

    inc word [frame]
    jmp .spin_loop
.spin_done:

    call long_delay

    ; ---- Desktop ----
    call draw_desktop

    ; Wait for keypress, then reboot
    mov ah, 0
    int 0x16
    int 0x19

.hang:
    cli
    hlt
    jmp .hang


; ============================================================================
; draw_win_logo: 4-pane Windows-style logo centered around (160, 80).
;   Two rows of two panes, each pane 18x18, with a 4 px gap between panes.
;   Total logo size = 18+4+18 = 40 px wide and tall.
;   Top-left corner = (160-20, 80-20) = (140, 60).
;   All panes drawn in palette index 3 (Win 10 blue).
; ============================================================================
draw_win_logo:
    pusha
    mov byte [rc], 3                ; Win 10 blue

    ; top-left pane
    mov word [rx], 140
    mov word [ry], 60
    mov word [rw], 18
    mov word [rh], 18
    call fill_rect

    ; top-right pane
    mov word [rx], 162
    mov word [ry], 60
    mov word [rw], 18
    mov word [rh], 18
    call fill_rect

    ; bottom-left pane
    mov word [rx], 140
    mov word [ry], 82
    mov word [rw], 18
    mov word [rh], 18
    call fill_rect

    ; bottom-right pane
    mov word [rx], 162
    mov word [ry], 82
    mov word [rw], 18
    mov word [rh], 18
    call fill_rect

    popa
    ret


; ============================================================================
; draw_spinner: Windows 10 style.  Ring of 12 small dots around (160, 140),
;   radius 14.  Head fully bright; longer fading trail (more dots lit than
;   in Win 11) so it reads like a "snake chasing itself".
;
;   12 angles at 30 deg intervals.  Offsets precomputed below.
;
;   Brightness mapping by distance behind head:
;     0 -> color 8  (white, head)
;     1 -> color 4  (very light grey)
;     2 -> color 14 (medium grey)
;     3 -> color 15 (darker grey)
;     4 -> color 12 (dim)
;     5 -> color 13 (very dim)
;     6+-> color 0  (black, "off")
; ============================================================================

NUM_DOTS equ 12

draw_spinner:
    pusha

    ; Clear a 40x40 box behind the spinner
    mov word [rx], 140
    mov word [ry], 120
    mov word [rw], 40
    mov word [rh], 40
    mov byte [rc], 0
    call fill_rect

    ; head = frame % NUM_DOTS
    mov ax, [frame]
    xor dx, dx
    mov bx, NUM_DOTS
    div bx                          ; dx = remainder
    mov [head], dl

    ; loop over 12 dots
    mov cx, NUM_DOTS
    mov bx, 0                       ; dot index i
.dot_loop:
    push cx

    ; dist = (head - i) mod NUM_DOTS  (using 16-bit arithmetic)
    xor ah, ah
    mov al, [head]
    sub ax, bx
    ; If negative, add NUM_DOTS until positive (only need at most one add)
    cmp ax, 0
    jge .pos
    add ax, NUM_DOTS
.pos:
    ; ax = dist (0..11).  Look up color in brightness table (max idx 6).
    cmp ax, 6
    jbe .have_idx
    mov ax, 6
.have_idx:
    mov si, brightness_table
    add si, ax
    mov al, [si]
    mov [rc], al

    ; offsets
    mov si, dot_offsets
    mov ax, bx
    shl ax, 1
    add si, ax

    ; X = 160 + signed offset - 1 (to center the 3x3 dot)
    mov al, [si]
    cbw
    add ax, 160
    dec ax
    mov [rx], ax

    mov al, [si+1]
    cbw
    add ax, 140
    dec ax
    mov [ry], ax

    mov word [rw], 3
    mov word [rh], 3
    call fill_rect

    inc bx
    pop cx
    loop .dot_loop

    popa
    ret

brightness_table:
    db 8        ; 0 head: white
    db 4        ; 1: very light
    db 14       ; 2: light grey
    db 15       ; 3: medium grey
    db 12       ; 4: dim
    db 13       ; 5: very dim
    db 0        ; 6+: off (black)

; Precomputed offsets for 12 dots on a circle of radius 14, starting at top
; and going clockwise.  Each entry is (dx, dy) as signed bytes.
;   angle_i = i * 30 deg, i=0 at the top
;   dx = round(14 * sin(angle))
;   dy = round(-14 * cos(angle))
dot_offsets:
    db   0, -14      ; 0   top         (0°)
    db   7, -12      ; 1   (30°)
    db  12,  -7      ; 2   (60°)
    db  14,   0      ; 3   right       (90°)
    db  12,   7      ; 4   (120°)
    db   7,  12      ; 5   (150°)
    db   0,  14      ; 6   bottom      (180°)
    db  -7,  12      ; 7   (210°)
    db -12,   7      ; 8   (240°)
    db -14,   0      ; 9   left        (270°)
    db -12,  -7      ; 10  (300°)
    db  -7, -12      ; 11  (330°)


; ============================================================================
; draw_desktop: Windows 10 style desktop.
;   - Blue hero wallpaper (palette index 10 = Win 10 wallpaper blue).
;   - Subtle "rays" effect using two diagonal lighter bands.
;   - Bottom taskbar in palette index 5 (Win 10 dark grey/black).
;   - Start button on far left (Win logo mini, 4 small blue panes).
;   - Search box (mid-grey rounded rect).
;   - System tray + clock on the right.
;   - A "Welcome" window with title bar + body.
;   - White arrow mouse cursor.
; ============================================================================
draw_desktop:
    pusha

    ; Wallpaper: fill screen with Win 10 wallpaper blue (palette 10)
    mov al, 10
    call clear_screen

    ; Two diagonal lighter "rays" using thin slanted blocks for a gentle
    ; lighting effect.  Approximate the diagonals with a few staggered rects.
    call draw_wallpaper_rays

    ; --- Taskbar at bottom: y=184..199, very dark ---
    mov word [rx], 0
    mov word [ry], 184
    mov word [rw], 320
    mov word [rh], 16
    mov byte [rc], 5
    call fill_rect

    ; --- Start button: Win mini logo on the left of the taskbar ---
    ; A 12x12 area at (4, 188) divided into 4 small blue panes
    call draw_start_button

    ; --- Search box: mid-grey rounded-ish rect after the start button ---
    mov word [rx], 22
    mov word [ry], 188
    mov word [rw], 78
    mov word [rh], 9
    mov byte [rc], 14
    call fill_rect

    ; --- System tray area (right side) ---
    mov word [rx], 250
    mov word [ry], 188
    mov word [rw], 30
    mov word [rh], 9
    mov byte [rc], 5
    call fill_rect

    ; --- Clock area on far right ---
    mov word [rx], 285
    mov word [ry], 188
    mov word [rw], 33
    mov word [rh], 9
    mov byte [rc], 5
    call fill_rect

    ; --- "Welcome" Window ---
    ; Body
    mov word [rx], 60
    mov word [ry], 40
    mov word [rw], 200
    mov word [rh], 120
    mov byte [rc], 6
    call fill_rect

    ; Title bar (Windows 10 typical: white/light with text and Win-style buttons)
    mov word [rx], 60
    mov word [ry], 40
    mov word [rw], 200
    mov word [rh], 14
    mov byte [rc], 15
    call fill_rect

    ; Minimize / Maximize / Close buttons (right end of title bar)
    ; Each ~10x6
    mov word [rx], 220
    mov word [ry], 44
    mov word [rw], 10
    mov word [rh], 6
    mov byte [rc], 14
    call fill_rect

    mov word [rx], 232
    mov word [ry], 44
    mov word [rw], 10
    mov word [rh], 6
    mov byte [rc], 14
    call fill_rect

    ; Close = red-ish (we use the orange/red shade in palette index 9)
    mov word [rx], 246
    mov word [ry], 44
    mov word [rw], 10
    mov word [rh], 6
    mov byte [rc], 9
    call fill_rect

    ; ---- Text labels ----

    ; Window title
    mov dh, 5
    mov dl, 9
    call set_cursor
    mov si, str_window_title
    call print_str

    ; Window body lines
    mov dh, 8
    mov dl, 9
    call set_cursor
    mov si, str_welcome1
    call print_str

    mov dh, 10
    mov dl, 9
    call set_cursor
    mov si, str_welcome2
    call print_str

    mov dh, 12
    mov dl, 9
    call set_cursor
    mov si, str_welcome3
    call print_str

    mov dh, 17
    mov dl, 9
    call set_cursor
    mov si, str_press_key
    call print_str

    ; Search box placeholder text
    mov dh, 23
    mov dl, 4
    call set_cursor
    mov si, str_search
    call print_str

    ; Clock
    mov dh, 23
    mov dl, 35
    call set_cursor
    mov si, str_clock
    call print_str

    ; Mouse cursor
    call draw_cursor

    popa
    ret


; ============================================================================
; draw_wallpaper_rays: paint a couple of lighter diagonal stripes so the
; wallpaper doesn't look flat.  We approximate diagonals with stacked
; horizontal rects of slightly lighter blue (palette 11).
; ============================================================================
draw_wallpaper_rays:
    pusha
    mov byte [rc], 11

    mov cx, 30                      ; number of stripe segments
    mov word [_ray_x], 60
    mov word [_ray_y], 0
.r1:
    mov ax, [_ray_x]
    mov [rx], ax
    mov ax, [_ray_y]
    mov [ry], ax
    mov word [rw], 30
    mov word [rh], 6
    call fill_rect
    add word [_ray_x], 5
    add word [_ray_y], 6
    loop .r1

    ; second, fainter ray on the other side
    mov byte [rc], 16               ; even lighter blue
    mov cx, 24
    mov word [_ray_x], 260
    mov word [_ray_y], 0
.r2:
    mov ax, [_ray_x]
    mov [rx], ax
    mov ax, [_ray_y]
    mov [ry], ax
    mov word [rw], 20
    mov word [rh], 7
    call fill_rect
    sub word [_ray_x], 4
    add word [_ray_y], 7
    loop .r2

    popa
    ret

_ray_x dw 0
_ray_y dw 0


; ============================================================================
; draw_start_button: tiny 4-pane Win logo on the taskbar at (4, 188), 12x12.
; ============================================================================
draw_start_button:
    pusha
    mov byte [rc], 3                ; Win blue

    mov word [rx], 4
    mov word [ry], 188
    mov word [rw], 5
    mov word [rh], 5
    call fill_rect

    mov word [rx], 11
    mov word [ry], 188
    mov word [rw], 5
    mov word [rh], 5
    call fill_rect

    mov word [rx], 4
    mov word [ry], 194
    mov word [rw], 5
    mov word [rh], 3
    call fill_rect

    mov word [rx], 11
    mov word [ry], 194
    mov word [rw], 5
    mov word [rh], 3
    call fill_rect

    popa
    ret


; ============================================================================
; draw_cursor: small white arrow at (160, 100)
; ============================================================================
draw_cursor:
    pusha
    mov byte [rc], 8

    mov word [rx],160
    mov word [ry],100
    mov word [rw],1
    mov word [rh],1
    call fill_rect

    mov word [rx],160
    mov word [ry],101
    mov word [rw],2
    mov word [rh],1
    call fill_rect

    mov word [rx],160
    mov word [ry],102
    mov word [rw],3
    mov word [rh],1
    call fill_rect

    mov word [rx],160
    mov word [ry],103
    mov word [rw],4
    mov word [rh],1
    call fill_rect

    mov word [rx],160
    mov word [ry],104
    mov word [rw],5
    mov word [rh],1
    call fill_rect

    mov word [rx],160
    mov word [ry],105
    mov word [rw],6
    mov word [rh],1
    call fill_rect

    mov word [rx],160
    mov word [ry],106
    mov word [rw],7
    mov word [rh],1
    call fill_rect

    mov word [rx],160
    mov word [ry],107
    mov word [rw],4
    mov word [rh],1
    call fill_rect

    mov word [rx],162
    mov word [ry],108
    mov word [rw],2
    mov word [rh],1
    call fill_rect

    mov word [rx],163
    mov word [ry],109
    mov word [rw],2
    mov word [rh],3
    call fill_rect

    popa
    ret


; ============================================================================
; install_palette: DAC entries for Windows 10 colors + spinner shades
;   0  black                        (boot screen bg)
;   1  background-dark              (unused now, kept for compat)
;   2  panel
;   3  Win 10 blue                  (#0078D7 -> /4 = 0, 30, 54)
;   4  very light grey/white-ish    (spinner trail 1)
;   5  taskbar very dark grey       (#1F1F1F-ish)
;   6  window body / off-white      (Win 10 window background)
;   7  title bar darker
;   8  pure white                   (spinner head, mouse cursor)
;   9  close-button red             (#E81123 -ish)
;   10 wallpaper blue               (Win 10 hero blue)
;   11 wallpaper lighter blue       (rays)
;   12 spinner dim
;   13 spinner very dim
;   14 button grey
;   15 title-bar light grey
;   16 even lighter wallpaper blue  (second ray)
; ============================================================================
install_palette:
    pusha
    mov dx, 0x03C8
    mov al, 0
    out dx, al
    inc dx
    mov si, palette_data
    mov cx, 17*3
.next:
    lodsb
    out dx, al
    loop .next
    popa
    ret

palette_data:
    db  0,  0,  0      ; 0  pure black (boot bg)
    db  7,  7, 11      ; 1
    db 10, 10, 15      ; 2
    db  0, 30, 54      ; 3  Win 10 blue (#0078D7)
    db 56, 56, 60      ; 4  very light grey (spinner trail 1)
    db  7,  7,  7      ; 5  taskbar very dark grey
    db 60, 60, 60      ; 6  window body (light grey/off-white)
    db 48, 48, 48      ; 7
    db 63, 63, 63      ; 8  white (spinner head)
    db 58, 17, 20      ; 9  close-button red (#E81123 -> 58,4,8 brighter)
    db  5, 25, 50      ; 10 wallpaper blue (Win 10 hero)
    db 12, 35, 58      ; 11 wallpaper lighter ray
    db 24, 24, 28      ; 12 spinner dim
    db 14, 14, 18      ; 13 spinner very dim
    db 35, 35, 38      ; 14 button grey
    db 50, 50, 52      ; 15 title-bar light grey
    db 18, 42, 60      ; 16 wallpaper even lighter (second ray)


; ============================================================================
; clear_screen(al=color)
; ============================================================================
clear_screen:
    pusha
    push es
    mov bx,0xA000
    mov es,bx
    xor di,di
    mov ah,al
    mov cx,(320*200)/2
    rep stosw
    pop es
    popa
    ret


; ============================================================================
; fill_rect: reads rx, ry, rw, rh, rc (rc is one byte) and draws a filled rect.
; ============================================================================
fill_rect:
    pusha
    push es
    mov ax,0xA000
    mov es,ax

    mov bp,[rh]
    mov ax,[ry]
.row:
    push ax
    mov di,ax
    mov bx,ax
    shl ax,8
    shl di,6
    add di,ax
    add di,[rx]
    mov cx,[rw]
    mov al,[rc]
.col:
    mov [es:di],al
    inc di
    loop .col
    pop ax
    inc ax
    dec bp
    jnz .row

    pop es
    popa
    ret


; ============================================================================
set_cursor:
    mov ah,0x02
    mov bh,0
    int 0x10
    ret

print_str:
    pusha
.next:
    lodsb
    or al,al
    jz .done
    mov ah,0x0E
    mov bx,0x0008                   ; page 0, foreground = white-ish
    int 0x10
    jmp .next
.done:
    popa
    ret


; ============================================================================
; Delays
; ============================================================================
short_delay:
    pusha
    mov cx, 0x0020
    mov dx, 0xFFFF
.d:
    dec dx
    jnz .d
    dec cx
    jnz .d
    popa
    ret

long_delay:
    pusha
    mov cx, 0x0080
    mov dx, 0xFFFF
.d:
    dec dx
    jnz .d
    dec cx
    jnz .d
    popa
    ret


; ============================================================================
; Globals
; ============================================================================
rx    dw 0
ry    dw 0
rw    dw 0
rh    dw 0
rc    db 0
frame dw 0
head  db 0


; ============================================================================
; Strings
; ============================================================================
str_window_title db "Welcome - RLVAL OS",0
str_welcome1     db "Hello, world!",0
str_welcome2     db "RLVAL OS booted successfully.",0
str_welcome3     db "Windows 10 style UI.",0
str_press_key    db "[Press any key to reboot]",0
str_search       db "Type here to search",0
str_clock        db "12:34",0


; ============================================================================
; Pad kernel to 32 sectors (16 KB)
; ============================================================================
times 16384-($-$$) db 0
