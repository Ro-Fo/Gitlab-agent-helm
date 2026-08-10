# 05 – Zielbild: Microservices, Isolation und die Situationsschicht

Antwort auf die Frage, ob sich `agentk` in kleinere, einzeln deploybare Einheiten
zerlegen lässt — und wie die Vertrauensschicht aussehen sollte, in der Abschalten
im Helm-Chart eine Garantie statt einer Konvention ist.

Zielumgebung: **Self-Managed GitLab.**

## 1. Die Frage hinter der Frage

„Gibt es kleinere Microservices?" lässt sich nur beantworten, wenn man weiß,
**welche Einheit dieses System überhaupt isoliert.** Bei `agentk` ist das nicht
das Modul, sondern der **Agent**. Das ist keine Designschwäche, sondern eine
Entscheidung, die sich durch den gesamten Code zieht — und wer gegen sie
arbeitet, stößt an harte Grenzen. Die wichtigste davon finde ich in der Leader
Election, siehe Abschnitt 4.

Zwei Upstream-Festlegungen setzen den Rahmen:

- **„Smart kas, dumb agentk"** (`doc/architecture.md`): Logik gehört bewusst auf
  die Serverseite, damit Cluster-Agenten selten aktualisiert werden müssen.
  `agentk` soll klein bleiben — nicht, weil es unwichtig ist, sondern weil es
  beim Kunden läuft.
- **Mehrere Agenten pro Cluster sind ausdrücklich vorgesehen**
  (`doc/identity_and_auth.md`): *„A Kubernetes cluster may have 0 or more agents
  running in it. Each agent likely has a different configuration… Each agent is
  likely running using a ServiceAccount, a distinct Kubernetes identity, with a
  distinct set of permissions attached to it. These permissions enable the agent
  administrator to follow the principle of least privilege."*

Der zweite Punkt ist die Antwort auf deine Frage, ausgesprochen von den Autoren
selbst: **Die vorgesehene Zerlegungseinheit ist der Agent.**

## 2. Leader-Module vs. Pro-Pod-Module

Für jede Zerlegung muss man wissen, was pro Pod und was genau einmal läuft.
Maßgeblich ist `IsProducingLeaderModules()` je Factory:

| Modul | Läuft | Bedeutung |
|---|---|---|
| `remote_development` | **nur Leader** | agiert im Hintergrund auf dem Cluster |
| `flux` | **nur Leader** | Controller mit Informern |
| `starboard_vulnerability` (OCS) | **nur Leader** | startet Scan-Pods |
| `kubernetes_api` | jeder Pod | Proxy skaliert horizontal |
| `agent_configuration` | jeder Pod | jeder Pod braucht die Config |
| `agent_registrar` | jeder Pod | jeder Pod meldet sich einzeln |
| `gitlab_access` | jeder Pod | Infrastruktur |
| `observability` | jeder Pod | eigener Listener je Pod |
| `google_profiler` | jeder Pod | Prozess-lokal |
| Tunnel (`agent2kas`/`kas2agentk`) | jeder Pod | jeder Pod hält eigene Tunnel |

Das Muster ist sauber: **Alles, was aktiv auf dem Cluster arbeitet, ist ein
Leader-Modul. Alles, was Anfragen bedient, skaliert pro Pod.** Genau deshalb
funktionieren die zwei Replicas des Charts ohne Doppelarbeit.

> Randnotiz zur Korrektur: Die beiden `FactoriesLayer` in
> `internal/cmd/agentk/command.go` sind **Startreihenfolge**, nicht
> Leader-Trennung — die zweite Schicht enthält die Module, die die
> kas-Verbindung brauchen. Die Leader-Frage entscheidet allein
> `IsProducingLeaderModules()`.

## 3. Modell A — Per-Modul-Schalter im Monolithen

**Idee:** `agentk` bleibt ein Prozess, bekommt aber pro Modul einen Schalter nach
dem Muster, das OCS bereits nutzt. Das Chart exponiert sie als `features:`-Block
und leitet **zusätzlich die RBAC daraus ab**.

```go
// Das existierende Muster, angewendet auf weitere Module:
if !moduleEnabled(cfg, "flux") {
    cfg.Log.Info("Module is disabled")
    return nil, nil   // modagent/api.go:82 erlaubt das ausdrücklich
}
```

