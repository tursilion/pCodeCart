  def _start

# GROM header
  byte 0xAA, 0x01, 0x00, 0x00

# Start of power-up chain (unused)
  data 0x0000

# Start of program chain
  data program_record

# Start of DSR chain (unused) AND
# Start of subprogram list (unused)
# This doubles as the terminator of the program chain
program_record:
  data  0x0000    # Next program chain record
  data  main    # Entry point for program
  nstring "M.WARD'S  \"STRANGER\""  # Name of program
  even

# just copy the program into RAM
main
_start
  CLR @0x6000    # set the bank
  LWPI 0x8300    # other bank will jump to here
  LI r0,0x6040   # src
  LI r1,0x2080   # dest
  LI r2,0x0BB6   # count
mlp
  MOV *r0+,*r1+
  DECT r2
  JNE mlp
  
  B @0x2080
  
  END
    