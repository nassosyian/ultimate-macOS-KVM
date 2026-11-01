#!/usr/bin/env python3
# pylint: disable=C0301,C0116,C0103,R0903

"""
Metal GPU acceleration (pvg-metal-vulkan): builds QEMU with the paravirtual GPU device,
collects its option ROM from the guest and boots the VM with it.
See pvg-metal-vulkan/README.md.

"""

# This script should NOT be run directly, but instead from the "extras.py" menu.


import os
import sys
sys.path.append('./resources/python')
from cpydColours import color

PVG = "./pvg-metal-vulkan"
QEMU = PVG+"/src/qemu/build/qemu-system-x86_64"
ROM = PVG+"/re/collected/collected/frameworks/ParavirtualizedGraphics.framework/Versions/A/Resources/AppleParavirtEFI.rom"


def clear(): print("\n" * 150)


def state(ok, yes, no):
    return (color.GREEN+"✔ "+yes if ok else color.YELLOW+"✖ "+no)+color.END


def startup():
    print("\n\n  "+color.BOLD+color.BLUE,"METAL GPU ACCELERATION"+color.END,"")
    print("   pvg-metal-vulkan\n")
    print("   Runs macOS Tahoe's Metal on your host GPU through Vulkan, with a paravirtual\n   GPU device for QEMU. Needs a Vulkan 1.3 GPU (tested on NVIDIA), LLVM 19 or newer\n   and Vulkan development files on the host, and a macOS Tahoe x86 guest.\n")
    print("   QEMU:   "+state(os.path.exists(QEMU), "built", "not built"))
    print("   ROM:    "+state(os.path.exists(ROM), "collected", "not collected")+"\n")
    print(color.BOLD+"      1. Build QEMU with the paravirtual GPU")
    print(color.END+"         Clones QEMU 11.1.3, applies the patches and builds it\n         (takes 10-20 minutes the first time)\n")
    print(color.END+"      2. Collect the option ROM from macOS (once)...")
    print(color.END+"      3. Boot macOS with Metal acceleration\n")
    print(color.END+"      B. Back...")
    print(color.END+"      Q. Exit\n")
    return str(input(color.BOLD+"Select> "+color.END))


def pause():
    input(color.BOLD+"\n   Press ENTER to return to the menu..."+color.END)


while True:
    clear()
    detectChoice = startup()
    clear()
    if detectChoice == "1":
        os.system(PVG+"/scripts/build-qemu.sh")
        pause()
    elif detectChoice == "2":
        print("\n\n   "+color.BOLD+color.GREEN+"COLLECT THE OPTION ROM"+color.END,"")
        print("   The VM will boot normally with a small transfer disk attached.\n   In macOS, open Terminal and run:\n")
        print(color.BOLD+"      sh /Volumes/PVGXFER/collect.sh rom\n"+color.END)
        print("   then shut the VM down. The ROM is copied back afterwards.\n")
        input(color.BOLD+"   Press ENTER to boot the VM..."+color.END)
        os.system(PVG+"/scripts/collect-rom.sh")
        pause()
    elif detectChoice == "3":
        if not os.path.exists(QEMU):
            print("\n\n   "+color.BOLD+color.YELLOW+"QEMU IS NOT BUILT YET"+color.END,"\n   Run option 1 first.")
        elif not os.path.exists(ROM):
            print("\n\n   "+color.BOLD+color.YELLOW+"THE OPTION ROM IS MISSING"+color.END,"\n   Run option 2 first.")
        else:
            os.system(PVG+"/scripts/run-pvg-vm.sh")
        pause()
    elif detectChoice == "b" or detectChoice == "B":
        os.execv('./scripts/extras.py', ['./scripts/extras.py'])
    elif detectChoice == "q" or detectChoice == "Q":
        break
