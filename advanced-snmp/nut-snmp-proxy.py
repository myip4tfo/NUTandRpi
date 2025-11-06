#!/usr/bin/env python3

# NUT to Standard UPS-MIB (RFC 1628) Proxy Agent
# This script is designed to be called by snmpd via 'pass_persist'.
# It listens for OID requests on stdin and prints results to stdout.

import sys
import subprocess
import time
import logging

# --- Configuration ---
# The OID base we are responsible for. snmpd will send us requests for OIDs
# *under* this base.
BASE_OID = ".1.3.6.1.2.1.33"

# The name of the UPS to query, as defined in /etc/nut/ups.conf
# We use @localhost to ensure we're talking to the local daemon.
NUT_UPS_NAME = "nutdev1@localhost"

# Set up logging to stderr. snmpd will redirect this to /var/log/syslog
logging.basicConfig(stream=sys.stderr, level=logging.INFO, 
                    format='[nut-snmp-proxy] %(levelname)s: %(message)s')

def get_upsc_value(var):
    """
    Runs upsc and returns the value for a given variable.
    Returns None if the command fails or returns no output.
    """
    try:
        result = subprocess.run(['/bin/upsc', NUT_UPS_NAME, var], 
                                capture_output=True, text=True, timeout=5, check=True)
        value = result.stdout.strip()
        if value:
            return value
        else:
            logging.warning(f"upsc returned empty value for {var}")
            return None
    except subprocess.CalledProcessError as e:
        # This often happens if the variable doesn't exist (e.g., input.current on a battery)
        logging.debug(f"upsc command failed for {var}: {e.stderr.strip()}")
        return None
    except Exception as e:
        logging.error(f"Error running upsc for {var}: {e}")
        return None

def convert_status_to_int(status_str):
    """
    Converts NUT status string to standard UPS-MIB integer.
    upsBatteryStatus: unknown(1), batteryNormal(2), batteryLow(3)
    
    NUT statuses are space-separated, e.g., "OL CHRG" (Online, Charging)
    """
    if "LB" in status_str:
        return 3 # batteryLow
    if "OL" in status_str or "OB" in status_str:
        return 2 # batteryNormal (Online or OnBattery)
    return 1 # unknown

