# 08 – Variante: der schreibfreie Agent

Verschärfung der Vorgabe: **Der GitLab Agent erzeugt keine Custom Resources.**
Dieses Dokument prüft, was das trifft, ob es Deal-Breaker gibt, und wie die
Architektur darunter aussieht. Es revidiert Teile von
[07](07-konflikte-und-backend-schicht.md).

**Ergebnis vorweg:** Die Vorgabe ist erfüllbar, und die Architektur wird dadurch
**einfacher**, nicht komplizierter. Es gibt genau einen echten Deal-Breaker, und
der betrifft nicht ArgoCD.

## 1. Wen die Vorgabe trifft

Sie trifft mehr als den ArgoCD-Entwurf — auch den Bestand:

| Komponente | Schreibt heute | Betroffen |
|---|---|---|
| `flux`-Modul | legt `Receiver` und dessen `Secret` an (`gitrepository_controller.go:417,429`) | ✅ ja |
| `argocd`-Backend (Entwurf aus 07) | `patch` der Refresh-Annotation auf `Application` | ✅ ja |
| `remote_development` | `Apply(ConfigToApply)`, Namespaces, Secrets | ✅ ja |
| `managed_resources` | Namespace, ServiceAccount, RoleBinding, Flux-CRs | ✅ ja |
| `starboard_vulnerability` | erzeugt Pods (keine CRs) | teilweise |

Das heutige Flux-Modul verstößt also selbst gegen die Vorgabe. Das ist kein
Argument gegen die Vorgabe — im Gegenteil: Dass der Agent `Receiver`-Objekte
außerhalb von Git anlegt, ist genau die Art von Out-of-Band-Mutation, die GitOps
eigentlich abschaffen soll. **Die Vorgabe ist GitOps-konsequenter als der
Ist-Zustand.**

## 2. Der Fund, der alles auflöst

Beide Operatoren lassen sich **ohne jeden Schreibzugriff** zum Reconcile
bewegen — über einen HTTP-Aufruf im Cluster:

| Operator | Trigger | Schreibzugriff |
|---|---|---|
| **Flux** | POST auf `Receiver.Status.WebhookPath` mit dem Receiver-Token | **keiner** |
| **ArgoCD** | POST auf `/api/webhook` am argocd-server, GitLab-Push-Payload | **keiner** |

Für ArgoCD verifiziert: `server/server.go:1274` registriert
`mux.HandleFunc("/api/webhook", …)`, und `util/webhook/webhook.go` parst
**GitLab-Push-Events nativ** (`gitlab.PushEventPayload`, Zeile 270), abgesichert
über ein konfigurierbares Shared Secret (`GetWebhookGitLabSecret`, Zeile 116).

Damit ist die Symmetrie hergestellt, die der Backend-Vertrag aus 07 gebraucht
hat: **Beide Backends triggern per HTTP-Webhook, keines braucht dafür
CR-Schreibrechte.** Die Refresh-Annotation aus dem 07er-Entwurf ist damit
hinfällig — sie war der schlechtere von zwei Wegen.

Was für Flux bleibt: Die `Receiver`- und `Secret`-Objekte müssen weiterhin
existieren, nur legt sie nicht mehr der Agent an, sondern **sie werden im Git
deklariert und von Flux selbst ausgerollt**. Der Agent liest sie nur noch, um
den Webhook-Pfad und das Token zu finden.

## 3. Der schreibfreie Agent

Was übrig bleibt, ist erstaunlich wenig — und genau das ist der Punkt:

| Aufgabe | Zugriff | Schreibt? |
|---|---|---|
| Projekte entdecken, für die Push-Events abonniert werden | `get`/`list`/`watch` auf `GitRepository` bzw. `Application` | nein |
| Reconcile auslösen | HTTP-POST auf den Webhook des Operators | nein |
| Vulnerabilities melden | `get`/`list`/`watch` auf `aquasecurity.github.io` → GitLab-Senke | nein |
| CI-Job liest Deployment-Status | über den bestehenden Proxy, read-only | nein |
| Cluster-Ansicht in der GitLab-UI | `WatchGraph`, read-only | nein |

**Die vollständige ClusterRole des Agenten:**

