#!/bin/bash
#
# setPL.sh - Sets Intel Power Limit registers, allowing you to control the maximum
# power consumption of the chip (ie, "overclock" for higher performance)
#
# Useage: setPL.sh <PL1 value in watts> <PL2 value in watts>
# Example: ./setPL.sh 25 25
#
# This script sets the power limits of modern Intel processors. PL1 defines
# the lower limit (watts), which will apply when the CPU isn't boosting. PL2
# is the higher limit (watts), which will apply when the CPU is under load.
# The processor returns from PL2 to PL1 after a configured amount of time to
# avoid overheating, even if it's still under load. The purpose of this script
# is to defeat that, typically by setting PL1 and PL2 both to high values,
# including the same high value.
#
# There are two configuration registers which define the PL1/PL2 limits applied.
# One is the MSR register (Model-specific register), which is accessible via
# special CPU instructions. The other is the MMIO register (Memory-Mapped I/O
# register), which is accessible as a memory address within the PCI memory bar
# region assigned to the processor's PCIe root  complex. The processor will use
# the lower PL1/PL2 limits between the two registers, so for example if one is
# set to PL1/PL2 of 10/15 and the other set to 20/25, the processor will use 10/15.
# Complicating matters further is the fact that many vendors have system microcode
# that will dynamically change the MMIO version of PL1/PL2 based on thermals, which
# can defeat our ability to set higher limits. To prevent this we disable the PL1/PL2
# thresholds in the MMIO register, then set the "lock" bit within that register
# to prevent the system's microcode from changing it. This locked status persists
# for the duration of the power-on session.
#
# Many thanks and credit to the author of the Windows ThrottleStop application for
# finding and applying these techniques - I used the knowledge gained from that app
# to write this script
#

#
# general constants
#
TRUE=1
FALSE=0
APP_NAME="setPL"

#
# intel constants
#
INTEL_MSR_PKG_POWER_LIMIT=0x610
INTEL_PACKAGE_RAPL_LIMIT_0_0_0_MCHBAR_PCU=0x59a0
INTEL_PL1_ENABLE_BITS_LOW=0x00008000
INTEL_PL2_ENABLE_BITS_HIGH=0x00008000
INTEL_PL1_PL2_ENABLE_BITS=$((INTEL_PL1_ENABLE_BITS_LOW | (INTEL_PL2_ENABLE_BITS_HIGH<<32)))

#
# operational flags
#
F_DISABLE_MMIO_PL1_PL2=$TRUE    # if TRUE, MMIO reg is cleared (all bits set to zero, including PL1/PL2 enable bits)
                                # if FALSE, MMIO reg PL1/PL2 is enabled, with PL1/PL2 set to same value as MSR

#
# functions
#

#
# Parameters:   $1 - Hex address
# Return Value: Value read (hex ASCII)
# Terminates script on error
#
readPhysMemWord() {
    #
    # sample devmem2 output that we need to parse:
    #   Value at address 0xFEDC0000 (0x7efd68cf4000): 0xEF32C519
    #
    printf -v addrHex "0x%x" $1
    output=$(devmem2 $addrHex w 2>&1)
    if [ $? -eq 0 ]; then
        retVal=$(echo "$output" | sed -nE 's/Value at address.*: (0x[0-9A-E]+)/\1/p')
        if [ -z "$retVal" ]; then
            echo "Error parsing devmem2 read output"
            exit 1
        fi
        # else successful - fall through to return from function
    else
        echo "Error reading from physical memory via devmem2. If due to permissions you may need to disable Secure Boot."
        echo "devmem2 output: ${output}"
        exit 1
    fi
}


#
# Parameters:   $1 - Hex address
# Return Value: None
# Terminates script on error
#
writePhysMemWord() {
    printf -v addrHex "0x%x" $1
    printf -v val "0x%x" $2
    output=$(devmem2 $addrHex w $val 2>&1)
    if [ $? -ne 0 ]; then
        echo "Error writing to physical memory via devmem2. If due to permissions you may need to disable Secure Boot."
        echo "devmem2 output: ${output}"
        exit 1
    fi
}


