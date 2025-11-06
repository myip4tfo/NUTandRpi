#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

# --- This script will install a Python SNMP agent to spoof the standard UPS-MIB ---

# Check if script is run as sudo/root
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: This script must be run as root or with sudo."
    exit 1
fi

# --- Configuration ---
# Determine the script's own directory to reliably find the python script
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
AGENT_INSTALL_DIR="/opt/nut-snmp-proxy"
PROXY_SCRIPT_SOURCE="$SCRIPT_DIR/nut-snmp-proxy.py"
PYTHON_AGENT_PATH="$AGENT_INSTALL_DIR/nut-snmp-proxy.py"
AGENT_SERVICE_FILE="/etc/systemd/system/nut-snmp-agent.service"
UPS_MIB_BASE_OID=".1.3.6.1.2.1.33"

# --- (Helper Functions are unchanged) ---
select_ups_device() {
    echo "Looking for connected USB devices..." >&2; echo "" >&2
    mapfile -t devices < <(lsusb | sed 's/:\s*/:/g')
    if [ ${#devices[@]} -eq 0 ]; then echo "No USB devices found." >&2; return 1; fi
    echo "Please select your UPS device:" >&2
    local i=1; for dev in "${devices[@]}"; do echo "$i) $dev" >&2; ((i++)); done; echo "$i) Quit" >&2
    read -p "Enter the number of your UPS (or 'q' to quit): " choice
    if [[ "$choice" =~ ^[Qq]$ ]] || [ "$choice" -eq "$i" ]; then echo "Quit." >&2; return 1; fi
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#devices[@]}" ]; then echo "Invalid choice." >&2; return 1; fi
    local selected_device=${devices[$((choice-1))]}
    if [[ "$selected_device" =~ ID\ ([0-9a-fA-F]{4}):([0-9a-fA-F]{4}) ]]; then
        echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"; return 0
    else
        echo "Could not parse Vendor/Product ID." >&2; return 1
    fi
}
create_udev_rule() {
    local idVendor=$1; local idProduct=$2
    local rule_file="/etc/udev/rules.d/50-nut-ups.rules"
    local udev_rule="SUBSYSTEM==\"hidraw\", ATTRS{idVendor}==\"$idVendor\", ATTRS{idProduct}==\"$idProduct\", MODE=\"0660\", GROUP=\"nut\""
    echo "Generated udev rule: $udev_rule"
    if [ -f "$rule_file" ] && grep -qFx -- "$udev_rule" "$rule_file"; then echo "Rule already exists."; else echo "Adding rule to $rule_file..."; echo "$udev_rule" >> "$rule_file"; fi
    udevadm control --reload-rules && udevadm trigger && udevadm settle
}
verify_permissions() {
    local idVendor=$1; local idProduct=$2; local retries=10
    while [ $retries -gt 0 ] && ! ls /sys/class/hidraw/hidraw* &>/dev/null; do sleep 1; ((retries--)); done
    if ! ls /sys/class/hidraw/hidraw* &>/dev/null; then echo "WARNING: No hidraw devices found." >&2; return 1; fi
    local found_dev=""; local idVendorUpper=$(echo "$idVendor"|tr '[:lower:]' '[:upper:]'); local idProductUpper=$(echo "$idProduct"|tr '[:lower:]' '[:upper:]')
    local search_pattern=":$idVendorUpper:$idProductUpper"
    for symlink in /sys/class/hidraw/hidraw*; do
        if [ -L "$symlink" ] && [[ "$(readlink "$symlink")" == *"$search_pattern"* ]]; then found_dev="/dev/$(basename "$symlink")"; break; fi
    done
    if [ -z "$found_dev" ]; then echo "WARNING: Could not find matching hidraw device." >&2; return 1; fi
    echo "Found device at $found_dev. Permissions: $(stat -c "%a" "$found_dev"), Group: $(stat -c "%G" "$found_dev")"
    if [ "$(stat -c "%a" "$found_dev")" == "660" ] && [ "$(stat -c "%G" "$found_dev")" == "nut" ]; then echo "SUCCESS: Permissions are correct."; return 0; else echo "ERROR: Permissions are NOT correct."; return 1; fi
}

# --- Main Script ---
echo "Starting Advanced NUT SNMP MIB Standalone Agent Installer..."
read -p "This will install a standalone Python SNMP agent for NUT. This may conflict with other services using port 161. Continue? (y/n) "
if [[ ! $REPLY =~ ^[Yy]$ ]]; then echo "Exiting."; exit; fi

# --- 1. Install Dependencies ---
echo "--- Step 1: Installing System Dependencies ---"
echo "Installing packages: nut, python3, python3-venv..."
apt-get update -y
apt-get install -y nut python3 python3-venv

# --- 2. Configure NUT (abbreviated) ---
echo "--- Step 2: Configuring NUT ---"
echo "MODE=netserver" > "/etc/nut/nut.conf"
# A simple attempt to auto-configure; user can modify this later
if ! nut-scanner -UNq 2>/dev/null > /etc/nut/ups.conf || [ ! -s /etc/nut/ups.conf ]; then
    echo "[nutdev1]" > "/etc/nut/ups.conf"
    echo "    driver=usbhid-ups" >> "/etc/nut/ups.conf"
    echo "    port = auto" >> "/etc/nut/ups.conf"
fi
echo "--- Current /etc/nut/ups.conf ---"; cat /etc/nut/ups.conf; echo "---------------------------------"
read -r idVendor idProduct < <(select_ups_device)
if [ -z "$idVendor" ] || [ -z "$idProduct" ]; then echo "Could not get Vendor/Product ID. Exiting."; exit 1; fi
create_udev_rule "$idVendor" "$idProduct" && verify_permissions "$idVendor" "$idProduct"
systemctl restart nut-driver.target; sleep 5; systemctl restart nut-server.service; sleep 5

# --- 3. Install the Python Agent and Virtual Environment ---
echo "--- Step 3: Setting up Python Virtual Environment ---"

echo "Creating clean agent directory and virtual environment at $AGENT_INSTALL_DIR..."
rm -rf "$AGENT_INSTALL_DIR"
mkdir -p "$AGENT_INSTALL_DIR"
python3 -m venv "$AGENT_INSTALL_DIR/venv"

echo "Copying Python agent script to $PYTHON_AGENT_PATH..."
cp "$PROXY_SCRIPT_SOURCE" "$PYTHON_AGENT_PATH"
chmod +x "$PYTHON_AGENT_PATH"

echo "Installing Python dependencies (pysnmp>=7.1) into virtual environment..."
# Use the pip from the virtual environment to install packages into it.
"$AGENT_INSTALL_DIR/venv/bin/pip" install "pysnmp>=7.1" || {
    echo "ERROR: Failed to install pysnmp library into the virtual environment."
    exit 1
}

# --- 4. Configure and Start Standalone Agent Service ---
echo "--- Step 4: Configuring and Starting systemd Service ---"
read -p "Enter SNMPv3 Username: " v3_username
read -s -p "Enter SNMPv3 Authentication Password (min 8 chars): " v3_authpass
echo ""
read -s -p "Enter SNMPv3 Privacy/Encryption Password (min 8 chars): " v3_privpass
echo ""

# Create the systemd service file
cat > $AGENT_SERVICE_FILE << EOL
[Unit]
Description=NUT to UPS-MIB SNMP Agent
After=network.target nut-server.service
Requires=nut-server.service

[Service]
Type=simple
User=root
# Execute the script using the python interpreter from the virtual environment
ExecStart=$AGENT_INSTALL_DIR/venv/bin/python $PYTHON_AGENT_PATH --snmp-user "$v3_username" --auth-key "$v3_authpass" --priv-key "$v3_privpass"
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOL

echo "Reloading systemd, enabling and starting nut-snmp-agent..."
systemctl daemon-reload
systemctl enable $AGENT_SERVICE_FILE
systemctl restart nut-snmp-agent

# --- 5. Test ---
echo "--- Step 5: Installation Complete! ---"
echo "The standalone Python agent should now be running."
echo "To check its status, run: systemctl status nut-snmp-agent"
echo "To see its logs, run: journalctl -u nut-snmp-agent -f"
echo ""
echo "Run this command to test your new SNMP agent:"
echo "snmpwalk -v 3 -l authPriv -u \"$v3_username\" -a SHA -A \"$v3_authpass\" -x AES -X \"$v3_privpass\" localhost $UPS_MIB_BASE_OID"
echo "--------------------------------------"
