# Ubuntu Desktop Sharing (RDP-based) Workflow

REAK Ubuntu workstations use Ubuntu's built-in Desktop Sharing for remote access, configured to use RDP.

## Setup

1. **Enable Desktop Sharing**
   - Open Settings → Sharing → Desktop Sharing
   - Toggle "Share my screen" on
   - Click "Security..." and set a password for remote access

2. **Configure RDP**
   - Install `xrdp` package: `apt-get install -y xrdp`
   - Start and enable the service:
     ```sh
     systemctl enable --now xrdp
     ```
   - Verify it's running: `systemctl status xrdp`

3. **Firewall Rules**
   - Allow RDP port through UFW:
     ```sh
     ufw allow 3389/tcp
     ```
   - If using `firewall-cmd` (rare on Ubuntu):
     ```sh
     firewall-cmd --permanent --add-port=3389/tcp
     firewall-cmd --reload
     ```

4. **Network Considerations**
   - Ensure port 3389 is open in any cloud security group
   - For Headscale/Tailscale users, Desktop Sharing traffic should be consistent with your internal network policy
   - Consider using a VPN (Tailscale/Headscale) for secure remote access instead of exposing RDP directly

5. **Access Controls**
   - Use strong passwords for the RDP session
   - Create a dedicated user account for remote desktop access if possible
   - Disable root RDP access
   - Audit RDP login attempts periodically

6. **Integration with Bootstrap**
   - The `setup.sh` script does not currently configure Desktop Sharing or xrdp
   - To add this enhancement, install `xrdp` in the bootstrap script and configure the firewall
   - Reference: `docs/future-enhancements.md` item 2 - "Document and validate Ubuntu's built-in Desktop Sharing (expected to use RDP)"

## Troubleshooting

- **Can't connect via RDP**: Verify xrdp is running, firewall allows 3389/tcp, and the user has a valid password
- **Blank screen on connect**: Ensure the user's desktop session is running (not just a locked screen)
- **Performance issues**: Limit color depth in Desktop Sharing settings, use a stable network connection