### Easy Inventory Key Rotation For Ansible
I manage 400+ devices, so this script lets me input a file containing a one per line listing of all the hostnames in my Tailscale network, and my ansible inventory.

It then generates a unique ssh private/public key for each device and saves that to the specified users directory on the ansible server, it then pushes that private and public key pair to the remote device.

I know it's not best practice to move private keys, but this is the best solution I could come up with, and removes the use of hardcoded credentials/predicatable passwords.

You can easily change all the ssh keys for the devices by just re-running the script.

The reason for the temporary playbook is if you have 400+ open ssh connections inevitably some will timeout, so it's just more reliable to do it one by one, it has the same result.

The script also generates a list of units it wasn't able to touch, so if you need to go back and do those ones, you can just change out the hosts file to target them.

The key is addedd to authorized hosts on the specified user on both the remote and ansible server to enable two way comms using the same key.
