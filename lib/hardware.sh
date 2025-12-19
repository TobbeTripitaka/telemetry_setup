#!/bin/bash

################################################################################
# Hardware Management Library
# Functions for checking hardware connectivity and control
################################################################################

# Prevent multiple sourcing
[[ -n "${_HARDWARE_LIB_LOADED:-}" ]] && return 0
readonly _HARDWARE_LIB_LOADED=1

################################################################################
# HARDWARE DETECTION
################################################################################

# Check for critical hardware presence
check_hardware_presence() {
    log_info "Checking hardware presence..."
    
    local all_ok=0
    
    # Check USB devices
    if ! check_usb_devices; then
        log_warn "USB device check failed"
        all_ok=1
    fi
    
    # Check network interface
    if ! check_network_interface; then
        log_warn "Network interface check failed"
        all_ok=1
    fi
    
    # Check Pegasus logger connectivity (critical)
    if ! check_pegasus_connected; then
        log_error "Pegasus logger not detected - cannot proceed with harvest"
        all_ok=1
    fi
    
    # FUTURE: Check timelapse camera connectivity
    # if ! check_camera_connected; then
    #     log_warn "Timelapse camera not detected (non-critical)"
    # fi
    
    # FUTURE: Check USB relay
    # if ! check_relay_connected; then
    #     log_warn "USB relay not detected (non-critical)"
    # fi
    
    return $all_ok
}

# Enumerate and log USB devices
check_usb_devices() {
    log_info "Enumerating USB devices..."
    
    if ! command -v lsusb &>/dev/null; then
        log_warn "lsusb command not available"
        return 1
    fi
    
    local usb_count
    usb_count=$(lsusb 2>/dev/null | wc -l)
    
    if [[ $usb_count -eq 0 ]]; then
        log_warn "No USB devices detected"
        return 1
    fi
    
    log_info "USB devices detected: $usb_count"
    
    # Log each USB device
    lsusb 2>/dev/null | while IFS= read -r line; do
        log_debug "  USB: $line"
    done
    
    return 0
}

# Check if Pegasus data logger is connected
check_pegasus_connected() {
    log_info "Checking for Pegasus data logger..."
    
    # Method 1: Check if Pegasus binary can detect device
    if [[ -x "$PEGASUS_BIN" ]]; then
        # Try to run Pegasus in test mode or check its device list
        # This is a placeholder - adjust based on actual Pegasus behavior
        log_debug "Pegasus binary found at: $PEGASUS_BIN"
    else
        log_error "Pegasus binary not executable: $PEGASUS_BIN"
        return 1
    fi
    
    # Method 2: Check for specific USB vendor/product ID if known
    # Uncomment and adjust if you know the Pegasus USB IDs
    # local pegasus_vendor_id="1234"
    # local pegasus_product_id="5678"
    # if lsusb -d "${pegasus_vendor_id}:${pegasus_product_id}" &>/dev/null; then
    #     log_info "Pegasus logger detected via USB ID"
    #     return 0
    # fi
    
    # Method 3: Check for device file or serial port
    # Adjust based on how Pegasus appears on your system
    # if [[ -e /dev/ttyUSB0 ]] || [[ -e /dev/ttyACM0 ]]; then
    #     log_info "Serial device detected (possible Pegasus logger)"
    #     return 0
    # fi
    
    # For now, assume if Pegasus binary exists, device might be connected
    # This should be enhanced based on your specific hardware
    log_info "Pegasus logger check passed (basic check only)"
    log_warn "NOTE: Actual device connectivity will be verified during harvest"
    
    return 0
}

# Check network interface status
check_network_interface() {
    log_info "Checking network interfaces..."
    
    local interfaces
    interfaces=$(ip link show 2>/dev/null | grep -E '^[0-9]+:' | awk -F': ' '{print $2}' | grep -v '^lo$')
    
    if [[ -z "$interfaces" ]]; then
        log_warn "No network interfaces found (except loopback)"
        return 1
    fi
    
    log_info "Network interfaces found:"
    echo "$interfaces" | while IFS= read -r iface; do
        local status
        status=$(ip link show "$iface" 2>/dev/null | grep -o 'state [A-Z]*' | awk '{print $2}')
        log_info "  - $iface: $status"
    done
    
    return 0
}

# Check if network is actually available (can reach internet)
check_network_available() {
    log_info "Checking network connectivity..."
    
    # Try to ping a reliable host
    if timeout 10 ping -c 1 8.8.8.8 &>/dev/null; then
        log_info "Network connectivity verified (8.8.8.8 reachable)"
        return 0
    elif timeout 10 ping -c 1 1.1.1.1 &>/dev/null; then
        log_info "Network connectivity verified (1.1.1.1 reachable)"
        return 0
    else
        log_warn "Network connectivity test failed"
        return 1
    fi
}

################################################################################
# SYSTEM INFORMATION
################################################################################

