# REAK device setup

Setup and enrollment notes for REAK-managed devices.

## Device management

| Device class | Management system | Setup entry point |
| --- | --- | --- |
| Linux workstations | Fleet | [Ubuntu workstation setup](workstations/ubuntu/README.md) |
| Windows workstations | Fleet | [Windows workstation setup](workstations/windows/README.md) |
| Mobile devices | Miradore | [Mobile device setup](mobile/README.md) |

Fleet and Miradore are separate management workflows. Headscale/Tailscale provides internal network access; SSH access is configured separately on workstations. Ubuntu Desktop Sharing and further Headscale/Tailscale automation are planned follow-up work.

## Repository layout

- `workstations/ubuntu/` — Ubuntu workstation bootstrap and Fleet enrollment.
- `workstations/windows/` — Windows workstation bootstrap and Fleet enrollment.
- `mobile/` — Miradore enrollment notes.
- `docs/` — shared operating notes and future enhancements.

## Secrets and device-specific values

Do not commit Fleet enrollment secrets, private SSH keys, or device credentials. The Fleet enrollment secret should be supplied locally when generating an enrollment package. Store any organization-managed configuration in an approved secret store.
