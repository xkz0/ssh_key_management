#!/bin/bash
# SSH Key Management - Crabman Stan
# This Script generates a public/private key pair for each device within the text file provided and then copies
# the key pair to the remote device via ansible

# Variables
KEY_DIR="WHERE YOU WANT TO STORE YOUR KEYS"          # Directory to store the keys
USER="USER ON REMOTE HOST"                           # The user on the target hosts
GIT_USER="USER ON ANSIBLE SERVER"                           # The user on the Ansible server
INVENTORY_FILE="YOUR ANSIBLE INVENTORY.yaml"  # Inventory file
HOSTS_FILE="LIST OF HOSTNAMES/IP ADDRESSES"                  # File containing hostnames

# Step 1: Read hosts from the specified file
echo "Reading hosts from $HOSTS_FILE..."
if [[ ! -f "$HOSTS_FILE" ]]; then
    echo "Error: $HOSTS_FILE does not exist."
    exit 1
fi

# Step 2: Iterate over each host to generate and push unique SSH keys
while IFS= read -r HOST; do
    echo "Generating SSH key pair for $HOST..."
    
    # Generate a unique SSH key pair for the host
    KEY_PATH="$KEY_DIR/id_ed25519_$HOST"
    ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" || { echo "Key generation failed for $HOST"; continue; }

    # Step 3: Create Ansible Playbook to Push Keys
    PLAYBOOK_CONTENT=$(cat <<EOF
---
    - name: Push SSH public key to target host
      hosts: "$HOST"
      tasks:
        - name: Ensure the user '$USER' exists
          user:
            name: "$USER"
            state: present
            create_home: yes
            shell: /bin/bash
            groups: sudo  # Add to sudo
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
    ansible-playbook -i "$INVENTORY_FILE" "$PLAYBOOK_FILE" --ssh-extra-args='-o StrictHostKeyChecking=no' || { echo "Failed to push key to $HOST" && echo "$HOST" >> failed_to_connect.txt; }

    # Clean up the temporary playbook file
    rm "$PLAYBOOK_FILE"
    
    # Step 5: Copy the public key to the git user's authorized_keys on the same server
    echo "Copying public key to $GIT_USER's authorized_keys..."
    if ! sudo bash -c "if ! grep -q \"$(cat $KEY_PATH.pub)\" /home/$GIT_USER/.ssh/authorized_keys; then cat $KEY_PATH.pub >> /home/$GIT_USER/.ssh/authorized_keys; fi && chmod 600 /home/$GIT_USER/.ssh/authorized_keys"; then
        echo "Failed to copy public key to $GIT_USER's authorized_keys for $HOST" >> failed_to_append.txt
    fi

    # Clean up the private key after use
    # rm "$KEY_PATH"
done < "$HOSTS_FILE"

echo "SSH keys have been successfully pushed to all hosts and copied to $GIT_USER's authorized_keys."
