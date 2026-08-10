# 06 – Strategie: Deployment und Scanning ausschließlich über CRDs

Zielbild für regulierte Umgebungen: **GitLab deployt nicht. GitLab schreibt
Absichten in CRDs, Operatoren setzen sie um, Status fließt an den Merge Request
zurück.**

Annahme laut Vorgabe: **ArgoCD und Trivy Operator sind im Cluster installiert.**
Die Schnittstelle zu beiden ist ausschließlich ihr CRD-Satz. Jede Funktion läuft
in einem eigenen Container mit eigenem ServiceAccount.

## 1. Das Problem in einem Bild

Heute kann der GitLab Agent Workloads direkt erzeugen. Es gibt dafür vier
offene Pfade:

| # | Pfad | Mechanismus | Wer löst aus |
|---|---|---|---|
| P1 | CI-Job → `kubectl apply` | K8s-API-Proxy über `ci_access` | jeder Developer mit Pipeline |
| P2 | Environment-Templates | `managed_resources` erzeugt Namespace, SA, RoleBinding | GitLab automatisch beim Environment-Start |
| P3 | User → `kubectl` | K8s-API-Proxy über `user_access` | jeder Developer ab Rolle Developer |
| P4 | Workspaces | `remote_development` erzeugt Workloads | jeder mit Workspace-Zugriff |

P2 verdient besondere Aufmerksamkeit. Das mitgelieferte Default-Template
(`internal/module/managed_resources/server/default_template.yaml`) tut Folgendes:

```yaml
- kind: Namespace
  metadata: { name: '{{ .environment.slug }}-{{ .project.id }}-{{ .agent.id }}' }
- kind: RoleBinding
  roleRef: { kind: ClusterRole, name: admin }      # ← admin im Environment-Namespace
  subjects:
    - kind: Group
      name: gitlab:project_env:{{ .project.id }}:{{ .environment.slug }}
```

Ein CI-Job bekommt damit automatisch `admin` in seinem Environment-Namespace —
ohne dass jemand RBAC schreibt. Für eine Bank ist das nicht verhandelbar: Der
Deploy-Pfad ist damit die Pipeline, nicht ein auditierbarer Operator.

**Das Ziel:** Alle vier Pfade werden geschlossen. Übrig bleibt genau ein
Schreiber auf Workload-Objekten — der GitOps-Operator.

## 2. Zielarchitektur

```
 Merge Request                                     Cluster
      │                                    ┌──────────────────────────┐
      │  (1) merge                         │                          │
      ▼                                    │   ┌──────────────────┐   │
 Git-Repository ◄────────── pull ──────────┼───│     ArgoCD       │   │
      │                                    │   └────────┬─────────┘   │
      │  (2) Application-CR                │            │ apply       │
      │      (deklarativ im Repo           │            ▼             │
      │       oder via ApplicationSet)     │      Workloads           │
      │                                    │                          │
      │                                    │   ┌──────────────────┐   │
      │  (4) Commit-Status / MR-Kommentar  │   │  Trivy Operator  │   │
      ◄────────────────────────────────────┼───│  schreibt CRs    │   │
      │         (3) Notifications          │   └────────┬─────────┘   │
      │                                    │            │             │
      │  (5) Vulnerabilities               │   ┌────────▼─────────┐   │
      ◄────────────────────────────────────┼───│  vuln-bridge     │   │
                                           │   └──────────────────┘   │
                                           └──────────────────────────┘
```

Kernaussage: **Es gibt keinen Pfeil mehr von GitLab in den Cluster hinein, der
Workloads erzeugt.** Was von GitLab kommt, ist entweder ein Git-Commit oder ein
CR — und CRs sind Absichtserklärungen, keine Ausführung.

## 3. Baustein 1 — Deployment über den GitOps-Operator

Drei Varianten, wie die `Application`-CRs entstehen. Sie unterscheiden sich
darin, **wer sie schreibt**.

### V1 — Reiner Pull, CRs liegen im Git

Die `Application`-CRs (oder ein `ApplicationSet`) liegen als Manifeste in einem
GitOps-Repository. ArgoCD zieht sie selbst. GitLab schreibt **nichts** in den
Cluster.

