# Troubleshooting

## Terraform

### 409 Conflict on Resource Provider Registration

```
registering resource provider "Microsoft.XXX": unexpected status 409 (409 Conflict)
```

**Cause:** Corporate subscription with concurrent provider registrations.

**Fix:** Already handled — `resource_provider_registrations = "none"` in `providers.tf` disables auto-registration. Only required providers are explicitly listed.

### 403 on Role Assignment

```
does not have authorization to perform action 'Microsoft.Authorization/roleAssignments/write'
```

**Cause:** Corporate subscription without RBAC write permissions.

**Fix:** The role assignment has been removed — it's not needed with Azure CNI overlay mode.

### Invalid CIDR Notation

```
The address prefix 10.0.2.0/22 has an invalid CIDR notation
```

**Cause:** Subnet address must be aligned to the prefix length. A /22 must start at a multiple of 4 on the third octet.

**Fix:** Use `10.0.4.0/22` (already fixed in the repo).

### K8s Version Not Supported

```
version 1.30 is only available for Long-Term Support (LTS)
```

**Cause:** Some Kubernetes versions require an LTS support plan on AKS.

**Fix:** Check available versions and use the latest GA:

```bash
az aks get-versions --location westeurope --output table
```

## KNative

### kafka-broker-dispatcher StatefulSet Invalid

```
volumeMounts[1].name: Not found: "contract-resources"
```

**Cause:** Bug in KNative v1.22.1 `eventing-kafka-broker.yaml` manifest — a volume mount references a volume that doesn't exist.

**Fix:** Run `./scripts/reinstall-kafka-components.sh` which downloads, patches, and re-applies the manifest.

### kafka-source-dispatcher / kafka-channel-dispatcher Not Found

```
statefulsets.apps "kafka-source-dispatcher" not found
statefulsets.apps "kafka-channel-dispatcher" not found
```

**Cause:** Only `eventing-kafka-broker.yaml` was installed. The Kafka controller also needs the source and channel components.

**Fix:** `./scripts/reinstall-kafka-components.sh` installs all three manifests.

### Broker Not Ready: "run out of available brokers"

```
cannot obtain Kafka cluster admin, kafka: client has run out of available brokers to talk to: EOF
```

**Cause:** The Kafka controller can't authenticate to Event Hubs. Usually means the SASL credentials are missing or misconfigured.

**Fix:** Ensure the auth secret exists and is correctly referenced:

```bash
# Check the secret
kubectl get secret kafka-auth-secret -n knative-eventing -o yaml

# Check the ConfigMap references it
kubectl get configmap kafka-broker-config -n knative-eventing -o yaml | grep auth

# Re-run setup
./scripts/setup-kafka-broker.sh
```

### broker-ingress Service Not Found

```
Could not resolve host: broker-ingress.knative-eventing.svc.cluster.local
```

**Cause:** The Kafka Broker uses a different ingress service name than the MT-Channel broker.

**Fix:** Use `kafka-broker-ingress` instead of `broker-ingress`:

```
http://kafka-broker-ingress.knative-eventing.svc.cluster.local/default/default
```

### Kourier Returns 404

```
HTTP/1.1 404 Not Found
```

**Cause:** KNative default domain is `svc.cluster.local` which makes routes cluster-local (not exposed via Kourier).

**Fix:** Configure an external domain:

```bash
kubectl patch configmap config-domain -n knative-serving \
  --type merge -p '{"data":{"example.com":""}}'
```

## Useful Debug Commands

```bash
# KNative Serving status
kubectl get ksvc -A

# KNative Eventing status
kubectl get broker -A
kubectl get trigger -A

# Kafka component pods
kubectl get pods -n knative-eventing

# Kafka controller logs
kubectl logs -l app=kafka-controller -n knative-eventing --tail=30

# Kafka broker receiver logs
kubectl logs -l app=kafka-broker-receiver -n knative-eventing --tail=30

# Kafka broker dispatcher logs
kubectl logs -l app=kafka-broker-dispatcher -n knative-eventing --tail=30

# Event Hubs connectivity test from the cluster
kubectl run kafkacat --image=confluentinc/cp-kafkacat --rm -it --restart=Never -- \
  -b <namespace>.servicebus.windows.net:9093 \
  -X security.protocol=SASL_SSL \
  -X sasl.mechanism=PLAIN \
  -X 'sasl.username=$ConnectionString' \
  -X 'sasl.password=<connection-string>' \
  -L
```
