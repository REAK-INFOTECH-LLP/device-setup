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