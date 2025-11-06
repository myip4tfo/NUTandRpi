#!/bin/bash

# Check if script is run as sudo/root
if [ "$EUID" -ne 0 ]; then
    echo "ERROR script not run as root/sudo. Please run as root or using sudo"
    exit
fi

# --- This script will install a Python SNMP agent to spoof the standard UPS-MIB ---
echo "Starting Advanced NUT SNMP MIB Standalone Agent Installer..."

# --- Configuration ---
AGENT_INSTALL_DIR="/opt/nut-snmp-proxy"
PROXY_SCRIPT_SOURCE="./nut-snmp-proxy.py" # Assumes this script is run from the advanced-snmp dir
PYTHON_AGENT_PATH="$AGENT_INSTALL_DIR/nut-snmp-proxy.py"
AGENT_SERVICE_FILE="/etc/systemd/system/nut-snmp-agent.service"
UPS_MIB_BASE_OID=".1.3.6.1.2.1.33"
UPS_CONF_NAME="nutdev1"

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
read -p "This will install a standalone Python SNMP agent for NUT. This may conflict with other services using port 161. Continue? (y/n) "
if [[ ! $REPLY =~ ^[Yy]$ ]]; then echo "Exiting."; exit; fi

# --- 1. Install Dependencies ---
echo "Installing packages: nut, python3, python3-venv..."
apt-get update -y
apt-get install -y nut python3 python3-venv

# --- 2. Configure NUT (abbreviated) ---
echo "Configuring NUT..."
echo "MODE=netserver" > "/etc/nut/nut.conf"
nut-scanner -UNq 2>/dev/null > /etc/nut/ups.conf
if [ $? -ne 0 ] || [ ! -s /etc/nut/ups.conf ]; then
    echo "[$UPS_CONF_NAME]" > "/etc/nut/ups.conf"
    echo "    driver=usbhid-ups" >> "/etc/nut/ups.conf"
    echo "    port = auto" >> "/etc/nut/ups.conf"
fi
echo "--- Current /etc/nut/ups.conf ---"; cat /etc/nut/ups.conf; echo "---------------------------------"
read -r idVendor idProduct < <(select_ups_device)
if [ -z "$idVendor" ] || [ -z "$idProduct" ]; then echo "Could not get Vendor/Product ID. Exiting."; exit 1; fi
create_udev_rule "$idVendor" "$idProduct" && verify_permissions "$idVendor" "$idProduct"
systemctl restart nut-driver.target; sleep 10; systemctl restart nut-server.service; sleep 10

# --- 3. Install the Python Agent and Virtual Environment ---
echo "Creating agent directory and virtual environment at $AGENT_INSTALL_DIR..."
mkdir -p "$AGENT_INSTALL_DIR"
python3 -m venv "$AGENT_INSTALL_DIR/venv"

echo "Installing Python agent script to $PYTHON_AGENT_PATH..."
cp "$PROXY_SCRIPT_SOURCE" "$PYTHON_AGENT_PATH"
chmod +x "$PYTHON_AGENT_PATH"

echo "Installing Python dependencies (pysnmp) into virtual environment..."
"$AGENT_INSTALL_DIR/venv/bin/pip" install pysnmp

# --- 4. Configure and Start Standalone Agent Service ---
echo "Configuring the standalone SNMP agent service..."
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
echo "---"
echo "Installation complete! The standalone Python agent should be running."
echo "NOTE: This agent runs on port 161. If you were running the system snmpd, it has NOT been disabled."
echo "Run this command to test:"
echo "snmpwalk -v 3 -l authPriv -u \"$v3_username\" -a SHA -A \"$v3_authpass\" -x AES -X \"$v3_privpass\" localhost $UPS_MIB_BASE_OID"
echo "---"
