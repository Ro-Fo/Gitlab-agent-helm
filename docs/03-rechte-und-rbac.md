# 03 – Rechte und RBAC

Vollständige Aufstellung aller Berechtigungen, die im Zusammenhang mit dem
Helm-Deployment vergeben werden — im Cluster **und** in GitLab.

## 0. Der wichtigste Befund

> **Die Standardkonfiguration des Charts bindet den `agentk`-ServiceAccount an
> `cluster-admin` — clusterweit, ohne jede Einschränkung.**

```yaml
# templates/clusterrolebinding.yaml (gerendert mit Default-Values)
kind: ClusterRoleBinding
metadata:
  name: <namespace>:<fullname>-cluster-admin
roleRef:
  kind: ClusterRole
  name: cluster-admin          # ← .Values.rbac.useExistingRole | default "cluster-admin"
subjects:
  - kind: ServiceAccount
    name: <fullname>
    namespace: <namespace>
```

Wer den Agent-Token besitzt oder über GitLab Zugriff auf den Agent erhält, kann
damit — je nach Impersonation-Modus — mit `cluster-admin`-Rechten auf dem
Cluster arbeiten. Der Agent ist damit ein **Cluster-weiter Vertrauensanker**,
kein namespace-begrenztes Werkzeug.

Das ist kein Versehen des Charts: Features wie Operational Container Scanning
sind darauf ausgelegt, den gesamten Cluster zu sehen (`doc/operational_container_scanning.md`
sagt explizit: „OCS requires a `cluster-admin` role to get all the workloads in
the cluster"). Es ist aber eine bewusste Entscheidung, die man treffen und
dokumentieren muss — nicht eine, in die man hineinrutschen sollte.

## 1. Kubernetes-RBAC aus dem Chart

### 1.1 Übersicht

| Objekt | Subjekt | Rolle | Scope | Bedingung |
|---|---|---|---|---|
| `ClusterRoleBinding` `{{ns}}:{{fullname}}-cluster-admin` | SA `{{fullname}}` | `cluster-admin` | **cluster-weit** | `rbac.create: true` (Default) |
| `ClusterRoleBinding` `{{ns}}:{{fullname}}:ocs` | SA `{{fullname}}-ocs-scanning-pod-sa` | `{{ns}}:{{fullname}}:ocs` | **cluster-weit** | OCS aktiv (Default) |
| `RoleBinding` `{{fullname}}:ocs` | SA `{{fullname}}-ocs-scanning-pod-sa` | Role `{{fullname}}:ocs` | Release-Namespace | OCS aktiv (Default) |

Es gibt also **zwei Identitäten** mit unterschiedlichen Rechten:

- **`{{fullname}}`** — der Agent selbst. Default: `cluster-admin`.
- **`{{fullname}}-ocs-scanning-pod-sa`** — die Scan-Pods. Nur Lesezugriff
  (plus `create` auf ConfigMaps im eigenen Namespace).

### 1.2 Stellschraube `rbac.useExistingRole`

```yaml
rbac:
  create: true
  useExistingRole: my-restricted-clusterrole   # statt cluster-admin
```

Wichtig zu verstehen:

- Der Wert ersetzt nur den **`roleRef`**. Es bleibt in jedem Fall ein
  **`ClusterRoleBinding`** und der Verweis geht auf eine **`ClusterRole`**.
- Eine Begrenzung auf einen Namespace ist über das Chart **nicht** möglich.
  Dafür: `rbac.create: false` setzen und `RoleBinding`(s) selbst verwalten
  (z. B. über `extraManifests`).
- Das Chart erzeugt die referenzierte ClusterRole **nicht** — sie muss existieren.
- Der Name des Bindings enthält den Rollennamen; eine Änderung von
  `useExistingRole` erzeugt also ein **neues** Binding. Das alte kann als
  Helm-Waise zurückbleiben — nach dem Umstellen prüfen.

### 1.3 OCS-ClusterRole im Detail

`templates/ocs/clusterrole.yaml`, alle Regeln clusterweit, Verben ausschließlich
`get` und `list`:

| API-Gruppe | Ressourcen |
|---|---|
| `batch` | `cronjobs`, `jobs` |
| `""` (core) | `pods`, `replicationcontrollers`, `serviceaccounts`, `namespaces`, `services`, `configmaps`, `resourcequotas`, `limitranges`, `nodes`, **`secrets`** |
| `apps` | `replicasets`, `daemonsets`, `statefulsets`, `deployments` |
| `rbac.authorization.k8s.io` | `roles`, `rolebindings`, `clusterroles`, `clusterrolebindings` |
| `networking.k8s.io` | `networkpolicies`, `ingresses` |

Zusätzlich `templates/ocs/role.yaml` — nur im Release-Namespace:

| API-Gruppe | Ressourcen | Verben |
|---|---|---|
| `""` | `configmaps` | `create` |

> ⚠️ **`secrets` mit `get`/`list` clusterweit** ist die schärfste Einzelregel
> dieses Charts. Das erlaubt dem Scan-Pod, **jedes Secret im Cluster zu lesen** —
> Datenbankpasswörter, TLS-Privatschlüssel, Cloud-Credentials. Fachlich braucht
> Trivy Secrets, um `imagePullSecrets` aufzulösen und private Registries zu
> scannen. Das Recht ist dafür aber deutlich breiter als nötig.
>
> Wer OCS nicht nutzt, sollte es abschalten:
> ```yaml
> config:
>   operational_container_scanning:
>     enabled: false
> ```
> Das entfernt SA, ClusterRole, ClusterRoleBinding, Role und RoleBinding
> vollständig.

### 1.4 Token-Handhabung im Pod

| Maßnahme | Wirkung |
|---|---|
| `automountServiceAccountToken: false` | kein automatisches Legacy-Token |
| projected volume mit `expirationSeconds: 3600` | kurzlebiges, rotierendes Token |
| `defaultMode: 0444` auf allen Secret-Volumes | Dateien nur lesbar |
| `checksum/token`-Annotation | Rollout bei Token-Rotation wird erzwungen |

Das ist sauber gelöst. Der Rest des Pods dagegen nicht: `securityContext` und
`podSecurityContext` sind **leer**. Es gibt per Default weder `runAsNonRoot` noch
`readOnlyRootFilesystem` noch `drop: [ALL]`. Die `values.yaml` nennt die passenden
Werte nur als Kommentarbeispiel — gesetzt sind sie nicht.

## 2. Welche Rechte wofür gebraucht werden

Grundlage für eine Least-Privilege-Rolle. Reihenfolge: was das Feature tut →
was es dafür können muss.

| Feature | Benötigte Kubernetes-Rechte |
|---|---|
| **CI-/User-Zugriff (`access_as: agent`)** | Genau das, was die durchgereichten `kubectl`-Aufrufe brauchen. Der Agent ist hier ein Proxy — sein SA ist die Obergrenze dessen, was CI und User können. |
| **CI-/User-Zugriff (Impersonation)** | `impersonate` auf `users`, `groups`, `serviceaccounts` und `uids` (API-Gruppe `authentication.k8s.io` für `userextras`). Zusätzlich müssen die impersonierten Identitäten eigene RBAC-Regeln haben. |
| **Live-Cluster-Ansicht (`WatchGraph`)** | `get`, `list`, `watch` auf die angezeigten Objektarten |
| **Flux-Modul** | `get`/`list`/`watch` auf `source.toolkit.fluxcd.io/GitRepository`, voller CRUD auf `notification.toolkit.fluxcd.io/Receiver` und die zugehörigen `Secret`s (in den jeweiligen Namespaces) |
| **Operational Container Scanning** | Agent: `create`/`get`/`delete` auf `pods` plus `pods/log` im Agent-Namespace. Scan-Pod: die ClusterRole aus 1.3. |
| **Managed Resources / Environments** | `create`/`update`/`delete` auf `namespaces`, `serviceaccounts`, `rolebindings` — abhängig von den Environment-Templates |
| **Remote Development / Workspaces** | CRUD in den Workspace-Namespaces inkl. `networkpolicies` |
| **Leader Election** | CRUD auf `coordination.k8s.io/leases` im Agent-Namespace (nötig, weil 2 Replicas) |
| **Events** | `create`/`patch` auf `events` |

Der Kern: **Nur die Impersonation-Modi verschieben die Rechtegrenze weg vom
Agent-SA.** In allen anderen Fällen ist der Agent-SA die harte Obergrenze — was
er nicht darf, kann auch über GitLab niemand.

## 3. GitLab-seitige Rechte

### 3.1 Agent-Token

| Eigenschaft | Wert |
|---|---|
| Typ | Bearer-Token, Zufallsstring ohne kodierten Inhalt |
| Erzeugung | in GitLab, Rolle **Maintainer** oder höher |
| Speicherung GitLab | verschlüsselt at rest |
| Speicherung Cluster | `Secret {{fullname}}-token`, Schlüssel `token` |
| Rotation | mehrere gültige Tokens pro Agent möglich → unterbrechungsfreie Rotation |
| Widerruf | einmalig setzbares `revoked`-Flag, danach unveränderlich |
| Übertragung | `authorization: Bearer <token>` bei jeder Anfrage |

(`doc/identity_and_auth.md`)

**Wichtig für die Chart-Nutzung:** `config.token` in `values.yaml` landet
im Klartext in der Helm-Release-History im Cluster. Sauberer ist
`config.secretName` — Secret extern verwalten (External Secrets Operator, SOPS,
Vault) und dem Chart nur den Namen geben. Dann greift allerdings die
`checksum/token`-Annotation nicht mehr; Rollouts bei Token-Rotation muss man
selbst anstoßen.

### 3.2 CI-Zugriff (`ci_access`)

Konfiguriert **nicht** im Chart, sondern in
`.gitlab/agents/<agent>/config.yaml` im Konfigurationsprojekt. Das heißt: **Wer
in dieses Repo schreiben darf, vergibt Cluster-Zugriff.** Dieses Projekt ist
sicherheitstechnisch so kritisch wie der Cluster selbst — Protected Branches und
Merge-Request-Approvals sind dort Pflicht.

```yaml
ci_access:
  projects:
    - id: group/project
      default_namespace: ns
      environments: [staging, "review/*"]
      protected_branches_only: true
      resource_management: { enabled: false }
      access_as: { agent: {} }
  groups:
    - id: group/subgroup
      # gleiche Felder
```

| Feld | Wirkung |
|---|---|
| `projects[].id` / `groups[].id` | wer den Agent nutzen darf; bei Gruppen **alle** enthaltenen Projekte |
| `default_namespace` | Default-Namespace im injizierten Kubecontext (keine Durchsetzung!) |
| `environments[]` | nur Jobs, die auf ein passendes Environment deployen (Glob) |
| `protected_branches_only` | nur Jobs auf geschützten Branches |
| `resource_management.enabled` | erlaubt automatisches Anlegen von Namespaces/SAs per Environment-Template |

Authentifizierung des CI-Jobs: `KUBECONFIG` wird injiziert, das Token hat die
Form `ci:<agent id>:<CI_JOB_TOKEN>`.

> `default_namespace` ist **keine Sicherheitsgrenze**. Es setzt nur den
> Default-Kontext; `kubectl -n anderer-namespace` funktioniert weiterhin, sofern
> die verwendete Identität es darf. Begrenzung erfolgt ausschließlich über RBAC
> im Cluster.

### 3.3 User-Zugriff (`user_access`)

```yaml
user_access:
  access_as: { agent: {} }     # oder { user: {} } (Premium)
  projects: [{ id: group/project }]
  groups:   [{ id: group }]
```

Zugriffsberechtigt sind Mitglieder ab Rolle **Developer**. Authentifizierung
über einen von drei Wegen (`doc/kubernetes_user_access.md`):

| Methode | Form |
|---|---|
| Personal Access Token | Bearer `pat:<agent id>:<token>`, Scope **`k8s_proxy`**, Laufzeit max. 1 Jahr |
| OIDC ID-Token | signiertes JWT als Bearer |
| Browser-Cookie | separater `Cookie`-Header (GitLab-UI) |

Der PAT soll ausschließlich den Scope `k8s_proxy` tragen — er darf keinen
Zugriff auf die übrige GitLab-API gewähren.

### 3.4 Impersonation-Modi — die eigentliche Rechtegrenze

`access_as` bestimmt, mit welcher Identität `agentk` gegenüber der
Kubernetes-API auftritt. Implementiert sind
(`pkg/agentcfg/agentcfg.proto:111-136, 178-190`):

| Modus | gültig für | Identität gegenüber Kubernetes |
|---|---|---|
| `agent: {}` | ci_access, user_access | der ServiceAccount des Pods — **Default, per Chart `cluster-admin`** |
| `impersonate: {…}` | ci_access | frei gewählter `username`, `uid`, `groups[]`, `extra[]` |
| `ci_job: {}` | ci_access | synthetische Identität aus dem CI-Job |
| `user: {}` | user_access (Premium) | der authentifizierte GitLab-User |

`ci_user` taucht in `doc/kubernetes_ci_access.md` auf, ist im Proto aber **nicht**
enthalten — geplant, nicht implementiert. Nicht darauf bauen.

Bei `ci_job` konstruiert der Agent (`doc/kubernetes_ci_access.md`):

- **UserName:** `gitlab:ci_job:<job id>`
- **Groups:**
  - `gitlab:ci_job`
  - `gitlab:group:<id>` je Gruppe der Projekthierarchie
  - `gitlab:group_env_tier:<group id>:<tier>`
  - `gitlab:project:<id>`
  - `gitlab:project_env:<project id>:<slug>`
  - `gitlab:project_env_tier:<project id>:<tier>`
- **Extra:** `agent.gitlab.com/id`, `…/config_project_id`, `…/project_id`,
  `…/ci_pipeline_id`, `…/ci_job_id`, `…/username`, `…/environment_slug`,
  `…/environment_tier`

**Das ist der Hebel für echte Least-Privilege-Deployments.** Man kann im Cluster
RBAC gegen diese synthetischen Gruppen schreiben, zum Beispiel:

```yaml
kind: RoleBinding
metadata: { name: deploy-prod, namespace: prod }
roleRef: { kind: ClusterRole, name: edit, apiGroup: rbac.authorization.k8s.io }
subjects:
  - kind: Group
    name: "gitlab:project_env_tier:150:production"
    apiGroup: rbac.authorization.k8s.io
```

Damit deployt nur noch Projekt 150 und nur in Produktions-Environments nach
`prod` — unabhängig davon, was der Agent-SA selbst dürfte.

Zwei Fallstricke:

1. Für alles außer `agent: {}` braucht der Agent-SA selbst das
   **`impersonate`-Recht**. Wird die Rolle verschärft, muss es explizit drinstehen.
2. Nur bei `agent: {}` dürfen Clients eigene `Impersonate-*`-Header schicken. In
   allen anderen Modi werden solche Requests mit **HTTP 400** abgelehnt —
   verschachtelte Impersonation gibt es nicht.

## 4. Vertrauensketten

Wer effektiv Rechte am Cluster hat:

```
GitLab-Konfigurationsprojekt (.gitlab/agents/<name>/config.yaml)
   └─ legt fest, wer den Agent nutzen darf und mit welcher Identität
        └─ Agent-Token (Secret im Cluster)
             └─ agentk-ServiceAccount  →  Kubernetes RBAC (Default: cluster-admin)
                  └─ ggf. impersonierte Identität → deren RBAC
```

Daraus folgt konkret:

| Wer | Kann effektiv |
|---|---|
| Maintainer des Konfigurationsprojekts | Zugriff für beliebige Projekte/Gruppen freischalten, Impersonation-Modus wählen |
| Developer in einem freigegebenen Projekt | CI-Jobs gegen den Cluster fahren, im Rahmen des gewählten Modus |
| Wer den Agent-Token liest | sich als Agent gegenüber GitLab ausgeben |
| Wer im Agent-Namespace `exec` darf | an das SA-Token kommen → bei Default `cluster-admin` |

Der letzte Punkt wird oft übersehen: `pods/exec` im Agent-Namespace ist bei
Default-RBAC gleichbedeutend mit Cluster-Admin. Der Agent-Namespace gehört
entsprechend geschützt.

## 5. Härtungsempfehlungen

Nach Wirkung sortiert.

| # | Maßnahme | Aufwand |
|---|---|---|
| 1 | `cluster-admin` ersetzen: eigene ClusterRole nach Abschnitt 2 bauen und über `rbac.useExistingRole` binden | mittel |
| 2 | OCS abschalten, wenn nicht genutzt (`config.operational_container_scanning.enabled: false`) — entfernt u. a. clusterweites `secrets`-Leserecht | gering |
| 3 | Impersonation statt `access_as: agent` — verlagert die Rechtegrenze auf granulare, pro Projekt/Environment definierte Identitäten | mittel |
| 4 | `securityContext` setzen: `runAsNonRoot`, `runAsUser`, `readOnlyRootFilesystem`, `capabilities.drop: [ALL]`, `allowPrivilegeEscalation: false` | gering |
| 5 | Token nicht über `config.token` ausrollen, sondern `config.secretName` + externes Secret-Management | gering |
| 6 | `protected_branches_only: true` und `environments[]` in jedem `ci_access`-Eintrag | gering |
| 7 | Konfigurationsprojekt schützen: Protected Branches, CODEOWNERS, MR-Approvals | gering |
| 8 | `resources.requests`/`limits` setzen — aktiviert nebenbei `GOMAXPROCS`/`GOMEMLIMIT` | gering |
| 9 | NetworkPolicy für den Agent-Namespace (Egress nur zu KAS und Kubernetes-API) | mittel |
| 10 | RBAC-Zugriff auf den Agent-Namespace beschränken, insbesondere `pods/exec` und `secrets` | gering |

### Beispiel: minimal gehärtete `values.yaml`

Startpunkt, kein fertiges Ergebnis — die ClusterRole aus Punkt 1 muss zu den
tatsächlich genutzten Features passen.

```yaml
config:
  kasAddress: wss://kas.gitlab.example.com
  secretName: gitlab-agent-token        # extern verwaltet
  operational_container_scanning:
    enabled: false

rbac:
  create: true
  useExistingRole: gitlab-agent-restricted

securityContext:
  runAsNonRoot: true
  runAsUser: 1000
  readOnlyRootFilesystem: true
  allowPrivilegeEscalation: false
  capabilities:
    drop: [ALL]

resources:
  requests: { cpu: 100m, memory: 128Mi }
  limits:   { cpu: 500m, memory: 512Mi }
```

## 6. Offene Punkte für die eigene Bewertung

- Welche Features werden tatsächlich genutzt? Daraus folgt die minimale ClusterRole.
- Wird `receptive` gebraucht? Das dreht die Firewall-Richtung um (siehe
  [02-gitlab-schnittstellen.md](02-gitlab-schnittstellen.md#3-verbindung-2-und-3-receptive-modus-eingehend)).
- Ein Agent pro Team/Namespace statt eines Cluster-Agenten? Mehrere Agenten mit
  je eigener Identität sind ausdrücklich vorgesehen (`doc/identity_and_auth.md`)
  und meist der sauberere Schnitt als ein allmächtiger Agent.
- Wer betreibt KAS/Relay — GitLab.com oder selbst? Bei Self-Managed kommt der
  gesamte serverseitige Schnittstellenblock aus
  [02, Abschnitt 7](02-gitlab-schnittstellen.md#7-serverseitige-gitlab-schnittstellen-nur-zur-einordnung)
  in die eigene Verantwortung.
