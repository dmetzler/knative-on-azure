# 4. Demo Application

## hello-knative (Serving)

A simple KNative Service that demonstrates scale-to-zero:

```bash
kubectl apply -f k8s/demo/hello-knative.yaml
```

### Verify

```bash
kubectl get ksvc hello-knative
```

```
NAME             URL                                               READY
hello-knative    http://hello-knative.default.svc.cluster.local    True
```

### Test

From inside the cluster:

```bash
kubectl run curl --image=curlimages/curl --rm -it --restart=Never -- \
  http://hello-knative.default.svc.cluster.local
```

From outside (requires [domain configuration](02-knative.md#configure-domain-optional)):

```bash
KOURIER_IP=$(kubectl get svc kourier -n kourier-system \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl -H "Host: hello-knative.default.example.com" http://$KOURIER_IP
```

### Scale-to-Zero

Watch the pods:

```bash
kubectl get pods -w
```

After ~60 seconds with no traffic, the pod terminates (scale to zero). The next request triggers a cold start (~2-3s) and the pod comes back.

## event-display (Eventing)

A sink service that logs received CloudEvents. Deployed as part of the Kafka Broker setup:

```bash
kubectl apply -f k8s/demo/event-display.yaml
```

It's connected to the Kafka Broker via a Trigger:

```yaml
apiVersion: eventing.knative.dev/v1
kind: Trigger
metadata:
  name: event-display-trigger
spec:
  broker: default
  subscriber:
    ref:
      apiVersion: serving.knative.dev/v1
      kind: Service
      name: event-display
```

This routes **all events** from the default broker to event-display. In production, you'd add filters:

```yaml
spec:
  broker: default
  filter:
    attributes:
      type: my.specific.event.type
  subscriber:
    ref:
      apiVersion: serving.knative.dev/v1
      kind: Service
      name: my-handler
```
