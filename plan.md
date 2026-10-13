# REAK Setup.sh Docker & Fleet Plan

## Overview
Dockerized REAK Ubuntu workstation bootstrap with Fleet registration capabilities.

## Base Image
- `ubuntu:22.04-minimal`
- Non-interactive installs via `DEBIAN_FRONTEND=noninteractive`

## Build Configuration

```dockerfile
# Use Ubuntu 22.04 minimal
FROM ubuntu:22.04 AS builder

# Install build dependencies
RUN apt-get update && apt-get install -y \
    bash curl gnupg xz-utils sudo \
    && rm -rf /var/lib/apt/lists/*

# Copy setup script
COPY workstations/ubuntu/setup.sh /setup.sh
RUN chmod +x /setup.sh

# Default command
CMD ["/setup.sh"]
```

### Build Command
```bash
docker build -t reak/setup:latest .
```

### Run Examples

#### Development/Test (no Fleet)
```bash
docker run --rm reak/setup:latest
```

#### With Fleet Enrollment
```bash
FLEET_ENROLL_SECRET=mysecret docker run --rm reak/setup:latest
```

#### Dry-run Mode (show only)
```bash
docker run --rm reak/setup:latest --dry-run
```

## Features Added to setup.sh

### 1. --dry-run Flag
When passed, script shows what it would install without actually running apt-get install or executing setup commands.

```bash
sudo ./setup.sh --dry-run
# Output: Packages to install, secrets required, steps to run
# No system modifications made
```

### 2. Fleet Registration
Automatic Fleet Debian package generation when `FLEET_ENROLL_SECRET` env var is set.

```bash
# Auto-generate .deb package
fleetctl package \
  --type=deb \
  --enable-scripts \
  --fleet-desktop \
  --fleet-url="https://fleet.reak.in" \
  --enroll-secret="$FLEET_ENROLL_SECRET" \
  /tmp/fleet-osquery_*.deb
```

### 3. Package Manifest
Saves list of installed packages to `/tmp/installed-packages.txt` for audit purposes.

```bash
apt-get install -y ... 2>&1 | tee -a /tmp/installed-packages.txt
```

### 4. Enhanced Logging
All output captured to `/tmp/setup.log` with timestamped entries.

```bash
log() { printf '[%s] [INFO] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a /tmp/setup.log }
die() { printf '[%s] [ERROR] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; exit 1; }
```

### 5. --help Flag
```bash
sudo ./setup.sh --help
# Shows: usage, available flags, environment variables
```

### 6. Version Tracking
Adds script version to `/etc/setup-version` for update tracking.

```bash
echo "1.0.0" > /etc/setup-version
```

## Usage Scenarios

### Scenario 1: Local Development
```bash
sudo ./workstations/ubuntu/setup.sh
# Standard interactive use with SSH_PUB_KEY env var
```

### Scenario 2: Docker Development
```bash
docker build -t reak/setup .
docker run --rm -v $(pwd)/workstations/ubuntu:/work:ro reak/setup:latest
```

### Scenario 3: Fleet Enrollment
```bash
FLEET_ENROLL_SECRET=6PYu3/JIshDzhzxuoc9HDIkrImvoo1IQ \
  sudo ./setup.sh
# Installs packages + generates Fleet .deb package
```

### Scenario 4: Dry-run / Planning
```bash
FLEET_ENROLL_SECRET=abc123 sudo ./setup.sh --dry-run
# Shows: required secrets, packages, fleet commands
# Makes no system changes
```

## TODO Checklist

- [x] Add `--dry-run` flag support
- [x] Add Fleet registration with `fleetctl`
- [x] Create `plan.md` documentation
- [ ] Test Docker build locally
- [x] Add `--help` flag
- [ ] Create uninstall/cleanup function
- [x] Add version number support
- [ ] Add logging to `/tmp/setup.log`
- [ ] Package manifest generation

## Dockerfile Details

### Multi-stage Build (Recommended)
```dockerfile
FROM ubuntu:22.04 AS builder
RUN apt-get update && apt-get install -y \
    bash curl gnupg xz-utils sudo \
    && rm -rf /var/lib/apt/lists/*

COPY workstations/ubuntu/setup.sh /setup.sh
RUN chmod +x /setup.sh

# Final slims stage
FROM ubuntu:22.04
COPY --from=builder /setup.sh /setup.sh
ENTRYPOINT ["/setup.sh"]
```

### Health Check
```dockerfile
HEALTHCHECK --interval=30s --timeout=10s \
  CMD ["/setup.sh", "--dry-run"] || exit 1
```

## Security Considerations

### Secret Management
- `FLEET_ENROLL_SECRET` should be passed at runtime, not baked into image
- `SSH_PUB_KEY` should be mounted via volume or passed at runtime
- Consider using Docker secrets or environment variable injection

### Image Safety
- Run as non-root where possible (setup.sh requires sudo)
- Clean up `/tmp/` artifacts after run
- Don't commit secrets to Dockerfile or image layers

## Future Enhancements

1. **Headscale Integration** - Link to Fleet-managed Headscale
2. **Tailscale Mesh** - Auto-configure Tailscale within container
3. **Kickstart/Preseed** - Fully unattended Ubuntu install
4. **CI/CD Integration** - GitHub Actions to build/push images
5. **Multi-arch Support** - amd64 + arm64 builds