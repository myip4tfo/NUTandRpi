#!/usr/bin/env python3

# NUT to Standard UPS-MIB (RFC 1628) Standalone SNMP Agent
# This script runs as a standalone SNMP agent using pysnmp and asyncio.

import sys
import subprocess
import logging
import argparse
import asyncio

try:
    from pysnmp.entity import engine, config
    from pysnmp.entity.rfc3413 import cmdrsp, context
    from pysnmp.carrier.asyncio.dgram import udp
    from pysnmp.smi import builder, instrum
    # Import the `univ` module from pyasn1 for base ASN.1 types
    from pyasn1.type import univ
    # Import the specific SNMP data types from their new MIB location
    from pysnmp.smi.mibs.SNMPv2_SMI import Integer32, Gauge32
except ImportError as e:
    print(f"Error: Failed to import pysnmp or pyasn1 library: {e}", file=sys.stderr)
    print("Please ensure pysnmp is installed in the virtual environment.", file=sys.stderr)
    sys.exit(1)

# --- Configuration ---
NUT_UPS_NAME = "nutdev1@localhost"

# --- Logging Setup ---
logging.basicConfig(stream=sys.stdout, level=logging.INFO,
                    format='[%(asctime)s] [%(levelname)s] %(message)s')

# --- Data Fetching ---
def get_upsc_value(var):
    """
    Runs upsc and returns the value for a given variable. Returns None on error.
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
        logging.debug(f"upsc failed for {var}: {e.stderr.strip()}")
        return None
    except FileNotFoundError:
        logging.error("Cannot find /bin/upsc. Ensure NUT is installed correctly.")
        return None
    except Exception as e:
        logging.error(f"Unhandled error running upsc for {var}: {e}")
        return None

# --- Data Conversion ---
def convert_status_to_int(status_str):
    if "LB" in status_str: return 3  # batteryLow
    if "OL" in status_str or "OB" in status_str: return 2  # batteryNormal
    if "RB" in status_str or "BYPASS" in status_str: return 2
    return 1  # unknown

# --- OID Mapping ---
OID_MAP = {
    "1.3.6.1.2.1.33.1.1.1.0": ("device.mfr", "STRING"),
    "1.3.6.1.2.1.33.1.1.2.0": ("device.model", "STRING"),
    "1.3.6.1.2.1.33.1.1.5.0": ("device.serial", "STRING"),
    "1.3.6.1.2.1.33.1.2.1.0": ("ups.status", "INTEGER", convert_status_to_int),
    "1.3.6.1.2.1.33.1.2.2.0": ("battery.runtime", "INTEGER"),
    "1.3.6.1.2.1.33.1.2.4.0": ("battery.charge", "GAUGE"),
    "1.3.6.1.2.1.33.1.2.5.0": ("battery.voltage", "GAUGE", lambda x: int(float(x) * 10)),
    "1.3.6.1.2.1.33.1.3.3.1.2.1": ("input.voltage", "GAUGE"),
    "1.3.6.1.2.1.33.1.3.3.1.3.1": ("input.current", "GAUGE", lambda x: int(float(x) * 10)),
    "1.3.6.1.2.1.33.1.3.3.1.4.1": ("input.frequency", "GAUGE", lambda x: int(float(x) * 10)),
    "1.3.6.1.2.1.33.1.4.4.1.2.1": ("output.voltage", "GAUGE"),
    "1.3.6.1.2.1.33.1.4.4.1.3.1": ("output.current", "GAUGE", lambda x: int(float(x) * 10)),
    "1.3.6.1.2.1.33.1.4.4.1.4.1": ("ups.realpower", "INTEGER"),
    "1.3.6.1.2.1.33.1.4.4.1.5.1": ("ups.load", "GAUGE"),
}

# Correct mapping for modern pysnmp/pyasn1
SNMP_TYPE_MAP = {
    'STRING': univ.OctetString,
    'INTEGER': Integer32,
    'GAUGE': Gauge32,
}

# --- MIB Instrumentation ---
def make_mib_scalar_instance(nut_var, snmp_type_class, converter=None):
    class MibScalar(instrum.MibScalarInstance):
        def getValue(self, name, idx):
            raw_value = get_upsc_value(nut_var)
            if raw_value is None:
                logging.warning(f"Returning default value for {nut_var} as upsc fetch failed.")
                # For strings, return empty string, otherwise 0.
                return self.syntax.clone("" if issubclass(self.syntax.__class__, univ.OctetString) else 0)
            try:
                processed_value = converter(raw_value) if converter else raw_value
                return self.syntax.clone(processed_value)
            except Exception as e:
                logging.error(f"Failed to process value '{raw_value}' for {nut_var}: {e}")
                return self.syntax.clone("" if issubclass(self.syntax.__class__, univ.OctetString) else 0)
    return MibScalar

async def main():
    parser = argparse.ArgumentParser(description="NUT to SNMP MIB Standalone Agent")
    parser.add_argument("--snmp-user", required=True, help="SNMPv3 username")
    parser.add_argument("--auth-key", required=True, help="SNMPv3 authentication key")
    parser.add_argument("--priv-key", required=True, help="SNMPv3 privacy key")
    parser.add_argument("--agent-address", default="0.0.0.0", help="IP address to listen on")
    parser.add_argument("--agent-port", type=int, default=161, help="Port to listen on")
    parser.add_argument("--debug", action="store_true", help="Enable DEBUG logging")
    args = parser.parse_args()

    if args.debug:
        logging.getLogger().setLevel(logging.DEBUG)

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
    listen_address = (args.agent_address, args.agent_port)
    config.addTransport(
        snmp_engine,
        udp.domainName,
        udp.UdpTransport().openServerMode(listen_address)
    )

    # --- MIB and Instrumentation Setup ---
    mib_builder = builder.MibBuilder()
    mib_instrum = instrum.MibInstrumController(mib_builder)

    for oid, (nut_var, snmp_type_str, *converter) in OID_MAP.items():
        oid_tuple = tuple(int(x) for x in oid.split('.'))
        snmp_type_class = SNMP_TYPE_MAP[snmp_type_str]
        converter_func = converter[0] if converter else None
        ScalarInstanceClass = make_mib_scalar_instance(nut_var, snmp_type_class, converter_func)
        mib_builder.exportSymbols('__MY_MIB', ScalarInstanceClass(oid_tuple, snmp_type_class()))

    # --- SNMP Context and Command Responder ---
    snmp_context = context.SnmpContext(snmp_engine)
    cmdrsp.GetCommandResponder(snmp_engine, snmp_context)
    cmdrsp.NextCommandResponder(snmp_engine, snmp_context)
    config.addContext(snmp_engine, '', mib_instrum)

    # --- Run the Agent ---
    logging.info(f"Starting SNMP agent at {listen_address} for user '{args.snmp_user}'...")
    snmp_engine.transportDispatcher.jobStarted(1)

    try:
        # Keep the script running indefinitely
        await asyncio.Event().wait()
    except (KeyboardInterrupt, asyncio.CancelledError):
        logging.info("Shutdown request received.")
    finally:
        logging.info("Shutting down SNMP agent.")
        snmp_engine.transportDispatcher.closeDispatcher()

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        logging.info("Agent stopped by user.")
