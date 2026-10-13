# Miradore Mobile Enrollment Workflows

REAK mobile devices are corporate-owned and managed through Miradore. This document records the management boundary and enrollment procedures.

## Management Boundary

- **Device ownership**: Corporate-owned
- **Management platform**: Miradore
- **Enrollment**: Platform-specific steps required per device type
- **Credentials**: Do not store enrollment tokens or user credentials in this repository

## iOS Enrollment

### Prerequisites
- Apple Business Manager (ABM) or Apple School Manager (ASM) account
- Miradore administrative access
- iOS devices supervised or unsupervised

### Steps
1. **Via Apple Business Manager/School Manager**
   - Add devices to ABM/ASM
   - Assign devices to Miradore organization
   - Use Miradore's native ABM enrollment flow

2. **Via Miradore Console**
   - Navigate to Devices → Add → iOS
   - Follow Miradore's enrollment wizard
   - Install Miradore enrollment profile on devices

3. **Configuration Profiles**
   - Set up required configuration profiles (Wi-Fi, email, VPN, etc.)
   - Assign profiles to device groups

### Notes
- iOS devices must have the Miradore app or enrollment profile installed
- Supervised devices have more extensive management capabilities
- Enrollment tokens must not be committed to this repository

## Android Enrollment

### Prerequisites
- Miradore administrative access
- Android devices with Google Play Services

### Steps
1. **Via Miradore Console**
   - Navigate to Devices → Add → Android
   - Select enrollment method (EMM, NFC, or QR code)
   - Follow Miradore's enrollment wizard

2. **Enrollment Methods**
   - **EMM (Enterprise Mobility Management)**: Requires Miradore admin console
   - **NFC**: Tap device to NFC-enabled phone with enrollment profile
   - **QR code**: Scan QR code displayed in Miradore console

3. **Configuration Profiles**
   - Set up required configuration profiles (Wi-Fi, email, VPN, security)
   - Assign profiles to device groups

### Notes
- Android enrollment varies by device manufacturer and Android version
- Work profiles vs. personal profiles may have different management capabilities
- Enrollment tokens must not be committed to this repository

## Post-Enrollment

1. **Verify device enrollment** in Miradore console
2. **Apply configuration profiles** (Wi-Fi, email, VPN, security settings)
3. **Set up device groups** for targeted policy application
4. **Configure remote wipe** and loss recovery procedures
5. **Regular audits** of device compliance and software inventory

## Repository Policy

- Do not store Miradore enrollment tokens, API keys, or user credentials
- Do not commit device serial numbers or IMEI numbers
- Enrollment procedures should be documented per platform but without secrets
- See top-level `README.md` for overall secrets policy