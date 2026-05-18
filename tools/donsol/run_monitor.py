import pexpect
import sys

def run_monitor_and_dump():
    child = pexpect.spawn('../../bin/sbc6502 -r build/test_io.rom', encoding='utf-8')
    child.logfile = sys.stdout
    
    try:
        # Wait for the program to run for a bit
        child.expect(pexpect.TIMEOUT, timeout=1)
    except:
        pass

    # Send SIGINT to enter the monitor
    child.sendcontrol('c')
    
    # Wait for the monitor prompt
    child.expect('>')
    
    # Send dump memory command for $8000 (Video RAM)
    child.sendline('m 8000 100')
    child.expect('>')
    
    # Exit monitor
    child.sendline('q')
    child.close()

if __name__ == "__main__":
    run_monitor_and_dump()