# Mapping from Standard MIB OID to:
# ( nut_variable, snmp_data_type, [optional_conversion_lambda] )
OID_MAP = {
    # upsIdent
    ".1.3.6.1.2.1.33.1.1.1.0": ("device.mfr", "STRING"),
    ".1.3.6.1.2.1.33.1.1.2.0": ("device.model", "STRING"),
    ".1.3.6.1.2.1.33.1.1.5.0": ("device.serial", "STRING"),
    
    # upsBattery
    ".1.3.6.1.2.1.33.1.2.1.0": ("ups.status", "INTEGER", convert_status_to_int),
    ".1.3.6.1.2.1.33.1.2.3.0": ("battery.runtime", "GAUGE", lambda x: int(x) // 60), # Convert sec to min
    ".1.3.6.1.2.1.33.1.2.4.0": ("battery.charge", "GAUGE"), # %
    ".1.3.6.1.2.1.33.1.2.5.0": ("battery.voltage", "GAUGE", lambda x: int(float(x) * 10)), # MIB wants 1/10 V
    
    # upsInput
    # .1.3.6.1.2.1.33.1.3.3.1.2.1 = upsInputVoltage (assumes line 1)
    ".1.3.6.1.2.1.33.1.3.3.1.2.1": ("input.voltage", "GAUGE"),
    # .1.3.6.1.2.1.33.1.3.3.1.3.1 = upsInputCurrent (assumes line 1)
    ".1.3.6.1.2.1.33.1.3.3.1.3.1": ("input.current", "GAUGE", lambda x: int(float(x) * 10)), # MIB wants 1/10 A
    # .1.3.6.1.2.1.33.1.3.3.1.4.1 = upsInputFrequency (assumes line 1)
    ".1.3.6.1.2.1.33.1.3.3.1.4.1": ("input.frequency", "GAUGE", lambda x: int(float(x) * 10)), # MIB wants 1/10 Hz
    
    # upsOutput
    # .1.3.6.1.2.1.33.1.4.4.1.2.1 = upsOutputVoltage (assumes line 1)
    ".1.3.6.1.2.1.33.1.4.4.1.2.1": ("output.voltage", "GAUGE"),
    # .1.3.6.1.2.1.33.1.4.4.1.3.1 = upsOutputCurrent (assumes line 1)
    ".1.3.6.1.2.1.33.1.4.4.1.3.1": ("output.current", "GAUGE", lambda x: int(float(x) * 10)), # MIB wants 1/10 A
    # .1.3.6.1.2.1.33.1.4.4.1.4.1 = upsOutputPower (assumes line 1) -> Real Power in Watts
    ".1.3.6.1.2.1.33.1.4.4.1.4.1": ("ups.realpower", "INTEGER"), # Watts
    # .1.3.6.1.2.1.33.1.4.4.1.5.1 = upsOutputPercentLoad (assumes line 1)
    ".1.3.6.1.2.1.33.1.4.4.1.5.1": ("ups.load", "GAUGE"), # %
}

# We need a sorted list of OIDs to handle GETNEXT
SORTED_OIDS = sorted(OID_MAP.keys())

def print_snmp_response(oid, snmp_type, value):
    """Formats and prints the response for snmpd."""
    print(oid)
    print(snmp_type)
    print(value)

def handle_get(oid):
    """Handles a GET request for a specific OID."""
    if oid not in OID_MAP:
        print("NONE") # SNMP "no such object"
        return

    var, snmp_type, *converter = OID_MAP[oid]
    
    value = get_upsc_value(var)
    if value is None:
        print("NONE")
        return

    try:
        if converter:
            value = converter[0](value) # Apply conversion function if it exists
        
        print_snmp_response(oid, snmp_type, value)
    except Exception as e:
        logging.error(f"Error processing value for {oid} ({var}): {e}")
        print("NONE")

def handle_getnext(oid):
    """
    Handles a GETNEXT request.
    Finds the next OID in our sorted list that is *after* the requested one.
    """
    for i, current_oid in enumerate(SORTED_OIDS):
        # Find the first OID that is numerically greater than the one requested
        if oid_to_tuple(current_oid) > oid_to_tuple(oid):
            handle_get(current_oid) # Handle GET for this "next" OID
            return
            
    # If we loop and find nothing, we are at the end of our MIB
    print("NONE")

def oid_to_tuple(oid_str):
    """Converts a dotted OID string to a tuple of integers for easy comparison."""
    return tuple(map(int, oid_str.strip('.').split('.')))

def main_loop():
    """Main loop, listening to stdin for requests from snmpd."""
    try:
        while True:
            # Wait for a line from stdin
            line = sys.stdin.readline().strip()
            if not line:
                if sys.stdin.closed:
                    logging.info("stdin closed, exiting.")
                    break
                # If stdin is not closed, it might be an empty line, just continue
                time.sleep(0.1)
                continue

            command = line.lower()

            if command == "ping":
                print("PONG")
            elif command.startswith("get"):
                _, oid = line.split()
                handle_get(oid)
            elif command.startswith("getnext"):
                _, oid = line.split()
                # Start searching from the OID requested.
                # If the OID is *in* our MIB, we must return the *next* one.
                # If the OID is *before* our MIB, we return the *first* one.
                if oid_to_tuple(oid) < oid_to_tuple(SORTED_OIDS[0]):
                    handle_get(SORTED_OIDS[0])
                else:
                    handle_getnext(oid)
            else:
                logging.warning(f"Received unknown command: {line}")

            # Flush stdout to ensure snmpd gets the response
            sys.stdout.flush()

    except KeyboardInterrupt:
        logging.info("Received KeyboardInterrupt, exiting.")
    except Exception as e:
        logging.error(f"Unhandled exception in main loop: {e}", exc_info=True)
    finally:
        logging.info("Shutting down proxy.")

if __name__ == "__main__":
    # We must run unbuffered
    try:
        sys.stdin = open(sys.stdin.fileno(), 'r', buffering=1)
        sys.stdout = open(sys.stdout.fileno(), 'w', buffering=1)
    except Exception as e:
        logging.error(f"Failed to set unbuffered I/O: {e}")
        sys.exit(1)
    
    logging.info(f"Starting nut-snmp-proxy agent for {NUT_UPS_NAME}.")
    main_loop()
