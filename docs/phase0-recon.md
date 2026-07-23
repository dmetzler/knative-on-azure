# Phase 0 Recon: eventing-kafka-broker OAUTHBEARER & Auth Architecture

## 1. Java Data Plane — KafkaClientsAuth OAUTHBEARER Behavior

### File & Class
- **File:** `data-plane/core/src/main/java/dev/knative/eventing/kafka/broker/core/security/KafkaClientsAuth.java`
- **Class:** `KafkaClientsAuth` (public, static utility methods)

### OAUTHBEARER Early-Return (Lines 64–76)

The `sasl()` method (line 56) determines the SASL mechanism and branches:

```java
// Line 62: mechanism defaults to "PLAIN" if saslMechanism is null
// Line 66: propertiesSetter.accept(SaslConfigs.SASL_MECHANISM, mechanism);
// Lines 67-68: PLAIN → sets SASL_JAAS_CONFIG with PlainLoginModule + username/password
// Lines 73-74: OAUTHBEARER → EMPTY BLOCK — no JAAS config, no username, no password
// Lines 75-81: SCRAM-* → sets SASL_JAAS_CONFIG with ScramLoginModule + username/password
```

**When mechanism=OAUTHBEARER, the Java data plane sets:**
- `sasl.mechanism` = `OAUTHBEARER`
- `security.protocol` = whatever the protocol is (SASL_PLAINTEXT or SASL_SSL)
- SSL properties if protocol is SASL_SSL (truststore, keystore)

**What is NOT set:**
- `sasl.jaas.config` — **not set at all**
- `sasl.login.callback.handler.class` — **not set**
- `sasl.oauthbearer.token.endpoint.url` — **not set**
- Any other OAUTHBEARER-specific Kafka client properties — **not set**

**Impact:** The OAUTHBEARER code path in the Java data plane is effectively a no-op stub. It sets `sasl.mechanism=OAUTHBEARER` but provides no JAAS config or callback handler. The Kafka client would fail at connection time because it has no way to obtain a token. This is the gap we need to fill for Azure/Entra ID.

### CredentialsValidator Behavior (Lines 59–65 of CredentialsValidator.java)

For `SASL_PLAINTEXT`: validates mechanism is valid, then requires username+password — **no OAUTHBEARER exception** → OAUTHBEARER with SASL_PLAINTEXT would fail validation.

For `SASL_SSL` (lines 71–78): has a special carve-out:
```java
if (anyBlank(credentials.SASLUsername(), credentials.SASLPassword())
        && (SASLMechanism == null || !"OAUTHBEARER".equals(SASLMechanism))) {
    return "invalid SASL username or password";
}
```
**OAUTHBEARER + SASL_SSL is allowed without username/password.** But OAUTHBEARER + SASL_PLAINTEXT is NOT (validation will reject it).

---

## 2. Full List of Recognized Auth Secret Keys

### Java Side (KubernetesCredentials.java)

| Secret Key | Java Constant | Used For |
|---|---|---|
| `protocol` | `SECURITY_PROTOCOL` | Maps to Kafka `SecurityProtocol` enum |
| `sasl.mechanism` | `SASL_MECHANISM` | Allowlist: PLAIN, SCRAM-SHA-256, SCRAM-SHA-512, OAUTHBEARER |
| `ca.crt` | `CA_CERTIFICATE_KEY` | PEM CA cert → SSL truststore |
| `user.crt` | `USER_CERTIFICATE_KEY` | PEM user cert → SSL keystore |
| `user.key` | `USER_KEY_KEY` | PEM user key → SSL keystore |
| `user.skip` | `USER_SKIP_KEY` | Boolean; skip mTLS client auth |
| `user` | `USERNAME_KEY` | SASL username |
| `password` | `PASSWORD_KEY` | SASL password |
| `type` | `TYPE_KEY` | Declared but **not used** in KafkaClientsAuth (only in proto mapping) |
| `tokenProvider` | `TOKEN_PROVIDER_KEY` | Declared but **not used** in Java data plane (only in proto mapping) |
| `roleARN` | `ROLE_ARN_KEY` | Declared but **not used** in Java data plane (only in proto mapping) |

**Note:** `type`, `tokenProvider`, and `roleARN` are mapped via `fieldContractToCredentialsString()` in `KubernetesAuthProvider.java` from protobuf fields but are **never read back** by `KafkaClientsAuth` or `KubernetesCredentials` accessor methods. They exist in the secret data map but are dead values on the Java side.

### Go Side (control-plane/pkg/security/)

