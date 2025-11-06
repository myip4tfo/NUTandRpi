#!/bin/bash

# Check if script is run as sudo/root
if [ "$EUID" -ne 0 ]; then
    echo "ERROR script not run as root/sudo. Please run as root or using sudo"
    exit
fi

# --- Helper Functions ---

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

# --- Main Script ---

echo "Hello Internet Freind. This is a test script."
echo " "
echo "This script is NOT production ready and, even if successful, the configuration you end up with will require some additional work to make it secure."
echo "You should really read the README (https://github.com/dzomaya/NUTandRpi/blob/main/README.md) to understand what you're getting into."
echo " "
echo " If you need a production-grade solution, I recommend contacting the Tripp Lite by Eaton team: https://tripplite.eaton.com/support/contact-us."
echo "This script will attempt to install multiple packages on this machine and configure Network UPS Tools and SNMP v2c."
echo " "
echo "IMPORTANT: WE ARE GOING TO RUN apt update"
echo "IMPORTANT: SCRIPT ASSUMES YOU DO NOT HAVE ANY OF THESE PACKAGES INSTALLED:"
echo "* nut"
echo "* nut-cgi"
echo "* snmp"
echo "* snmpd"
echo "* libsnmp-dev"
echo "* snmp-mibs-downloader"
echo "* net-snmp"
echo "* Apache or any other http server running on port 80"
read -p "Do you want to assume the risk and continue? Enter 'y' for yes or 'n' for no."
echo " "
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Maybe another time Internet Freind. Goodbye";
    exit
fi

echo "WOOOOOOO! Here... we... go..."
# Make sure you are up to date
read -p "If you haven't updated your package lists... Want us to run 'apt update' for you? (y/n) "
if [[ $REPLY =~ ^[Yy]$ ]]; then
    apt update -y
else
    echo "Ok, we will NOT run 'apt update'";
fi

# --- SNMP Configuration Choice ---
snmp_version=""
while [[ "$snmp_version" != "v2c" && "$snmp_version" != "v3" ]]; do
    read -p "Which SNMP version do you want to configure? (v2c/v3) [Default: v2c]: " snmp_choice
    snmp_version=${snmp_choice:-v2c} # Default to v2c if empty
    snmp_version=$(echo "$snmp_version" | tr '[:upper:]' '[:lower:]') # convert to lowercase
    if [[ "$snmp_version" == "2c" ]]; then snmp_version="v2c"; fi
    if [[ "$snmp_version" == "3" ]]; then snmp_version="v3"; fi

    if [[ "$snmp_version" != "v2c" && "$snmp_version" != "v3" ]]; then
        echo "Invalid choice. Please enter 'v2c' or 'v3'."
    fi
done

echo "Configuring for SNMP $snmp_version..."

# Prompt for UPS Name (needed for both versions)
read -p "Please enter a descriptive name for this UPS (e.g., 'Main Office UPS'): " ups_name
while [[ -z "$ups_name" ]]; do
    echo "The UPS name cannot be empty."
    read -p "Please enter a descriptive name for this UPS: " ups_name
done

# Version-specific prompts
if [ "$snmp_version" == "v2c" ]; then
    read -n 32 -p "Tell me what SNMP v2c community string I should use for your configuration: " v2ccommunity
    while [[ "$v2ccommunity" =~ [^a-zA-Z0-9] || -z "$v2ccommunity" ]]; do
        echo "I cannot use that. Please only use alphanumeric characters. You can use 1-32 characters total"
        read -n 32 -p "Tell me what SNMP v2c community string I should use for your configuration: " v2ccommunity
    done
    echo "" # Newline after read -n