```yaml
rules:
  - apiGroups: ["source.toolkit.fluxcd.io", "notification.toolkit.fluxcd.io"]
    resources: ["gitrepositories", "receivers"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["argoproj.io"]
    resources: ["applications"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["aquasecurity.github.io"]
    resources: ["vulnerabilityreports", "clustervulnerabilityreports"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: []          # nur die Receiver-Token-Secrets, namentlich
    verbs: ["get"]
  - apiGroups: ["coordination.k8s.io"]
    resources: ["leases"]
    verbs: ["get", "create", "update"]     # eigener Namespace, Leader Election
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["create", "patch"]             # eigener Namespace
```

Von `cluster-admin` auf **Lesen plus zwei Verwaltungsrechte im eigenen
Namespace**. Kein `create`, kein `apply`, kein `patch` auf irgendeiner
Cluster-Ressource außerhalb der eigenen Verwaltung.

Bemerkenswert: Damit ist der Agent auch **kein plausibles Angriffsziel für
laterale Bewegung** mehr. Wer ihn übernimmt, kann lesen und Reconciles
auslösen — er kann nichts deployen.

## 4. Deal-Breaker: einer, und er betrifft nicht ArgoCD

Du hast direkt danach gefragt, deshalb ohne Weichzeichner:

### Echter Deal-Breaker: Workspaces

`remote_development` funktioniert ausschließlich dadurch, dass es
**beliebige, von GitLab berechnete Manifeste anwendet**
(`reconciler.go:213,481`). Es gibt keine schreibfreie Variante davon und kein
Cluster-Produkt, das GitLab an dieser Stelle kennt. Entweder das Modul darf
schreiben, oder es gibt keine Workspaces.

**Das ist eine Entweder-Oder-Entscheidung, kein Kompromiss.** Wenn Workspaces
gebraucht werden, gehören sie als ausdrücklich dokumentierte Ausnahme in einen
**eigenen Agenten mit eigenem ServiceAccount**, dessen Schreibrechte auf die
Workspace-Namespaces begrenzt sind — nicht in den schreibfreien Agenten.

### Kein Deal-Breaker: ArgoCD-Integration

Deine Sorge war, dass ArgoCD „zu hart" integriert wird. Nach dem Fund aus
Abschnitt 2 ist die Integration:

- **Lesen** von `Application.spec.source.repoURL`, um zu wissen, welche
  GitLab-Projekte relevant sind
- **Ein HTTP-POST** auf `/api/webhook`

Das ist keine harte Integration, das ist ein Adapter von rund hundert Zeilen.
ArgoCD bleibt unangetastet und weiß nichts vom Agenten.

### Kein Deal-Breaker: Statusrückmeldung

Hier ist die Antwort auf deine Frage besser als die Frage: **Der Status-Teil
braucht überhaupt keine Integration im Agenten.**