Dynamische Environments (Review-Apps pro MR) löst der **ApplicationSet PR
Generator**: ArgoCD fragt die GitLab-API nach offenen Merge Requests und erzeugt
je MR eine `Application`. Der Trigger bleibt lesend und liegt beim Operator.

| | |
|---|---|
| **Cluster-Schreibrechte für GitLab** | keine |
| **Neue Komponenten** | keine |
| **Review-Apps** | über ApplicationSet PR Generator |
| **Grenze** | Environment-Metadaten in GitLab (Deployments, Environment-Status) müssen separat gepflegt werden |

### V2 — Ein eigener Broker schreibt CRs

Ein kleiner Dienst im Cluster („deploy-bridge") übersetzt GitLab-Environments in
`Application`-CRs. Eigener Container, eigener SA, RBAC **ausschließlich** auf
`applications.argoproj.io`.

| | |
|---|---|
| **Cluster-Schreibrechte** | nur `applications.argoproj.io` |
| **Neue Komponenten** | eine, selbst zu pflegen |
| **Review-Apps** | explizit modelliert |
| **Grenze** | wird selbst zur privilegierten Komponente: wer `Application` schreiben darf, kann alles deployen, was ArgoCD deployen darf |

### V3 — Der Agent schreibt CRs, RBAC begrenzt ihn darauf

`agentk` und `ci_access` bleiben, aber die ClusterRole des Agenten erlaubt
**nur** `applications.argoproj.io`. Der CI-Job macht
`kubectl apply -f application.yaml` — und kann strukturell nichts anderes.

```yaml
kind: ClusterRole
metadata: { name: gitlab-agent-argo-only }
rules:
  - apiGroups: ["argoproj.io"]
    resources: ["applications"]
    verbs: ["get", "list", "watch", "create", "update", "patch"]
```

| | |
|---|---|
| **Cluster-Schreibrechte** | nur `applications.argoproj.io` |
| **Neue Komponenten** | keine |
| **Durchsetzung** | reine RBAC — Klasse **K4** nach [04](04-feature-matrix-abschaltbarkeit.md#2-wirksamkeitsklassen) |
| **Grenze** | der K8s-API-Proxy existiert weiter (K0), ist aber wirkungslos |

### Empfehlung

**V1 als Zielbild, V3 als Migrationsschritt.** V3 ist heute mit
`rbac.useExistingRole` umsetzbar und braucht weder Code noch neue Komponenten —
und er ist trotzdem eine echte Grenze, weil RBAC im Cluster durchgesetzt wird.
V1 entfernt danach auch noch den letzten Schreibpfad.

**V2 nur, wenn V1 an den Review-Apps scheitert.** Ein selbst gebauter Broker mit
Schreibrecht auf `Application` ist sicherheitstechnisch fast so stark wie der
Agent heute — er verlagert das Problem, statt es zu lösen.

### Die Grenze wandert zum Operator

Wichtig und oft übersehen: Sobald nur noch ArgoCD deployt, ist **ArgoCD** die
privilegierte Komponente. Ohne zusätzliche Begrenzung ist damit nichts gewonnen,
nur verschoben. Die Begrenzung erfolgt über:

- **`AppProject`** — schränkt je Projekt ein, aus welchen Repos deployt werden
  darf, in welche Cluster und Namespaces (`destinations`), und welche
  Ressourcenarten überhaupt erlaubt sind (`namespaceResourceWhitelist`,
  `clusterResourceBlacklist`). Ein `AppProject` pro Mandant ist das Gegenstück
  zum heutigen `ci_access`-Eintrag.
- **`Application.spec.destination`** — bindet die Anwendung an Cluster und
  Namespace.
- Bei Flux entsprechend **`Kustomization.spec.serviceAccountName`**: Flux
  wendet die Manifeste dann *als dieser ServiceAccount* an. Damit lässt sich
  Least Privilege pro Mandant erzwingen, ohne dass Flux selbst entmachtet wird.

> **Ohne `AppProject`-Begrenzung ist die Migration eine Umbenennung, keine
> Härtung.** Dieser Punkt gehört in jedes Review.

## 4. Baustein 2 — Status zurück an den Merge Request

Hier ist die Lage besser als erwartet, und sie unterscheidet die beiden
Operatoren deutlich.

### Flux — nativ, ohne Code

Der notification-controller kennt `Provider`-Typen, die direkt auf GitLab
schreiben. Verifiziert gegen
`notification.toolkit.fluxcd.io_providers.yaml` (Stand `main`):

```
slack · generic · generic-hmac · github · gitlab · gitea ·
giteapullrequestcomment · bitbucketserver · bitbucket · azuredevops ·
githubdispatch · githubpullrequestcomment · gitlabmergerequestcomment
```

- **`gitlab`** → setzt den **Commit-Status**. Erscheint direkt im Merge Request
  als Check.
- **`gitlabmergerequestcomment`** → schreibt einen **Kommentar in den Merge
  Request**.

Das ist exakt die geforderte Rückschreibung, fertig implementiert. Benötigt wird
ein `Provider` mit `secretRef` auf ein Token und ein `Alert`, der die
`Kustomization` als Quelle referenziert.

### ArgoCD — über Argo CD Notifications

ArgoCD löst dasselbe über sein Notifications-Subsystem: Trigger auf
`on-sync-succeeded` / `on-health-degraded` / `on-sync-failed`, Template mit einem
Webhook auf die GitLab-Commit-Status-API. Der Weg ist etabliert, aber es ist
Konfiguration, die man selbst schreibt und testet — kein fertiger
„MR-Kommentar"-Typ wie bei Flux.

Die verwendete GitLab-Schnittstelle ist in beiden Fällen die **öffentliche**
Commit-Status-API:

```
POST /api/v4/projects/:id/statuses/:sha
     state=pending|running|success|failed|canceled
     name, target_url, description
```

Das ist bewusst hervorzuheben: **Diese Rückschreibung braucht keinen Agenten,
keinen Tunnel und keine interne API.** Sie braucht ein Projekt- oder
Gruppen-Access-Token mit `api`-Scope, abgelegt als Secret im Cluster — und der
Datenfluss ist ausgehend vom Cluster.

### Konsequenz für die Operatorwahl

Wenn die MR-Rückschreibung ein Kernziel ist, spricht viel für Flux:

| | Flux | ArgoCD |
|---|---|---|
| Commit-Status | nativer `Provider`-Typ | eigene Notification-Konfiguration |
| MR-Kommentar | nativer `Provider`-Typ | selbst zu bauen |
| GitLab-Agent kennt die CRs | ✅ `managed_resources` rendert sie | ❌ nicht unterstützt |
| Least Privilege beim Apply | `Kustomization.spec.serviceAccountName` | über `AppProject` + Cluster-Credentials |

Der zweite Punkt ist bemerkenswert: `internal/module/managed_resources/server/rest_mapper.go`
kennt `GitRepository`, `HelmRepository`, `HelmChart`, `Bucket`, `OCIRepository`,
`Kustomization`, `HelmRelease`, `Alert`, `Provider` und `Receiver` — **aber
keine ArgoCD-Ressourcen.** GitLab hat sich produktseitig bereits auf Flux
festgelegt. Wer ArgoCD nutzt, arbeitet an dieser Stelle ohne Produktunterstützung.

Da laut Vorgabe ArgoCD installiert ist, ist das kein K.-o.-Kriterium — aber es
ist ein Argument, das vor der endgültigen Festlegung auf dem Tisch liegen sollte.

## 5. Baustein 3 — Trivy über CRDs statt im Produkt

### Ist-Zustand

`agentk` startet heute selbst Scan-Pods: Das Modul `starboard_vulnerability`
erzeugt pro Namespace einen `trivy-k8s-wrapper`-Pod, liest dessen Logs, parst
sie und meldet die Ergebnisse an GitLab. Der Preis dafür steht in
[03](03-rechte-und-rbac.md#13-ocs-clusterrole-im-detail): eine ClusterRole mit
`get`/`list` auf **`secrets` clusterweit**, plus Pod-Erzeugung im
Agent-Namespace.

### Zielbild

Der **Trivy Operator** läuft eigenständig, mit eigenem Lebenszyklus und eigenem
ServiceAccount, und schreibt seine Ergebnisse als CRs. Verifizierter CRD-Satz
(Gruppe `aquasecurity.github.io`, Stand `main`):

| CRD | Scope |
|---|---|
| `VulnerabilityReport` / `ClusterVulnerabilityReport` | Namespaced / Cluster |
| `ConfigAuditReport` / `ClusterConfigAuditReport` | Namespaced / Cluster |
| `ExposedSecretReport` | Namespaced |
| `RbacAssessmentReport` / `ClusterRbacAssessmentReport` | Namespaced / Cluster |
| `InfraAssessmentReport` / `ClusterInfraAssessmentReport` | Namespaced / Cluster |
| `SbomReport` / `ClusterSbomReport` | Namespaced / Cluster |
| `ClusterComplianceReport` | Cluster |

`VulnerabilityReport` trägt je Eintrag: `vulnerabilityID`, `severity`, `score`,
`title`, `resource`, `installedVersion`, `fixedVersion`, `primaryLink`,
`target` — plus `artifact`, `registry`, `scanner`, `summary`, `updateTimestamp`.
Das deckt sich weitgehend mit dem, was GitLab heute vom Agenten entgegennimmt.

### Wie kommen die Findings nach GitLab?

Hier liegt die eigentliche Schwierigkeit, und sie ist nicht offensichtlich.
Der heutige Meldeweg ist eine **interne** API:

```
PUT  /api/v4/internal/kubernetes/modules/starboard_vulnerability/            → legt Vulnerability an, liefert UUID
POST /api/v4/internal/kubernetes/modules/starboard_vulnerability/scan_result → löst UUIDs auf
```

Aufgerufen über den Tunnel, authentifiziert mit **Agent-Token und JWT**
(`internal/module/starboard_vulnerability/agentk/reporter.go:85,120`,
`internal/gitlab/api/module_request.go:13`). Das ist keine öffentliche
Schnittstelle und trägt keine Kompatibilitätszusage.

| Variante | Weg | Bewertung |
|---|---|---|
| **W1** | `starboard_vulnerability` forken: Scan-Pods raus, `VulnerabilityReport`-CRs rein, Meldeweg bleibt | **Empfohlen.** Findings landen unverändert in der Operational-Vulnerability-Ansicht. Rechte schrumpfen drastisch. Preis: Agent-Fork und eigener Image-Build. |
| **W2** | Eigener Container mit eigenem Agent-Token spricht die interne API direkt | Nicht empfohlen. Interne API ohne Vertrag, Tunnel und Auth wären nachzubauen. |
| **W3** | Geplante Pipeline liest CRs und lädt `gl-container-scanning-report.json` als CI-Artefakt hoch | Nur öffentliche Schnittstellen, kein Agent nötig. Aber: Findings erscheinen als Pipeline-Findings, nicht als operative Vulnerabilities — und der Cluster-Lesezugriff aus CI muss anders gelöst werden. |

### Was W1 an Rechten spart

| | Heute | Mit W1 |
|---|---|---|
| Scan-Pods erzeugen | `pods` create/get/delete + `pods/log` | — |
| Scan-SA | ClusterRole mit `secrets` get/list **clusterweit** | — |
| Neue Rechte | — | `get`/`list`/`watch` auf `aquasecurity.github.io` |
| Cluster-weiter Secret-Zugriff | **ja** | **nein** |

Der Wegfall des clusterweiten Secret-Lesezugriffs ist der stärkste einzelne
Sicherheitsgewinn dieser gesamten Strategie. Er entsteht dadurch, dass der
Scanner ein Operator mit eigenem SA wird, dessen Rechte der Bank gehören und
nicht dem GitLab-Chart.

## 6. Komponenten- und ServiceAccount-Schnitt

Umsetzung der Vorgabe „eigenständige Container, eigene ServiceAccounts":

| Komponente | Container | ServiceAccount | Rechte | Herkunft |
|---|---|---|---|---|
| **ArgoCD** | eigen | eigener | über `AppProject` begrenzt | Upstream-Chart |
| **Trivy Operator** | eigen | eigener | scannt, schreibt eigene CRs | Upstream-Chart |
| **vuln-bridge** | eigen | eigener | `get`/`list`/`watch` auf `aquasecurity.github.io` | Fork (W1) |
| **deploy-bridge** (nur V2) | eigen | eigener | CRUD nur auf `applications.argoproj.io` | Eigenbau |
| **notification** | Teil von Argo/Flux | eigener | keine Cluster-Schreibrechte | Upstream |
| **agentk** (reduziert) | eigen | eigener | read-only, oder entfällt | Chart, gehärtet |

Jede Zeile ist ein eigener Helm-Release mit eigenem RBAC. Fällt eine Komponente
aus oder wird ihr Token kompromittiert, ist der Schaden auf ihre Zeile begrenzt.

Die `vuln-bridge` ist dabei nach dem Muster aus
[05](05-zielbild-architektur.md#5-modell-b--multi-agent-split) ein **eigener
GitLab-Agent** mit eigenem Token — nicht ein zusätzliches Modul im bestehenden.
Das ist wichtig, weil die Leader-Lease `agent-<id>-lock` an der Agent-ID hängt:
Ein eigener Agent bekommt automatisch eine eigene Lease und kollidiert nicht.

## 7. Die Rolle von agentk im Zielbild — und ein ungelöster Konflikt

Wenn V1 und W1 stehen, bleibt für `agentk` fast nichts übrig. Naheliegend wäre,
ihn ganz zu entfernen. Genau hier liegt aber ein Zielkonflikt, der benannt
gehören:

> **W1 setzt einen Agenten voraus.** Der Meldeweg für operative Vulnerabilities
> läuft über den Tunnel und die interne Modul-API. Ohne Agent-Identität gibt es
> keinen Weg, Findings in die Operational-Vulnerability-Ansicht zu bekommen.

Daraus folgen genau zwei konsistente Endzustände:

**Endzustand A — „ein Agent, minimal".**
Ein einziger Agent bleibt, ausschließlich als `vuln-bridge`. Seine RBAC:
Lesezugriff auf `aquasecurity.github.io`, `leases` und `events` im eigenen
Namespace. Kein K8s-Proxy-Nutzen, weil kein `ci_access` und kein `user_access`
konfiguriert ist. GitLab-Integration bleibt vollständig.

**Endzustand B — „kein Agent".**
`agentk` entfällt komplett, Vulnerabilities kommen über W3 als CI-Artefakt.
Kein Tunnel aus dem Cluster heraus, kein Agent-Token, keine interne API. Preis:
Findings sind Pipeline-Findings statt operativer Vulnerabilities, und die
Cluster-Ansicht in der GitLab-UI entfällt.

Für ein Bankenumfeld ist **B die konsequentere Antwort** — kein dauerhafter
ausgehender Tunnel, keine Abhängigkeit von einer internen API. **A ist die
funktional vollständigere.** Diese Entscheidung sollte bewusst fallen und nicht
implizit durch die Reihenfolge der Umsetzung.

## 8. Was die Strategie an Rechten einspart

| Recht | Heute | Zielbild (Endzustand A) |
|---|---|---|
| `cluster-admin` für den Agenten | ✅ Default | ❌ |
| `secrets` get/list clusterweit (OCS) | ✅ Default | ❌ |
| `pods` create im Agent-Namespace | ✅ | ❌ |
| `impersonate` auf users/groups | bei CI-Impersonation | ❌ |
| CI-Jobs mit `admin` im Env-Namespace | ✅ Default-Template | ❌ |
| Beliebiges `kubectl apply` aus CI | ✅ | ❌ |
| Lesen von `aquasecurity.github.io` | ❌ | ✅ |
| `leases`/`events` im eigenen Namespace | ✅ | ✅ |

Von „darf alles" zu „darf Vulnerability-Reports lesen".

## 9. Umsetzungsstufen

| Stufe | Inhalt | Code | Reversibel |
|---|---|---|---|
| **1** | `AppProject`-Modell je Mandant definieren, Destinations und erlaubte Ressourcenarten festlegen | nein | ja |
| **2** | Deploy-Pfad auf V3 umstellen: ClusterRole nur auf `applications.argoproj.io`, `rbac.useExistingRole` setzen | nein | ja |
| **3** | P2 und P4 schließen: Environment-Templates abschaffen, `resource_management` und `remote_development` aus der Agent-Config nehmen | nein | ja |
| **4** | Status-Rückschreibung aufsetzen: Notifications → Commit-Status, Access-Token als Secret | nein | ja |
| **5** | Trivy Operator ausrollen, OCS im Chart abschalten (`operational_container_scanning.enabled: false`) | nein | ja |
| **6** | `vuln-bridge` bauen (W1-Fork) und als eigener Agent ausrollen | **ja** | ja |
| **7** | Entscheidung Endzustand A oder B, Restagent entfernen oder minimieren | nein | — |

Die Stufen 1 bis 5 brauchen **keine Zeile Code** und sind einzeln
zurückdrehbar. Erst Stufe 6 berührt die Fork-Frage — und selbst dann ist der
Eingriff auf ein Modul begrenzt.

Nach Stufe 5 ist bereits erreicht: kein `cluster-admin`, kein clusterweiter
Secret-Zugriff, kein freier `kubectl apply`, Deployment nur über ArgoCD. Das ist
der überwiegende Teil des Ziels.

## 10. Offene Entscheidungen

1. **Endzustand A oder B** (Abschnitt 7) — operative Vulnerabilities gegen
   „kein Tunnel". Die Entscheidung bestimmt, ob Stufe 6 überhaupt gebaut wird.
2. **ArgoCD oder Flux als führender Operator.** Vorgabe ist ArgoCD; die
   Flux-Argumente aus Abschnitt 4 sind stark genug, um sie einmal bewusst zu
   verwerfen statt sie zu übergehen.
3. **Review-Apps:** ApplicationSet PR Generator (V1) oder eigener Broker (V2).
   Erst wenn V1 an einer konkreten Anforderung scheitert, wird V2 sinnvoll.
4. **Fork-Strategie für Stufe 6** — additiv und upstream-fähig oder eigenständig.
   Diese Frage ist aus [05](05-zielbild-architektur.md#10-offene-entscheidung)
   noch offen und wird hier zum zweiten Mal relevant.

## 11. Verifizierte Grundlagen

Alles Folgende ist gegen Quelle geprüft, nicht aus Erinnerung geschrieben:

| Aussage | Quelle | Stand |
|---|---|---|
| `managed_resources` rendert Flux-CRs, keine ArgoCD-CRs | `internal/module/managed_resources/server/rest_mapper.go:26-135` | `5c79b354` |
| Default-Template bindet `ClusterRole: admin` an die CI-Gruppe | `…/server/default_template.yaml` | `5c79b354` |
| OCS meldet über interne Modul-API mit Agent-Token und JWT | `starboard_vulnerability/agentk/reporter.go:85,120`; `internal/gitlab/api/module_request.go:13` | `5c79b354` |
| Flux-Provider-Typen inkl. `gitlab` und `gitlabmergerequestcomment` | `notification.toolkit.fluxcd.io_providers.yaml` | `main`, 2026-08-10 |
| Trivy-Operator-CRDs, Gruppe `aquasecurity.github.io` | `deploy/helm/crds/` | `main`, 2026-08-10 |
| `VulnerabilityReport` ist Namespaced, Felder wie oben | `aquasecurity.github.io_vulnerabilityreports.yaml` | `main`, 2026-08-10 |
| ArgoCD `Application`, Gruppe `argoproj.io`, Namespaced | `manifests/crds/application-crd.yaml` | `master`, 2026-08-10 |

Nicht verifiziert und vor der Umsetzung zu prüfen: die genaue Konfiguration des
ApplicationSet PR Generators gegen GitLab, sowie das exakte Schema, das GitLab
beim internen Vulnerability-Endpunkt erwartet — Letzteres ergibt sich aus
`trivy-k8s-wrapper`s `report`-Paket und ist beim Bau von Stufe 6 gegen die
tatsächliche GitLab-Version zu prüfen.
