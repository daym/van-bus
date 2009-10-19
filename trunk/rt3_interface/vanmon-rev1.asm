  list p=16f877, st=OFF, x=OFF, n=0
  errorlevel -302
  #include <p16f877.inc>

	__config _PWRTE_ON & _WDT_OFF & _HS_OSC

; Constants

CMDBUFF_LEN   EQU 0x20      ; Length of command buffer

MODE_NONE     EQU 0x00      ; Modes for main_mode variable
MODE_CAPTURE  EQU 0x01

; RAM variables

    CBLOCK        0x20

    crc_h:          1       ; CRC high byte, used by _CalcCrc
    crc_l:          1       ; CRC low byte, used by _CalcCrc
    crc_bit:        1       ; CRC bit counte, used by _CalcCrc
    crc_count:      1       ; CRC byte counter, used by _CalcCrc

    tx_bytes:       1       ; No of bytes to transmit (incl CRC)
    tx_byte_buf:    1       ; Byte to transmit
    tx_output_buf:  1       ; Bits during transmission
    tx_nibblecnt:   1       ; Count bits during transmission
    tx_delay:       1       ; Timedelay
    
    rx_input_buf:   1       ; Input buffer
    rx_delay:       1       ; Timedelay
    rx_bytes:       1       ; No of bytes received
    rx_fsr:         1       ; Temporary storage for FSR pointer

    rx232_bytes:    1       ; Bytes left in rs232 buffer to transmit
    rs232_txptr:    1       ; Pointer to next byte in rs232 buffer to transmit
    rs232_temp:     1       ; Temporary RS232 variable
    rs232_txinptr:  1       ; Pointer to where to add data in tx queue
    
    dec_count:      1       ; Counter when decoding packages
    dec_ptr:        1       ; Byte pointer to packet buffer while decoding
    dec_temp:       1       ; Temporary variable

    main_inptr:     1       ; Pointer to cmd bytes read    
    main_inchar:    1       ; Character read from RS232 port
    main_mode:      1       ; Current mode of operation
    main_txcount:   1       ; Bytes to transmit by the "t" command
    
    hex_temp:       1       ; Hex conversion temporary variable
    
    ENDC

    CBLOCK        0x190
    cmd_buffer:     CMDBUFF_LEN   ; Command buffer
    
    ENDC

Bank0   MACRO     ; Macro to select data RAM bank 0
    bcf STATUS,RP0
    bcf STATUS,RP1
    ENDM

Bank1   MACRO     ; Macro to select data RAM bank 1
    bsf STATUS,RP0
    bcf STATUS,RP1
    ENDM

Bank2   MACRO     ; Macro to select data RAM bank 2
    bcf STATUS,RP0
    bsf STATUS,RP1
    ENDM

Bank3   MACRO     ; Macro to select data RAM bank 3
    bsf STATUS,RP0
    bsf STATUS,RP1
    ENDM
    
Tx232   MACRO     ; Send W to serial port
    bsf     STATUS,RP0
    bcf     STATUS,RP1
    btfss   TXSTA,TRMT
    goto    $-2
    bcf     STATUS,RP0
    movwf   TXREG
    ENDM

    ORG 0x0000 

_ResetVector: 
  clrf    PCLATH          ; Set page bits for page0
  goto    _Main           ; Go to startup code


;---------------------------
; Convert W to hex character
;
; Input:  W - Value to convert
;
; Output: Ascii character 0..9, A..F

_HexConv:
  clrf    PCLATH
  andlw   0x0f
  addwf   PCL,F
  retlw   '0'
  retlw   '1'
  retlw   '2'
  retlw   '3'
  retlw   '4'
  retlw   '5'
  retlw   '6'
  retlw   '7'
  retlw   '8'
  retlw   '9'
  retlw   'A'
  retlw   'B'
  retlw   'C'
  retlw   'D'
  retlw   'E'
  retlw   'F'


