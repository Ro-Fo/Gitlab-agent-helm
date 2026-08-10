# 07 – Konflikte und die Backend-Zwischenschicht

Zwei Dinge: Erstens die Konflikte, die entstehen, wenn man
[06](06-strategie-gitops-crd.md) unter der Auflage umsetzt, **nur GitLab-Schnittstellen
zu verwenden, die es gibt und die der GitLab Agent heute bereits nutzt**.
Zweitens der Entwurf einer Zwischenschicht, die Flux und ArgoCD gleichwertig
trägt und für weitere Produkte offen ist.

## Teil 1 — Was die Auflage überhaupt zulässt

Bevor man Konflikte benennen kann, muss der erlaubte Schnittstellensatz feststehen.
Vollständig, aus dem Code erhoben:

### GitLab → Cluster

| Schnittstelle | Nutzung |
|---|---|
| `KubernetesApi.MakeRequest` | Kubernetes-API-Proxy für CI und User |
| `KubernetesApi.WatchGraph` / `WatchGraphWithRoots` | Cluster-Ansicht in der UI |
| `AgentConfiguration.GetConfiguration` | Konfigurations-Stream (Pull vom Agent) |

### Cluster → GitLab

| Schnittstelle | Nutzung |
|---|---|
| `AgentRegistrar.Register` / `Unregister` | Registrierung, Telemetrie |
| `GitLabFlux.ReconcileProjects` | Push-Events für Projekte (Stream) |
| `GitlabAccess.MakeRequest` | **die einzige generische Schreibrichtung** |

`GitlabAccess.MakeRequest` läuft auf
`/api/v4/internal/kubernetes/modules/<modulname>/<pfad>` und ist damit **an
Modulnamen gebunden, die die Rails-Seite kennt**. Tatsächlich genutzt werden
heute genau fünf Endpunkte:

| Modul | Pfad | Methode | Zweck |
|---|---|---|---|
| `starboard_vulnerability` | `/` | PUT | Vulnerability anlegen, liefert UUID |
| `starboard_vulnerability` | `/scan_result` | POST | UUIDs auflösen |
| `starboard_vulnerability` | `/policies_configuration` | GET | Scan-Execution-Policies holen |
| `remote_development` | `/reconcile` | POST | Workspace-Abgleich |
| `remote_development` | `/prerequisites` | GET | Voraussetzungen |

**Das ist der komplette Werkzeugkasten.** Alles, was in der Strategie darüber
hinausgeht, ist eine neue Schnittstelle — und damit ausgeschlossen.

## Teil 2 — Die Konflikte

### K1 — Für die MR-Rückschreibung gibt es keine Agent-Schnittstelle

