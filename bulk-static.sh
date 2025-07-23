#!/usr/bin/env bash
#
# bulk-static.sh — Bulk‐apply static IPs to all LXC containers and QEMU VMs in Proxmox
#
# Usage:
#   bulk-static.sh -g <gateway> -n <netmask> [ -a ] [ -d ] [ -h ]
#
# Options:
#   -g, --gateway    Gateway IP to assign (e.g. 192.168.0.1)
#   -n, --netmask    Netmask in CIDR form (e.g. /24)
#   -a, --auto       Auto-detect gateway and netmask from host system
#   -d, --dry-run    Show what would be done without making changes
#   -h, --help       Show this help message and exit
#
# For each LXC container in /etc/pve/lxc/*.conf and each QEMU VM in /etc/pve/qemu-server/*.conf:
#   1. Try to read the first IP matching the subnet prefix from its `tags:` line.
#   2. If no tag is found:
#      - For LXC: run `pct exec ... ip addr` to detect the current IP.
#      - For QEMU: use `qm guest cmd ... network-get-interfaces` (requires guest-agent + jq).
#   3. Clean out any existing `,gw=…` from the config and inject `,gw=<gateway>`.
#   4. Stop & start the workload so it picks up the new static‐IP config.
#

set -euo pipefail

# Print usage/help
usage() {
  sed -n '2,14p' "$0"
  exit 0
}

# Parse flags
GATEWAY=""
NETMASK=""
AUTO=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -g|--gateway)
      GATEWAY="$2"; shift 2;;
    -n|--netmask)
      NETMASK="$2"; shift 2;;
    -a|--auto)
      AUTO=true; shift;;
    -d|--dry-run)
      DRY_RUN=true; shift;;
    -h|--help)
      usage;;
    *)
      echo "Unknown option: $1"; usage;;
  esac
done

# Auto-detect gateway and netmask if requested
if [[ "$AUTO" == "true" ]]; then
  echo "→ Auto-detecting network configuration..."

  # Get default route info
  DEFAULT_ROUTE=$(ip route | grep '^default' | head -1)
  if [[ -z "$DEFAULT_ROUTE" ]]; then
    echo "Error: Cannot auto-detect - no default route found."
    exit 1
  fi

  # Extract gateway and interface
  AUTO_GATEWAY=$(echo "$DEFAULT_ROUTE" | awk '{print $3}')
  AUTO_INTERFACE=$(echo "$DEFAULT_ROUTE" | awk '{print $5}')

  # Get netmask from interface
  AUTO_NETMASK=$(ip addr show "$AUTO_INTERFACE" | awk '/inet /{print $2}' | head -1 | cut -d/ -f2)

  if [[ -z "$AUTO_GATEWAY" || -z "$AUTO_NETMASK" ]]; then
    echo "Error: Auto-detection failed. Gateway: $AUTO_GATEWAY, Netmask: /$AUTO_NETMASK"
    exit 1
  fi

  GATEWAY="$AUTO_GATEWAY"
  NETMASK="/$AUTO_NETMASK"
  echo "   • Auto-detected: gateway=$GATEWAY, netmask=$NETMASK"
fi

# Validate required flags (unless auto-detected)
if [[ -z "$GATEWAY" || -z "$NETMASK" ]]; then
  echo "Error: both --gateway and --netmask are required (or use --auto)."
  usage
fi

# Validate netmask format (/8, /16, /24, etc)
if [[ ! $NETMASK =~ ^/[0-9]+$ ]]; then
  echo "Error: netmask must be in CIDR form (e.g. /24)."
  exit 1