_Main:

  bcf     INTCON,7    ; Disable all interrupts

  Bank1 

  movlw   0x0A        ; Set baud rate 115200
  movwf   SPBRG 
  movlw   0x24        ; Transmitter enable, asyncronus mode, high speed mode
  movwf   TXSTA
  
  movlw   0x06        ; Switch off ADC
  movwf   ADCON1
  
  movlw   0x37        ; Bit 0 : Input, Bit 3 : Output
  movwf   TRISA      
  movlw   0xff
  movwf   TRISB 
  
  Bank0
  bcf     PORTA,3     ; No VAN TX
  bcf     PORTB,4
  movlw   0x90        ; Enable Serial port and Receiver
  movwf   RCSTA
  
  ; Ready

  clrf    rx232_bytes
  clrf    rs232_txptr
  clrf    rs232_txinptr
  clrf    main_inptr
  clrf    main_mode

_WritePrompt: 
  movlw   0x0d            ; Write < CR > 
  call    _QueueRs232
  movlw   '>'             ; Write ">" (prompt)
  call    _QueueRs232
  
_WaitCmd:
  call    _SendRs232
  
bank0
  btfss   PIR1,RCIF
  goto    _NoRs232Rx
  movf    RCREG,W
  call    _InterpretCmd
  movwf   main_inchar
  sublw   0x02
  btfsc   STATUS,Z
  goto    _WritePrompt
  
_NoRs232Rx:
  movf    main_mode,W
  sublw   MODE_CAPTURE
  btfss   STATUS,Z
  goto    _WaitCmd
  
  btfsc   PORTA,0
  goto    _WaitCmd
  call    _VAN_rx 
  call    _HexDecodePacket  
  goto    _WaitCmd
  
  ; Load message

  movlw   0x8d
  ;movwf   indata+0x00
  movlw   0x4c
  ;movwf   indata+0x01
  movlw   0x12
  ;movwf   indata+0x02
  movlw   0x03
  ;movwf   indata+0x03
  
  
;-----------------------------------------------------------------------
; Interpret command from RS232 port
;
; Input: W = Received character

_InterpretCmd:
  movwf   main_inchar
  
  sublw   0x08            ; Is it DEL key?
  btfss   STATUS,Z
  goto    _Rx232NotDel  
  movf    main_inptr,W
  btfsc   STATUS,Z        ; Are there any characters in the buffer?
  retlw   0x00
  decf    main_inptr,F
  movlw   0x08            ; Yes - erase the last character in 
  call    _QueueRs232     ; input buffer
  movlw   ' '
  call    _QueueRs232
  movlw   0x08
  call    _QueueRs232
  retlw   0x00
  
_Rx232NotDel:
  movf    main_inchar,W   ; Is it CR ?
  sublw   0x0d
  btfss   STATUS,Z
  goto    _KeyNotCR

  movlw   cmd_buffer
  movwf   FSR
  bsf     STATUS,IRP      ; Point to cmd buffer at 0x190 in RAM
  
  movf    INDF,W          ; Is it capture command?
  sublw   'c'
  btfss   STATUS,Z
  goto    _CmdNotCapt
  movlw   MODE_CAPTURE    ; Start capture
  movwf   main_mode
  movlw   0x0d            ; Write < CR > 
  call    _QueueRs232
  clrf    main_inptr      ; Clear buffer
  retlw   0x00  
  
_CmdNotCapt:
  movf    INDF,W          ; Is it transmit command?
  sublw   't'
  btfss   STATUS,Z
  goto    _CmdNotTransm

  btfss   main_inptr,0
  goto    _CmdInvChar

  clrf    main_txcount
  
_DecNextByte:
  incf    main_txcount,W
  addwf   main_txcount,W
  subwf   main_inptr,W
  btfsc   STATUS,Z
  goto    _CreatePackage
  
  movf    main_txcount,W
  addwf   main_txcount,W
  andlw   0x3e
  addlw   LOW cmd_buffer+1
  movwf   FSR
  bsf     STATUS,IRP      ; Point to cmd buffer at 0x190 in RAM

  movf    INDF,W
  call    _HexDecode
  btfsc   STATUS,C
  goto    _CmdInvChar
  movwf   tx_bytes
  swapf   tx_bytes,F
  incf    FSR,F
  movf    INDF,W
  call    _HexDecode
  btfsc   STATUS,C
  goto    _CmdInvChar
  iorwf   tx_bytes,F

  movf    main_txcount,W
  addlw   0x10    
  movwf   FSR             ; package buffer  
  bsf     STATUS,IRP      ; Point to packet buffer at 0x110 in RAM
  
  movf    tx_bytes,W
  movwf   INDF
  
  incf    main_txcount,F
  goto    _DecNextByte  

