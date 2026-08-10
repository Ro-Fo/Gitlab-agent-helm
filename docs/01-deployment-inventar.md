# 01 – Deployment-Inventar

Was das Chart in den Cluster schreibt, in welcher Reihenfolge der Bedingungen und
mit welchen Parametern. Quelle: `templates/`, `values.yaml` (Chart 2.29.0).

## 1. Erzeugte Kubernetes-Objekte

`{{fullname}}` = `<Release-Name>-gitlab-agent` (bzw. nur `<Release-Name>`, wenn
der Release-Name den Chart-Namen bereits enthält), siehe
`templates/_helpers.tpl`.

| Objekt | Name | Template | Bedingung | Default aktiv |
|---|---|---|---|---|
| `Deployment` | `{{fullname \| trunc 60}}-v2` | `deployment.yaml` | immer | ✅ |
| `ServiceAccount` | `{{fullname}}` | `serviceaccount.yaml` | `serviceAccount.create` | ✅ |
| `ClusterRoleBinding` | `{{namespace}}:{{fullname}}-cluster-admin` | `clusterrolebinding.yaml` | `rbac.create` | ✅ |
| `Secret` (Opaque) | `{{fullname}}-token` | `secret.yaml` | `config.token` **oder** `config.api.jwtPublicKey` **oder** ein TLS-Cert/Key **oder** `config.receptive.enabled` | ➖ ¹ |
| `ConfigMap` | `{{fullname}}` | `configmap.yaml` | `config.kasCaCert` **oder** `config.privateApi.tls.caCert` | ❌ |
| `Service` | `{{fullname \| trunc 55}}-service` | `service.yaml` | `config.receptive.enabled` **oder** `config.observability.enabled` | ✅ (Observability an) |
| `Ingress` | `{{fullname}}-ingress` | `ingress.yaml` | `config.receptive.enabled` **und** `ingress.enabled` | ❌ |
| `Service` + `ServiceMonitor` | `{{fullname}}-observability` | `servicemonitor.yaml` | `serviceMonitor.enabled` | ❌ |
| `Secret` (`kubernetes.io/tls`) | `{{fullname}}-observability` | `observability-secret.yaml` | `config.observability.tls.enabled` **und** `.secret.create` | ❌ |
| `ServiceAccount` (OCS) | `{{fullname}}-ocs-scanning-pod-sa` | `ocs/serviceaccount.yaml` | `config.operational_container_scanning.enabled` | ✅ |
| `ClusterRole` (OCS) | `{{namespace}}:{{fullname}}:ocs` | `ocs/clusterrole.yaml` | dito | ✅ |
| `ClusterRoleBinding` (OCS) | `{{namespace}}:{{fullname}}:ocs` | `ocs/clusterrolebinding.yaml` | dito | ✅ |
| `Role` (OCS) | `{{fullname}}:ocs` | `ocs/role.yaml` | dito | ✅ |
| `RoleBinding` (OCS) | `{{fullname}}:ocs` | `ocs/rolebinding.yaml` | dito | ✅ |
| beliebige Objekte | – | `extra-manifests.yaml` | `extraManifests` gesetzt | ❌ |
| ingress-nginx (Subchart) | – | `Chart.yaml: dependencies` | `ingress-nginx.enabled` | ❌ |

¹ Mit reinen Defaults entsteht **kein** Secret, weil `config.token` leer ist —
das Deployment übergibt aber immer `--token-file=/etc/agentk/secrets/token`.
Ein Token muss deshalb in jedem Fall über einen der beiden Wege kommen:
`config.token` (Chart erzeugt das Secret) **oder** `config.secretName` (Chart
mountet ein extern verwaltetes Secret, erzeugt es aber nicht). Ohne beides
startet der Pod nicht.

> **Merke:** Auch ohne jede Zusatzkonfiguration entstehen **zwei ServiceAccounts,
> zwei ClusterRoleBindings, eine ClusterRole und eine Role** — weil sowohl RBAC
> als auch Operational Container Scanning per Default eingeschaltet sind.

### Namens-Besonderheit `-v2`

