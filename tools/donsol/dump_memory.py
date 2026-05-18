import subprocess
import time
import os

def run_test():
    # Run the emulator for a short period and capture stdout/stderr
    try:
        process = subprocess.Popen(['../../bin/sbc6502', '-r', 'build/test_io.rom'], 
                                   stdout=subprocess.PIPE, 
                                   stderr=subprocess.PIPE,
                                   text=True)
        time.sleep(2)
        process.terminate()
        stdout, stderr = process.communicate()
        return stdout, stderr
    except Exception as e:
        return "", str(e)

if __name__ == "__main__":
    stdout, stderr = run_test()
    print("STDOUT:")
    print(stdout)
    print("STDERR:")
    print(stderr)
