#!/bin/bash
# SSH Key Management - Crabman Stan
# This Script generates a public/private key pair for each device within the text file provided and then copies
# the key pair to the remote device via ansible
# Once copied it then removes the private key from the ansible server and appends the public key of the remote device to the git user

# Variables - defined first so they can be used as defaults
KEY_DIR="WHERE THE KEYS WILL BE STORED"
USER="REMOTE USER"
GIT_USER="GIT USER ON SERVER"
INVENTORY_FILE="INVENTORY.YAML"
HOSTS_FILE="LIST OF HOSTNAMES"
DOMAIN="example.ts.net"

# Function to backup git user's authorized_keys file
backup_git_auth_keys() {
    local backup_file="/home/$GIT_USER/.ssh/authorized_keys.backup"
    echo "Creating backup of git user's authorized_keys file..."
    if sudo cp "/home/$GIT_USER/.ssh/authorized_keys" "$backup_file"; then
        sudo chmod 600 "$backup_file"
        sudo chown "$GIT_USER:$GIT_USER" "$backup_file"
        echo "Backup created successfully at $backup_file"
    else
        echo "Failed to create backup of authorized_keys file"
        exit 1
    fi
}

# Function to get user input for variables
get_user_input() {
    read -p "Enter directory to store keys [$KEY_DIR]: " input_key_dir
    KEY_DIR=${input_key_dir:-"/home/ubuntu/ssh_keys/gateway_key_pairs"}

    read -p "Enter target user [$USER]: " input_user
    USER=${input_user:-"ansible"}

    read -p "Enter git user [$GIT_USER]: " input_git_user
    GIT_USER=${input_git_user:-"git"}

    read -p "Enter inventory file path [$INVENTORY_FILE]: " input_inventory
    INVENTORY_FILE=${input_inventory:-"/home/ubuntu/nomad-ansible/dev/inventory.yaml"}

    read -p "Do you want to target one host or multiple hosts? (one/multiple) [multiple]: " target_choice
    TARGET_CHOICE=${target_choice:-"multiple"}

    if [[ "$TARGET_CHOICE" == "one" ]]; then
        read -p "Enter the hostname: " input_host
        HOSTS_FILE=$(mktemp)
        echo "$input_host" > "$HOSTS_FILE"
    else
        read -p "Enter hosts file name [$HOSTS_FILE]: " input_hosts
        HOSTS_FILE=${input_hosts:-"/home/ubuntu/nomad-ansible/dev/pull/hosts_uniq.txt"}
    fi

    # Validate inputs
    if [[ ! -f "$INVENTORY_FILE" ]]; then
        echo "Error: Inventory file does not exist!"
        exit 1
    fi

    if [[ ! -f "$HOSTS_FILE" ]]; then
        echo "Error: Hosts file does not exist!"
        exit 1
    fi

    # Create key directory if it doesn't exist
    mkdir -p "$KEY_DIR"
}

# Function to validate inventory file format
validate_inventory() {
    if ! grep -q "gateways:" "$INVENTORY_FILE"; then
        echo "Error: Invalid inventory format - missing 'gateways' group"
        exit 1
    fi
}

# Function to extract hostname from Tailscale address
get_hostname() {
    local fqdn=$1
    echo "${fqdn%.$DOMAIN}"
}

# Function to display mode selection menu
select_mode() {
    echo "Select operation mode:"
    echo "1) Generate and push SSH keys"
    echo "2) Push existing SSH keys only"
    read -p "Enter choice [1-2]: " mode_choice

    case $mode_choice in
        1) return 0 ;; # Generate and push
        2) return 1 ;; # Push only
        *) echo "Invalid choice"; exit 1 ;;
    esac
}

# Function to display progress bar
show_progress() {
    local current=$1
    local total=$2
    local width=50
    local percentage=$((current * 100 / total))
    local completed=$((width * current / total))
    local remaining=$((width - completed))
    
    printf "\rProgress: [%${completed}s%${remaining}s] %d%% (%d/%d)" \
           "$(printf '#%.0s' $(seq 1 $completed))" \
           "$(printf ' %.0s' $(seq 1 $remaining))" \
           "$percentage" "$current" "$total"
}

