#!/bin/bash

# Check if script is run as sudo/root
if [ "$EUID" -ne 0 ]; then
    echo "ERROR script not run as root/sudo. Please run as root or using sudo"
    exit
fi

# --- This script will install a Python sub-agent to spoof the standard UPS-MIB ---
echo "Starting Advanced NUT SNMP MIB Proxy Installer..."

# --- Configuration ---
# Source files (expected in the same directory as this script)
PROXY_SCRIPT_SOURCE="./nut-snmp-proxy.py"
SERVICE_FILE_SOURCE="./nut-snmp-proxy.service"

# Destination files
PYTHON_AGENT_PATH="/usr/local/bin/nut-snmp-proxy.py"
SYSTEMD_SERVICE_FILE="/etc/systemd/system/nut-snmp-proxy.service"

UPS_MIB_BASE_OID=".1.3.6.1.2.1.33" # The base OID for the standard UPS-MIB
UPS_CONF_NAME="nutdev1" # The name of the UPS in /etc/nut/ups.conf

# --- Helper Functions (Copied from base script) ---

# Asks the user to select a USB device and returns the VendorID and ProductID
select_ups_device() {
    echo "Looking for connected USB devices..." >&2
    echo "" >&2
    
    # Store lsusb output in an array
    # We use a subshell and process substitution for reliability
    mapfile -t devices < <(lsusb | sed 's/:\s*/:/g')

    if [ ${#devices[@]} -eq 0 ]; then
        echo "No USB devices found. Please make sure your UPS is connected." >&2
        return 1
    fi

    echo "Please select your UPS device from the list below:" >&2
    
    local i=1
    for device in "${devices[@]}"; do
        echo "$i) $device" >&2
        ((i++))
    done
    echo "$i) Quit" >&2

    read -p "Enter the number of your UPS (or 'q' to quit): " choice

    if [[ "$choice" =~ ^[Qq]$ ]] || [ "$choice" -eq "$i" ]; then
        echo "Quit." >&2
        return 1
    fi

    # Validate choice is a number and in range
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#devices[@]}" ]; then
        echo "Invalid choice." >&2
        return 1
    fi

    # Extract ID from the selected device string
    local selected_device=${devices[$((choice - 1))]}
    # This regex matches the ID XYYY:ZZZZ pattern
    if [[ "$selected_device" =~ ID\ ([0-9a-fA-F]{4}):([0-9a-fA-F]{4}) ]]; then
        # BASH_REMATCH holds the captured groups
        # We need to return these values. We'll echo them space-separated.
        echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
        return 0
    else
        echo "Could not parse Vendor/Product ID from: $selected_device" >&2
        return 1
    fi
}

# Creates the udev rule idempotently
# $1: idVendor
# $2: idProduct
create_udev_rule() {
    local idVendor=$1
    local idProduct=$2
    local rule_file="/etc/udev/rules.d/50-nut-ups.rules"
    local udev_rule="SUBSYSTEM==\"hidraw\", ATTRS{idVendor}==\"$idVendor\", ATTRS{idProduct}==\"$idProduct\", MODE=\"0660\", GROUP=\"nut\""

    echo "----------------------------------------------------------------"
    echo "Generated udev rule:"
    echo "$udev_rule"
    echo "----------------------------------------------------------------"
    
    if [ -f "$rule_file" ] && grep -qFx -- "$udev_rule" "$rule_file"; then
        echo "Rule already exists in $rule_file. No changes made."
    else
        echo "Adding rule to $rule_file..."
        echo "$udev_rule" >> "$rule_file"
        echo "Successfully added rule."
    fi

    echo "Reloading udev rules..."
    udevadm control --reload-rules
    udevadm trigger
    echo "Waiting for udev to finish processing events..."
    udevadm settle
}

# Verifies the permissions of the hidraw device
# $1: idVendor
# $2: idProduct
verify_permissions() {
    local idVendor=$1
    local idProduct=$2
    
    echo "Waiting for hidraw device to appear (up to 10 seconds)..."
    local retries=10
    while [ $retries -gt 0 ]; do
        # Check if any hidraw devices exist
        if ls /sys/class/hidraw/hidraw* &>/dev/null; then
            break
        fi
        sleep 1
        ((retries--))
    done

    if ! ls /sys/class/hidraw/hidraw* &>/dev/null; then
        echo "WARNING: No hidraw devices found in /sys/class/hidraw."
        echo " - Please make sure the UPS is plugged in."
        return 1
    fi
    
    echo "Checking permissions for your device..."
    
    local found_dev=""
    
    # Convert selected IDs to uppercase for comparison with symlink target
    local idVendorUpper=$(echo "$idVendor" | tr '[:lower:]' '[:upper:]')
    local idProductUpper=$(echo "$idProduct" | tr '[:lower:]' '[:upper:]')
    local search_pattern=":$idVendorUpper:$idProductUpper" # e.g., :0463:FFFF

    # Loop through all hidraw symlinks
    for symlink in /sys/class/hidraw/hidraw*; do
        if [ -L "$symlink" ]; then
            local target_path=$(readlink "$symlink")
            
            if [[ "$target_path" == *"$search_pattern"* ]]; then
                found_dev="/dev/$(basename "$symlink")"
                break
            fi
        fi
    done

    if [ -z "$found_dev" ]; then
        echo "WARNING: Could not find a matching hidraw device for $search_pattern."
        echo " - This can happen if the device is not plugged in or if udev is slow."
        echo " - Please try unplugging the UPS USB cable and plugging it back in."
        return 1
    fi
    
    echo "Found matching device at: $found_dev"
    
    # Use stat to get permissions and group
    local perms=$(stat -c "%a" "$found_dev")
    local group=$(stat -c "%G" "$found_dev")

    echo "  - Current Permissions: $perms (Expected: 660)"
    echo "  - Current Group: $group (Expected: nut)"

    if [ "$perms" == "660" ] && [ "$group" == "nut" ]; then
        echo "SUCCESS: Permissions and group are set correctly!"
        echo "You can now try restarting the nut-driver:"
        echo "sudo systemctl restart nut-driver.target"
        return 0
    else
        echo "ERROR: Permissions are NOT correct."
        echo "Please try unplugging your UPS, waiting 10 seconds, and plugging it back in."
        return 1
    fi
}
# --- (End Helper Functions) ---


# --- Main Script ---
echo "This advanced script will configure NUT and set up a Python proxy to"
echo "map NUT data to the standard UPS-MIB ($UPS_MIB_BASE_OID)."
echo "This will *overwrite* any existing snmpd.conf settings."
read -p "Do you want to continue? (y/n) "
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Exiting."
    exit
fi

# --- 1. Install Dependencies ---
echo "Installing packages: nut, snmpd, python3..."
apt-get update -y
apt-get install nut snmp snmpd libsnmp-dev python3 -y

# --- 2. Configure NUT (abbreviated, same as base script) ---
echo "Configuring NUT..."
echo "MODE=netserver" > "/etc/nut/nut.conf"
nut-scanner -UNq 2>/dev/null > /etc/nut/ups.conf
if [ $? -ne 0 ] || [ ! -s /etc/nut/ups.conf ]; then
    echo "[$UPS_CONF_NAME]" > "/etc/nut/ups.conf"
    echo "    driver=usbhid-ups" >> "/etc/nut/ups.conf"
    echo "    port = auto" >> "/etc/nut/ups.conf"
fi
echo "--- Current /etc/nut/ups.conf ---"
cat /etc/nut/ups.conf
echo "---------------------------------"

# --- Full permissions fix ---
echo "We need to fix USB permissions for the NUT driver."
read -r idVendor idProduct < <(select_ups_device)

if [ -z "$idVendor" ] || [ -z "$idProduct" ]; then
    echo "Could not get Vendor/Product ID. Exiting."
    exit 1
fi

echo "Got VendorID: $idVendor, ProductID: $idProduct"
create_udev_rule "$idVendor" "$idProduct"
verify_permissions "$idVendor" "$idProduct"
# --- End permissions fix ---

echo "Restarting NUT drivers..."
systemctl restart nut-driver.target
sleep 10
systemctl restart nut-server.service
sleep 10
upsc $UPS_CONF_NAME@localhost > /dev/null
echo "NUT configured."

# --- Update hosts.conf ---
echo "Updating hosts.conf..."
read -p "Please enter a descriptive name for this UPS (e.g., 'Main Office UPS'): " ups_name
# Ensure we don't add duplicate MONITOR lines
if ! grep -q "MONITOR $UPS_CONF_NAME@localhost" /etc/nut/hosts.conf; then
    echo "MONITOR $UPS_CONF_NAME@localhost \"$ups_name\"" >> "/etc/nut/hosts.conf"
else
    echo "MONITOR line already exists in hosts.conf."
fi

# --- 3. Install the Python Agent ---
echo "Checking for proxy script at $PROXY_SCRIPT_SOURCE..."
if [ ! -f "$PROXY_SCRIPT_SOURCE" ]; then
    echo "ERROR: $PROXY_SCRIPT_SOURCE not found."
    echo "Please make sure it is in the same directory as this script."
    exit 1
fi
echo "Installing Python agent to $PYTHON_AGENT_PATH..."
cp "$PROXY_SCRIPT_SOURCE" "$PYTHON_AGENT_PATH"
chmod +x "$PYTHON_AGENT_PATH"
echo "Python agent installed."

# --- 4. Create systemd Service ---
echo "Checking for service file at $SERVICE_FILE_SOURCE..."
if [ ! -f "$SERVICE_FILE_SOURCE" ]; then
    echo "ERROR: $SERVICE_FILE_SOURCE not found."
    echo "Please make sure it is in the same directory as this script."
    exit 1
fi
echo "Installing systemd service to $SYSTEMD_SERVICE_FILE..."
cp "$SERVICE_FILE_SOURCE" "$SYSTEMD_SERVICE_FILE"

echo "Reloading systemd and enabling proxy service..."
systemctl daemon-reload
systemctl enable nut-snmp-proxy.service
systemctl restart nut-snmp-proxy.service
echo "Service created and started."

# --- 5. Configure snmpd.conf ---
echo "Configuring snmpd.conf..."
# We must also create a v3 user for this to be secure
read -p "Enter SNMPv3 Username: " v3_username
read -s -p "Enter SNMPv3 Authentication Password (min 8 chars): " v3_authpass
echo ""
read -s -p "Enter SNMPv3 Privacy/Encryption Password (min 8 chars): " v3_privpass
echo ""

echo "Stopping snmpd to configure..."
systemctl stop snmpd

# Overwrite snmpd.conf
echo "createUser $v3_username SHA \"$v3_authpass\" AES \"$v3_privpass\"" > /etc/snmp/snmpd.conf
echo "rwuser $v3_username authPriv" >> /etc/snmp/snmpd.conf

# Add the magic 'pass_persist' line
echo "Adding proxy line to snmpd.conf..."
echo "pass_persist $UPS_MIB_BASE_OID $PYTHON_AGENT_PATH" >> /etc/snmp/snmpd.conf

echo "Restarting snmpd..."
systemctl restart snmpd
sleep 10

# --- 6. Test ---
echo "---"
echo "Installation complete!"
echo "Your monitoring tool can now query this host using the standard UPS-MIB."
echo "Run this command to test (replace with your credentials):"
echo "snmpwalk -v 3 -l authPriv -u \"$v3_username\" -a SHA -A \"(your_auth_pass)\" -x AES -X \"(your_priv_pass)\" localhost $UPS_MIB_BASE_OID"
echo "---"