_CreatePackage:
  movlw   0x10            ; Setup FSR to point to first byte in
  movwf   FSR             ; package buffer  
  bsf     STATUS,IRP      ; Point to packet buffer at 0x110 in RAM
  movf    main_txcount,W  ; Load number of bytes to calculate CRC for
  call    _CalcCrc        ; Calculate CRC
  movf    crc_h,W         ; Store CRC last in package
  movwf   INDF            ; MSB
  incf    FSR,F
  movf    crc_l,W       
  movwf   INDF            ; LSB
  movlw   0x02            ; Add 0x02 to package length
  addwf   main_txcount,F

_WaitSendBus:

  ; Vait EOF (64 us)
  ; Wait IFS (32 us)

  movlw   0x00-0x30
_WaitHigh00:
  btfss   PORTA,0         ; 2 us each turn
  goto    _WaitSendBus
  addlw   0x01
  btfss   PORTA,0
  goto    _WaitSendBus
  btfss   PORTA,0
  goto    _WaitSendBus
  btfss   STATUS,Z
  goto    _WaitHigh00
  
  movf    main_txcount,W
  call    _VAN_tx         ; Send package
  movwf   tx_bytes
  sublw   0x02
  btfsc   STATUS,Z
  goto    _WaitSendBus
  movlw   0x0d            ; Write < CR > 
  call    _QueueRs232 
  btfsc   tx_bytes,0
  goto    _CmdTxGotAck
  movlw   'N'
  call    _QueueRs232
  movlw   'O'
  call    _QueueRs232
  movlw   ' '
  call    _QueueRs232
_CmdTxGotAck:
  movlw   'A'
  call    _QueueRs232
  movlw   'C'
  call    _QueueRs232
  movlw   'K'
  call    _QueueRs232
  clrf    main_inptr      ; Clear buffer
  retlw   0x02
  
_CmdInvChar:
  movlw   '?'             ; Write < ? > 
  call    _QueueRs232

  clrf    main_inptr      ; Clear buffer
  retlw   0x02
  
_CmdNotTransm:
  movlw   0x0d            ; Write < CR > 
  call    _QueueRs232
  movlw   '?'             ; Write < ? > 
  call    _QueueRs232
  movlw   0x0d            ; Write < CR > 
  call    _QueueRs232
  clrf    main_inptr      ; Clear buffer
  retlw   0x02
  
_KeyNotCR:
  movf    main_inchar,W   ; Is it Esc
  sublw   0x1b
  btfss   STATUS,Z
  goto    KeyNotEsc

  movf    main_mode,W     ; Ignore key of no special mode
  btfsc   STATUS,Z
  retlw   0x00
    
  movlw   MODE_NONE       ; Stop capturing packets
  movwf   main_mode
  retlw   0x02            ; Write command prompt again
    
KeyNotEsc:
  movf    main_inptr,W    ; Check if buffer is filled
  sublw   CMDBUFF_LEN
  btfsc   STATUS,Z
  retlw   0x01
  
  movf    main_inptr,W    ; No, add character
  addlw   cmd_buffer
  movwf   FSR
  bsf     STATUS,IRP      ; Point to cmd buffer at 0x190 in RAM
  incf    main_inptr,F
  
  movf    main_inchar,W
  movwf   INDF
  goto    _QueueRs232     ; Print character

;-----------------------------------------------------------------------
; Convert Hex Ascii to hex
;
; Input: W = Ascii character
;
; Output: C = 0, W = value 
;         C = 1 : Invalid character
;

_HexDecode:
  movwf   hex_temp
  sublw   0x2f
  btfsc   STATUS,C
  goto    _HexInvChar
  movf    hex_temp,W
  sublw   0x39
  btfss   STATUS,C
  goto    _HexChkAF
  movlw   0x30
  subwf   hex_temp,W
  bcf     STATUS,C
  return
