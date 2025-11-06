#!/usr/bin/env python3

# NUT to Standard UPS-MIB (RFC 1628) Standalone SNMP Agent
# This script runs as a standalone SNMP agent using pysnmp.
# It listens for SNMPv3 requests and serves data fetched from NUT.

import sys
import subprocess
import logging
import argparse
import threading

try:
    from pysnmp.entity import engine, config
    from pysnmp.entity.rfc3413 import cmdrsp, context
    from pysnmp.carrier.asyncore.dgram import udp
    from pysnmp.smi import builder, instrum, view, rfc1902
    from pyasn1.type import univ
except ImportError:
    print("Error: pysnmp library not found. Please install with: pip3 install pysnmp", file=sys.stderr)
    sys.exit(1)

# --- Configuration ---
NUT_UPS_NAME = "nutdev1@localhost"

# --- Logging Setup ---
logging.basicConfig(stream=sys.stdout, level=logging.INFO,
                    format='[%(asctime)s] [%(levelname)s] %(message)s')

# --- Data Fetching ---
def get_upsc_value(var):
    """
    Runs upsc and returns the value for a given variable.
    Returns None on any error.
    """
    try:
        # Use the full path for upsc to avoid PATH issues when run as a service
        result = subprocess.run(['/bin/upsc', NUT_UPS_NAME, var],
                                capture_output=True, text=True, timeout=5, check=True)
        value = result.stdout.strip()
        if value:
            return value
        else:
            logging.warning(f"upsc returned empty value for {var}")
            return None
    except subprocess.CalledProcessError as e:
        logging.debug(f"upsc failed for {var}: {e.stderr.strip()}")
        return None
    except FileNotFoundError:
        logging.error(f"Cannot find /bin/upsc. Ensure NUT is installed correctly.")
        return None
    except Exception as e:
        logging.error(f"Unhandled error running upsc for {var}: {e}")
        return None

# --- Data Conversion ---
def convert_status_to_int(status_str):
    """
    Converts NUT status string (e.g., "OL CHRG") to standard UPS-MIB integer.
    upsBatteryStatus: unknown(1), batteryNormal(2), batteryLow(3), depleted(4)
    """
    if "LB" in status_str:
        return 3  # batteryLow
    if "OL" in status_str or "OB" in status_str:
        # "OL" = Online, "OB" = On Battery. Both are considered "normal".
        return 2  # batteryNormal
    if "RB" in status_str or "BYPASS" in status_str:
        return 2 # Also consider "Replace Battery" and "Bypass" as normal states for this value
    return 1  # unknown

# --- OID Mapping ---
# Mapping from Standard MIB OID to:
# ( nut_variable, snmp_data_type_str, [optional_conversion_lambda] )
OID_MAP = {
    # upsIdent
    "1.3.6.1.2.1.33.1.1.1.0": ("device.mfr", "STRING"),
    "1.3.6.1.2.1.33.1.1.2.0": ("device.model", "STRING"),
    "1.3.6.1.2.1.33.1.1.5.0": ("device.serial", "STRING"),
    # upsBattery
    "1.3.6.1.2.1.33.1.2.1.0": ("ups.status", "INTEGER", convert_status_to_int),
    "1.3.6.1.2.1.33.1.2.2.0": ("battery.runtime", "INTEGER"), # Seconds
    "1.3.6.1.2.1.33.1.2.4.0": ("battery.charge", "GAUGE"),  # Percentage
    "1.3.6.1.2.1.33.1.2.5.0": ("battery.voltage", "GAUGE", lambda x: int(float(x) * 10)),  # MIB wants 1/10 V
    # upsInput
    "1.3.6.1.2.1.33.1.3.3.1.2.1": ("input.voltage", "GAUGE"),
    "1.3.6.1.2.1.33.1.3.3.1.3.1": ("input.current", "GAUGE", lambda x: int(float(x) * 10)), # MIB wants 1/10 A
    "1.3.6.1.2.1.33.1.3.3.1.4.1": ("input.frequency", "GAUGE", lambda x: int(float(x) * 10)), # MIB wants 1/10 Hz
    # upsOutput
    "1.3.6.1.2.1.33.1.4.4.1.2.1": ("output.voltage", "GAUGE"),
    "1.3.6.1.2.1.33.1.4.4.1.3.1": ("output.current", "GAUGE", lambda x: int(float(x) * 10)), # MIB wants 1/10 A
    "1.3.6.1.2.1.33.1.4.4.1.4.1": ("ups.realpower", "INTEGER"),  # Watts
    "1.3.6.1.2.1.33.1.4.4.1.5.1": ("ups.load", "GAUGE"),  # Percentage
}