# Collect and log comprehensive system information
get_system_info() {
    log_info "Collecting system information..."
    log_info "================================"
    
    # Basic system info
    log_info "Hostname: $(hostname)"
    log_info "Username: $(whoami)"
    log_info "Uptime: $(uptime -p 2>/dev/null || uptime)"
    log_info "Kernel: $(uname -r)"
    
    # Try to get last reboot time
    local last_reboot
    last_reboot=$(who -b 2>/dev/null | awk '{print $3, $4}' || echo 'N/A')
    log_info "Last reboot: $last_reboot"
    
    # CPU information
    if [[ -f /proc/cpuinfo ]]; then
        local cpu_model
        cpu_model=$(grep 'model name' /proc/cpuinfo | head -1 | awk -F': ' '{print $2}')
        log_info "CPU: $cpu_model"
        
        local cpu_cores
        cpu_cores=$(grep -c '^processor' /proc/cpuinfo)
        log_info "CPU cores: $cpu_cores"
    fi
    
    # CPU temperature (if available)
    if [[ -f /sys/class/thermal/thermal_zone0/temp ]]; then
        local temp
        temp=$(($(cat /sys/class/thermal/thermal_zone0/temp) / 1000))
        log_info "CPU temperature: ${temp}°C"
    fi
    
    # Memory information
    if [[ -f /proc/meminfo ]]; then
        local mem_total
        mem_total=$(grep MemTotal /proc/meminfo | awk '{print int($2/1024)}')
        local mem_available
        mem_available=$(grep MemAvailable /proc/meminfo | awk '{print int($2/1024)}')
        log_info "Memory: ${mem_available}MB available / ${mem_total}MB total"
    fi
    
    # Disk space
    local disk_avail
    disk_avail=$(df -h "$DATA_DIR" 2>/dev/null | tail -1 | awk '{print $4}' || echo 'N/A')
    log_info "Disk space available: $disk_avail"
    
    # Process count
    local proc_count
    proc_count=$(ps aux 2>/dev/null | wc -l || echo 'N/A')
    log_info "Running processes: $proc_count"
    
    # Get public IP if network available
    local public_ip
    public_ip=$(timeout 5 curl -s ifconfig.me 2>/dev/null || echo 'N/A')
    log_info "Public IP: $public_ip"
    
    log_info "================================"
    log_info ""
}

################################################################################
# USB RELAY CONTROL (FUTURE IMPLEMENTATION)
################################################################################

# Turn on USB relay for specified device
relay_on() {
    local device_name="$1"  # e.g., "starlink", "camera", etc.
    
    log_info "Turning ON relay for: $device_name"
    
    # FUTURE IMPLEMENTATION:
    # This will control the USB relay to power on devices
    # The actual implementation depends on your relay hardware
    # 
    # Example using usbrelay utility:
    # usbrelay RELAY1_1=1
    #
    # Or using GPIO:
    # echo "1" > /sys/class/gpio/gpio17/value
    #
    # Or using Python script:
    # python3 /home/toby/relay_control.py --device "$device_name" --action on
    
    log_warn "Relay control not yet implemented (stub function)"
    
    return 0
}

# Turn off USB relay for specified device
relay_off() {
    local device_name="$1"
    
    log_info "Turning OFF relay for: $device_name"
    
    # FUTURE IMPLEMENTATION:
    # See relay_on() for examples
    
    log_warn "Relay control not yet implemented (stub function)"
    
    return 0
}

# Check if USB relay is connected
check_relay_connected() {
    log_debug "Checking for USB relay..."
    
    # FUTURE IMPLEMENTATION:
    # Check for specific USB vendor/product ID
    # Or check for relay control device file
    
    log_warn "Relay detection not yet implemented (stub function)"
    
    return 0
}

################################################################################
# RGB LED STATUS INDICATORS (FUTURE IMPLEMENTATION)
################################################################################

# Set LED status indicator
# Status codes:
#   YELLOW_SOLID   - Initializing
#   GREEN_FLASHING - Running normally
#   BLUE_FLASHING  - Running Pegasus Harvester
#   ORANGE_FLASHING - Failed step, retrying
#   RED_SOLID      - Fatal error
#   GREEN_SOLID    - Complete success, waiting to shutdown
led_set_status() {
    local status="$1"
    
    log_debug "Setting LED status: $status"
    
    # FUTURE IMPLEMENTATION:
    # This will control an RGB LED via GPIO or serial
    #
    # Example using GPIO (RPi):
    # - Use separate GPIO pins for R, G, B
    # - Use PWM for color mixing
    # - Use timer for flashing patterns
    #
    # Example implementation structure:
    # case "$status" in
    #     YELLOW_SOLID)
    #         set_rgb 255 255 0
    #         stop_flashing
    #         ;;
    #     GREEN_FLASHING)
    #         set_rgb 0 255 0
    #         start_flashing 500  # 500ms interval
    #         ;;
    #     BLUE_FLASHING)
    #         set_rgb 0 0 255
    #         start_flashing 300
    #         ;;
    #     ORANGE_FLASHING)
    #         set_rgb 255 165 0
    #         start_flashing 200
    #         ;;
    #     RED_SOLID)
    #         set_rgb 255 0 0
    #         stop_flashing
    #         ;;
    #     GREEN_SOLID)
    #         set_rgb 0 255 0
    #         stop_flashing
    #         ;;
    # esac
    
    log_warn "LED control not yet implemented (stub function)"
    
    return 0
}

################################################################################
# EXPORT FUNCTIONS
################################################################################

export -f check_hardware_presence check_usb_devices check_pegasus_connected
export -f check_network_interface check_network_available
export -f get_system_info
export -f relay_on relay_off check_relay_connected
export -f led_set_status