fi
BITS=${NETMASK#/}
if (( BITS % 8 != 0 )); then
  echo "Error: only octet-aligned netmasks (/8, /16, /24) are supported."
  exit 1
fi

# Derive subnet prefix (e.g. "192.168.0") from gateway + mask
OCTETS=$((BITS/8))
SUBNET_PREFIX=$(echo "$GATEWAY" | cut -d. -f1-"$OCTETS")

# Initialize counters
LXC_PROCESSED=0
LXC_SKIPPED=0
LXC_ERRORS=0
VM_PROCESSED=0
VM_SKIPPED=0
VM_ERRORS=0

# Ensure 'jq' is installed for VM guest-agent parsing
if ! command -v jq &>/dev/null; then
  echo "Error: 'jq' is required for VM IP detection. Please install it."
  exit 1
fi

# Check if LXC container is running
is_lxc_running() {
  local vmid="$1"
  pct status "$vmid" 2>/dev/null | grep -q "status: running"
}

# Check if QEMU VM is running
is_vm_running() {
  local vmid="$1"
  qm status "$vmid" 2>/dev/null | grep -q "status: running"
}

# Check if LXC container already has correct static IP configuration
lxc_has_correct_config() {
  local cfg="$1"
  local expected_ip="$2"
  local expected_gateway="$3"
  local expected_netmask="$4"

  # Check if net0 line has the expected IP and gateway
  local net0_line=$(grep "^net0:" "$cfg" 2>/dev/null || true)
  if [[ -z "$net0_line" ]]; then
    return 1
  fi

  # Extract current IP and gateway from net0 line
  local current_ip=$(echo "$net0_line" | sed -n 's/.*ip=\([0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+\/[0-9]\+\).*/\1/p')
  local current_gw=$(echo "$net0_line" | sed -n 's/.*,gw=\([0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+\).*/\1/p')

  # Compare with expected values
  if [[ "$current_ip" == "${expected_ip}${expected_netmask}" && "$current_gw" == "$expected_gateway" ]]; then
    return 0
  else
    return 1
  fi
}

# Check if QEMU VM already has correct static IP configuration
vm_has_correct_config() {
  local cfg="$1"
  local expected_ip="$2"
  local expected_gateway="$3"
  local expected_netmask="$4"

  # Check ipconfig0 line
  local ipconfig_line=$(grep "^ipconfig0:" "$cfg" 2>/dev/null || true)
  if [[ -z "$ipconfig_line" ]]; then
    return 1
  fi

  # Extract current IP and gateway from ipconfig0 line
  local current_config=$(echo "$ipconfig_line" | sed 's/^ipconfig0: *//')
  local current_ip=$(echo "$current_config" | sed -n 's/.*ip=\([0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+\/[0-9]\+\).*/\1/p')
  local current_gw=$(echo "$current_config" | sed -n 's/.*,gw=\([0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+\).*/\1/p')

  # Compare with expected values
  if [[ "$current_ip" == "${expected_ip}${expected_netmask}" && "$current_gw" == "$expected_gateway" ]]; then
    return 0
  else
    return 1
  fi
}

# Dry-run helper function
run_cmd() {
  local cmd="$1"
  local description="$2"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "   [DRY-RUN] Would run: $cmd"
    if [[ -n "$description" ]]; then
      echo "             → $description"
    fi
  else
    eval "$cmd"
  fi
}

echo "→ Bulk‐static starting: gateway=${GATEWAY}, netmask=${NETMASK}, subnet=${SUBNET_PREFIX}.×"
if [[ "$DRY_RUN" == "true" ]]; then
  echo "→ DRY-RUN MODE: No changes will be made"
else
  echo "→ WARNING: This will modify configs and restart running containers/VMs!"
  read -p "→ Continue? [y/N]: " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "→ Aborted by user"
    exit 0
  fi
fi
echo

##################################
# 1) LXC Containers
##################################
echo "=== Processing LXC containers ==="
for cfg in /etc/pve/lxc/*.conf; do
  # Skip if no config files exist (glob didn't match)
  [[ ! -f "$cfg" ]] && echo "   • No LXC containers found" && break

  vmid=$(basename "$cfg" .conf)
  echo "-- LXC #$vmid"

  # Check if container has network config
  if ! grep -q "^net0:" "$cfg"; then
    echo "   • No network interface configured - skipping"
    LXC_SKIPPED=$((LXC_SKIPPED + 1))
    continue
  fi

  # Try to read tag-based IP
  tagip=$(awk -F'tags: ' '/^tags:/{
             split($2,a,";");
             for(i in a) if (a[i] ~ /^'"$SUBNET_PREFIX"'\.[0-9]+$/) { print a[i]; exit }
           }' "$cfg")

  # Fallback: query live container via pct exec (only if running)
  if [[ -z "$tagip" ]]; then
    echo "   • No tag → querying live IP inside container"
    if is_lxc_running "$vmid"; then
      tagip=$(pct exec "$vmid" -- ip -4 addr show eth0 2>/dev/null \
               | awk '/inet /{print $2}' \
               | cut -d/ -f1 \
               | grep -m1 "^${SUBNET_PREFIX}\." || true)
    fi
    if [[ -z "$tagip" ]]; then
      echo "   !! Could not detect IP in ${SUBNET_PREFIX}.× (container not running or no IP) — skipping"
      LXC_SKIPPED=$((LXC_SKIPPED + 1))
      continue
    fi
  fi

  echo "   • Using IP ${tagip}${NETMASK}, gw=${GATEWAY}"

  # Check if container already has correct configuration
  if lxc_has_correct_config "$cfg" "$tagip" "$GATEWAY" "$NETMASK"; then
    echo "   • Container already has correct static IP configuration - skipping"
    LXC_SKIPPED=$((LXC_SKIPPED + 1))
    continue
  fi

  # Check if container is running
  container_was_running=false
  if is_lxc_running "$vmid"; then
    container_was_running=true
    echo "   • Container is running"
  else
    echo "   • Container is stopped"
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "   [DRY-RUN] Would backup: cp -p $cfg ${cfg}.bak.static"
    echo "   [DRY-RUN] Would modify network config in: $cfg"
    if [[ "$container_was_running" == "true" ]]; then
      echo "   [DRY-RUN] Would stop LXC #$vmid"
      echo "   [DRY-RUN] Would start LXC #$vmid"
    else
      echo "   [DRY-RUN] Container stopped - no restart needed"
    fi
  else
    cp -p "$cfg" "${cfg}.bak.static"    # backup

    # Clean existing gw= entries, then inject correct IP and gateway
    netmask_escaped="${NETMASK//\//\\\/}"
    new_ip="${tagip}${netmask_escaped}"
    
    # Remove existing gateway settings and update IP
    sed -i 's/,gw=[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+//g' "$cfg"
    sed -i "s/ip=dhcp/ip=${new_ip}/" "$cfg"
    sed -i "s/ip=[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+\/[0-9]\+/ip=${new_ip}/" "$cfg"
    
    # Add gateway to the IP configuration
    sed -i "s/\(ip=[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+\/[0-9]\+\)/\1,gw=${GATEWAY}/" "$cfg"

    if [[ "$container_was_running" == "true" ]]; then
      echo "   • Stopping & starting LXC #$vmid"
      if pct stop "$vmid" 2>/dev/null; then
        if ! pct start "$vmid" 2>/dev/null; then
          echo "   !! ERROR: Failed to start LXC #$vmid"
          LXC_ERRORS=$((LXC_ERRORS + 1))
        else
          LXC_PROCESSED=$((LXC_PROCESSED + 1))
        fi
      else
        echo "   !! ERROR: Failed to stop LXC #$vmid"
        LXC_ERRORS=$((LXC_ERRORS + 1))
      fi
    else
      echo "   • Container stopped - config updated without restart"
      LXC_PROCESSED=$((LXC_PROCESSED + 1))
    fi
  fi
done

##################################
# 2) QEMU VMs
##################################
echo
echo "=== Processing QEMU VMs ==="
for cfg in /etc/pve/qemu-server/*.conf; do
  # Skip if no config files exist (glob didn't match)
  [[ ! -f "$cfg" ]] && echo "   • No QEMU VMs found" && break

  vmid=$(basename "$cfg" .conf)
  echo "-- VM #$vmid"

  # Check if VM has network config (for Cloud-Init)
  if ! grep -q "^net0:" "$cfg" && ! grep -q "^ipconfig0:" "$cfg"; then
    echo "   • No network interface or ipconfig configured - skipping"
    VM_SKIPPED=$((VM_SKIPPED + 1))
    continue
  fi

  # Try to read tag-based IP
  tagip=$(awk -F'tags: ' '/^tags:/{
             split($2,a,";");
             for(i in a) if (a[i] ~ /^'"$SUBNET_PREFIX"'\.[0-9]+$/) { print a[i]; exit }
           }' "$cfg")

  # Fallback: query via guest agent (requires agent + jq and running VM)
  if [[ -z "$tagip" ]]; then
    echo "   • No tag → querying via QEMU Guest Agent"
    if is_vm_running "$vmid"; then
      json=$(timeout 10 qm guest cmd "$vmid" network-get-interfaces 2>/dev/null || true)
      if [[ -n "$json" ]]; then
        tagip=$(echo "$json" \
          | jq -r '.[]
                     | select(.name=="eth0")
                     | .["ip-addresses"][]
                     | select(.family=="ipv4")
                     | .["ip-address"]' 2>/dev/null \
          | grep -m1 "^${SUBNET_PREFIX}\." || true)
      fi
    fi
    if [[ -z "$tagip" ]]; then
      echo "   !! Could not detect IP in ${SUBNET_PREFIX}.× (VM not running, no guest agent, or no IP) — skipping"
      VM_SKIPPED=$((VM_SKIPPED + 1))
      continue
    fi
  fi

  echo "   • Using IP ${tagip}${NETMASK}, gw=${GATEWAY}"

  # Check if VM already has correct configuration
  if vm_has_correct_config "$cfg" "$tagip" "$GATEWAY" "$NETMASK"; then
    echo "   • VM already has correct static IP configuration - skipping"
    VM_SKIPPED=$((VM_SKIPPED + 1))
    continue
  fi

  # Check if VM is running
  vm_was_running=false
  if is_vm_running "$vmid"; then
    vm_was_running=true
    echo "   • VM is running"
  else
    echo "   • VM is stopped"
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "   [DRY-RUN] Would run: qm set $vmid --ipconfig0 ip=${tagip}${NETMASK},gw=${GATEWAY}"
    if [[ "$vm_was_running" == "true" ]]; then
      echo "   [DRY-RUN] Would stop VM #$vmid"
      echo "   [DRY-RUN] Would start VM #$vmid"
    else
      echo "   [DRY-RUN] VM stopped - no restart needed"
    fi
  else
    # Apply via qm set (Cloud-Init)
    qm set "$vmid" --ipconfig0 "ip=${tagip}${NETMASK},gw=${GATEWAY}"

    if [[ "$vm_was_running" == "true" ]]; then
      echo "   • Stopping & starting VM #$vmid"
      if qm stop "$vmid" --skiplock 2>/dev/null; then
        if ! qm start "$vmid" 2>/dev/null; then
          echo "   !! ERROR: Failed to start VM #$vmid"
          VM_ERRORS=$((VM_ERRORS + 1))
        else
          VM_PROCESSED=$((VM_PROCESSED + 1))
        fi
      else
        echo "   !! ERROR: Failed to stop VM #$vmid"
        ((VM_ERRORS++))
      fi
    else
      echo "   • VM stopped - config updated without restart"
      VM_PROCESSED=$((VM_PROCESSED + 1))
    fi
  fi
done

echo
echo "=== Summary ==="
echo "LXC Containers: $LXC_PROCESSED processed, $LXC_SKIPPED skipped, $LXC_ERRORS errors"
echo "QEMU VMs:       $VM_PROCESSED processed, $VM_SKIPPED skipped, $VM_ERRORS errors"
echo
if (( LXC_ERRORS + VM_ERRORS > 0 )); then
  echo "⚠️  Completed with errors. Check output above for details."
else
  echo "✅ All operations completed successfully!"
fi
echo
echo "Verify examples:"
echo "   grep '^net0:' /etc/pve/lxc/101.conf"
echo "   qm config 200 | grep ipconfig0"
