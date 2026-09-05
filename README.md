# Initial Setup

## Installing the OS

1. Grab the latest insaller ISO for Ubuntu Server LTS

2. Connect a keyboard and monitor to the machine and start installing Ubuntu Server on the target machine

3. During installation, select option to encrypt hard disk and save the password in BitWarden or similar password manager

3. Post-installation, reboot to confirm successful installation of OS, then copy your SSH public key to somewhere on the machine for SSH and *dropbear* setup below (note: standard dropbear package only supports RSA keys at this time)

## Setting up DropBear for SSH unlock

1. Connect the target machine to the internet and run `sudo apt update && sudo apt install dropbear-initramfs`. Also run `sudo apt upgrade` and reboot if the system has not been updated yet.

2. On another computer, log into the router and assign a static IP address to this machine. You shouldn't need to set the static IP on the target machine (DHCP *should* work), but there's a change that the dropbear shell doesn't have proper networking setup so be aware of that possibility when troubleshooting

2. Append public SSH key to `/etc/dropbear/initramfs/authorized_keys` and check permissions (`chmod 600`)

3. Run `sudo update-initramfs -u -v` to update the bootloader. Check for any warnings about an invalid authorized_keys file

4. Confirm that the necessary files (dropbear binary and authorized_keys file) were installed into the initramfs filesystem by running `sudo lsinitramfs /boot/initrd.img-$(uname -r) | grep -E 'dropbear|authorized_keys'`

5. Reboot the system with a monitor and keyboard attached (just in case) and when it shows "dropbear" on the screen, try to SSH with `ssh -i ~/.ssh/dropbear-rsa-key root@<IP address> -p 2222` and enter the encryption password

6. If the above worked, then try to SSH as your normal username and SSH key. If successful, then you're done. If not, troubleshoot

## Installing servces

1. Run the 
 