_HexChkAF:
  movf    hex_temp,W
  sublw   0x40
  btfsc   STATUS,C
  goto    _HexInvChar
  movf    hex_temp,W
  sublw   0x46
  btfss   STATUS,C
  goto    _HexInvChar
  movlw   0x37
  subwf   hex_temp,W
  bcf     STATUS,C
  return  
_HexInvChar:
  bsf     STATUS,C
  retlw   0x00

;-----------------------------------------------------------------------
; Calculate 15-bit CRC
;
; Input: W = Number of bytes in VAN package (excluding CRC)
;        FSR register must point to the first byte in the VAN package
;
; Output: crc_h (MSB) and crc_l (LSB) inverted and rotated checksum
;         bit 0 of LSB is always zero.
;         FSR will point to the byte in packet where the MSB of CRC
;         shall be stored to.
;

_CalcCrc:
  movwf   crc_count   ; Bytes to calculate checksum for

  movlw   0xff        ; Setup CRC start value
  movwf   crc_l
  movwf   crc_h
  
_CrcByte:
  movlw   0x08        ; 8 bits in each byte
  movwf   crc_bit

_CrcBit:
  rlf     INDF,W      ; Load MSB into carry so buffer contents
  rlf     INDF,F      ; isn't destroyed while rotating each byte. 

  rlf     crc_l,F     ; Carry flag is rotated into CRC bit 0
  rlf     crc_h,F
  movlw   0x01        ; CRC bit 0 is used as flag if the CRC 
  btfsc   crc_h,7     ; polynom shall be xor:ed with CRC. Xor 
  xorwf   crc_l,F     ; this flag with MSB of CRC

  movlw   0x0f        ; If bit 0 (flag) is set, xor with polynom
  btfsc   crc_l,0
  xorwf   crc_h,F
  movlw   0x9c        ; Bit 0 is already set so 0x9c is used
  btfsc   crc_l,0     ; instead of 0x9d for least significant
  xorwf   crc_l,F     ; byte for polynom

  decfsz  crc_bit,F   ; Next bit
  goto    _CrcBit
  
  incf    FSR,F       ; Update pointer to next byte in buffer
  decfsz  crc_count,F ; Has all bytes been included in CRC?
  goto    _CrcByte    

  movlw   0xff        ; Invert CRC
  xorwf   crc_h,F
  xorwf   crc_l,F
  bcf     STATUS,C    ; Ensure bit 0 is cleared in CRC after
  rlf     crc_l,F     ; rotating it one bit to the left.
  rlf     crc_h,F

  return


;-----------------------------------------------------------------------
; Decode a received VAN packet 
;
; Destroys: FSR and IRP bit

_HexDecodePacket:
  bsf     STATUS,IRP      ; Point to packet buffer at 0x110 in RAM
  movlw   0x10
  movwf   FSR
  movwf   dec_ptr
  
  movf    INDF,W          ; Read length of packet without CRC
  andlw   0x3f
  movwf   dec_count
  movlw   0x02
  subwf   dec_count,F
  
  incf    dec_ptr,F       ; Move on to first data byte
  
_WriteDecByte:
  movf    dec_ptr,W       ; Read bit 7..4 of data byte and convert
  movwf   FSR             ; it to hex
  bsf     STATUS,IRP    
  swapf   INDF,W
  movwf   dec_temp
  call    _HexConv  
  call    _QueueRs232

  movf    dec_ptr,W       
  sublw   0x12
  btfss   STATUS,Z
  goto    _DecNotCmd
  movlw   ' '             ; Add a Space after addres
  call    _QueueRs232 
  movlw   'R'             ; Decode R/W
  btfss   dec_temp,5
  movlw   'W'
  call    _QueueRs232 
  movlw   'A'             ; Decode RAK
  btfss   dec_temp,6
  movlw   '-'
  call    _QueueRs232 
  movlw   'T'             ; Decode RTR 
  btfss   dec_temp,4
  movlw   '-'
  call    _QueueRs232   
  movlw   ' '             ; Add a Space after addres
  call    _QueueRs232 
  goto    _DecSkipLSB
  
