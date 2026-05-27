#!/bin/bash

# Check for jq and install if missing
if ! command -v jq &> /dev/null; then
    echo "Installing jq..."
    apt-get update && apt-get install -y jq
fi

# API credentials
API_HOST="https://dash.simplux.xyz:8006"
API_TOKEN="root@pam!auto-billing=dc39fabe-c253-48f1-84e4-e07d2168563d"

# Template mapping (source_id:template_name)
declare -A templates=(
    [9009]="debian11bullseye"
    [9010]="debian12bookworm"
    [9011]="debian13trixie"
    [9015]="fedora37"
    [9016]="fedora38"
    [9017]="rocky8"
    [9018]="rocky9"
    [9019]="alpine319"
)

# Source and destination nodes
SOURCE_NODE="s1"
DEST_NODES=("s2" "s3")

# Starting VMID for clones
NEXT_ID=9100

# Function to check if template exists by name
template_exists() {
    local node="$1"
    local template_name="$2"
    
    # Get list of all VMs on the node
    local vms=$(call_api "/nodes/${node}/qemu" "GET")
    
    # Check if any VM has matching name and is a template
    echo "$vms" | jq -r '.data[] | select(.template == 1) | .name' | grep -q "^${template_name}$"
    return $?
}

# Function to make API calls
call_api() {
    local endpoint="$1"
    local method="$2"
    local data="$3"
    
    if [ -n "$data" ]; then
        curl -k -s -X "$method" \
            -H "Authorization: PVEAPIToken=$API_TOKEN" \
            -H "Content-Type: application/json" \
            -d "$data" \
            "${API_HOST}/api2/json${endpoint}"
    else
        curl -k -s -X "$method" \
            -H "Authorization: PVEAPIToken=$API_TOKEN" \
            "${API_HOST}/api2/json${endpoint}"
    fi
}

# Function to wait for task completion
wait_for_task() {
    local node="$1"
    local task_id="$2"
    local max_attempts=60
    local attempt=0
    
    echo "Waiting for task $task_id to complete..."
    while [ $attempt -lt $max_attempts ]; do
        local status=$(call_api "/nodes/${node}/tasks/${task_id}/status" "GET" | jq -r '.data.status')
        
        if [ "$status" = "stopped" ]; then
            local exitstatus=$(call_api "/nodes/${node}/tasks/${task_id}/status" "GET" | jq -r '.data.exitstatus')
            if [ "$exitstatus" = "OK" ]; then
                echo "Task completed successfully"
                return 0
            else
                echo "Task failed with status: $exitstatus"
                return 1
            fi
        fi
        
        attempt=$((attempt + 1))
        sleep 10
    done
    
    echo "Timeout waiting for task completion"
    return 1
}

# Main script
echo "Starting template transfer process..."

# Process each template
for source_vmid in "${!templates[@]}"; do
    template_name="${templates[$source_vmid]}"
    echo "Processing template: $template_name (Source VMID: $source_vmid)"
    
    # Clone to each destination node
    for dest_node in "${DEST_NODES[@]}"; do
        # Check if template already exists on destination
        if template_exists "$dest_node" "$template_name"; then
            echo "Template $template_name already exists on $dest_node, skipping..."
            continue
        fi
        
        echo "Cloning to node $dest_node with new ID: $NEXT_ID..."
        
        # Create full clone with new ID
        response=$(call_api "/nodes/${SOURCE_NODE}/qemu/${source_vmid}/clone" "POST" \
            "{\"newid\": \"${NEXT_ID}\", \"target\": \"${dest_node}\", \"full\": 1, \"name\": \"${template_name}\"}")
        
        # Extract task ID
        task_id=$(echo "$response" | jq -r '.data')
        
        if [ -n "$task_id" ] && [ "$task_id" != "null" ]; then
            # Wait for clone to complete
            if wait_for_task "$SOURCE_NODE" "$task_id"; then
                echo "Successfully cloned $template_name to $dest_node as VMID $NEXT_ID"
                # Convert the cloned VM to template
                convert_response=$(call_api "/nodes/${dest_node}/qemu/${NEXT_ID}/template" "POST")
                echo "Converting to template on $dest_node..."
                if [[ $(echo "$convert_response" | jq -r '.data') == "null" ]]; then
                    echo "Successfully converted VMID $NEXT_ID to template on $dest_node"
                else
                    echo "Failed to convert VMID $NEXT_ID to template on $dest_node"
                    echo "API Response: $convert_response"
                fi
            else
                echo "Failed to clone $template_name to $dest_node"
            fi
        else
            echo "Failed to start clone task for $template_name to $dest_node"
            echo "API Response: $response"
        fi
        
        # Increment ID for next clone
        NEXT_ID=$((NEXT_ID + 1))
    done
done

echo "Template transfer process completed"
