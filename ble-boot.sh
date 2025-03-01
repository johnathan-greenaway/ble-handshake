#!/bin/bash

# Log everything
LOGFILE="/var/log/bt-setup.log"
exec > >(tee -a "$LOGFILE") 2>&1

echo "Starting Bluetooth setup at $(date)"

# Install required packages
apt-get update
apt-get install -y bluetooth bluez bluez-tools python3-dbus python3-gi rfkill

# Completely stop and reset Bluetooth
echo "Resetting Bluetooth stack..."
systemctl stop bluetooth
modprobe -r btusb
modprobe -r bluetooth
sleep 2
modprobe bluetooth
modprobe btusb
sleep 2

# Ensure firmware is loaded
echo "Loading Bluetooth firmware..."
if [ -f /lib/firmware/brcm/BCM43430A1.hcd ]; then
    echo "Raspberry Pi 3/Zero W firmware found"
elif [ -f /lib/firmware/brcm/BCM4345C0.hcd ]; then
    echo "Raspberry Pi 3B+/4 firmware found"
else
    echo "WARNING: Could not find Bluetooth firmware files"
fi

# Restart Bluetooth with clean config
echo "Starting Bluetooth service..."
systemctl start bluetooth
sleep 5

# Confirm Bluetooth is working
echo "Checking Bluetooth status:"
if ! hciconfig -a | grep -q "hci0"; then
    echo "ERROR: No Bluetooth adapter found! Trying to fix..."
    # Try to reset the Bluetooth hardware
    rfkill unblock bluetooth
    sleep 2
    
    # Check if we have an adapter now
    if ! hciconfig -a | grep -q "hci0"; then
        echo "CRITICAL: Still no Bluetooth adapter found. Script cannot continue."
        exit 1
    fi
fi

# Show detected Bluetooth adapter
hciconfig -a

# Remove existing audio profiles by modifying main.conf
echo "Disabling audio profiles..."
cat > /etc/bluetooth/main.conf << 'EOF'
[General]
Name = KaliPi-BT
Class = 0x000100
DiscoverableTimeout = 0
PairableTimeout = 0
AutoConnectTimeout = 60000

[Policy]
AutoEnable=true

# Disable audio profiles
Disable=audio,media,a2dp,avrcp
EOF

# Restart Bluetooth again with new configuration
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

# Create the serial handler script
echo "Creating serial handler script..."
cat > /usr/local/bin/bt-serial.sh << 'EOF'
#!/bin/bash

# Log file
LOGFILE="/var/log/bt-serial.log"
exec > >(tee -a "$LOGFILE") 2>&1

echo "Starting Bluetooth serial service at $(date)"

# Make sure device exists
if ! hciconfig -a | grep -q "hci0"; then
    echo "ERROR: No Bluetooth adapter found"
    systemctl restart bluetooth
    sleep 3
    
    if ! hciconfig -a | grep -q "hci0"; then
        echo "CRITICAL: Still no Bluetooth adapter. Exiting."
        exit 1
    fi
fi

# Configure Bluetooth adapter
echo "Configuring Bluetooth adapter..."
hciconfig hci0 up
hciconfig hci0 reset
sleep 1

# Set class to Serial Port device only (0x000100)
hciconfig hci0 class 0x000100
hciconfig hci0 name KaliPi-BT
hciconfig hci0 piscan

# Disable SSP for classic PIN code
echo "Disabling Simple Secure Pairing..."
btmgmt ssp off

# Make sure there are no stale RFCOMM sessions
echo "Cleaning up any existing RFCOMM sessions..."
killall rfcomm 2>/dev/null
sleep 1

# Remove existing services
echo "Removing any existing service profiles..."
for i in $(sdptool browse local | grep "Service RecHandle" | awk '{print $3}'); do
    sdptool del $i
done

# Register only the Serial Port Profile
echo "Registering Serial Port Profile..."
sdptool add --channel=1 SP