SNMP_TYPE_MAP = {
    'STRING': rfc1902.OctetString,
    'INTEGER': rfc1902.Integer32,
    'GAUGE': rfc1902.Gauge32,
}

# --- MIB Instrumentation ---
# This class factory creates a MibScalarInstance subclass for a given NUT variable.
def make_mib_scalar_instance(nut_var, snmp_type_class, converter=None):
    class MibScalar(instrum.MibScalarInstance):
        def getValue(self, name, idx):
            # This method is called by the pysnmp engine when a GET/GETNEXT request comes in.
            raw_value = get_upsc_value(nut_var)
            if raw_value is None:
                # To comply with SNMP, we must return an object of the expected type.
                # Returning a "zero" equivalent is a safe default.
                logging.warning(f"Returning default value for {nut_var} as upsc fetch failed.")
                return self.syntax.clone(0 if self.syntax.isSuperTypeOf(rfc1902.Integer32(0)) else "")

            try:
                # Apply conversion if one is defined
                processed_value = converter(raw_value) if converter else raw_value
                # Cast to the final pysnmp object type and return
                return self.syntax.clone(processed_value)
            except Exception as e:
                logging.error(f"Failed to process value '{raw_value}' for {nut_var}: {e}")
                return self.syntax.clone(0 if self.syntax.isSuperTypeOf(rfc1902.Integer32(0)) else "")

    return MibScalar

def main():
    # --- Argument Parsing ---
    parser = argparse.ArgumentParser(description="NUT to SNMP MIB Standalone Agent")
    parser.add_argument("--snmp-user", required=True, help="SNMPv3 username")
    parser.add_argument("--auth-key", required=True, help="SNMPv3 authentication key")
    parser.add_argument("--priv-key", required=True, help="SNMPv3 privacy (encryption) key")
    parser.add_argument("--agent-address", default="0.0.0.0", help="IP address to listen on")
    parser.add_argument("--agent-port", type=int, default=161, help="Port to listen on")
    parser.add_argument("--debug", action="store_true", help="Enable DEBUG logging")
    args = parser.parse_args()

    if args.debug:
        logging.getLogger().setLevel(logging.DEBUG)

    # --- SNMP Engine Setup ---
    snmp_engine = engine.SnmpEngine()

    # --- SNMPv3 USM Configuration ---
    config.addV3User(
        snmp_engine,
        userName=args.snmp_user,
        authProtocol=config.usmHMACSHAAuthProtocol,
        authKey=args.auth_key,
        privProtocol=config.usmAesCfb128Protocol,
        privKey=args.priv_key,
    )

    # --- Transport Endpoint ---
    # Listen on all interfaces by default
    listen_address = (args.agent_address, args.agent_port)
    config.addTransport(
        snmp_engine,
        udp.domainName,
        udp.UdpTransport().openServerMode(listen_address)
    )

    # --- MIB and Instrumentation Setup ---
    mib_builder = builder.MibBuilder()
    mib_instrum = instrum.MibInstrumController(mib_builder)
    
    # Dynamically build the MIB from our OID_MAP
    for oid, (nut_var, snmp_type_str, *converter) in OID_MAP.items():
        oid_tuple = tuple(int(x) for x in oid.split('.'))
        snmp_type_class = SNMP_TYPE_MAP[snmp_type_str]
        converter_func = converter[0] if converter else None

        # Create the specialized class for this OID
        ScalarInstanceClass = make_mib_scalar_instance(nut_var, snmp_type_class, converter_func)
        
        # Instantiate and export the symbol to the MIB builder
        mib_builder.exportSymbols(
            '__MY_MIB', # The name can be arbitrary
            ScalarInstanceClass(oid_tuple, snmp_type_class())
        )

    # --- SNMP Context and Command Responder ---
    snmp_context = context.SnmpContext(snmp_engine)
    cmdrsp.GetCommandResponder(snmp_engine, snmp_context)
    cmdrsp.NextCommandResponder(snmp_engine, snmp_context)
    # Note: We do not add a SetCommandResponder, making our agent read-only.
    
    # Register the MIB view with the SNMP context
    config.addContext(snmp_engine, '', mib_instrum)

    # --- Run the Agent ---
    logging.info(f"Starting SNMP agent at {listen_address} for user '{args.snmp_user}'...")
    snmp_engine.transportDispatcher.jobStarted(1)
    
    try:
        snmp_engine.transportDispatcher.runDispatcher()
    except Exception as e:
        logging.error(f"Agent failed: {e}")
        snmp_engine.transportDispatcher.closeDispatcher()
        raise
    except KeyboardInterrupt:
        logging.info("Shutting down SNMP agent.")
    finally:
        snmp_engine.transportDispatcher.closeDispatcher()

if __name__ == "__main__":
    main()