| | |
|---|---|
| **Erreicht** | K3 für alle Module, K4 zusammen mit der RBAC-Kopplung |
| **Aufwand** | ca. 30–50 Zeilen Go, additiv; Chart-Umbau der RBAC-Generierung |
| **Fork-Kosten** | eigener Image-Build, dauerhafte Merge-Pflege im Agent-Fork |
| **Grenze** | `kubernetes_api` registriert seinen Service in derselben Funktion, in der er ihn baut — hier braucht es eine echte kleine Umstellung, keinen reinen Guard |

Der große Vorteil: Es ist **upstream-fähig**. Ein MR, der dem OCS-Muster folgt
und den dokumentierten Factory-Vertrag nutzt, ist argumentierbar — insbesondere
mit dem Sicherheitsargument, dass Cluster-Betreiber heute keine Kontrolle über
die Angriffsfläche ihres eigenen Agenten haben.

## 4. Modell C — Modul-Split über getrennte Deployments

Ich behandle C vor B, weil das Ergebnis die Empfehlung erklärt.

**Idee:** Mehrere Deployments unter *einem* Agent-Token, jedes mit einer anderen
Modulauswahl und eigener RBAC. Ein „Proxy-Deployment" mit engen Rechten, ein
„Scan-Deployment" mit Leserechten, ein „Flux-Deployment" mit CRD-Rechten.

**Was dafür spricht — und es ist mehr, als ich erwartet hatte:** Das Routing
trägt es. `internal/module/agent2kas_tunnel/agent/factory.go:46` baut über
`tunclient.APIDescriptor(apiServer)` einen Deskriptor aus den tatsächlich
registrierten gRPC-Services und sendet ihn je Tunnelverbindung an Relay. Relay
routet danach. Ein Pod ohne `KubernetesApi` bekommt also keine Proxy-Requests —
ohne dass die Gegenstelle etwas konfigurieren müsste.

**Woran es scheitert:** die Leader Election.

```go
// internal/cmd/agentk/command.go:177-186
return fmt.Sprintf("agent-%d-lock", agentKey.ID), nil
```

Der Lease-Name leitet sich aus der **Agent-ID** ab, also aus dem Token — nicht
aus dem Deployment. Alle Pods aller Split-Deployments unter einem Token
konkurrieren damit um **dieselbe** Lease `agent-<id>-lock`. Es gewinnt genau
einer, clusterweit.

Und die drei Module, die man beim Split am ehesten trennen will — OCS, Flux,
Remote Development — sind **genau die drei Leader-Module**. Ein „Scan-Deployment"
und ein „Flux-Deployment" unter einem Token würden sich gegenseitig ausschalten:
Wer die Lease verliert, führt seine Leader-Module nie aus. Nicht mit einem
Fehler, sondern still.

| | |
|---|---|
| **Verdikt** | **Nicht empfohlen.** Am Routing tragfähig, an der Leader Election gebrochen. |
| **Was es bräuchte** | Lease-Namen um eine Deployment-Kennung erweitern — ein Eingriff in die Identitätslogik, deutlich tiefer als Modell A |
| **Zusätzliche Grenze** | Ein Token = ein Agent = **eine** GitLab-seitige Config. `ci_access` gilt für alle Split-Deployments gleich. Der Split kauft nur cluster-seitige RBAC-Trennung, keine GitLab-seitige. |

Der letzte Punkt ist der eigentliche Sargnagel: Selbst wenn man die Lease
repariert, bleibt E3 ungeteilt. Man hätte drei Deployments, die sich eine
Zugriffskonfiguration teilen.

## 5. Modell B — Multi-Agent-Split

**Idee:** Nicht das Modul ist die Einheit, sondern der Agent. Pro Aufgabe ein
eigener Agent in GitLab, ein eigener Token, ein eigener Helm-Release, ein eigener
ServiceAccount, ein eigener RBAC-Zuschnitt.

Und plötzlich fällt alles an seinen Platz:

| Grenze | Modell C | Modell B |
|---|---|---|
| Lease-Kollision | ❌ geteilte Lease | ✅ `agent-<eigene id>-lock` je Agent |
| GitLab-seitige Config | ❌ geteilt | ✅ eigenes `.gitlab/agents/<name>/config.yaml` |
| ServiceAccount / RBAC | ✅ trennbar | ✅ trennbar |
| Token-Kompromittierung | ❌ trifft alles | ✅ trifft einen Agenten |
| Codeänderung nötig | ✅ ja | **❌ nein** |
| Upstream-konform | ⚠️ gegen den Strich | ✅ ausdrücklich vorgesehen |

