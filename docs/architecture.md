# Architecture

## Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│  AKS Cluster                                                       │
│                                                                     │
│  ┌─────────────┐    ┌──────────────────────────────────────────┐   │
│  │   KRO       │    │  default namespace (mTLS STRICT)         │   │
│  │ Controller  │    │                                          │   │
│  │             │    │  ┌──────────┐       ┌──────────────┐     │   │
│  │ Watches     │───▶│  │ frontend │──────▶│   backend    │     │   │
│  │ AcmeService │    │  │ (static) │ allow │   (static)   │     │   │
│  │ instances   │    │  └──────────┘  From └──────┬───────┘     │   │
│  └─────────────┘    │       ▲                    │  ▲          │   │
│                     │       │ ingress        pub │  │ events   │   │
│  ┌──────────────┐   │  ┌────┴─────┐    ┌────────┴────────┐    │   │
│  │ Istio (AKS)  │   │  │   LB     │    │  Kafka Broker   │    │   │
│  │ asm-1-29     │   │  └──────────┘    │  (Event Hubs)   │    │   │
│  │ mTLS between │   │                  └────────┬────────┘    │   │
│  │ all pods     │   │                           │             │   │
│  └──────────────┘   │                    ┌──────┴───────┐     │   │
│                     │                    │ event-display │     │   │
│  ┌──────────────┐   │                    │  (knative)   │     │   │
│  │ ArgoCD       │   │                    │ scale-to-0   │     │   │
│  │ GitOps       │   │                    └──────────────┘     │   │
│  └──────────────┘   └──────────────────────────────────────────┘   │
│                                                                     │
│  ┌──────────────────┐  ┌──────────────────┐  ┌─────────────────┐   │
│  │ knative-serving   │  │ knative-eventing  │  │ kourier-system  │   │
│  │ (mTLS PERMISSIVE) │  │ (mTLS PERMISSIVE) │  │ (PERMISSIVE)   │   │
│  └──────────────────┘  └──────────────────┘  └─────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

## Event Flow

```
User (browser)
    │
    ▼
demo-frontend (React UI, LoadBalancer)
    │  HTTP POST /api/events
    ▼
demo-backend (FastAPI)
    │  Publishes CloudEvent
    ▼
Kafka Broker Ingress
    │  Accepts CloudEvents over HTTP
    ▼
Azure Event Hubs (Kafka protocol, SASL_SSL :9093)
    │  Events stored as Kafka records
    ▼
Kafka Broker Dispatcher (reads from Event Hubs)
    │  Matches Triggers, delivers to subscribers
    ├───────────────────────────┐
    ▼                           ▼
demo-backend                 event-display
(processes event,            (logs the event,
 returns response)            scale-to-zero ksvc)
```

## Networking

| Component | CIDR / Endpoint |
|-----------|----------------|
| VNet | `10.0.0.0/16` |
| AKS nodes subnet | `10.0.1.0/24` |
| Pod IPs (CNI overlay) | Virtual (not routable on VNet) |
| K8s services | `172.16.0.0/16` |
| K8s DNS | `172.16.0.10` |
| Event Hubs Kafka | `evhns-knative-lab.servicebus.windows.net:9093` |
| Kourier LB | Public IP (auto-assigned) |

## Authentication to Event Hubs

Azure Event Hubs Kafka authentication uses **SASL_SSL + PLAIN** with a SAS connection string:

| Parameter | Value |
|-----------|-------|
| Security protocol | `SASL_SSL` |
| SASL mechanism | `PLAIN` |
| Username | `$ConnectionString` (literal string) |
| Password | SAS connection string from Event Hubs |

!!! note "Why not OAuth/OAUTHBEARER?"
    Event Hubs supports OAUTHBEARER for Kafka, but KNative's Kafka Broker does not implement OAUTHBEARER natively. We've prepared an upstream proposal to add Azure OAUTHBEARER support to KNative. See [Troubleshooting](troubleshooting.md) for details.

## Security Architecture

See [Security Model](security.md) for the full two-layer defense model (NetworkPolicy + Istio AuthorizationPolicy).