| Secret Key | Go Constant | File | Used For |
|---|---|---|---|
| `protocol` | `ProtocolKey` | `secret.go` | Required. Determines auth flow |
| `ca.crt` | `CaCertificateKey` | `secret.go` | PEM CA cert → TLS RootCAs |
| `user.crt` | `UserCertificate` | `secret.go` | PEM user cert → TLS mTLS |
| `user.key` | `UserKey` | `secret.go` | PEM user key → TLS mTLS |
| `user.skip` | `UserSkip` | `secret.go` | Boolean; skip mTLS client auth |
| `sasl.mechanism` | `SaslMechanismKey` | `secret.go` | PLAIN/SCRAM-SHA-256/SCRAM-SHA-512/OAUTHBEARER |
| `user` | `SaslUserKey` | `secret.go` | SASL username |
| `password` | `SaslPasswordKey` | `secret.go` | SASL password |
| `sasltype` | `SaslType` | `secret.go` | Legacy secret key (not actively used in main path) |
| `saslType` | `SaslTypeLegacy` | `secret.go` | Legacy secret key |
| `username` | `SaslUsernameKey` | `secret.go` | Legacy secret key |
| `tls.enabled` | `SSLLegacyEnabled` | `secret.go` | Legacy channel TLS toggle |
| `tokenProvider` | `saslTokenProviderKey` | `oauth/common.go` | Required for OAUTHBEARER; values: `MSKAccessTokenProvider`, `MSKRoleAccessTokenProvider` |
| `roleARN` | `saslRoleARNKey` | `oauth/common.go` | Required for `MSKRoleAccessTokenProvider` |
| `awsRegion` | `saslAWSRegion` | `oauth/common.go` | Optional; defaults to env or `us-east-1` |

---

## 3. Go-Side Secret Validation

### No Strict Allowlist — Unknown Keys Are Ignored

The Go `secretData()` function in `secret.go` (line 68) reads `data[ProtocolKey]` and then selectively picks known keys based on the protocol path. **There is no allowlist or rejection of unknown keys.** Any extra keys in the secret are silently ignored.

```go
func secretData(data map[string][]byte) kafka.ConfigOption {
    // Only reads: ProtocolKey, then branches to saslConfig/sslConfig
    // which read specific known keys. Extra keys are never accessed.
}
```

**What happens with unknown keys:** Nothing. The `data` map is a `map[string][]byte` and Go only accesses it by known key lookups. Unknown keys sit in the map untouched.

### OAUTHBEARER Validation (Go side)

When `sasl.mechanism=OAUTHBEARER`, the Go side:
1. Sets `config.Net.SASL.Enable = true` and `Mechanism = SASLTypeOAuth`
2. Calls `oauth.NewTokenProvider(data)` which requires `tokenProvider` key
3. Currently only supports `MSKAccessTokenProvider` and `MSKRoleAccessTokenProvider`
4. Returns error if `tokenProvider` is missing or unsupported

---

## 4. ConfigMap vs Secret Precedence

### How Properties Are Merged

The data plane pods mount a ConfigMap as properties files:
- `config-kafka-broker-producer.properties` (defined in `data-plane/config/broker/100-config-kafka-broker-data-plane.yaml`)
- `config-kafka-broker-consumer.properties`
- `config-kafka-broker-webclient.properties`
- `config-kafka-broker-httpserver.properties`

These are loaded at startup as base `Properties` objects (e.g., `producerConfigs` in `IngressProducerReconcilableStore`).

**Merge order (IngressProducerReconcilableStore.java, line 137):**
```java
final var producerProps = (Properties) this.producerConfigs.clone();  // ConfigMap base
// then:
KafkaClientsAuth.attachCredentials(producerProps, credentials);  // Secret overrides
// then:
producerProps.setProperty(ProducerConfig.BOOTSTRAP_SERVERS_CONFIG, ...);  // Resource-specific
```

**Secret wins over ConfigMap.** The ConfigMap properties are cloned first, then `attachCredentials` calls `properties.setProperty()` which overwrites any existing key. The same pattern in `ConsumerVerticleBuilder.java` (line 100-101).

---

## 5. Contract Between Control Plane and Data Plane

### Transport: Protobuf File on Shared Volume

**Proto file:** `proto/contract.proto`

The Go control plane reconcilers write a `Contract` protobuf message to a file on a shared volume. The Java data plane watches this file and reconciles resources.

### Auth in the Contract

The `Resource` message has a `oneof Auth` field with three options:
1. `Empty absentAuth` (field 7) — no auth
2. `Reference authSecret` (field 8) — single secret reference (namespace + name)
3. `MultiSecretReference multiAuthSecret` (field 9) — multiple secret references with field mappings

**For `authSecret`:** The data plane reads the secret reference, fetches the secret directly from Kubernetes API, and parses it via `KubernetesCredentials`.

