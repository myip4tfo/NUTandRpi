#!/usr/bin/env python3

# NUT to Standard UPS-MIB (RFC 1628) Standalone SNMP Agent
#
# This script is a self-contained SNMPv3 agent that uses the PySNMP library.
# It is designed to be compatible with modern PySNMP versions (5.x+) and Python 3.8+.
# It dynamically responds to SNMP GET/GETNEXT queries for UPS-MIB OIDs
# by fetching the corresponding data from the NUT `upsc` command.

# --- Standard Library Imports ---
import sys
import subprocess
import logging
import argparse
import asyncio

# --- PySNMP Core Imports ---
try:
    from pysnmp.entity import engine, config
    from pysnmp.entity.rfc3413 import cmdrsp, context
    from pysnmp.carrier.asyncio.dgram import udp
    from pysnmp.smi import builder, instrum, rfc1902

    # In modern PySNMP (5.x+), MibScalarInstance is located in the rfc1902 module.
    # This is consistent with the deprecation warnings observed.
    from pysnmp.smi.rfc1902 import MibScalarInstance

    # The base ASN.1 types like OctetString are in the `pyasn1` dependency.
    from pyasn1.type import univ

except ImportError as e:
    print(f"FATAL: A required library (PySNMP or PyASN1) is missing.", file=sys.stderr)
    print(f"Error details: {e}", file=sys.stderr)
    print("Please ensure pysnmp is installed in the script's Python environment.", file=sys.stderr)
    sys.exit(1)


# --- MIB Builder Setup and Symbol Loading ---
mib_builder = builder.MibBuilder()
(
    Integer32,
    Gauge32,
) = mib_builder.import_symbols(
    "SNMPv2-SMI",
    "Integer32",
    "Gauge32"
)

# --- Agent Configuration ---
NUT_UPS_NAME = "nutdev1@localhost"
AGENT_VERSION = "2.3.0" # Updated version

# --- Logging Setup ---
logging.basicConfig(
    stream=sys.stdout,
    level=logging.INFO,
    format='[%(asctime)s] [%(levelname)s] (%(name)s) %(message)s'
)
log = logging.getLogger('NUT-SNMP-Agent')


# --- Data Fetching Logic ---
def get_upsc_value(variable_name):
    """
    Executes the `upsc` command to get a value from NUT.
    Returns the string value on success, None on any failure.
    """
    command = ['/bin/upsc', NUT_UPS_NAME, variable_name]
    try:
        result = subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=5,
            check=True
        )
        value = result.stdout.strip()
        if value:
            log.debug(f"upsc fetch for '{variable_name}': SUCCESS -> '{value}'")
            return value
        else:
            log.warning(f"upsc fetch for '{variable_name}': returned an EMPTY value.")
            return None
    except FileNotFoundError:
        log.error(f"upsc command not found at '/bin/upsc'. Is NUT installed?")
        return None
    except subprocess.CalledProcessError as e:
        # This is common if the UPS is not connected or the variable doesn't exist.
        log.debug(f"upsc fetch for '{variable_name}': FAILED. Error: {e.stderr.strip()}")
        return None
    except Exception as e:
        log.error(f"An unexpected error occurred while running upsc for '{variable_name}': {e}")
        return None

# --- Data Type Conversion ---
def convert_status_to_mib_integer(status_string):
    """
    Converts a NUT status string (e.g., "OL CHRG") into the corresponding
    integer value required by the UPS-MIB `upsBatteryStatus` OID.
    """
    if "LB" in status_string:
        return 3  # batteryLow
    if "OL" in status_string or "OB" in status_string:
        return 2  # batteryNormal
    # Treat other states like "Replace Battery" (RB) or "Bypass" as normal for this value.
    if "RB" in status_string or "BYPASS" in status_string:
        return 2  # batteryNormal
    return 1  # unknown

# --- OID to NUT Variable Mapping ---
OID_TO_NUT_MAP = {
    # upsIdent group
    "1.3.6.1.2.1.33.1.1.1.0": ("device.mfr", univ.OctetString),
    "1.3.6.1.2.1.33.1.1.2.0": ("device.model", univ.OctetString),
    "1.3.6.1.2.1.33.1.1.5.0": ("device.serial", univ.OctetString),
    # upsBattery group
    "1.3.6.1.2.1.33.1.2.1.0": ("ups.status", Integer32, convert_status_to_mib_integer),
    "1.3.6.1.2.1.33.1.2.2.0": ("battery.runtime", Integer32),
    "1.3.6.1.2.1.33.1.2.4.0": ("battery.charge", Gauge32),
    "1.3.6.1.2.1.33.1.2.5.0": ("battery.voltage", Gauge32, lambda v: int(float(v) * 10)),
    # upsInput group
    "1.3.6.1.2.1.33.1.3.3.1.2.1": ("input.voltage", Gauge32),
    # upsOutput group
    "1.3.6.1.2.1.33.1.4.4.1.2.1": ("output.voltage", Gauge32),
    "1.3.6.1.2.1.33.1.4.4.1.5.1": ("ups.load", Gauge32),
}