_DecNotCmd:
  movf    dec_ptr,W       ; Read bit 3..0 of data byte and convert
  movwf   FSR             ; it to hex
  bsf     STATUS,IRP    
  movf    INDF,W
  call    _HexConv  
  call    _QueueRs232
  
_DecSkipLSB:
  
  incf    dec_ptr,F       ; Move on to next data byte
  decfsz  dec_count,F
  goto    _WriteDecByte

  movlw   ' '
  call    _QueueRs232

  movlw   0x10
  movwf   FSR
  
  movlw   '-'             ; Write an 'A' if an ACK was recived, '-' if not
  btfss   INDF,7
  movlw   'A'
  call    _QueueRs232
  
  movlw   0x0d            ; Write < CR > 
  call    _QueueRs232
  
  return


;-----------------------------------------------------------------------
; Add character to RS232 buffer
;
; Input:    W  : Character to add
;
; Output:   0x00 : Ok
;           0x01 : Buffer overflow, byte not queued
;
; Destroys: FSR and IRP bit

_QueueRs232:
  movwf   rs232_temp
  movf    rx232_bytes,W
  bsf     STATUS,RP0      ; Switch to register bank 1 
  btfsc   STATUS,Z
  btfss   TXSTA,TRMT      ; Check if Rs232 Tx in progrress
  goto    _AddToRs232Queue
  bcf     STATUS,RP0      ; Switch to register bank 0
  movf    rs232_temp,W
  movwf   TXREG           
  retlw   0x00
_AddToRs232Queue:
  bcf     STATUS,RP0      ; Switch to register bank 0
  sublw   0x40
  btfsc   STATUS,Z
  retlw   0x01            ; Queue is full - exit with code 0x01

  movf    rs232_txinptr,W ; Read byte from buffer 
  andlw   0x3f            
  addlw   0x30
  movwf   FSR
  bsf     STATUS,IRP      
  movf    rs232_temp,W    ; Add byte to queue
  movwf   INDF
  incf    rs232_txinptr,F
  incf    rx232_bytes,F
  retlw   0x00


;-----------------------------------------------------------------------
; Send RS232 buffer
;
; Output: W = x 0.6 us to wait after routine to remain sync
;
; Destroys: FSR and IRP bit

_SendRs232:
  bsf     STATUS,RP0      ; Switch to register bank 1 
  bsf     STATUS,IRP      ; Update FSR 9 th bit
  btfsc   TXSTA,TRMT      ; Exit if transmission queue is full
  goto    _ChkRs232Queue
  bcf     STATUS,RP0      ; Switch to register bank 0
  retlw   0x04            ; Yes - exit

_ChkRs232Queue:
  bcf     STATUS,RP0      ; Switch to register bank 0
  movf    rx232_bytes,W   ; Are there are any bytes to transmit?
  btfsc   STATUS,Z
  retlw   0x03            ; No - exit
  
  movf    rs232_txptr,W   ; Read byte from buffer 
  andlw   0x3f            
  addlw   0x30
  movwf   FSR
  movf    INDF,W          ; Sent the byte
  movwf   TXREG
  incf    rs232_txptr,F   ; Update pointer and counter
  decf    rx232_bytes,F   
  retlw   0x00  


;-----------------------------------------------------------------------
; Receive packet from VAN bus 
;
; Input: -
;
; Output: W = 0x00 : Read packet, no ACK
;             0x01 : Read packet, ACK received
;             0x02 : Buffer overflow (>31 bytes)
;             0x03 : Start not detected (low 32 us, high 32 us)

_VAN_rx:

  movlw   0x01            ; Setup pointer to packet length
  movwf   rx_bytes        ; (packet length is stored first in buffer)

  movlw   0x00-0x20
_Rx_Wait_Hi:              ; Wait for VAN to be low for maximum 32 us
  addlw   0x01
  btfsc   STATUS,Z
  retlw   0x03
  btfss   PORTA,0
  goto    _Rx_Wait_Hi
  bsf     PORTB,4
  bcf     PORTB,4

  movlw   0x00-0x17       ; Wait for VAN to be high during 32 us