**Beleg.** In [06](06-strategie-gitops-crd.md#4-baustein-2--status-zurück-an-den-merge-request)
habe ich Flux' `Provider`-Typen `gitlab` / `gitlabmergerequestcomment` und Argo CD
Notifications vorgeschlagen. Beide schreiben auf die **öffentliche** API
(`POST /api/v4/projects/:id/statuses/:sha`). Der Agent nutzt diese API nicht.
Zusätzlich bräuchte es ein eigenes GitLab-Token als Secret im Cluster — eine
zweite Vertrauensbeziehung neben dem Agent-Token.

**Auswirkung.** Der gesamte Baustein 2 aus Dokument 06 fällt unter deiner Auflage
weg. Keiner der fünf verfügbaren Endpunkte ist ein Statuskanal.

**Auflösung — Richtung umdrehen.** Nicht der Cluster meldet an GitLab, sondern
**der CI-Job liest den Cluster**. Der Job, der das Deployment auslöst, pollt den
Status der `Application` bzw. `Kustomization` über
`KubernetesApi.MakeRequest` — eine Schnittstelle, die existiert und genutzt wird —
und **sein eigener Erfolg oder Misserfolg ist der MR-Status.** Nativ, ohne
Webhook, ohne Zusatztoken, ohne neue Schnittstelle.

```yaml
deploy:
  environment: { name: review/$CI_COMMIT_REF_SLUG }
  script:
    - kubectl apply -f application.yaml            # optional, je nach Variante
    - |
      kubectl wait --for=jsonpath='{.status.sync.status}'=Synced \
        application/$APP -n argocd --timeout=10m
    - |
      kubectl wait --for=jsonpath='{.status.health.status}'=Healthy \
        application/$APP -n argocd --timeout=10m
```

**Preis, ehrlich benannt.** Der Job wartet und verbraucht Compute-Minuten. Und
der K8s-API-Proxy muss bestehen bleiben — siehe K6.

### K2 — Ein neuer Modulname bekommt keine Route

**Beleg.** `internal/gitlab/api/module_request.go:13` setzt den Pfad aus
`ModuleRequestAPIPath + url.PathEscape(moduleName)` zusammen. Rails routet nur
bekannte Modulnamen.

**Auswirkung.** Ein eigenes Modul `trivy_bridge` oder `deploy_bridge` bekäme
404. Die naheliegende Bauform „neues Modul für neue Funktion" ist versperrt.

**Auflösung.** Die Vulnerability-Bridge muss den Modulnamen
`starboard_vulnerability` und dessen Payload-Schema **unverändert** behalten.
Als Entwurfsregel für den gesamten Fork:

> **Die Quelle der Daten darf getauscht werden, die Senke niemals.**

### K3 — Eigene Felder in der Agent-Config brechen die gesamte Konfiguration

**Beleg.** `internal/module/agent_configuration/server/server.go:208` ruft
`prototool.ParseYAMLToProto` auf, das intern `protojson.Unmarshal`
**ohne `DiscardUnknown`** nutzt (`internal/tool/prototool/converters.go:24`).
Unbekannte Felder erzeugen damit einen Fehler.

**Auswirkung.** Das ist schärfer, als es zunächst klingt: Ein `argocd:`- oder
`plugins:`-Block in `.gitlab/agents/<name>/config.yaml` führt nicht dazu, dass
das Feld ignoriert wird — **die komplette Konfiguration schlägt fehl und der
Agent bekommt gar keine.** Eine Konfigurationsebene in GitLab für die
Zwischenschicht ist ohne kas-Fork ausgeschlossen.

**Auflösung.** Die Konfiguration der Zwischenschicht lebt **im Helm-Chart**.
Das ist kein Zugeständnis, sondern deckt sich mit dem Ergebnis aus
[04](04-feature-matrix-abschaltbarkeit.md#1-die-drei-schalterebenen): Der
Schalter gehört auf Ebene E1, wo der Cluster-Betreiber ihn durchsetzt.

### K4 — Push-Benachrichtigung gibt es nur für Flux — dem Namen nach

**Beleg.** `GitLabFlux.ReconcileProjects` ist der einzige Kanal, über den GitLab
dem Cluster mitteilt, dass in einem Projekt gepusht wurde.

**Und hier liegt die gute Nachricht.** Die Nutzlast ist **nicht** Flux-spezifisch
(`internal/module/flux/rpc/rpc.proto`):

```protobuf
message Project {
  // The project `id` here must be a GitLab full project path, e.g. `gitlab-org/gitlab`.
  string id = 1;
}
```

Der Agent schickt eine Liste von Projektpfaden und bekommt gestreamt zurück, in
welchem gepusht wurde. **Flux steckt nur im Modul- und Servicenamen, nicht in den
Daten.** Damit ist dieser Kanal die tragfähige Grundlage für einen
operator-unabhängigen Push-Mechanismus — und genau der Punkt, an dem die
Zwischenschicht ihren Wert hat.

**Restkonflikt.** Ohne Zwischenschicht bekommt ArgoCD keine Push-Events und ist
auf sein eigenes Polling angewiesen (Standard: drei Minuten). Das ist kein
Fehler, aber ein spürbarer Unterschied in der Reaktionszeit, den man kennen muss.

### K5 — `managed_resources` kann keine ArgoCD-Ressourcen rendern

**Beleg.** `internal/module/managed_resources/server/rest_mapper.go:26-135`
ist eine feste Allowlist: Namespace, ServiceAccount, RoleBinding und zehn
Flux-Arten. Kein `argoproj.io`.

**Auswirkung.** Feature-Parität über Environment-Templates ist für ArgoCD nicht
herstellbar, und da der Mapper serverseitig in kas liegt, auch nicht ohne
kas-Fork nachrüstbar.

**Auflösung.** Nicht darauf aufbauen. Die Zielarchitektur schließt den
Environment-Template-Pfad ohnehin (P2 aus Dokument 06). Parität entsteht dadurch,
dass **beide** Backends ohne `managed_resources` auskommen.

### K6 — Der K8s-API-Proxy muss bleiben

**Beleg.** Die Auflösung von K1 setzt voraus, dass der CI-Job den CR-Status liest
— über den Proxy.

**Auswirkung.** Das revidiert die Stoßrichtung aus
[04](04-feature-matrix-abschaltbarkeit.md) und
[06](06-strategie-gitops-crd.md), wo der Proxy als zu schließender Pfad geführt
wird. **Man kann nicht beides haben:** den Proxy schließen *und* ihn als
Statuskanal nutzen.

**Auflösung.** Der Proxy bleibt, aber die ClusterRole des Agenten erlaubt nur
noch, was für Status und Deployment nötig ist:

```yaml
rules:
  - apiGroups: ["argoproj.io"]
    resources: ["applications"]
    verbs: ["get", "list", "watch"]          # + create/patch nur bei Variante V3
  - apiGroups: ["kustomize.toolkit.fluxcd.io", "source.toolkit.fluxcd.io"]
    resources: ["kustomizations", "gitrepositories"]
    verbs: ["get", "list", "watch"]
```

Der Proxy existiert dann zwar (Klasse K0 — nicht abschaltbar), kann aber
strukturell nur Deployment-Zustand lesen. Das ist eine im Cluster durchgesetzte
Grenze, also Klasse **K4**. Der Unterschied zwischen „Proxy weg" und „Proxy kann
nur lesen" ist sicherheitstechnisch gering, betrieblich aber erheblich.

### K7 — OCS und Trivy Operator schließen sich aus

**Beleg.** Beide erzeugen Findings für dieselbe GitLab-Ansicht.

**Auswirkung.** Laufen beide, entstehen doppelte Vulnerabilities und doppelte
Scan-Last. Schlimmer: Die Auflösungslogik (`/scan_result` löst UUIDs auf, die
nicht mehr gefunden werden) würde sich gegenseitig Findings wegräumen.

**Auflösung.** Im Chart als sich ausschließende Auswahl modellieren, nicht als
zwei unabhängige Schalter. Die Zwischenschicht macht daraus eine
Backend-Auswahl mit genau einem aktiven Wert.

### K8 — GitLab-Scan-Policies steuern den Trivy Operator nicht

**Beleg.** `starboard_vulnerability/agentk/security_policies_worker.go:86` holt
über `/policies_configuration` die Scan-Execution-Policies aus GitLab; sie
bestimmen heute Namespaces, Cadence und Filter des Scannings.

**Auswirkung.** Übernimmt der Trivy Operator das Scannen, hat er seine **eigene**
Konfiguration. Die in GitLab gepflegten Policies wirken dann nicht mehr — ohne
dass es jemandem auffällt. Für ein Bankenumfeld ist genau das gefährlich: Die
Governance-Oberfläche zeigt weiterhin Policies an, die niemand mehr durchsetzt.

**Auflösung, drei Möglichkeiten.** (a) Policies weiter abrufen und auf die
Konfiguration des Trivy Operators abbilden — aufwendig und dauerhaft
abgleichpflichtig. (b) Policies bewusst aufgeben und die Scan-Governance in den
Cluster verlagern, dann aber in GitLab sichtbar dokumentieren. (c) Als
Zwischenlösung die abgerufenen Policies nur noch **prüfen** und bei Abweichung
zur Operator-Konfiguration ein Finding oder eine Warnung erzeugen.
Meine Empfehlung ist (b) mit dem Zusatz aus (c).

### K9 — Der Payload-Schemavertrag ist einseitig

**Beleg.** Die Nutzlast ist `report.Vulnerability` aus
`gitlab-org/security-products/analyzers/trivy-k8s-wrapper`. Der Endpunkt ist
intern und trägt keine Kompatibilitätszusage.

**Auswirkung.** Ändert GitLab das Schema, bricht die Bridge — und zwar bei einem
GitLab-Upgrade, nicht bei einem eigenen Deployment. Das ist die dauerhafte
Wartungslast des gesamten Ansatzes.

**Auflösung.** Die Konvertierung von `VulnerabilityReport` auf `report.Vulnerability`
in eine eigene, testbare Schicht mit Golden-File-Tests legen und die
`trivy-k8s-wrapper`-Version pinnen. Damit wird ein Bruch beim Bauen sichtbar
statt im Betrieb.

## Teil 3 — Die Backend-Zwischenschicht

### Idee

Zwei Erweiterungspunkte mit je einem stabilen internen Vertrag. Was darüber
liegt — die GitLab-Schnittstellen — bleibt unangetastet. Was darunter liegt, ist
austauschbar.

```
   GitLab (unveränderte Schnittstellen)
   ReconcileProjects · GitlabAccess · KubernetesApi
                    │
        ┌───────────┴────────────┐
        │   Zwischenschicht      │   Vertrag, Auswahl über Helm-Werte
        └───────────┬────────────┘
          ┌─────────┴──────────┐
   SyncBackend            FindingsSource
   ├── flux               ├── in-cluster-scan   (heute)
   ├── argocd             ├── trivy-operator
   └── noop               └── noop
```

### Erweiterungspunkt 1 — `SyncBackend`

Verantwortlich dafür, GitLab-Push-Events in Reconciliation des jeweiligen
Operators zu übersetzen und dessen Zustand zu melden.

```go
type SyncBackend interface {
    // Name des Backends, für Logging und Chart-Auswahl.
    Name() string

    // Welche GitLab-Projekte sind im Cluster referenziert?
    // Ergebnis speist ReconcileProjectsRequest.
    DiscoverProjects(ctx context.Context) ([]string, error)

    // Ein Push in diesem Projekt ist passiert. Reconciliation auslösen.
    Reconcile(ctx context.Context, projectFullPath string) error

    // Welche RBAC-Regeln braucht dieses Backend?
    // Wird vom Chart zur Erzeugung der ClusterRole ausgewertet.
    RequiredRules() []rbacv1.PolicyRule
}
```

`DiscoverProjects` und `Reconcile` sind exakt die beiden Operationen, die das
heutige Flux-Modul bereits ausführt — es implementiert diesen Vertrag faktisch
schon, nur ohne ihn zu benennen. Der Umbau ist damit ein Extrahieren, kein
Neuschreiben.

#### Backend `flux` (aus dem Bestand)

| | |
|---|---|
| Entdeckung | `GitRepository`-Objekte, gefiltert auf die GitLab-Instanz |
| Auslösung | HTTP-POST auf `Receiver.Status.WebhookPath` mit dem Receiver-Token (`flux/agentk/client.go:242,259`) |
| Setup-Schreibrechte | `Receiver` und zugehörige `Secret`s anlegen/aktualisieren |
| Schreibrecht im Betrieb | **keines** — die Auslösung ist ein HTTP-Aufruf, kein API-Write |

#### Backend `argocd` (neu)

| | |
|---|---|
| Entdeckung | `Application.spec.source.repoURL`, gefiltert auf die GitLab-Instanz, in Projektpfade übersetzt |
| Auslösung | Refresh-Annotation auf der `Application` setzen (`normal` oder `hard`) |
| Setup-Schreibrechte | keine |
| Schreibrecht im Betrieb | `patch` auf `applications.argoproj.io` |

Verifiziert ist, dass ArgoCD einen annotationsgesteuerten Refresh kennt:
`RefreshType` mit den Werten `normal` und `hard`
(`pkg/apis/application/v1alpha1/types.go:544`), gesetzt über
`AnnotationKeyRefresh` (`util/argo/argo.go:246`). **Den exakten Schlüsselnamen
habe ich nicht abschließend verifizieren können** — er ist bei der Umsetzung
gegen die eingesetzte Argo-Version zu prüfen.

Die Asymmetrie ist der eigentliche Grund für den Vertrag: **Die beiden Backends
brauchen unterschiedliche Rechte, und zwar zu unterschiedlichen Zeitpunkten.**
Deshalb gehört `RequiredRules()` in die Schnittstelle — das Chart generiert die
ClusterRole aus dem gewählten Backend und nur aus diesem.

### Erweiterungspunkt 2 — `FindingsSource`

```go
type FindingsSource interface {
    Name() string

    // Liefert Findings, sobald sie vorliegen. Der Aufrufer meldet sie
    // unverändert über die bestehende starboard_vulnerability-Senke.
    Run(ctx context.Context, out chan<- []*Payload) error

    RequiredRules() []rbacv1.PolicyRule
}
```

| Implementierung | Quelle | Rechte |
|---|---|---|
| `in-cluster-scan` | eigene Trivy-Pods (heutiges Verhalten) | `pods` create/get/delete, `pods/log`; Scan-SA mit clusterweitem `secrets`-Lesen |
| `trivy-operator` | Informer auf `VulnerabilityReport` | `get`/`list`/`watch` auf `aquasecurity.github.io` |
| `noop` | — | keine |

Die Senke bleibt in allen Fällen `PUT /` und `POST /scan_result` unter dem
Modulnamen `starboard_vulnerability` — das ist die Auflösung von K2, in den
Vertrag eingebaut.

### Wo die Auswahl konfiguriert wird

Wegen K3 zwingend im Chart, nicht in GitLab:

```yaml
backends:
  sync:
    kind: argocd          # flux | argocd | noop
    argocd:
      namespace: argocd
      refreshType: normal
  findings:
    kind: trivy-operator  # in-cluster-scan | trivy-operator | noop
    trivyOperator:
      namespaces: []      # leer = alle
```

Das Chart leitet daraus dreierlei ab: die Environment-Variablen für die
Backend-Auswahl, die **generierte ClusterRole** aus `RequiredRules()` des
gewählten Backends, und die Deaktivierung sich ausschließender Pfade — was K7
strukturell löst, statt es zu dokumentieren.

### Deployment-Topologie

Deine Vorgabe „eigenständige Container, eigene ServiceAccounts" führt zu einem
Agenten je Erweiterungspunkt, nach Modell B aus
[05](05-zielbild-architektur.md#5-modell-b--multi-agent-split):

| Release | Backend | Eigener SA | Rechte |
|---|---|---|---|
| `agent-sync` | `SyncBackend` aktiv, `FindingsSource: noop` | ✅ | nur `RequiredRules()` des Sync-Backends |
| `agent-findings` | `FindingsSource` aktiv, `SyncBackend: noop` | ✅ | nur Lesen auf `aquasecurity.github.io` |

Getrennte Agenten heißen getrennte Tokens und damit getrennte Agent-IDs — und
damit **getrennte Leader-Leases** (`agent-<id>-lock`). Genau die Kollision, an
der ein Modul-Split unter einem Token scheitert
([05, Abschnitt 4](05-zielbild-architektur.md#4-modell-c--modul-split-über-getrennte-deployments)),
tritt hier nicht auf. Die Zwischenschicht und das Multi-Agent-Modell passen
zusammen, das ist kein Zufall: Beide folgen derselben Erkenntnis, dass der Agent
die Isolationseinheit ist.

### Wie ein drittes Produkt andockt

Kurzfristig: eine weitere Implementierung des Vertrags im Fork, plus ein
`kind:`-Wert im Chart. Der Aufwand liegt bei zwei Methoden und einer
RBAC-Liste — für einen Operator mit vergleichbarem Modell überschaubar.

Langfristig ließe sich derselbe Vertrag **out-of-process** anbieten: Das Backend
läuft als eigener Container und spricht ein schmales gRPC-Interface, sodass
Dritte nichts kompilieren müssen. Ehrlich zu den Kosten: Das ist ein eigenes
Produkt mit Versionierung, Kompatibilitätszusagen und einer weiteren
Vertrauensgrenze im Cluster. Ich würde es erst bauen, wenn es einen konkreten
dritten Interessenten gibt — vorher ist die In-Process-Variante die
angemessene Größe.

## Teil 4 — Was damit an Dokument 06 revidiert wird

| Aussage in 06 | Status |
|---|---|
| Status-Rückschreibung über Flux-`Provider` bzw. Argo Notifications | **Zurückgezogen.** Verstößt gegen die Auflage (K1). Ersetzt durch den CI-Job als Statusträger. |
| „V1 reiner Pull" als Zielbild | **Revidiert.** Der CI-Job braucht Lesezugriff über den Proxy; damit wird **V3 mit enger RBAC** das Zielbild, nicht V1. |
| Alle vier Deploy-Pfade schließen | **Präzisiert.** P1 wird nicht geschlossen, sondern auf Lesen und auf die CR-Arten des Backends verengt. P2, P3, P4 bleiben zu schließen. |
| Endzustand B („kein Agent") | **Eingeschränkt.** Ohne Agent gibt es weder Push-Events noch den Vulnerability-Meldeweg. Unter deiner Auflage ist **Endzustand A** der einzig konsistente. |
| Flux-Vorteil bei der Rückschreibung | **Entfällt.** Der Vorteil bestand gerade in der öffentlichen API. Unter der Auflage sind beide Operatoren gleichgestellt — was deinem Ziel entgegenkommt. |

Der letzte Punkt ist bemerkenswert: **Deine Auflage beseitigt den stärksten
Grund, Flux gegenüber ArgoCD zu bevorzugen.** Übrig bleibt als Flux-Vorteil nur
noch `managed_resources` (K5) — ein Pfad, den die Zielarchitektur ohnehin nicht
nutzt. Damit sind die beiden Operatoren unter dieser Auflage tatsächlich
gleichwertig, und die Zwischenschicht ist nicht nur möglich, sondern die
natürliche Bauform.

## Teil 5 — Offene Punkte

1. **Exakter Annotationsschlüssel für den ArgoCD-Refresh** — Mechanismus
   verifiziert, Schlüsselname bei der Umsetzung gegen die eingesetzte Version
   prüfen.
2. **Verhalten des Refresh bei `ApplicationSet`-erzeugten Applications** — ob
   die Annotation dort dieselbe Wirkung hat oder der ApplicationSet-Controller
   sie überschreibt.
3. **Entscheidung zu K8** — GitLab-Scan-Policies abbilden, aufgeben oder nur
   noch prüfen. Das ist eine Governance-, keine Technikfrage.
4. **Wartezeit-Budget für den CI-Job** aus der K1-Auflösung — bestimmt, ob
   `kubectl wait` genügt oder ein schlankerer Poller nötig ist.
5. **Fork-Strategie** — weiterhin offen, jetzt zum dritten Mal relevant. Die
   Zwischenschicht ist additiv umsetzbar: neue Pakete, ein extrahierter Vertrag,
   keine geänderte Semantik bestehender Module.

## Teil 6 — Verifizierte Grundlagen

| Aussage | Quelle |
|---|---|
| Modulanfragen sind an rails-bekannte Modulnamen gebunden | `internal/gitlab/api/module_request.go:13` |
| Genutzte Modul-Endpunkte (fünf, siehe Teil 1) | `starboard_vulnerability/agentk/{reporter.go:85,120, security_policies_worker.go:86}`, `remote_development/agentk/{reconciler.go:373, module.go:91}` |
| Agent-Config lehnt unbekannte Felder ab | `agent_configuration/server/server.go:208` → `tool/prototool/converters.go:24` |
| Push-Event-Nutzlast ist operator-unabhängig | `internal/module/flux/rpc/rpc.proto` |
| Flux-Auslösung per Receiver-Webhook, kein API-Write | `internal/module/flux/agentk/client.go:242,259` |
| `managed_resources` ohne ArgoCD-Arten | `managed_resources/server/rest_mapper.go:26-135` |
| ArgoCD-Refresh über Annotation, Werte `normal`/`hard` | `argo-cd:pkg/apis/application/v1alpha1/types.go:544`, `util/argo/argo.go:246` |