**Modell B ist die Microservice-Architektur, die dieses System bereits hat.** Sie
kostet keine Zeile Code und keine Fork-Divergenz.

### Referenzaufstellung für Self-Managed

| Agent | Zweck | Aktive Features | RBAC-Zuschnitt |
|---|---|---|---|
| `agent-deploy` | CI-Deployments | K8s-Proxy mit `ci_access` + Impersonation | nur Ziel-Namespaces, `impersonate` |
| `agent-gitops` | Flux-Integration | Flux | Flux-CRDs + Ziel-Namespaces |
| `agent-scan` | Container-Scanning | OCS | clusterweit lesend, `pods` im eigenen Namespace |
| `agent-workspaces` | Remote Development (optional) | Workspaces | Workspace-Namespaces |

Jeder als eigener Helm-Release, jeder mit `rbac.useExistingRole` auf eine eigene,
zugeschnittene ClusterRole und `config.operational_container_scanning.enabled`
nur bei `agent-scan`.

Der Gewinn ist konkret: Wird der Token von `agent-scan` kompromittiert, bekommt
der Angreifer clusterweite **Leserechte** — nicht `cluster-admin`. Heute bekommt
er bei jedem Token alles.

**Was es kostet, ehrlich benannt:**

- N Agent-Registrierungen und N Tokens zu verwalten und zu rotieren.
- N Konfigurationsverzeichnisse in GitLab.
- N Tunnel-Verbindungspools. Jeder Agent hält mindestens 2 Leerlaufverbindungen
  (`minIdleConnections = 2`, `agent2kas_tunnel/agent/factory.go`) — bei 4 Agenten
  mit je 2 Replicas also ≥ 16 offene Verbindungen zu Relay statt 4.
- N Helm-Releases in der Betriebsroutine.
- In der GitLab-UI erscheinen N Agenten statt einem.

Für einen mittleren Cluster ist das vertretbar. Für dreißig Teams mit je eigenem
Agenten wird die Token-Verwaltung zum eigenen Thema — dann führt an Automation
(External Secrets, Terraform-Provider) kein Weg vorbei.

## 6. Empfehlung

**Modell B sofort. Modell A als Ausbaustufe. Modell C nicht.**

Begründung in drei Sätzen: B liefert heute echte Isolation auf allen drei Ebenen,
ohne Code und ohne Fork-Schulden. A macht aus der Konvention „wir konfigurieren
das Feature nicht" die Garantie „das Modul ist nicht geladen und hat keine
Rechte" — der Schritt von K2 auf K4. C sieht nach der saubersten Zerlegung aus,
bricht aber an der Leader Election und teilt sich weiterhin eine GitLab-Config.

## 7. Die Situationsschicht

Was du am Ende haben willst: Für jedes Feature eine **belastbare, prüfbare
Aussage**, ob es an oder aus ist. Das entsteht aus drei Bausteinen.

### Baustein 1 — Verteidigung in der Tiefe über alle drei Ebenen

Bei Self-Managed besitzt du E1, E2 und E3. Ein Feature gilt erst dann als
belastbar abgeschaltet, wenn es auf der **niedrigsten verfügbaren Ebene** aus ist
und die darüberliegenden mitziehen:

| Feature | E1 Cluster | E2 Relay | E3 GitLab |
|---|---|---|---|
| Workspaces | (Modell A) | `workspaces.enabled: false` | `remote_development.enabled: false` |
| OCS | `operational_container_scanning.enabled: false` | — | `container_scanning` weglassen |
| Flux | Flux-CRDs / (Modell A) | — | `flux.enabled: false` |
| AutoFlow | — | Abschnitt weglassen | — |
| Events Platform | — | Abschnitt weglassen | — |
| K8s-Proxy | (Modell A) | Port 8154 nicht exponieren | `ci_access`/`user_access` leer |

Die letzte Zeile ist die wichtigste und die unbequemste: Der K8s-API-Proxy hat
**auf keiner Ebene einen Schalter**. Auf E2 bleibt nur, den Listener nicht
erreichbar zu machen — `pkg/kascfg/kascfg_defaults.yaml:16-24` startet ihn immer.

