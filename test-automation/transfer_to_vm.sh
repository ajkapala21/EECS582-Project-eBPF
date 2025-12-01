#!/bin/bash
# Transfer test-automation directory to VM
# Usage: ./transfer_to_vm.sh <vm_hostname_or_ip>

set -e

VM_HOST=$1

if [ -z "$VM_HOST" ]; then
    echo "Usage: $0 <vm_hostname_or_ip>"
    echo "Example: $0 nikhil-vm-2"
    echo "Example: $0 192.168.1.100"
    echo "Example: $0 user@192.168.1.100"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "Transferring test-automation to $VM_HOST..."
rsync -avz --progress "$SCRIPT_DIR/" "$VM_HOST:~/EECS582-Project-eBPF/test-automation/"

echo ""
echo "Transfer complete!"
echo ""
echo "On the VM, run:"
echo "  cd ~/EECS582-Project-eBPF/test-automation"
echo "  chmod +x scripts/*.sh scripts/workloads/*.sh"