# --- Dynamic MIB Instrumentation Class Factory ---
def create_mib_scalar_instance(nut_variable, snmp_syntax, converter=None):
    """
    A class factory that creates a MibScalarInstance subclass for a given NUT variable.
    """
    class NutMibScalar(MibScalarInstance):
        def getValue(self, name, idx):
            raw_value = get_upsc_value(nut_variable)

            if raw_value is None:
                log.warning(f"Returning default value for {nut_variable} as upsc fetch failed.")
                return self.syntax.clone('' if issubclass(self.syntax.__class__, univ.OctetString) else 0)

            try:
                final_value = converter(raw_value) if converter else raw_value
                return self.syntax.clone(final_value)
            except (ValueError, TypeError) as e:
                log.error(f"Failed to process value '{raw_value}' for {nut_variable}. Error: {e}")
                return self.syntax.clone('' if issubclass(self.syntax.__class__, univ.OctetString) else 0)

    return NutMibScalar


async def main():
    """The main entry point for the SNMP agent."""
    # --- Argument Parsing ---
    parser = argparse.ArgumentParser(description=f"NUT to SNMP MIB Standalone Agent (v{AGENT_VERSION})")
    parser.add_argument("--snmp-user", required=True, help="SNMPv3 username for USM")
    parser.add_argument("--auth-key", required=True, help="SNMPv3 authentication key (SHA, min 8 chars)")
    parser.add_argument("--priv-key", required=True, help="SNMPv3 privacy (encryption) key (AES, min 8 chars)")
    parser.add_argument("--agent-address", default="0.0.0.0", help="IP address to listen on (default: 0.0.0.0)")
    parser.add_argument("--agent-port", type=int, default=161, help="UDP port to listen on (default: 161)")
    parser.add_argument("--debug", action="store_true", help="Enable verbose DEBUG logging")
    args = parser.parse_args()

    if args.debug:
        log.setLevel(logging.DEBUG)
        log.info("DEBUG logging enabled.")

    # --- Initialize SNMP Engine ---
    snmp_engine = engine.SnmpEngine()

    # --- Configure SNMPv3 User Security Model (USM) ---
    config.add_v3_user(
        snmp_engine,
        args.snmp_user,
        authProtocol=config.USM_AUTH_HMAC96_SHA,
        authKey=args.auth_key,
        privProtocol=config.USM_PRIV_CFB128_AES,
        privKey=args.priv_key,
    )

    # --- Configure Network Transport ---
    listen_address = (args.agent_address, args.agent_port)
    config.add_transport(
        snmp_engine,
        udp.DOMAIN_NAME,
        udp.UdpTransport().open_server_mode(listen_address)
    )

    # --- Build the MIB and Register OIDs ---
    mib_instrum = instrum.MibInstrumController(mib_builder)

    for oid_str, (nut_var, snmp_class, *converter_func) in OID_TO_NUT_MAP.items():
        oid_tuple = tuple(int(x) for x in oid_str.split('.'))
        converter = converter_func[0] if converter_func else None
        ScalarInstanceClass = create_mib_scalar_instance(nut_var, snmp_class(), converter)
        mib_builder.export_symbols(
            '__LOCAL_NUT_MIB',
            ScalarInstanceClass(oid_tuple, snmp_class())
        )

    # --- Register Command Responders and MIB View ---
    snmp_context = context.SnmpContext(snmp_engine, mib_instrum)
    cmdrsp.GetCommandResponder(snmp_engine, snmp_context)
    cmdrsp.NextCommandResponder(snmp_engine, snmp_context)
    cmdrsp.BulkCommandResponder(snmp_engine, snmp_context)

    # --- Start the Agent ---
    log.info(f"Agent starting. Listening on udp:{args.agent_address}:{args.agent_port}")
    log.info(f"Configured for SNMPv3 user: '{args.snmp_user}'")

    snmp_engine.transportDispatcher.job_started(1)

    try:
        await asyncio.Event().wait()
    except (KeyboardInterrupt, asyncio.CancelledError):
        log.info("Shutdown signal received.")
    finally:
        log.info("Shutting down agent...")
        snmp_engine.transportDispatcher.close_dispatcher()
        log.info("Agent stopped.")


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except Exception as e:
        log.critical(f"A critical error occurred in the main event loop: {e}", exc_info=True)
        sys.exit(1)