#
# Parameters:   $1 - Hex address
# Return Value: Value read (hex ASCII)
# Terminates script on error
#
readMsr() {
    printf -v addrHex "0x%x" $1
    output=$(rdmsr --hexadecimal --zero-pad --c-language $addrHex 2>&1)
    if [ $? -ne 0 ]; then
        echo "Error reading MSR. If due to permissions you may need to disable Secure Boot."
        echo "rdmsr output: ${output}"
        exit 1
    fi
    retVal=$output
}


#
# Parameters:   $1 - Hex address
#               $2 - Hex value to write
# Return Value: None
# Terminates script on error
#
writeMsr() {
    printf -v addrHex "0x%x" $1
    printf -v val "0x%x" $2
    output=$(wrmsr $addrHex $val 2>&1)
    if [ $? -ne 0 ]; then
        echo "Error writing MSR. If due to permissions you may need to disable Secure Boot."
        echo "wrmsr output: ${output}"
        exit 1
    fi
}
printTurboStat_PL1_PL2() {
    turbostat sleep 0 2>&1 | grep MSR_PKG_POWER_LIMIT -A 2
}
verifyAppInstalled() {
    toolName=$1
    if ! command -v "$toolName" &> /dev/null; then
        # app not installed
       retVal=1 
    else
        retVal=0
    fi
}
verifyAppsInstalled() {
    local appsList
    local appsMissingList
    local appName
    appsList=("$@")
    appsMissingList=()
    for appName in "${appsList[@]}"; do
        verifyAppInstalled "$appName"
        if [ $retVal -eq 1 ]; then
            appsMissingList+=("$appName")
        fi
    done
    if [ ${#appsMissingList[@]} -gt 0 ]; then
        echo "The following apps must be installed to run ${APP_NAME}: ${appsMissingList[@]}"
        exit 1
    fi
}

verifyTurbostatInstallation() {
    # sample warning when turbostat not properly installed for running kernel:
    #   WARNING: turbostat not found for kernel 5.15.0-30
    output=$(turbostat 2>&1 --help | grep "WARNING: turbostat not found for kernel");
    if [ -n "$output" ]; then
        kernelVer=$(uname -r)
        echo "turbostat is installed but not the package needed for current kernel"
        echo "Maybe try sudo apt install linux-tools-${kernelVer}"
        exit 1
    fi
}

#
# script entry point
# arguments: <PL1 value in watts> <PL2 value in watts>
#
if [ "$#" != "2" ]; then
    echo "Usage: ${APP_NAME} <PL1 watts> <PL2 watts>"
    exit 1
fi
# convert values to micro-watts
PL1=$(($1 * 1000000))
PL2=$(($2 * 1000000))

# make sure script is running with root privilege
if [ $(id -u) -ne 0 ]; then
    echo "This script must be run with root privileges (root user or with 'sudo')"
    exit 1
fi

# make sure the necessary apps are installed
requiredApps=('devmem2' 'rdmsr' 'wrmsr' 'turbostat' 'setpci')
verifyAppsInstalled "${requiredApps[@]}"
verifyTurbostatInstallation

# print current values
echo "**** Current PL values from 'turbostat'"
printTurboStat_PL1_PL2

# set new PL1/PL2 values
echo "**** Setting PL1=$PL1 and PL2=$PL2 in /sys/class/powercap/intel-rapl/intel-rapl:0/constraint_*_power_limit_uw"
echo "$PL1" > /sys/class/powercap/intel-rapl/intel-rapl:0/constraint_0_power_limit_uw
echo "$PL2" > /sys/class/powercap/intel-rapl/intel-rapl:0/constraint_1_power_limit_uw

# enable both PL1 and PL2 (bit 15 and 47) if not already enabled
readMsr $INTEL_MSR_PKG_POWER_LIMIT; msr=$retVal
is_PL1_PL2_Enabled=$(((msr & INTEL_PL1_PL2_ENABLE_BITS) == INTEL_PL1_PL2_ENABLE_BITS))
if [ $is_PL1_PL2_Enabled -ne $TRUE ]; then
    echo "**** Enabling PL1 and PL2 in MSR_PKG_POWER_LIMIT"
    msr=$((msr | INTEL_PL1_PL2_ENABLE_BITS))
    writeMsr $INTEL_MSR_PKG_POWER_LIMIT $msr
else
    echo "**** PL1 and PL2 already enabled in MSR_PKG_POWER_LIMIT"
fi

echo "**** New PL values from 'turbostat'"
printTurboStat_PL1_PL2

#
# now handle the MMIO version of the power-limit register (PACKAGE_RAPL_LIMIT_0_0_0_MCHBAR_PCU)
#

# get the MCHBAR address, which is at config offset 0x48 in config space for the processor
mchbar="0x"$(setpci -s 00:00.0 48.l)
printf "**** MCHBAR is 0x%x\n" $mchbar
isMchbarEnabled=$(((mchbar & 0x1) != 0))
if [ $isMchbarEnabled -ne $TRUE ]; then
    echo "MCHBAR is not enabled!!!"
    exit 1
fi
mchbar=$((mchbar & ~1)) # clear off enable bit so value represents valid physical address

# calculate address of PACKAGE_RAPL_LIMIT_0_0_0_MCHBAR_PCU MMIO register
raplLimitAddr=$((mchbar + INTEL_PACKAGE_RAPL_LIMIT_0_0_0_MCHBAR_PCU))

# get the current value of PACKAGE_RAPL_LIMIT_0_0_0_MCHBAR_PCU
readPhysMemWord $((raplLimitAddr+0)); low=$retVal
readPhysMemWord $((raplLimitAddr+4)); high=$retVal
printf "**** Current value of PACKAGE_RAPL_LIMIT_0_0_0_MCHBAR_PCU = 0x%08x:0x%08x\n" $high $low

# set the new value for PACKAGE_RAPL_LIMIT_0_0_0_MCHBAR_PCU
isMMIOLocked=$(((high & 0x80000000) == 0x80000000))
if [ $isMMIOLocked -eq $TRUE ]; then
    if ((low & INTEL_PL1_ENABLE_BITS_LOW || high & INTEL_PL1_ENABLE_BITS_HIGH)); then
        # MMIO is locked but either PL1 and/or PL2 are enabled, meaning we can't disable PL1+PL2 this power-on session
        echo "**** Warning: MMIO limit reg already locked but with PL1 and/or PL2 enabled, can't change"
    else
        # MMIO is locked with PL1/PL2 disabled, likely from our script doing so on previous invocation this power-on session
        if [ $F_DISABLE_MMIO_PL1_PL2 -eq $TRUE ]; then
            echo "**** MMIO limit reg locked with PL1/PL2 disabled on previous invocation (expected)"
        else
            echo "**** Warning: MMIO limit already locked so can't set PL1/PL2 values in it"
        fi
    fi
else
    if [ $F_DISABLE_MMIO_PL1_PL2 -eq $TRUE ]; then
        # set MMIO to zero, which will also set the PL1/PL2 enable bits for the MMIO reg to FALSE
        lowNew=0x00000000;
        highNew=0x00000000;
    else
        # set MMIO to the same PL1/PL2 values as the MSR reg
        lowNew=$((msr & 0x00000000FFFFFFFF))
        highNew=$(((msr & 0xFFFFFFFF00000000)>>32))
    fi
    highNew=$((highNew | 0x80000000))   # set lock bit
    printf "**** Setting PACKAGE_RAPL_LIMIT_0_0_0_MCHBAR_PCU = 0x%08x:0x%08x\n" $highNew $lowNew
    writePhysMemWord $((raplLimitAddr+0)) $lowNew
    writePhysMemWord $((raplLimitAddr+4)) $highNew
fi

