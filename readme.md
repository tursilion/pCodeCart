20261017

This is a port of the UCSD P-System card to cartridge. It includes the major files from EDT/FIL, COMPILER, and ASM/LNK on a new drive PSYS: mounted as #12. This allows the default utilities to all be accessed without any floppies. It also includes a roughly 40k flash drive mounted as #11, meaning you can use this without a disk system, or bring files around with just the cartridge. (You still need a 32k memory expansion though).

The system uses pretty much all of the TI's memory space. I opted not to delete any functions (*cough*Thermal Printer*cough*), and I'm pretty much out of the one free memory space I found. So, although I considered using the spare GROM flash as another drive, there isn't enough room for the driver (only a bit under 400 bytes free).

The primary code bank was moved out of the VDP memory and into GRAM, which also increased the size from 12k to 15k. It remains to be seen how much this helps, if at all. 

But it allows for 80 columns!

All that said:
- the system starts up a few seconds slower, at least in Classic99, I think because of the extra mounted drive. It's not too noticable given how long startup is anyway.
- the RAM area from >3A00 to >3FFF is now full of support code. If you were using it, you can't now.
- I'm not 100% sure the GROM/GRAM functionality will work with the cart now at the normal GROM ports. I'm not entirely sure what the GROM/GRAM functionality was used for. It's unlikely that GROM/GRAM disk expansion will work as the GROM access scheme now assumes it is talking to the built in OS: drive, in order to split it across GROM bases.
- Drive #11 and #12 are no longer available for DSK5/DSK6. Although you could steal it back the same way you always did, but you'll lose the flash drive and rom drive respectively.

Most of this porting effort was done with Claude, based on notes I wrote in the past, and the disassembly work/advice from Anders Persson. For what it's worth, even Claude took a few weeks to get this going smoothly.

One caveat - it's not deeply exercised as I don't really know how to use it. I ran through all the menu options, and I typed in, compiled, and executed a hello world, and Vorticon's port of my old sprite 'benchmark' program. Note that the system doesn't automatically find the sprite library on the ROM disk - you may have to copy it over to your working disk, or there may be a way to point at it - that's above my pay grade!

Unlike the original pCode card, this does not take over your system but rather boots as a standard cartridge named 'PSYS'. It takes about 30 seconds to come up to the main prompt, you'll hear periodic beeps as it runs through the processing. If you use HALT it will return to the title back, and do a fresh init the next time you enter the cart.

CLASSIC99

Classic99 can't drag and drop ubergrom carts, so you need to copy the INI settings in Classic99.txt into your Classic99.ini. Update numbers and paths to match your install.

Overdrive plays nicely, autorepeat is fixed as of 399.094a.

UberGROM

Hardware UberGROM cart is the sole target of this code, since emulation can run the real pCode anyway. Burn the ROM_8 to the 512k flash chip, the AVR_FLASH to the AVR's 128k flash region, and the AVR_EEPROM to the AVR's 4k EEPROM. PCODE_AVR_ConfigTab.png shows a snapshot of the programmer settings on my device, which is the same recommended settings for all UberGROMs. 

A non-ubergrom version is no longer available, since it won't have the RAM or flash devices.

ALTERNATE DISK DEVICES

The pCode card rather strictly expects a TI disk controller. VDP being laid out differently confuses it, causing issues. It also requires direct sector access to a disk device, as it maintains its own file system. The VDP layout issue used to cause crashes with TIPI and probably others, but the system will now attempt to correct for that. This doesn't promise that those devices will work with it, however!

