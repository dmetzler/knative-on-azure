# AGENTS.md — KNative on Azure

## Project Overview

**Goal:** POC demonstrating KNative Eventing's Kafka Broker running on AKS, backed by Azure Event Hubs in Kafka compatibility mode. No Kafka cluster to manage.

**Repo:** <https://github.com/dmetzler/knative-on-azure>
**Local clone:** `/tmp/knative-on-azure` (on Jarvis gateway — may need re-clone)

## Current State

### ✅ Done (main branch)
- Terraform IaC: RG + VNet + AKS (2× D4s_v5, K8s 1.36.1) + Event Hubs (Standard)
- KNative Serving v1.22.1 (Kourier ingress) + Eventing v1.22.1
- Kafka Broker backed by Event Hubs — **working end-to-end**
- Demo apps: `hello-knative` (scale-to-zero), `event-display` (CloudEvent sink)
- Full mkdocs documentation (7 pages) + GitHub Actions for GitHub Pages
- Troubleshooting guide covering every issue encountered

### 🔀 In Progress (feature/workload-identity branch)
- Replaces static SAS connection strings with Azure Workload Identity
- Terraform: Managed Identity + Federated Credentials + Role Assignment
- Workaround: CronJob refreshes Azure AD token every 5 min, writes to Secret
- Event Hubs accepts OAuth tokens via SASL/PLAIN with username=`$aad`
- **Not yet tested** — needs `terraform apply` + `setup-workload-identity.sh`
- **Blocker:** Role Assignment requires `Microsoft.Authorization/roleAssignments/write` (may need admin on Hyland sub)

## Architecture

```
CloudEvent (HTTP) → kafka-broker-ingress → Azure Event Hubs (SASL_SSL :9093) → kafka-broker-dispatcher → Trigger → App
```

## Key Technical Decisions

| Decision | Rationale |
|----------|-----------|
| Event Hubs Kafka mode (not native Azure source) | More mature via `eventing-kafka-broker`, portable to real Kafka |
| Kafka Broker class (not KafkaSource) | Broker/Trigger model, not raw Kafka consumption |
| CNI overlay (not pod subnet) | Avoids role assignment requirement |
| `resource_provider_registrations = "none"` | Corporate sub has 409 conflicts |
| No role assignments on main branch | No `Microsoft.Authorization/roleAssignments/write` permission |
| KNative v1.22.1 | Latest at time of build |

## Known Issues / Gotchas

1. **v1.22.1 volume bug:** `kafka-broker-dispatcher` StatefulSet references `contract-resources` volume that doesn't exist. Fixed by `reinstall-kafka-components.sh` (Python patch).
2. **Service name:** Kafka Broker ingress is `kafka-broker-ingress`, NOT `broker-ingress` (that's MT-Channel).
3. **Auth secret format:** Must use `auth.secret.ref.name` in `kafka-broker-config` ConfigMap pointing to a Secret with keys: `protocol`, `sasl.mechanism`, `user`, `password`.
4. **Default domain:** KNative defaults to `svc.cluster.local` (cluster-local). Patch `config-domain` to expose via Kourier.
5. **Event Hubs Standard:** Max 10 topics per namespace, `replication.factor` must be `1`.
6. **OAUTHBEARER upstream:** KNative only supports AWS MSK token providers. Azure needs upstream PR or the `$aad` SASL/PLAIN workaround.

## Scripts

| Script | Purpose |
|--------|---------|
| `scripts/install-knative.sh` | Install Serving + Kourier + Eventing + Kafka controller/broker |
| `scripts/reinstall-kafka-components.sh` | Re-download + patch Kafka broker manifest (v1.22.1 fix) |
| `scripts/setup-kafka-broker.sh` | Create auth Secret + ConfigMap + Broker + event-display |
| `scripts/setup-workload-identity.sh` | (WI branch) SA annotations + token CronJob |

## Terraform Outputs

| Output | Used by |
|--------|---------|
| `kafka_bootstrap_server` | `setup-kafka-broker.sh`, `setup-workload-identity.sh` |
| `kafka_sasl_connection_string` | `setup-kafka-broker.sh` (SAS auth) |
| `kafka_broker_identity_client_id` | `setup-workload-identity.sh` (WI branch) |
| `aks_oidc_issuer_url` | Terraform federated credentials |

## Azure Identifiers

| Resource | Value |
|----------|-------|
| Subscription | `ff55c2e2-6845-4814-b7b8-f730f6d5fe35` |
| Resource Group | `rg-knative-lab` |
| AKS | `aks-knative-lab` |
| Event Hubs NS | `evhns-knative-lab` |
| Kafka bootstrap | `evhns-knative-lab.servicebus.windows.net:9093` |
| Region | `westeurope` |

## Constraints

- **Damien runs `az` and `terraform` locally** (macOS) — not on the agent machine
- **Always build containers with `--platform linux/amd64`** (Mac is ARM, AKS nodes are AMD64)
- Subscription is Hyland corporate — limited RBAC/provider registration permissions
- User: `Damien.Metzler@hyland.com`

## Next Steps

1. Test Workload Identity branch end-to-end
2. Merge WI branch or keep as optional path
3. Consider: GitHub Pages deployment (Actions workflow ready, need to enable in repo settings)
4. Consider: make repo public
5. Consider: upstream PR for Azure OAUTHBEARER support in KNative