# Remove the duplicate variable declarations here
# Start main script execution
get_user_input
backup_git_auth_keys
select_mode
GENERATE_KEYS=$?

# Step 1: Read hosts from the specified file
echo "Reading hosts from $HOSTS_FILE..."
if [[ ! -f "$HOSTS_FILE" ]]; then
    echo "Error: $HOSTS_FILE does not exist."
    exit 1
fi

# Count total hosts for progress bar
TOTAL_HOSTS=$(wc -l < "$HOSTS_FILE")
CURRENT_HOST=0

# Step 2: Iterate over each host to generate and push unique SSH keys
while IFS= read -r HOST; do
    ((CURRENT_HOST++))
    show_progress $CURRENT_HOST $TOTAL_HOSTS
    
    echo -e "\nProcessing $HOST..."
    KEY_PATH="$KEY_DIR/id_ed25519_$HOST"
    
    if [ $GENERATE_KEYS -eq 0 ]; then
        echo "Generating SSH key pair for $HOST..."
        # Remove existing keys first to avoid prompt
        rm -f "$KEY_PATH" "$KEY_PATH.pub" 2>/dev/null
        ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" || { echo "Key generation failed for $HOST"; continue; }
    else
        # Check if keys exist when in push-only mode
        if [[ ! -f "$KEY_PATH" || ! -f "$KEY_PATH.pub" ]]; then
            echo "Error: Keys for $HOST not found at $KEY_PATH"
            continue
        fi
    fi

    # Step 3: Create Ansible Playbook to Push Keys
    PLAYBOOK_CONTENT=$(cat <<EOF
---
    - name: Push SSH public key to target host
      hosts: "$HOST"
      vars:
        random_password: "{{ lookup('pipe', 'openssl rand -base64 32') }}"
      tasks:
        - name: Ensure the user '$USER' exists and has a psuedorandom password
          user:
            name: "$USER"
            state: present
            create_home: yes
            shell: /bin/bash
            groups: sudo
            password: "{{ random_password | password_hash('sha512') }}"
            password_lock: yes  # Disable password login
            expires: -1        # Remove password expiry
            password_expire_max: 2000
          become: yes

        - name: Allow ansible user to use sudo without password
          become: yes
          lineinfile:
            path: /etc/sudoers.d/ansible
            line: "ansible ALL=(ALL) NOPASSWD:ALL"
            create: yes
            mode: '0440'
            validate: 'visudo -cf %s'

        - name: Ensure the $USER group exists
          group:
            name: $USER
            state: present
          become: yes

        - name: Ensure the home directory exists for user $USER and is owned by them
          become: yes
          file:
            path: /home/$USER/
            state: directory
            owner: $USER
            group: $USER
            mode: '0700'
            recurse: yes

        - name: Ensure the .ssh directory exists for user $USER
          become: yes
          file:
            path: /home/$USER/.ssh
            state: directory
            owner: $USER
            group: $USER
            mode: '0700'

        - name: Copy the public key to the target hosts authorized_keys
          become: yes
          copy:
            src: "$KEY_PATH.pub"
            dest: /home/$USER/.ssh/authorized_keys
            owner: $USER
            group: $USER
            mode: '0600'

        - name: Copy the public key to the target host
          become: yes
          copy:
            src: "$KEY_PATH.pub"
            dest: /home/$USER/.ssh/id_ed25519.pub
            owner: $USER
            group: $USER
            mode: '0600'

        - name: Copy the private key to the target host
          become: yes
          copy:
            src: "$KEY_PATH"
            dest: /home/$USER/.ssh/id_ed25519
            owner: $USER
            group: $USER
            mode: '0600'

        - name: Ensure the authorized_keys file has the correct permissions
          become: yes
          file:
            path: /home/$USER/.ssh/authorized_keys
            owner: $USER
            group: $USER
            mode: '0600'
EOF
)

    # Save the playbook to a temporary file
    PLAYBOOK_FILE=$(mktemp)
    echo "$PLAYBOOK_CONTENT" > "$PLAYBOOK_FILE"

    # Step 4: Push the SSH key to the host
    echo "Pushing SSH public key to $HOST..."
    ansible-playbook -i "$INVENTORY_FILE" "$PLAYBOOK_FILE" \
        --limit "$HOST" \
        --ssh-extra-args='-o StrictHostKeyChecking=no' || \
        { echo "Failed to push key to $HOST" && echo "$HOST" >> failed_to_connect.txt; }

    # Clean up the temporary playbook file
    rm "$PLAYBOOK_FILE"
    
    # Step 5: Copy the public key to the git user's authorized_keys on the same server
    echo "Copying public key to $GIT_USER's authorized_keys..."
    if ! sudo bash -c "if ! grep -q \"$(cat $KEY_PATH.pub)\" /home/$GIT_USER/.ssh/authorized_keys; then cat $KEY_PATH.pub >> /home/$GIT_USER/.ssh/authorized_keys; fi && chmod 600 /home/$GIT_USER/.ssh/authorized_keys"; then
        echo "Failed to copy public key to $GIT_USER's authorized_keys for $HOST" >> failed_to_append.txt
    fi


