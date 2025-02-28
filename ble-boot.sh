#!/bin/bash

# Log file
LOGFILE="/var/log/bt-setup.log"
exec > >(tee -a "$LOGFILE") 2>&1

echo "Starting Bluetooth setup at $(date)"

# Check if we've already updated today
LAST_UPDATE_FILE="/var/log/last-apt-update"
TODAY=$(date +%Y-%m-%d)

if [ -f "$LAST_UPDATE_FILE" ] && [ "$(cat $LAST_UPDATE_FILE)" = "$TODAY" ]; then
    echo "Already updated packages today, skipping update"
else
    echo "Updating package lists..."
    apt-get update
    # Save today's date to the file
    echo "$TODAY" > "$LAST_UPDATE_FILE"
    echo "Package lists updated and timestamp recorded"
fi

# Install required packages only if not already installed
echo "Checking and installing required Bluetooth packages if needed..."
for pkg in bluetooth bluez bluez-tools python3-dbus python3-gi; do
    if ! dpkg -l | grep -q " $pkg "; then
        echo "Installing $pkg..."
        apt-get install -y $pkg
    else
        echo "$pkg is already installed"
    fi
done

# Stop any services using the serial port
systemctl disable serial-getty@ttyAMA0.service 2>/dev/null
systemctl disable serial-getty@ttyS0.service 2>/dev/null

# Reset Bluetooth to clean state
echo "Resetting Bluetooth..."
rfkill block bluetooth
rfkill unblock bluetooth
systemctl restart bluetooth
sleep 3

# Create the PIN agent script
echo "Creating PIN agent script..."
cat > /usr/local/bin/bt-pin-agent.py << 'EOF'
#!/usr/bin/python3
import sys
import dbus
import dbus.service
import dbus.mainloop.glib
from gi.repository import GLib

BUS_NAME = 'org.bluez'
AGENT_INTERFACE = 'org.bluez.Agent1'
AGENT_PATH = "/test/agent"
PIN_CODE = "5471"  # Your specific PIN

class Agent(dbus.service.Object):
    @dbus.service.method(AGENT_INTERFACE, in_signature="", out_signature="")
    def Release(self):
        print("Release")

    @dbus.service.method(AGENT_INTERFACE, in_signature="os", out_signature="")
    def AuthorizeService(self, device, uuid):
        print("AuthorizeService (%s, %s)" % (device, uuid))
        return

    @dbus.service.method(AGENT_INTERFACE, in_signature="o", out_signature="s")
    def RequestPinCode(self, device):
        print("RequestPinCode (%s)" % (device))
        return PIN_CODE

    @dbus.service.method(AGENT_INTERFACE, in_signature="o", out_signature="u")
    def RequestPasskey(self, device):
        print("RequestPasskey (%s)" % (device))
        return dbus.UInt32(PIN_CODE)

    @dbus.service.method(AGENT_INTERFACE, in_signature="ouq", out_signature="")
    def DisplayPasskey(self, device, passkey, entered):
        print("DisplayPasskey (%s, %06u entered %u)" % (device, passkey, entered))

    @dbus.service.method(AGENT_INTERFACE, in_signature="os", out_signature="")
    def DisplayPinCode(self, device, pincode):
        print("DisplayPinCode (%s, %s)" % (device, pincode))

    @dbus.service.method(AGENT_INTERFACE, in_signature="ou", out_signature="")
    def RequestConfirmation(self, device, passkey):
        print("RequestConfirmation (%s, %06d)" % (device, passkey))
        return

    @dbus.service.method(AGENT_INTERFACE, in_signature="o", out_signature="")
    def RequestAuthorization(self, device):
        print("RequestAuthorization (%s)" % (device))
        return

    @dbus.service.method(AGENT_INTERFACE, in_signature="", out_signature="")
    def Cancel(self):
        print("Cancel")

if __name__ == '__main__':
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SystemBus()
    agent = Agent(bus, AGENT_PATH)
    obj = bus.get_object(BUS_NAME, "/org/bluez")
    manager = dbus.Interface(obj, "org.bluez.AgentManager1")
    manager.RegisterAgent(AGENT_PATH, "DisplayYesNo")
    print("Agent registered")
    manager.RequestDefaultAgent(AGENT_PATH)
    print("Default agent request completed")
    mainloop = GLib.MainLoop()
    mainloop.run()
