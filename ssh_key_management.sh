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

# Function to get user input for variables
get_user_input() {
    read -p "Enter directory to store keys [$KEY_DIR]: " input_key_dir
    KEY_DIR=${input_key_dir:-"DEFAULT DIRECTORY"}

    read -p "Enter target user [$USER]: " input_user
    USER=${input_user:-"DEFAULT REMOTE USER"}

    read -p "Enter git user [$GIT_USER]: " input_git_user
    GIT_USER=${input_git_user:-"DEFAULT LOCAL GIT USER"}

    read -p "Enter inventory file path [$INVENTORY_FILE]: " input_inventory
    INVENTORY_FILE=${input_inventory:-"DEFAULT INVENTORY"}

    read -p "Enter hosts file name [$HOSTS_FILE]: " input_hosts
    HOSTS_FILE=${input_hosts:-"DEFAULT HOSTS LIST"}

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

# Remove the duplicate variable declarations here
# Start main script execution
get_user_input
select_mode
GENERATE_KEYS=$?

# Step 1: Read hosts from the specified file
echo "Reading hosts from $HOSTS_FILE..."
if [[ ! -f "$HOSTS_FILE" ]]; then
    echo "Error: $HOSTS_FILE does not exist."
    exit 1
fi

# Step 2: Iterate over each host to generate and push unique SSH keys
while IFS= read -r HOST; do
    echo "Processing $HOST..."
    KEY_PATH="$KEY_DIR/id_ed25519_$HOST"
    
    if [ $GENERATE_KEYS -eq 0 ]; then
        echo "Generating SSH key pair for $HOST..."
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
    ansible-playbook -i "$INVENTORY_FILE" "$PLAYBOOK_FILE" --ssh-extra-args='-o StrictHostKeyChecking=no' || { echo "Failed to push key to $HOST" && echo "$HOST" >> failed_to_connect.txt; }

    # Clean up the temporary playbook file
    rm "$PLAYBOOK_FILE"
    
    # Step 5: Copy the public key to the git user's authorized_keys on the same server
    echo "Copying public key to $GIT_USER's authorized_keys..."
    if ! sudo bash -c "if ! grep -q \"$(cat $KEY_PATH.pub)\" /home/$GIT_USER/.ssh/authorized_keys; then cat $KEY_PATH.pub >> /home/$GIT_USER/.ssh/authorized_keys; fi && chmod 600 /home/$GIT_USER/.ssh/authorized_keys"; then
        echo "Failed to copy public key to $GIT_USER's authorized_keys for $HOST" >> failed_to_append.txt
    fi


done < "$HOSTS_FILE"

echo "SSH keys have been successfully processed for all hosts."