# Start RFCOMM in watch mode
echo "Starting RFCOMM watch on channel 1..."
rfcomm watch hci0 1 /bin/bash -c "cat /dev/rfcomm0 | /bin/bash 2>&1 | cat > /dev/rfcomm0" &
RFCOMM_PID=$!

# Keep the service running
while true; do
    echo "=== Status check at $(date) ==="
    
    # Verify adapter is up
    if ! hciconfig -a | grep -q "UP RUNNING"; then
        echo "Adapter down, bringing it up..."
        hciconfig hci0 up
        hciconfig hci0 class 0x000100
        hciconfig hci0 piscan
    fi
    
    # Check if RFCOMM process is running
    if ! ps -p $RFCOMM_PID > /dev/null; then
        echo "RFCOMM process died, restarting..."
        rfcomm watch hci0 1 /bin/bash -c "cat /dev/rfcomm0 | /bin/bash 2>&1 | cat > /dev/rfcomm0" &
        RFCOMM_PID=$!
    fi
    
    # Display current status
    echo "Current adapter status:"
    hciconfig -a
    
    echo "Current services:"
    sdptool browse local
    
    echo "RFCOMM status:"
    rfcomm
    
    sleep 60
done
EOF
chmod +x /usr/local/bin/bt-serial.sh

# Create services
echo "Creating systemd services..."
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
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# Create control script
echo "Creating control script..."
cat > /usr/local/bin/bt-control << 'EOF'
#!/bin/bash

# Display usage if no parameters given
if [ -z "$1" ]; then
    echo "Usage: bt-control [start|stop|restart|status|enable|disable]"
    exit 1
fi

case "$1" in
    start)
        echo "Starting Bluetooth serial services..."
        systemctl start bt-pin-agent.service
        systemctl start bt-serial.service
        ;;
    stop)
        echo "Stopping Bluetooth serial services..."
        systemctl stop bt-serial.service
        systemctl stop bt-pin-agent.service
        ;;
    restart)
        echo "Restarting Bluetooth stack and services..."
        systemctl stop bt-serial.service
        systemctl stop bt-pin-agent.service
        systemctl stop bluetooth
        sleep 2
        systemctl start bluetooth
        sleep 3
        systemctl start bt-pin-agent.service
        systemctl start bt-serial.service
        ;;
    status)
        echo "=== Bluetooth Service Status ==="
        systemctl status bluetooth
        echo "=== PIN Agent Status ==="
        systemctl status bt-pin-agent.service
        echo "=== Serial Service Status ==="
        systemctl status bt-serial.service
        echo "=== RFCOMM Connections ==="
        rfcomm
        echo "=== Bluetooth Adapter Status ==="
        hciconfig -a
        echo "=== Bluetooth Services ==="
        sdptool browse local
        ;;
    enable)
        echo "Enabling Bluetooth serial services to start at boot..."
        systemctl enable bt-pin-agent.service
        systemctl enable bt-serial.service
        ;;
    disable)
        echo "Disabling Bluetooth serial services at boot..."
        systemctl disable bt-serial.service
        systemctl disable bt-pin-agent.service
        ;;
    *)
        echo "Unknown command: $1"
        echo "Usage: bt-control [start|stop|restart|status|enable|disable]"
        exit 1
        ;;
esac

exit 0
EOF
chmod +x /usr/local/bin/bt-control

# Enable services
echo "Enabling services to start at boot..."
systemctl daemon-reload
systemctl enable bt-pin-agent.service
systemctl enable bt-serial.service

# Start services
echo "Starting services..."
systemctl start bt-pin-agent.service
systemctl start bt-serial.service

echo "Setup complete at $(date)"
echo "PIN code is set to: 5471"
echo "Your device should appear as 'KaliPi-BT'"
echo "Use '/usr/local/bin/bt-control [start|stop|restart|status|enable|disable]' to control the service"
echo "You MUST reboot for all changes to take full effect"
echo "Please run: sudo reboot"