**For `multiAuthSecret`:** The data plane fetches multiple secrets and assembles a virtual credentials map using `KeyFieldReference` mappings (secretKey → SecretField enum).

### SecretField Enum (proto)

```protobuf
enum SecretField {
  SASL_MECHANISM = 0;
  CA_CRT = 1;
  USER_CRT = 2;
  USER_KEY = 3;
  USER = 4;
  PASSWORD = 5;
  TYPE = 6;
  TOKEN_PROVIDER = 7;
  ROLE_ARN = 8;
}
```

### Would Adding New Fields Require Proto Changes?

**For `authSecret` path (single secret reference):** NO proto changes needed. The data plane fetches the secret directly from Kubernetes and reads whatever keys are in it. New keys just need to be consumed by `KubernetesCredentials` and `KafkaClientsAuth`.

**For `multiAuthSecret` path:** YES — would need new `SecretField` enum values if new semantic fields are added, since each secret key is mapped through `KeyFieldReference` using the enum.

**However**, for Azure OAUTHBEARER support, the most likely approach is:
- Add new keys to the secret (e.g., `sasl.login.callback.handler.class`, `sasl.oauthbearer.token.endpoint.url`)
- For the `authSecret` path: no proto changes (secret is read directly)
- For the `multiAuthSecret` path: might need new `SecretField` values OR pass them through existing fields

---

## 6. Existing Tests

### Java Tests

| File | Lines | Coverage |
|---|---|---|
| `data-plane/core/src/test/java/dev/knative/eventing/kafka/broker/core/security/KafkaClientsAuthTest.java` | 206 | Tests PLAIN, SCRAM-SHA-256, SCRAM-SHA-512, SSL, SASL_SSL combinations. **No OAUTHBEARER test cases.** |
| `data-plane/core/src/test/java/dev/knative/eventing/kafka/broker/core/security/CredentialsValidatorTest.java` | 344 | Tests all protocol/mechanism combos. **Has one OAUTHBEARER test** (line 331) — verifies SASL_SSL+OAUTHBEARER passes validation without username/password. |

### Go Tests

| File | Lines | Coverage |
|---|---|---|
| `control-plane/pkg/security/secret_test.go` | 475 | Tests all protocols, SASL mechanisms. **4 OAUTHBEARER tests:** `TestSASLOAuth` (MSK provider), `TestSASLOAuthWithMSKRoleProvider`, `TestSASLOAuthMissingTokenProvider`, `TestSASLOAuthInvalidTokenProvider` |
| `control-plane/pkg/security/oauth/token_provider_test.go` | — | Tests `NewTokenProvider` factory |
| `control-plane/pkg/security/oauth/msk_access_token_issuer_test.go` | — | Tests MSK token issuer |
| `control-plane/pkg/security/oauth/msk_role_access_token_issuer_test.go` | — | Tests MSK role-based token issuer |
| `control-plane/pkg/security/config_test.go` | — | Tests ConfigMap-based secret locator |
| `control-plane/pkg/security/scram_test.go` | — | Tests SCRAM client generator |
| `control-plane/pkg/security/secrets_provider_net_spec_test.go` | — | Tests NetSpec → MultiSecretReference conversion |
| `control-plane/pkg/security/secrets_provider_legacy_channel_secret_test.go` | — | Tests legacy channel secret format |

---

## Summary: Key Findings for Azure OAUTHBEARER Implementation

1. **Java data plane OAUTHBEARER is a stub.** It sets `sasl.mechanism=OAUTHBEARER` but configures nothing else — no JAAS config, no callback handler. Kafka client will fail to connect.

2. **Go control plane OAUTHBEARER is AWS-only.** The `tokenProvider` key supports only `MSKAccessTokenProvider` and `MSKRoleAccessTokenProvider`. There's no Azure/Entra ID token provider.

3. **The `authSecret` path is the easiest to extend** — the data plane fetches the secret directly from k8s and reads keys by name. No proto changes needed. Just:
   - Add new key reads in `KubernetesCredentials` (e.g., for JAAS config, callback handler class)
   - Add OAUTHBEARER handling in `KafkaClientsAuth.sasl()` to set those properties
   - Add an Azure token provider on the Go side

4. **CredentialsValidator already allows OAUTHBEARER+SASL_SSL without username/password.** But OAUTHBEARER+SASL_PLAINTEXT is rejected (probably fine — Azure Event Hubs always uses SSL).

5. **ConfigMap properties are base; secret-derived properties override.** This means custom OAUTHBEARER properties set via the secret will win over any ConfigMap defaults.

6. **Proto `SecretField` enum already has `TOKEN_PROVIDER` (7) and `ROLE_ARN` (8)** — these exist but only support AWS values. For Azure, we might need additional fields or a new token provider type.
