

# setPL
Linux script for setting the PL1/PL2 power limits on modern Intel processors

## Installation
Download the script by right-clicking on [setPL.h](https://raw.githubusercontent.com/horshack-dpreview/setPL/master/setPL.sh) and choosing "Save Link As..." After downloading, make it executable via "chmod +x setPL.sh"

## Use
`./setPL.sh <PL1 watts> <PL2 watts>`

Example: `./setPL.sh 25 25`

## Sample Output

    $ sudo ./setPL.sh 25 30
    [sudo] password for user: 
    **** Current PL values from 'turbostat'
    cpu0: MSR_PKG_POWER_LIMIT: 0x5c0280001e8640 (UNlocked)
    cpu0: PKG Limit #1: ENabled (200.000000 Watts, 32.000000 sec, clamp DISabled)
    cpu0: PKG Limit #2: DISabled (80.000000 Watts, 20.000000* sec, clamp DISabled)
    **** Setting PL1=25000000 and PL2=30000000 in /sys/class/powercap/intel-rapl/intel-rapl:0/constraint_*_power_limit_uw
    **** Enabling PL1 and PL2 in MSR_PKG_POWER_LIMIT
    **** New PL values from 'turbostat'
    cpu0: MSR_PKG_POWER_LIMIT: 0x5c80f0001e80c8 (UNlocked)
    cpu0: PKG Limit #1: ENabled (25.000000 Watts, 32.000000 sec, clamp DISabled)
    cpu0: PKG Limit #2: ENabled (30.000000 Watts, 20.000000* sec, clamp DISabled)
    **** MCHBAR is 0xfedc0001
    **** Current value of PACKAGE_RAPL_LIMIT_0_0_0_MCHBAR_PCU = 0x00438280:0x001f8118
    **** Setting PACKAGE_RAPL_LIMIT_0_0_0_MCHBAR_PCU = 0x80000000:0x00000000


## Tech Details
On modern Intel processors, PL1 defines the lower limit of power consumption (watts), which applies when the CPU is under low load. PL2 is the higher limit, which applies when the CPU is under heavy load and is temporarily boosted (overclocked). To avoid overheating, the processor returns from PL2 to PL1 after a configured amount of time, even if it's still under load. The purpose of this script is to defeat that mechanism, so that the processor performs better under longer stretches under load. This is particularly applicable to notebooks, where vendors can use overly-conservative PL1/PL2 values.

I typically set PL1 and PL2 to the same equal values. This doesn't mean the processor run at PL1 constantly (consuming more power) - it'll still down-clock to low frequencies/power when CPU load is low.

 There are two configuration registers which define the PL1/PL2 limits applied. One is the MSR register (Model-specific register), which is accessible via special CPU instructions. The other is the MMIO register (Memory-Mapped I/O register), which is accessible as a memory address within the PCI memory bar region assigned to the processor's PCIe root  complex. The processor will use the lower PL1/PL2 limits between the two registers, so for example if one is set to PL1/PL2 of 10/15 and the other set to 20/25, the processor will use 10/15. Complicating matters further is the fact that many vendors have system microcode that will dynamically change the MMIO version of PL1/PL2 based on thermals, which can defeat our ability to set higher limits. To prevent this we disable the PL1/PL2 thresholds in the MMIO register, then set the "lock" bit within that register to prevent the system's microcode from changing it. This locked status persists for the duration of the power-on session.

Many thanks and credit to the author of the Windows ThrottleStop application for finding and applying these techniques - I used the knowledge gained from that app to write this script

## System Requirements
Most Linux installations require Secure Boot to be disabled in order to access the Intel MSRs (Model-specific registers) and physical memory.

## Finding the optimal PL1/PL2 values
Most Intel processors will thermal throttle at 100C, so you generally want to set PL1/PL2 to values somewhat below to where the processor will reach 100C. Use whatever temperature you feel comfortable with. My comfort level is at around 90C.

To find the optimal PL1/PL2 values I generate a 100% CPU load using [stress-ng](https://wiki.ubuntu.com/Kernel/Reference/stress-ng), while monitoring the CPU temperatures using [turbostat](https://www.linux.org/docs/man8/turbostat.html). Here is how I run those tools:

`stress-ng --cpu=8 --cpu-method matrixprod --metrics-brief -t 60`

Set `--cpu` to the number of cores in your system, including Hyperthreaded cores. You can find the number via `cat /proc/cpuinfo | grep -m 1 "siblings"`

While running stress-ng, run turbostat in a another terminal session to monitor the CPU load and temps:

`turbostat --quiet --interval 1 --cpu 0-3 --show "PkgWatt","Busy%","Core","CoreTmp"`

Set `--cpu` to the range of physical cores (not including Hyperthreaded cores). You can find this number via `cat /proc/cpuinfo | grep -m 1 "cpu cores"`

