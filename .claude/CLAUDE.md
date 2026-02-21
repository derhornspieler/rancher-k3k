# rancher-k3k Project Instructions

## Purpose
Deploy Rancher via k3k (k3s-in-k3s) on Harvester with cert-manager CA Issuer TLS,
Harbor pull-through cache, and MinIO backups.

## PKI Hierarchy
Certificates come from the PKI repo (`/home/rocky/code/PKI`):

```
Aegis Group Root CA (30yr, offline)
└── K3K Signing CA (15yr, pathlen:0) → cert-manager CA Issuer
    └── Rancher leaf cert (90d, auto-renewed)
```

## Variable Semantics
| Variable | Points to | Used for |
|----------|-----------|----------|
| `CA_CERT_PATH` | Intermediate (signing) CA cert | cert-manager CA Issuer `ca-signing-keypair` secret |
| `CA_KEY_PATH` | Intermediate CA private key | cert-manager CA Issuer `ca-signing-keypair` secret |
| `CA_ROOT_PATH` | Root CA cert (trust anchor) | Rancher `tls-ca` secret → `/cacerts` endpoint |
| `PRIVATE_CA_PATH` | Harbor/registry CA bundle | K3s registry TLS trust, Helm repo TLS |

`CA_ROOT_PATH` falls back to `CA_CERT_PATH` if unset (backward compat, warns).

## Shell Conventions
- `set -euo pipefail` in all scripts
- `shellcheck` clean
- Template placeholders: `__PLACEHOLDER__` (double underscore)
- `prompt_or_default VAR "prompt" "default"` for interactive/config-file input
- `sedi` wrapper for cross-platform sed -i

## Known Issues
- **CA checksum bug**: Three Rancher components compute SHA-256 of cacerts differently.
  No single hash works for all. See `teams/security.md` for SOP.

## Sister Repos
- **PKI** (`/home/rocky/code/PKI`): Root CA + intermediate generation
- **harvester-rke2-platform**: Harvester + RKE2 cluster management (separate team)