else
    # SNMPv3 Prompts
    read -p "Enter SNMPv3 Username: " v3_username
    while [[ -z "$v3_username" ]]; do
        echo "Username cannot be empty."
        read -p "Enter SNMPv3 Username: " v3_username
    done
    
    read -s -p "Enter SNMPv3 Authentication Password (min 8 chars): " v3_authpass
    echo ""
    while [[ ${#v3_authpass} -lt 8 ]]; do
        echo "Password must be at least 8 characters."
        read -s -p "Enter SNMPv3 Authentication Password (min 8 chars): " v3_authpass
        echo ""
    done
    
    read -s -p "Enter SNMPv3 Privacy/Encryption Password (min 8 chars): " v3_privpass
    echo ""
    while [[ ${#v3_privpass} -lt 8 ]]; do
        echo "Password must be at least 8 characters."
        read -s -p "Enter SNMPv3 Privacy/Encryption Password (min 8 chars): " v3_privpass
        echo ""
    done
fi


echo "*********************"

# Install NUT and NUT CGI from repo
echo "Installing NUT packages (nut, nut-cgi)..."
apt-get install nut nut-cgi -y

#make backups of the conf files we touch
echo "Backing up nut.conf and ups.conf..."
cp /etc/nut/nut.conf /etc/nut/nut.conf.bak
cp /etc/nut/ups.conf /etc/nut/ups.conf.bak

# edit nut.conf
echo "Setting MODE=netserver in /etc/nut/nut.conf..."
echo "MODE=netserver" > "/etc/nut/nut.conf"

#Try to run nut-scanner to create a ups.conf
echo "Running nut-scanner to detect UPS and create /etc/nut/ups.conf..."
nut-scanner -UNq 2>/dev/null > /etc/nut/ups.conf

#Check if nut-scanner failed
if [ $? -ne 0 ] || [ ! -s /etc/nut/ups.conf ]; then
    echo "nut-scanner failed or found no UPS. We will build the ups.conf manually."
    # echo ups.conf this is cheap, need to fix
    echo "[nutdev1]" >> "/etc/nut/ups.conf"
    echo "    driver=usbhid-ups" >> "/etc/nut/ups.conf"
    echo "    port = auto" >> "/etc/nut/ups.conf"
fi

echo "--- Current /etc/nut/ups.conf ---"
cat /etc/nut/ups.conf
echo "---------------------------------"

# --- NEW PERMISSIONS FIX ---
echo "We need to fix USB permissions for the NUT driver."
# Call function to get IDs
# `read` splits the space-separated output from the function
read -r idVendor idProduct < <(select_ups_device)

if [ -z "$idVendor" ] || [ -z "$idProduct" ]; then
    echo "Could not get Vendor/Product ID. Exiting."
    exit 1
fi

echo "Got VendorID: $idVendor, ProductID: $idProduct"
create_udev_rule "$idVendor" "$idProduct"
verify_permissions "$idVendor" "$idProduct"

# --- End new permissions fix ---

echo "Restarting NUT drivers..."
systemctl restart nut-driver.target
echo "Waiting for drivers to start (10 seconds)..."
sleep 10
echo "Restarting NUT server..."
systemctl restart nut-server.service
echo "Waiting for server to connect (10 seconds)..."
sleep 10

# check if we're talking
echo "Checking connection to UPS (upsc nutdev1@localhost)..."
# Note: The UPS name 'nutdev1' MUST match what's in /etc/nut/ups.conf
# We use @localhost for robustness
upsc nutdev1@localhost

# Allow CGI to work for upsset, not secure uncomment if you want to
# echo  "I_HAVE_SECURED_MY_CGI_DIRECTORY" >> "/etc/nut/upsset.conf"

# Allow NUT hosts
echo "Updating hosts.conf..."
# Ensure we don't add duplicate MONITOR lines
if ! grep -q "MONITOR nutdev1@localhost" /etc/nut/hosts.conf; then
    echo "MONITOR nutdev1@localhost \"$ups_name\"" >> "/etc/nut/hosts.conf"
else
    echo "MONITOR line already exists in hosts.conf."
fi

# enable apache CGI
echo "Enabling Apache CGI module..."
a2enmod cgi
# restart apache
echo "Restarting Apache..."
systemctl restart apache2
# sleep 3 seconds
sleep 3
# are we working?  This will be ugly curl output, but easy quick check
echo "Testing CGI (curl)..."
curl -f http://localhost/cgi-bin/nut/upsstats.cgi

# Install SNMP packages
echo "Installing SNMP packages..."
sudo apt-get install snmp snmpd libsnmp-dev snmp-mibs-downloader -y

# make backups of the conf files we touch if they exist
echo "Backing up snmpd.conf..."
cp /etc/snmp/snmpd.conf /etc/snmp/old.snmpd.conf.old

# --- NEW SNMP Config Section ---
echo "Configuring snmpd.conf for $snmp_version..."

if [ "$snmp_version" == "v2c" ]; then
    # v2c configuration (overwrites file)
    echo "rocommunity $v2ccommunity" > /etc/snmp/snmpd.conf
else
    # v3 configuration (overwrites file)
    echo "Stopping snmpd to create v3 user..."
    systemctl stop snmpd
    
    # Create the v3 user. This line creates the user with SHA auth and AES privacy.
    # This *replaces* any previous config.
    echo "createUser $v3_username SHA \"$v3_authpass\" AES \"$v3_privpass\"" > /etc/snmp/snmpd.conf
    
    # Give the new user read-write access
    echo "rwuser $v3_username authPriv" >> /etc/snmp/snmpd.conf
fi

# Append the rest of the snmpd.conf (same for v2c and v3)
echo "Appending NUT OIDs to snmpd.conf..."
echo 'extend-sh upsmodel "/bin/upsc nutdev1@localhost ups.model"' >> /etc/snmp/snmpd.conf
echo 'extend-sh upsmfr "/bin/upsc nutdev1@localhost  ups.mfr"' >> /etc/snmp/snmpd.conf
echo 'extend-sh upsserial "/bin/upsc nutdev1@localhost ups.serial"' >> /etc/snmp/snmpd.conf
echo 'extend-sh upsstatus "/bin/upsc nutdev1@localhost ups.status"' >> /etc/snmp/snmpd.conf
echo 'extend-sh battcharge "/bin/upsc nutdev1@localhost battery.charge"' >> /etc/snmp/snmpd.conf
echo 'extend-sh battruntimeest "/bin/upsc nutdev1@localhost battery.runtime"' >> /etc/snmp/snmpd.conf
echo 'extend-sh battvolts "/bin/upsc nutdev1@localhost battery.voltage"' >> /etc/snmp/snmpd.conf
echo 'extend-sh inputvolt "/bin/upsc nutdev1@localhost input.voltage"' >> /etc/snmp/snmpd.conf
echo 'extend-sh inputHZ "/bin/upsc nutdev1@localhost input.frequency"' >> /etc/snmp/snmpd.conf
echo 'extend-sh outputvolt "/bin/upsc nutdev1@localhost output.voltage"' >> /etc/snmp/snmpd.conf
echo 'extend-sh outputHZ "/bin/upsc nutdev1@localhost output.frequency"' >> /etc/snmp/snmpd.conf
echo 'extend-sh outputloadVA "/bin/upsc nutdev1@localhost ups.power"' >> /etc/snmp/snmpd.conf

# --- NEW ITEMS ---
echo 'extend-sh upsloadpercent "/bin/upsc nutdev1@localhost ups.load"' >> /etc/snmp/snmpd.conf
echo 'extend-sh upsrealpowerW "/bin/upsc nutdev1@localhost ups.realpower"' >> /etc/snmp/snmpd.conf
echo 'extend-sh inputcurrent "/bin/upsc nutdev1@localhost input.current"' >> /etc/snmp/snmpd.conf
echo 'extend-sh outputcurrent "/bin/upsc nutdev1@localhost output.current"' >> /etc/snmp/snmpd.conf
echo 'extend-sh upsfirmware "/bin/upsc nutdev1@localhost ups.firmware"' >> /etc/snmp/snmpd.conf
echo 'extend-sh upstestresult "/bin/upsc nutdev1@localhost ups.test.result"' >> /etc/snmp/snmpd.conf
# --- END NEW ITEMS ---


# enable and restart snmpd
echo "Enabling and restarting snmpd..."
systemctl enable snmpd
systemctl restart snmpd
# sleep for 20 seconds
echo "Waiting for snmpd to start (20 seconds)..."
sleep 20

# --- NEW Conditional SNMP Test ---
# run our snmptest
echo "Running snmpwalk test for $snmp_version..."

# This is the base OID for the 'extend-sh' feature. Walking it is more robust.
local base_oid=".1.3.6.1.4.1.8072.1.3.2.4.1.2"

if [ "$snmp_version" == "v2c" ]; then
    snmpwalk -v2c -c "$v2ccommunity" localhost $base_oid
else
    snmpwalk -v 3 -l authPriv -u "$v3_username" -a SHA -A "$v3_authpass" -x AES -X "$v3_privpass" localhost $base_oid
fi

# Be nice
echo "---"
echo "Done!"
echo "You should now be able to see cool UPS stats at http://localhost/cgi-bin/nut/upsstats.cgi."

# Conditional final message
if [ "$snmp_version" == "v2c" ]; then
    echo "snmpwalk -v2c -c $v2ccommunity localhost $base_oid should give you all your UPS data."
else
    echo "snmpwalk -v 3 -l authPriv -u \"$v3_username\" -a SHA -A \"$v3_authpass\" -x AES -X \"$v3_privpass\" localhost $base_oid should give you all your UPS data."
fi

echo "This was fun. Thanks. Have a great day Internet Freind. Goodbye";
