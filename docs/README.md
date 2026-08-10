# Analyse-Dokumentation (Fork)

Diese Dokumentation gehört zum Fork von
`gitlab.com/gitlab-org/charts/gitlab-agent` und beschreibt, **was das Helm-Chart
tatsächlich ausrollt**, **welche Schnittstellen zu GitLab dabei entstehen** und
**welche Rechte** dafür vergeben werden.

Sie ist bewusst getrennt vom generierten `README.md` (das aus `values.yaml` per
`helm-docs` erzeugt wird und bei jedem Upstream-Merge überschrieben wird).

## Inhalt

| Dokument | Inhalt |
|---|---|
| [01-deployment-inventar.md](01-deployment-inventar.md) | Welche Kubernetes-Objekte das Chart erzeugt, unter welchen Bedingungen, mit welchen Parametern |
| [02-gitlab-schnittstellen.md](02-gitlab-schnittstellen.md) | Alle Schnittstellen zwischen Cluster und GitLab: Netzwerkverbindungen, Ports, Protokolle, Authentifizierung, Egress-Anforderungen |
| [03-rechte-und-rbac.md](03-rechte-und-rbac.md) | Alle Rechte: Kubernetes-RBAC aus dem Chart, GitLab-seitige Tokens und Scopes, Impersonation-Modelle, Härtungsempfehlungen |
| [04-feature-matrix-abschaltbarkeit.md](04-feature-matrix-abschaltbarkeit.md) | Alle Features mit Schalter-Ort und Wirksamkeitsklasse: was sich wo abschalten lässt und wie man es verifiziert |
| [05-zielbild-architektur.md](05-zielbild-architektur.md) | Microservice-Frage, Bewertung dreier Isolationsmodelle, Zielbild der Situationsschicht, Stufenplan |
| [06-strategie-gitops-crd.md](06-strategie-gitops-crd.md) | Strategie für regulierte Umgebungen: Deployment nur über ArgoCD/Flux, Scanning über Trivy-Operator-CRDs, Status zurück an den Merge Request |

Die produktseitige Einordnung (welche Binaries und Module es überhaupt gibt, was
davon im Cluster läuft und was serverseitig) liegt im Fork des Agent-Repos:
`gitlab-agent/doc/fork/`.

## Analysestand

| Gegenstand | Stand |
|---|---|
| Chart-Version (`Chart.yaml: version`) | 2.29.0 |
| Ausgerollte App-Version (`Chart.yaml: appVersion`) | v19.2.1 |
| Upstream-Commit Chart | `fc5d8820` (`main`) |
| Upstream-Commit Agent-Repo | `5c79b354` (`master`, `VERSION` = 19.3.0-rc3) |
| Analysedatum | 2026-08-10 |

## Kurzfassung für Eilige

- Das Chart rollt **genau eine Anwendung** aus: `agentk`, den clusterseitigen
  Agenten. Der Serverteil (Relay/KAS) ist **nicht** Teil dieses Charts.
- Im Standardbetrieb baut `agentk` **eine einzige ausgehende Verbindung** nach
  GitLab auf (`wss://` auf Port 443). Es wird **kein eingehender Port** aus dem
  Internet benötigt.
- Alle GitLab-Funktionen (CI-Zugriff, User-Zugriff, GitOps/Flux, Container-Scanning,
  Workspaces) laufen **über diese eine Verbindung** — sie sind logische Kanäle,
  keine zusätzlichen Netzwerkverbindungen.
- **Die Standardkonfiguration gibt `agentk` `cluster-admin` im gesamten Cluster.**
  Das ist der mit Abstand wichtigste Befund dieser Analyse. Siehe
  [03-rechte-und-rbac.md](03-rechte-und-rbac.md).
- **Von 13 clusterrelevanten Feature-Flächen sind heute zwei im Cluster
  abschaltbar.** Alle übrigen Schalter liegen in GitLab, nicht im Chart. Siehe
  [04-feature-matrix-abschaltbarkeit.md](04-feature-matrix-abschaltbarkeit.md).
- **Die Isolationseinheit dieses Systems ist der Agent, nicht das Modul.**
  Mehrere Agenten mit je eigenem Token und RBAC sind der gangbare Weg zu echter
  Trennung — ohne Codeänderung. Siehe
  [05-zielbild-architektur.md](05-zielbild-architektur.md).
- **Für regulierte Umgebungen lassen sich alle vier Deploy-Pfade des Agenten
  schließen**, sodass nur noch ein GitOps-Operator Workloads erzeugt. Die ersten
  fünf von sieben Umsetzungsstufen brauchen keine Codeänderung. Siehe
  [06-strategie-gitops-crd.md](06-strategie-gitops-crd.md).
