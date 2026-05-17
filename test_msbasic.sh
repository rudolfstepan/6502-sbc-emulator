#!/bin/bash
# Test MS BASIC startup by examining initial PC and memory

cd /home/rudolf/repos/6502

# Start in debug mode and immediately check PC
echo "r" | timeout 2 ./sbc6502 -d sbc.ini 2>&1 | grep -A5 "PC:"