done < "$HOSTS_FILE"
echo # New line after progress bar

# Function to retry failed hosts
retry_failed_hosts() {
    local failed_hosts="$1"
    echo "Retrying failed hosts from $failed_hosts..."
    
    TOTAL_RETRY=$(wc -l < "$failed_hosts")
    CURRENT_RETRY=0
    
    while IFS= read -r HOST; do
        ((CURRENT_RETRY++))
        show_progress $CURRENT_RETRY $TOTAL_RETRY
        echo -e "\nRetrying $HOST..."
        KEY_PATH="$KEY_DIR/id_ed25519_$HOST"
        
        # Create temporary playbook for this host
        PLAYBOOK_FILE=$(mktemp)
        echo "$PLAYBOOK_CONTENT" > "$PLAYBOOK_FILE"

        # Retry pushing the SSH key to the host
        echo "Pushing SSH public key to $HOST..."
        if ansible-playbook -i "$INVENTORY_FILE" "$PLAYBOOK_FILE" \
            --limit "$HOST" \
            --ssh-extra-args='-o StrictHostKeyChecking=no'; then
            # If successful, remove the host from failed_to_connect.txt
            sed -i "/$HOST/d" "$failed_hosts"
        fi

        rm "$PLAYBOOK_FILE"
        
        # Copy the public key to git user's authorized_keys
        echo "Copying public key to $GIT_USER's authorized_keys..."
        if ! sudo bash -c "if ! grep -q \"$(cat $KEY_PATH.pub)\" /home/$GIT_USER/.ssh/authorized_keys; then cat $KEY_PATH.pub >> /home/$GIT_USER/.ssh/authorized_keys; fi && chmod 600 /home/$GIT_USER/.ssh/authorized_keys"; then
            echo "Failed to copy public key to $GIT_USER's authorized_keys for $HOST" >> failed_to_append.txt
        fi
    done < "$failed_hosts"
    echo # New line after progress bar
}

# Replace the final echo statement with:
if [[ -f "failed_to_connect.txt" && -s "failed_to_connect.txt" ]]; then
    echo "Some hosts failed to connect. Failed hosts are listed in failed_to_connect.txt"
    read -p "Would you like to retry these hosts? (y/n): " retry_choice
    if [[ "$retry_choice" =~ ^[Yy]$ ]]; then
        retry_failed_hosts "failed_to_connect.txt"
    fi
fi

# Final status
if [[ -f "failed_to_connect.txt" && -s "failed_to_connect.txt" ]]; then
    echo "Some hosts still failed to connect. Check failed_to_connect.txt for details."
elif [[ -f "failed_to_append.txt" && -s "failed_to_append.txt" ]]; then
    echo "Some hosts failed to append keys to git user. Check failed_to_append.txt for details."
else
    echo "SSH keys have been successfully processed for all hosts."
fi

generate_inventory() {
    # Add domain configuration
    read -p "Enter Tailscale domain [$DOMAIN]: " input_domain
    DOMAIN=${input_domain:-"example.ts.net"}

 
    cat << EOF > "$INVENTORY_FILE"
# Ansible inventory generated from Tailscale custom data
---
parent:
  children:
EOF

    
}