_Rx_Wait_Lo:
  btfss   PORTA,0
  retlw   0x03
  addlw   0x01
  btfss   STATUS,Z
  goto    _Rx_Wait_Lo

  bsf     PORTB,4         ; Read syncronization bits and sync on 
  movlw   0x08            ; rising edge
  movwf   rx_input_buf
  bcf     PORTB,4
  movlw   0x0c    
  
_Rx_Nibble:               ; Receive 4 NRZ bits 
  movwf   rx_delay  
  
_Rx_Wait:                 ; Wait W * 0.6 us
  decfsz  rx_delay,F
  goto    _Rx_Wait
  
  rrf     PORTA,W         ; Read bit
  bsf     PORTB,4
  rlf     rx_input_buf,F  
  nop
  bcf     PORTB,4
  call    _SendRs232      ; Send any RS232 data from buffer
  addlw   0x03
  
  btfss   rx_input_buf,4  
  goto    _Rx_Nibble      ; < 4 bits has been read
  
  movlw   0x00            ; Sync on manchester coded bit
  btfss   rx_input_buf,0
  goto    _Rx_Sync0
  
_Rx_Sync1:
  btfss   PORTA,0         ; 0.0   (Sync on falling edge)
  goto    _Rx_Synced
  btfss   PORTA,0         ; 0.4
  goto    _Rx_Synced
  btfss   PORTA,0         ; 0.8
  goto    _Rx_Synced
  btfss   PORTA,0         ; 1.2
  goto    _Rx_Synced
  btfss   PORTA,0         ; 1.6
  goto    _Rx_Synced
  btfss   PORTA,0         ; 2.0
  goto    _Rx_Synced
  btfss   PORTA,0         ; 2.4
  goto    _Rx_Synced
  btfss   PORTA,0         ; 2.8
  goto    _Rx_Synced
  btfss   PORTA,0         ; 3.2
  goto    _Rx_Synced
  btfss   PORTA,0         ; 3.6
  goto    _Rx_Synced
  btfss   PORTA,0         ; 4.0
  goto    _Rx_Synced
  
  retlw   0x05
  
_Rx_Sync0:
  btfsc   PORTA,0         ; 0.0   (Sync on rising edge)
  goto    _Rx_Synced
  btfsc   PORTA,0         ; 0.4
  goto    _Rx_Synced
  btfsc   PORTA,0         ; 0.8
  goto    _Rx_Synced
  btfsc   PORTA,0         ; 1.2
  goto    _Rx_Synced
  btfsc   PORTA,0         ; 1.6
  goto    _Rx_Synced
  btfsc   PORTA,0         ; 2.0
  goto    _Rx_Synced
  btfsc   PORTA,0         ; 2.4
  goto    _Rx_Synced
  btfsc   PORTA,0         ; 2.8
  goto    _Rx_Synced
  btfsc   PORTA,0         ; 3.2
  goto    _Rx_Synced
  btfsc   PORTA,0         ; 3.6
  goto    _Rx_Synced
  btfsc   PORTA,0         ; 4.0
  goto    _Rx_Synced
  
  rrf     rx_bytes,W      ; Sync failed (no rising edge detected)
  andlw   0x1f            ; It must be EOP 
  addlw   0x10
  movwf   FSR
  bsf     STATUS,IRP

  swapf   INDF,F          ; Store last 4 bits of CRC
  movf    rx_input_buf,W
  andlw   0x0f
  iorwf   INDF,F

  movlw   0x10
  movwf   FSR
  
  movlw   0x1b            ; Wait for ACK bit
  movwf   rx_delay  
  
_Rx_Wait_Ack: 
  decfsz  rx_delay,F
  goto    _Rx_Wait_Ack

  movlw   0x00
  bsf     PORTB,4         
  btfsc   PORTA,0         ; Set bit 7 in packet legnth byte if no
  movlw   0x80            ; ACK pulse is detected
  movwf   INDF
  bcf     PORTB,4

  rrf     rx_bytes,W      ; Divide received bytes with 2
  andlw   0x3f
  iorwf   INDF,F          ; Store package length first in the buffer
  
  btfss   INDF,7
  retlw   0x01            ; Return 0x01 if ACK was detected
  retlw   0x00            ; Return 0x00 if not 
  