### Baustein 2 — Rechte an Schalter koppeln

Solange `cluster-admin` gebunden ist, ist jeder Feature-Schalter kosmetisch. Die
Zielform ist eine ClusterRole, die aus den aktivierten Features **generiert**
wird — die Rechtetabelle aus
[04, Abschnitt 6](04-feature-matrix-abschaltbarkeit.md#6-rechtebedarf-je-feature)
ist die Vorlage. Bemerkenswert daran: Der Agent-Kern braucht praktisch nichts —
`leases` und `events` im eigenen Namespace. Alle übrigen Rechte lassen sich einem
Feature zuordnen und damit einem Schalter.

### Baustein 3 — Verifikation statt Behauptung

Für jede Zeile der Matrix ein ausführbarer Nachweis:

| Prüfung | Womit |
|---|---|
| Rechte wirklich weg | `kubectl auth can-i … --as=system:serviceaccount:…` → `no` |
| Modul wirklich nicht geladen | Agent-Log auf `"Module is disabled"` |
| Relay kann nichts routen | gRPC-Service fehlt im Tunnel-Deskriptor |
| Objekte existieren nicht | gerenderte Manifeste diffen |
| E2/E3 konsistent | Config-Review, idealerweise in CI |

Erst mit Baustein 3 wird es eine Vertrauensschicht. Ohne ihn ist es eine Meinung
über den Zustand des Systems.

## 8. Vorgeschlagener Stufenplan

| Stufe | Inhalt | Code nötig | Fork-Divergenz |
|---|---|---|---|
| **1** ✅ | Feature-Matrix und Abschaltbarkeit ([04](04-feature-matrix-abschaltbarkeit.md)) | nein | keine |
| **2** ✅ | Zielbild und Modellbewertung (dieses Dokument) | nein | keine |
| **3** | Chart-Umbau: `features:`-Block, generierte RBAC statt `cluster-admin`, Multi-Agent-Profile | nein | nur Chart |
| **4** | Verifikationsschicht: Prüfskripte und Helm-Tests gegen die Matrix | nein | nur Chart |
| **5** | `agentk`-Patch: per-Modul-Schalter nach dem OCS-Muster | **ja** | Agent-Fork + eigener Image-Build |
| **6** | optional: Upstream-MR für Stufe 5 | ja | löst die Divergenz wieder auf |

Stufe 3 und 4 liefern den größten Teil des Nutzens **ohne** die Fork-Frage zu
berühren — Modell B lässt sich vollständig im Chart abbilden. Erst Stufe 5
erzwingt die Entscheidung, die du dir offengehalten hast.

## 9. Was ich nicht empfehle

- **`agentk` in echte Microservices zerschneiden.** Siehe Abschnitt 4. Der
  Aufwand liegt in der Identitäts- und Lease-Logik, nicht in den Modulen, und am
  Ende teilen sich die Teile weiterhin eine GitLab-Config.
- **Auf E3 allein vertrauen.** Die Agent-Config ist ein Git-Commit weit von
  „Feature ist wieder an" entfernt. Als alleinige Kontrolle ist sie zu dünn,
  selbst wenn dir das Repo gehört.
- **`cluster-admin` behalten und dafür Feature-Schalter bauen.** Das ergibt K3
  ohne K4 — eine Abschaltung, die keine Sicherheitsgrenze ist. Wenn nur eine
  Maßnahme umgesetzt wird, sollte es die RBAC sein, nicht der Schalter.

## 10. Offene Entscheidung

Stufe 5 setzt die Fork-Strategie voraus, die du dir bewusst offengehalten hast.
Die Entscheidungsgrundlage aus dieser Analyse:

- Der Patch wäre **additiv und upstream-idiomatisch** — er nutzt einen
  dokumentierten Vertrag (`modagent/api.go:82`) und ein existierendes Muster (OCS).
- Er kostet einen **eigenen Image-Build und -Lebenszyklus**. Das ist bei einem
  Agenten, der Cluster-Zugriff vermittelt, der eigentliche Aufwand: Du übernimmst
  die Verantwortung für Security-Patches im Bauzyklus.
- Er ist **nicht nötig für Modell B**. Wenn Stufe 3 und 4 stehen, kannst du in
  Ruhe entscheiden, ob der Rest den Bauzyklus wert ist.