EOF
chmod +x /usr/local/bin/bt-pin-agent.py

# Create PIN agent service
echo "Creating PIN agent service..."
cat > /etc/systemd/system/bt-pin-agent.service << 'EOF'
[Unit]
Description=Bluetooth PIN Agent
After=bluetooth.service
Requires=bluetooth.service

[Service]
ExecStart=/usr/local/bin/bt-pin-agent.py
Type=simple
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

# Create the serial service
echo "Creating serial service..."
cat > /etc/systemd/system/bt-serial.service << 'EOF'
[Unit]
Description=Bluetooth Serial Service
After=bluetooth.service bt-pin-agent.service
Requires=bluetooth.service

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/bt-serial.sh
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# Create the serial handler script with automatic connection to first paired device
cat > /usr/local/bin/bt-serial.sh << 'EOF'
#!/bin/bash

# Log file
LOGFILE="/var/log/bt-serial.log"
exec > >(tee -a "$LOGFILE") 2>&1

echo "Starting Bluetooth serial service at $(date)"

# Configure Bluetooth
echo "Configuring Bluetooth adapter..."
hciconfig hci0 up
hciconfig hci0 piscan
hciconfig hci0 name KaliPi-BT

# Disable SSP (Simple Secure Pairing) to use legacy PIN code pairing
btmgmt ssp off

# Set up SPP profile
echo "Setting up Serial Port Profile..."
sdptool add SP

# Monitor for the first device to pair and connect to it
echo "Waiting for first device to pair..."

# Function to get paired but not connected devices
get_first_paired_device() {
    bluetoothctl paired-devices | head -n 1 | cut -d ' ' -f 2
}

# Wait until we have at least one paired device
while true; do
    DEVICE=$(get_first_paired_device)
    if [ -n "$DEVICE" ]; then
        echo "Found paired device: $DEVICE"
        break
    fi
    echo "No paired devices found yet, waiting..."
    sleep 5
done

# Trust and connect to the first paired device
echo "Trusting and connecting to device: $DEVICE"
bluetoothctl trust "$DEVICE"

# Establish RFCOMM connection in client mode
echo "Establishing RFCOMM connection to $DEVICE..."
rfcomm connect hci0 "$DEVICE" 1 &
RFCOMM_PID=$!

# Give RFCOMM time to establish
sleep 3

# Check if connection was successful
if ps -p $RFCOMM_PID > /dev/null; then
    echo "RFCOMM connection established successfully"
    echo "Connecting serial port to shell..."
    # Set up shell access through the connection
    cat /dev/rfcomm0 | /bin/bash 2>&1 | cat > /dev/rfcomm0 &
    SHELL_PID=$!
else
    echo "Failed to establish RFCOMM connection, falling back to watch mode"
    rfcomm watch hci0 1 /bin/bash -c "cat /dev/rfcomm0 | /bin/bash 2>&1 | cat > /dev/rfcomm0" &
fi

# Keep the service running and log active connections
while true; do
    echo "=== Status check at $(date) ==="
    hciconfig -a
    echo "RFCOMM connections:"
    rfcomm
    
    # Check if our connection is still alive
    if [ -n "$RFCOMM_PID" ] && ! ps -p $RFCOMM_PID > /dev/null; then
        echo "RFCOMM connection lost, reconnecting..."
        rfcomm connect hci0 "$DEVICE" 1 &
        RFCOMM_PID=$!
        sleep 3
        
        # Restart shell if connection was re-established
        if ps -p $RFCOMM_PID > /dev/null; then
            if [ -n "$SHELL_PID" ] && ps -p $SHELL_PID > /dev/null; then
                kill $SHELL_PID
            fi
            cat /dev/rfcomm0 | /bin/bash 2>&1 | cat > /dev/rfcomm0 &
            SHELL_PID=$!
        fi
    fi
    
    sleep 60
done
EOF
chmod +x /usr/local/bin/bt-serial.sh

# Enable and start services
echo "Enabling and starting services..."
systemctl daemon-reload
systemctl enable bt-pin-agent.service
systemctl start bt-pin-agent.service
systemctl enable bt-serial.service
systemctl start bt-serial.service

echo "Setup complete at $(date)"
echo "PIN code is set to: 5471"
echo "Your device should appear as 'KaliPi-BT'"
echo "Please check logs at /var/log/bt-setup.log and /var/log/bt-serial.log for details"
