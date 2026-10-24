"""Capture launch/signing policy diagnostics when an actual simulator stage fails."""
import pathlib
import subprocess
import sys

device, destination = sys.argv[1:]
predicate = 'process == "amfid" OR process == "syspolicyd" OR eventMessage CONTAINS[c] "Minis" OR eventMessage CONTAINS[c] "ZEUSBrowserAnalysis"'
with pathlib.Path(destination).open("w") as output:
    try:
        subprocess.run(["xcrun", "simctl", "spawn", device, "log", "show", "--last", "4m", "--style", "compact", "--predicate", predicate], stdout=output, stderr=subprocess.STDOUT, timeout=20, check=False)
    except subprocess.TimeoutExpired:
        output.write("\nSystem-log collection timed out after 20 seconds.\n")
