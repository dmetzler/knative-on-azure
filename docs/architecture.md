# Architecture

## Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                      Azure Subscription                         │
│                                                                 │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │                Resource Group (rg-knative-lab)             │  │
│  │                                                           │  │
│  │  ┌─────────────────────────────────────────────────────┐  │  │
│  │  │              VNet (10.0.0.0/16)                     │  │  │
│  │  │                                                     │  │  │
│  │  │  ┌───────────────────────────────────────────────┐  │  │  │
│  │  │  │        Subnet: AKS nodes (10.0.1.0/24)       │  │  │  │
│  │  │  │                                               │  │  │  │
│  │  │  │  ┌─────────────────────────────────────────┐  │  │  │  │
│  │  │  │  │     AKS Cluster (2× D4s_v5, k8s 1.36)  │  │  │  │  │
│  │  │  │  │                                         │  │  │  │  │
│  │  │  │  │  ┌──────────┐  ┌───────────────────┐   │  │  │  │  │
│  │  │  │  │  │ KNative  │  │  KNative Eventing  │   │  │  │  │  │
│  │  │  │  │  │ Serving  │  │  (Kafka Broker)    │   │  │  │  │  │
│  │  │  │  │  │          │  │         │          │   │  │  │  │  │
│  │  │  │  │  │ Kourier  │  │         │ SASL_SSL │   │  │  │  │  │
│  │  │  │  │  │ Ingress  │  │         │ :9093    │   │  │  │  │  │
│  │  │  │  │  └──────────┘  └─────────┼─────────-┘   │  │  │  │  │
│  │  │  │  └──────────────────────────┼──────────────┘  │  │  │  │
│  │  │  └─────────────────────────────┼─────────────────┘  │  │  │
│  │  └────────────────────────────────┼────────────────────┘  │  │
│  │                                   │                       │  │
│  │  ┌────────────────────────────────▼───────────────────┐   │  │
│  │  │         Azure Event Hubs (Standard tier)           │   │  │
│  │  │         Kafka endpoint: :9093                      │   │  │
│  │  │         Topic: knative-events                      │   │  │
│  │  └────────────────────────────────────────────────────┘   │  │
│  └───────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

## Event Flow

```
Producer (curl/app)
    │
    ▼
Kafka Broker Ingress (kafka-broker-ingress service)
    │  Accepts CloudEvents over HTTP
    ▼
Azure Event Hubs (Kafka protocol, SASL_SSL)
    │  Events stored as Kafka records
    ▼
Kafka Broker Dispatcher (reads from Event Hubs)
    │  Matches Triggers
    ▼
Trigger (event-display-trigger)
    │  Routes matching events
    ▼
event-display (KNative Serving service)
    Logs the received CloudEvent
```

## Networking

| Component | CIDR / Endpoint |
|-----------|----------------|
| VNet | `10.0.0.0/16` |
| AKS nodes subnet | `10.0.1.0/24` |
| Pod IPs (CNI overlay) | Virtual (not routable on VNet) |
| K8s services | `172.16.0.0/16` |
| K8s DNS | `172.16.0.10` |
| Event Hubs Kafka | `<namespace>.servicebus.windows.net:9093` |
| Kourier LB | Public IP (auto-assigned) |

## Authentication

Azure Event Hubs Kafka authentication uses **SASL_SSL + PLAIN**:

| Parameter | Value |
|-----------|-------|
| Security protocol | `SASL_SSL` |
| SASL mechanism | `PLAIN` |
| Username | `$ConnectionString` (literal string) |
| Password | SAS connection string from Event Hubs |

This is configured via a Kubernetes Secret referenced in the `kafka-broker-config` ConfigMap through `auth.secret.ref.name`.
