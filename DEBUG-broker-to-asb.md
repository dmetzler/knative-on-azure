# broker-to-asb — État & Debug Notes

## Problème actuel (2026-07-21 soir)
Le ksvc `broker-to-asb` a été supprimé puis recréé par Camel-K Integration.
Le nouveau pod ne reçoit plus de trafic → probablement NetworkPolicy / AuthorizationPolicy cassées.

## Architecture
- **Source** : `k8s/integrations/broker-to-asb.yaml` (Camel-K Integration, PAS le Quarkus)
- **L'ancien** : `k8s/camel-quarkus/deployment.yaml` = deployment `asb-bridge` (image Quarkus) — **NE PLUS UTILISER**
- Camel-K crée automatiquement un KNative Service `broker-to-asb`

## Réseau — CE QUI DOIT MATCHER
Le ksvc `broker-to-asb` est un event sink du Broker KNative. Pour qu'il reçoive du trafic :

### NetworkPolicy
Le pod doit être accessible depuis :
- `knative-eventing` (le dispatcher/broker envoie les events)
- `knative-serving` (activator, queue-proxy)
- `kourier-system` (ingress)

Ports nécessaires :
- **8012** (queue-proxy h2c)
- **8013** (queue-proxy h2c — CELUI QUI A CAUSÉ LES 504 INITIAUX)
- **8080** (user container)
- **8443** (queue-proxy HTTPS)
- **9090** (autoscaler metrics)
- **9091** (autoscaler metrics alt)

### AuthorizationPolicy (Istio)
Le pod doit avoir un ALLOW rule depuis :
- namespaces: `knative-eventing`, `knative-serving`, `kourier-system`

### Labels à vérifier
Le pod Camel-K `broker-to-asb` doit avoir le label `app: broker-to-asb` (ou `serving.knative.dev/service: broker-to-asb`).
Les policies actuelles (`k8s/apps/authz-policies.yaml`) utilisent un selector → vérifier lequel.

## Fix demain
1. `kubectl get pods -l serving.knative.dev/service=broker-to-asb --show-labels`
2. Vérifier que les NetworkPolicies et AuthorizationPolicies matchent les labels du nouveau pod
3. Si pas de match → mettre à jour les policies dans `k8s/apps/authz-policies.yaml`
4. Tester : envoyer un event type `asb.outbound` via le broker et vérifier qu'il arrive sur ASB

## Policies existantes
- `k8s/apps/authz-policies.yaml` — contient les allow rules
- `k8s/apps/network-policy-allow-knative-serving.yaml` — NetworkPolicy globale pour pods KNative (selector: `serving.knative.dev/configuration: Exists`)

## Note importante
La NetworkPolicy `allow-knative-serving-traffic` utilise `serving.knative.dev/configuration: Exists` comme podSelector.
Si le pod Camel-K a ce label (il devrait, c'est un ksvc), la NetworkPolicy s'applique automatiquement.
Le problème est probablement côté **AuthorizationPolicy Istio** qui est plus restrictive.

## Historique du debug réseau (pour mémoire)
- Les 504 initiaux étaient causés par le port 8013 manquant dans la NetworkPolicy
- L'autoscaler qui ne scalait pas à zéro → port 9090 manquant
- mTLS STRICT dans `default` namespace + PERMISSIVE dans knative namespaces
- Le `default-deny` AuthorizationPolicy bloque tout sauf les rules explicites