_Rx_Synced:
  rrf     rx_bytes,W      ; Syncronized in manchester bit
  andlw   0x1f
  addlw   0x10
  movwf   FSR
  bsf     STATUS,IRP
  
  btfss   rx_bytes,0      
  clrf    INDF

  swapf   INDF,F          ; Store 4 bits at a time in buffer
  movf    rx_input_buf,W
  andlw   0x0f
  iorwf   INDF,F
  
  incf    rx_bytes,F      ; Increase number of received groups of 4 bits
  
  movf    rx_bytes,W      ; Is the 32 byte buffer filled?
  sublw   0x40
  btfsc   STATUS,Z
  retlw   0x02            ; Error - buffer overflow. Return 0x02
  
  movlw   0x01
  movwf   rx_input_buf

  call    _SendRs232      ; Send any buffered RS232 data
  addlw   0x05

  goto    _Rx_Nibble      ; Receive next 4 bits
        

;-----------------------------------------------------------------------
; Send packet on VAN bus 
;
; Ensure the VAN bus has been "free" for atleast 96 us before calling
; this routine.
;
; Input:  W = Number of bytes in VAN package (including CRC)
;         Packet on address 0x110-0x0x12F (incl CRC)
;
; Output: W = 0x00 -> Transmission OK, no ACK
;             0x01 -> Transmission OK, got ACK
;             0x02 -> Transmission aborted by arbitation
;

_VAN_tx:
  movwf   tx_bytes
  incf    tx_bytes,F
  rlf     tx_bytes,F
  bcf     tx_bytes,0

  bsf     PORTB,4         
  nop
  nop
  bcf     PORTB,4

  movlw   0x0f
  movwf   FSR
  bsf     STATUS,IRP
  
  movlw   0x0e
  movwf   tx_byte_buf
  
_ByteLoop:
  
  nop
  nop
  
  swapf   tx_byte_buf,F
  movf    tx_byte_buf,W
  movwf   tx_output_buf
  
  btfsc   tx_bytes,0
  incf    FSR,F
  movf    INDF,W
  btfsc   tx_bytes,0
  movwf   tx_byte_buf
  
  rrf     tx_output_buf,W
  rlf     tx_output_buf,W
  xorlw   0x01
  movwf   tx_output_buf
  
  decf    tx_bytes,W
  btfsc   STATUS,Z
  bcf     tx_output_buf,0
  
  clrf    tx_nibblecnt
  movlw   0x02
  
_NibbleLoop:
  movwf   tx_delay        
_WaitDel0:
  decfsz  tx_delay,F
  goto    _WaitDel0
  
  btfsc   tx_output_buf,4 
  goto    _Bit0
  movlw   0x01
  bsf     PORTA,3         ; Bus=0
  incf    tx_nibblecnt,F    
  rlf     tx_output_buf,F 
  goto    _ChkArbitation  
_Bit0:
  bcf     PORTA,3         ; Bus=1
  incf    tx_nibblecnt,F    
  rlf     tx_output_buf,F 
  movf    PORTA,W
_ChkArbitation:
  andlw   0x01
  btfsc   STATUS,Z
  retlw   0x02            ; Collision -> Exit
                        
  movlw   0x08            
  btfsc   tx_nibblecnt,2
  btfss   tx_nibblecnt,0
  goto    _NibbleLoop
  
  decfsz  tx_bytes,F
  goto    _ByteLoop

  movlw   0x08
  movwf   tx_delay        ; Wait W * 0.6 us
_WaitDel1:
  decfsz  tx_delay,F
  goto    _WaitDel1
  nop
  
  bcf     PORTA,3

  movlw   0x14
  movwf   tx_delay        ; Wait W * 0.6 us
_WaitDel2:
  decfsz  tx_delay,F
  goto    _WaitDel2
  
  btfss   PORTA,0         ; Check of ACK
  retlw   0x01
  retlw   0x00


  END
