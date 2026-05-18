#!/usr/bin/env python3
"""
Convert Donsol assembly labels from @ format to CA65 format
Original: reset@player -> reset_player
"""

import re
import sys

def convert_labels(asm_text):
    """Convert @ style labels to _ style"""
    
    # Replace label definitions: @label: -> label_sbc:
    # But only for labels not ending with @ 
    
    # Split by @module pattern and collect module names
    modules = re.findall(r';;.*?@(\w+)', asm_text)
    print(f"Found modules: {modules}", file=sys.stderr)
    
    # Replace all @-style references
    output = asm_text
    
    # Pattern 1: label@module: -> label_module:
    output = re.sub(r'(\w+)@(\w+):', r'\1_\2:', output)
    
    # Pattern 2: JSR label@module -> JSR label_module
    output = re.sub(r'(JSR|jsr|BRA|bra|BEQ|beq|BNE|bne|BCC|bcc|BCS|bcs)\s+(\w+)@(\w+)',
                     r'\1 \2_\3', output)
    
    # Pattern 3: CMP/LDA/STA etc with @-style addresses
    output = re.sub(r'([A-Z]{3})\s+(\w+)@(\w+)', r'\1 \2_\3', output)
    
    # Remove extra whitespace
    output = re.sub(r'\s+;', ' ;', output)
    
    return output

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("Usage: convert_labels.py <input.asm> [output.asm]")
        sys.exit(1)
    
    with open(sys.argv[1], 'r') as f:
        content = f.read()
    
    converted = convert_labels(content)
    
    output_file = sys.argv[2] if len(sys.argv) > 2 else sys.argv[1]
    with open(output_file, 'w') as f:
        f.write(converted)
    
    print(f"Converted {sys.argv[1]} -> {output_file}")