Das Deployment trägt den Suffix `-v2` (`deployment.yaml:18`). Das ist eine
absichtliche „Epoch"-Version, um bei Änderungen an unveränderlichen Feldern
(z. B. `spec.selector`) ein sauberes Neuanlegen zu erlauben, statt einen
Upgrade-Fehler zu produzieren
([Chart-Issue #38](https://gitlab.com/gitlab-org/charts/gitlab-agent/-/issues/38)).

## 2. Pod-Spezifikation

| Eigenschaft | Wert | Quelle |
|---|---|---|
| Image | `registry.gitlab.com/gitlab-org/cluster-integration/gitlab-agent/agentk:<appVersion>` | `values.yaml`, `Chart.yaml` |
| Replicas | `2` | `values.yaml: replicas` |
| Update-Strategie | RollingUpdate, `maxSurge: 1`, `maxUnavailable: 0` | `deployment.yaml:26-30` |
| `automountServiceAccountToken` | **`false`** | `deployment.yaml:41` |
| Liveness | `GET :8080/liveness`, delay 15 s, period 20 s | `deployment.yaml:141` |
| Readiness | `GET :8080/readiness`, delay 5 s, period 10 s | `deployment.yaml:147` |
| Observability-Listener | immer aktiv auf `:8080` | `internal/cmd/agent/options.go:52` |
| `terminationMessagePolicy` | `FallbackToLogsOnError` | `values.yaml` |
| `podSecurityContext` / `securityContext` | **leer** (kein Default-Hardening) | `values.yaml:52,57` |
| `resources` | **leer** (keine Requests/Limits) | `values.yaml:198` |

> **Stolperfalle `config.observability.enabled: false`:** Der Wert steuert nur,
> was das *Chart* tut — Prometheus-Annotationen entfernen, `containerPort` und
> `Service` weglassen. Er wird **nicht** an `agentk` durchgereicht: Es gibt kein
> entsprechendes Flag, und der Default-Listener bleibt `:8080`
> (`internal/cmd/agent/options.go:52`). Der Port ist also weiterhin offen, und
> die Health-Probes funktionieren weiter — sie sind im Template ohnehin
> unbedingt. „Observability aus" heißt hier „nicht mehr beworben", nicht
> „abgeschaltet".

### ServiceAccount-Token

`automountServiceAccountToken: false` bedeutet **nicht**, dass der Pod kein
Token bekommt. Das Chart mountet stattdessen ein *projected volume* selbst
(`deployment.yaml:238-253`):

```yaml
- name: service-account-token-volume        # → /var/run/secrets/kubernetes.io/serviceaccount
  projected:
    sources:
      - configMap: { name: kube-root-ca.crt }
      - downwardAPI: [ metadata.namespace ]
      - serviceAccountToken: { expirationSeconds: 3600, path: token }
```

Das ist eine **Verbesserung gegenüber dem Default**: kurzlebiges Token mit 1 h
Gültigkeit und automatischer Rotation statt eines unbefristeten Legacy-Tokens.
Der Mountpfad bleibt der Standardpfad, damit die Kubernetes-Client-Bibliothek in
`agentk` ihn unverändert findet.

### Environment-Variablen

| Variable | Quelle | Zweck |
|---|---|---|
| `POD_NAMESPACE`, `POD_NAME`, `POD_IP` | Downward API | Identität, Telemetrie, Peer-Discovery |
| `SERVICE_ACCOUNT_NAME` | Downward API | wird an OCS-Modul durchgereicht |
| `GITLAB_AGENT_TELEMETRY_installation_method` | fix: `helm-chart` | **wird an GitLab gemeldet** |
| `GITLAB_AGENT_TELEMETRY_helm_chart_version` | `.Chart.Version` | **wird an GitLab gemeldet** |
| `OCS_ENABLED`, `OCS_SERVICE_ACCOUNT_NAME` | Values | Steuerung Container-Scanning |
| `OWN_PRIVATE_API_URL`, `POD_SELECTOR_LABELS` | nur bei `receptive.enabled` | agentk↔agentk-Peer-Discovery |
| `GOMAXPROCS`, `GOMEMLIMIT` | `resources.limits` | nur gesetzt, wenn Limits definiert sind |

Alle `GITLAB_AGENT_TELEMETRY_*`-Variablen werden von `agentk` eingesammelt
(`internal/cmd/agent`: `CollectExtraTelemetryData`) und als
`ExtraTelemetryData` an GitLab übertragen — siehe
[02-gitlab-schnittstellen.md](02-gitlab-schnittstellen.md#agent-registrierung).

### Abbildung Values → agentk-Flags

`deployment.yaml:65-123` übersetzt Values in Kommandozeilenflags:

| Value | Flag | Bemerkung |
|---|---|---|
| immer | `--token-file=/etc/agentk/secrets/token` | |
| `config.kasAddress` | `--kas-address` | **entfällt bei `receptive.enabled`** |
| `config.kasCaCert` | `--kas-ca-cert-file` | aus ConfigMap |
| `config.kasHeaders[]` | `--kas-header` (mehrfach) | z. B. Canary-Cookie |
| `config.observability.tls.*` | `--observability-cert-file`, `--observability-key-file` | |
| `config.api.*` | `--api-listen-network/-address/-cert-file/-key-file`, `--api-jwt-file` | nur bei `receptive.enabled` |
| `config.privateApi.*` | `--private-api-*` | nur bei `receptive.enabled` |
| `extraArgs[]` | frei | ungeprüft durchgereicht |

Nicht vom Chart gesetzt, aber in `agentk` vorhanden (über `extraArgs` erreichbar):
`--kas-insecure-skip-tls-verify`, `--kas-tls-server-name`,
`--api-client-ca-cert-file`, `--api-mtls`
(`internal/cmd/agent/options.go`, `internal/cmd/agentk/command.go`).

## 3. Zwei Betriebsmodi

Das Chart unterstützt beide Verbindungsrichtungen. Die Wahl trifft
`config.receptive.enabled`.

### Modus A – ausgehend (Default, `receptive.enabled: false`)

`agentk` wählt sich bei Relay/KAS ein und hält einen langlebigen
bidirektionalen gRPC-Stream offen. Kein eingehender Port nötig, funktioniert
hinter NAT und Firewall.

### Modus B – „receptive" (`receptive.enabled: true`)

Umgekehrte Richtung: **GitLab/Relay verbindet sich zum Cluster.** Dann gilt:

- `--kas-address` wird **nicht** gesetzt.
- `agentk` öffnet zwei Listener: API (`:8082`) und Private API (`:8081`).
- Ein `Service` (Default `ClusterIP`, externer Port `8182`) und optional ein
  `Ingress` mit `backend-protocol: GRPC` machen den Agenten erreichbar.
- Authentifizierung von Relay gegenüber `agentk` per **EdDSA-JWT**
  (`config.api.jwtPublicKey`) oder **mTLS**.
- Die Pods sprechen untereinander über die Private API; das Chart erzeugt dafür
  automatisch ein 64-Byte-Zufallssecret (`private-api-jwt`, `secret.yaml`), das
  bei Upgrades über `lookup` erhalten bleibt.

Laut `doc/kas_to_agentk_connectivity.md` im Agent-Repo ist Modus B ausdrücklich
**nur für Self-Managed-Installationen** vorgesehen, nicht für GitLab.com.

Die Helper `gitlab-agent.validateApiPort` und `…validatePrivateApiPort`
(`_helpers.tpl`) brechen das Rendering ab, wenn `service.internalPort` bzw.
`service.privateApiPort` nicht zu den Ports in den `listenAddress`-Werten passen.

## 4. Was das Chart **nicht** tut

- Es erzeugt **keinen Namespace**. Der muss vorhanden sein
  (`helm install --create-namespace` oder vorab angelegt).
- Es rollt **kein KAS/Relay** aus — das kommt aus dem GitLab-Chart.
- Es installiert **kein Flux**. Das Flux-Modul in `agentk` erwartet eine
  bestehende Flux-Installation im Cluster.
- Es setzt **keine NetworkPolicy**, keine PodDisruptionBudget, kein HPA.
- Es setzt **keine Ressourcen-Limits** und **keinen SecurityContext** — beides
  muss bewusst über `values.yaml` ergänzt werden.
- Es legt **keine Agent-Registrierung in GitLab** an; Agent und Token müssen dort
  vorher erzeugt werden.
