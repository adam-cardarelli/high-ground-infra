# NAT gateway

Static-IP egress for Cloud Run services that need to call externally-whitelisted APIs.

## Why

FactSet whitelists outbound IPs. Cloud Run services use ephemeral IPs by default. Without a NAT gateway, FactSet rejects requests from any newly-spun-up container.

The fix: route Cloud Run egress through a VPC connector → Cloud NAT → reserved static IP `34.59.21.34`. FactSet whitelists that one IP. Every service that needs FactSet (or any other whitelisted API) opts in via `vpc_egress: all-traffic`.

## Topology

```
Cloud Run service (data-vendors-api)
    │
    │ --vpc-egress all-traffic
    │ --vpc-connector company-data-conn
    ▼
VPC Access Connector (company-data-conn)
    │
    ▼
VPC network (default)
    │
    ▼
Cloud Router (cloud-run-nat-router)
    │
    ▼
Cloud NAT (cloud-run-nat)  → static IP 34.59.21.34  → FactSet
```

## Setup

```bash
./scripts/nat-gateway.sh
```

Idempotent. Creates the static IP reservation, router, NAT, and VPC connector if missing.

## Per-service opt-in

Services that need static-IP egress add to their workflow:

```yaml
vpc_egress: all-traffic
```

Services that don't (most of them) leave it at the default `none` and skip the VPC connector entirely. **Don't enable VPC egress unless needed** — it adds latency and small cost.

## Verifying

After deploying a service with `vpc_egress: all-traffic`, run from inside it:

```python
import requests
print(requests.get("https://api.ipify.org").text)
# Expect: 34.59.21.34
```

If it returns anything else, the VPC connector isn't wired. Check the Cloud Run service's "Networking" tab.

## Capacity

The current VPC connector is sized `e2-micro`, min 2 instances, max 10. Plenty for a few services with light traffic. Bump max-instances if you start seeing connection contention.

## Resources

| Resource | Name |
|---|---|
| Static IP | `34.59.21.34` (named `cloud-run-nat-ip` or earlier-bound name) |
| Cloud Router | `cloud-run-nat-router` |
| Cloud NAT | `cloud-run-nat` |
| VPC Connector | `company-data-conn` |
| Network | `default` |
| Region | `us-central1` |