Nach [07, K1](07-konflikte-und-backend-schicht.md#k1--für-die-mr-rückschreibung-gibt-es-keine-agent-schnittstelle)
gibt es keine GitLab-Schnittstelle, über die der Cluster einen MR-Status
schreiben könnte — die Lösung war, die Richtung umzudrehen: Der CI-Job liest
den Zustand über den bestehenden Proxy, und **sein eigener Ausgang ist der
MR-Status**. Dafür ist kein Modul, kein Backend und keine Zeile Code nötig, nur
ein `kubectl wait` und Leserechte.

Du musst also nicht zwischen „harte Integration" und „nur Status" wählen. Der
Status ist ohnehin kostenlos; die Trigger-Integration ist optional.

### Abstufung, falls auch der Webhook zu viel ist

| Stufe | Trigger | Agent-Aufwand | Reaktionszeit |
|---|---|---|---|
| **0** | keiner — Operator pollt Git selbst | **null** | ArgoCD-Standard ca. 3 Minuten |
| **1** | Agent ruft den Operator-Webhook | ein Adapter, read-only | sofort |

Stufe 0 ist ein legitimes Ziel. Wenn drei Minuten Latenz akzeptabel sind,
braucht der Agent für Deployments **gar nichts** — nur noch für Vulnerabilities
und die Cluster-Ansicht.

## 5. Reversibilität als Entwurfsregel

Dein zweiter Punkt — „ich würde das gerne wieder zurückbringen können" — ist
kein Nachgedanke, sondern eine Anforderung an den Entwurf. Sie ist erfüllbar,
wenn zwei Regeln gelten:

> **Regel 1: Jede Änderung ist ein Schalter, kein Umbau.**
> Der Fork muss das Upstream-Verhalten als *wählbaren Zustand* behalten. Jedes
> Backend hat eine Implementierung, die genau das tut, was Upstream tut —
> `FindingsSource: in-cluster-scan` ist das heutige OCS, `SyncBackend: flux` mit
> Receiver-Verwaltung ist das heutige Flux-Modul. Zurückgehen heißt dann:
> Wert ändern, `helm upgrade`.

> **Regel 2: Die GitLab-Senke wird nie verändert.**
> Modulnamen, Endpunkte und Payload-Schemata bleiben, wie sie sind — bereits
> Entwurfsregel aus [07, K2](07-konflikte-und-backend-schicht.md#k2--ein-neuer-modulname-bekommt-keine-route).
> Damit bleiben die Daten in GitLab kompatibel, egal welches Backend sie erzeugt
> hat.

Unter diesen Regeln sieht die Rückholbarkeit so aus:

| Änderung | Rückweg | Aufwand |
|---|---|---|
| RBAC verengt | Werte zurücksetzen | Minuten |
| OCS abgeschaltet | Schalter umlegen | Minuten |
| Environment-Templates entfernt | Config-Commit zurücknehmen | Minuten |
| `ci_access` / `user_access` verengt | Config-Commit zurücknehmen | Minuten |
| Fork-Image im Einsatz | `image.repository` auf Upstream zurück | Minuten |
| Workspaces abgeschaltet | wieder einschalten, Rechte zurückgeben | Minuten |
| **Scan-Quelle gewechselt** | Schalter umlegen — **aber siehe unten** | Minuten + Datenrauschen |

### Die eine Einbahnstraße

Beim Wechsel der Scan-Quelle ändern sich die **Vulnerability-UUIDs**. Findings
der alten Quelle werden über `/scan_result` aufgelöst, die der neuen neu
angelegt. In der Security-Ansicht sieht das aus wie „alles behoben, alles neu
gefunden" — auch beim Zurückwechseln.

Technisch reversibel, in der Historie aber sichtbar. Wer das vermeiden will,
sollte den Wechsel **einmal und bewusst** vollziehen, ihn dokumentieren und ihn
nicht als Experiment fahren. Das ist der einzige Schritt der gesamten Strategie,
den ich nicht als folgenlos umkehrbar bezeichnen würde.

## 6. Was das an Dokument 07 revidiert

| Aussage in 07 | Status |
|---|---|
| ArgoCD-Backend triggert über die Refresh-Annotation | **Ersetzt.** Webhook auf `/api/webhook`, ohne Schreibrechte. |
| `SyncBackend.RequiredRules()` liefert je Backend andere Schreibrechte | **Vereinfacht.** Beide Backends brauchen nur noch Leserechte; die Methode bleibt sinnvoll, ihr Inhalt schrumpft. |
| Flux-Backend verwaltet `Receiver` und `Secret` | **Optional gestellt.** Im schreibfreien Modus werden sie in Git deklariert; die verwaltende Variante bleibt als Upstream-kompatibler Schalter erhalten (Regel 1). |
| Asymmetrie der Backends als Begründung für den Vertrag | **Abgeschwächt.** Die Backends sind sich jetzt ähnlicher; der Vertrag rechtfertigt sich über Austauschbarkeit statt über unterschiedliche Rechte. |

## 7. Offene Punkte

1. **Payload-Synthese für den ArgoCD-Webhook.** `ReconcileProjectsResponse`
   liefert nur den Projektpfad, **keinen Ref** (`flux/rpc/rpc.proto`). ArgoCDs
   Webhook-Handler wertet den Ref aus, um passende Applications zu finden. Der
   Adapter müsste den Ref aus `Application.spec.source.targetRevision` ableiten
   und je Application ein Ereignis erzeugen. Machbar und lesend — aber vor der
   Umsetzung an einer echten Installation zu prüfen. Bei Flux stellt sich die
   Frage nicht, weil der Receiver-Webhook keinen Ref braucht.
2. **Shared Secret für den ArgoCD-Webhook** muss als Secret im Cluster liegen
   und dem Agenten lesbar sein — ein zusätzlicher, eng benennbarer Leserechteintrag.
3. **Entscheidung Stufe 0 oder 1** (Abschnitt 4) — drei Minuten Latenz gegen
   einen Adapter.
4. **Entscheidung zu Workspaces** (Abschnitt 4) — Ausnahme mit eigenem Agenten
   oder Verzicht.
