# 04 – Feature-Matrix und Abschaltbarkeit

Vollständige Extraktion aller Features und die Antwort auf die eigentliche Frage:
**Wo genau sitzt der Schalter, und wie sehr kann man ihm trauen?**

Zielumgebung dieser Analyse: **Self-Managed GitLab.** Das ist wichtig, weil du
dort alle drei Schalterebenen selbst betreibst — bei GitLab.com wäre Ebene 2
fremdbetrieben und damit für dich keine Kontrolle, sondern eine Annahme.

## 1. Die drei Schalterebenen

Ein Feature „abschalten" kann an drei verschiedenen Orten passieren. Sie sind
**nicht gleichwertig**, und das ist der Kern dieses Dokuments.

| Ebene | Ort | Wer kontrolliert sie | Artefakt |
|---|---|---|---|
| **E1 – Cluster** | Helm-Chart → `agentk`-Prozess | Cluster-Betreiber | `values.yaml`, RBAC |
| **E2 – Relay** | KAS-Konfigurationsdatei | GitLab-Betreiber (bei Self-Managed: du) | `kascfg`, GitLab-Chart |
| **E3 – GitLab** | Agent-Config im Git-Repo | Maintainer des Konfigurationsprojekts | `.gitlab/agents/<name>/config.yaml` |

Der entscheidende Unterschied: **E1 ist die einzige Ebene, die im Cluster
durchgesetzt wird.** E2 und E3 sind Entscheidungen einer Gegenstelle. Wenn diese
Gegenstelle kompromittiert wird, falsch konfiguriert ist oder schlicht von jemand
anderem verwaltet wird, hält der Schalter nicht.

## 2. Wirksamkeitsklassen

Damit „aus" ein prüfbarer Zustand wird statt einer Behauptung:

| Klasse | Bedeutung | Vertrauenswürdig? |
|---|---|---|
| **K0** | Kein Schalter auf keiner Ebene. Das Feature ist immer da. | — |
| **K1** | Code läuft, Zugriff wird **serverseitig autorisiert** abgelehnt. | Nur so weit, wie du der Serverseite traust |
| **K2** | Modul ist geladen, tut aber nichts, weil die **Config es sagt**. | Nur so weit, wie du dem Config-Repo traust |
| **K3** | Modul wird **gar nicht konstruiert**. Kein Code, keine Verbindung. | Ja — im Cluster durchgesetzt |
| **K4** | K3 **plus**: die zugehörigen Rechte und Objekte existieren nicht. | Ja — auch bei kompromittiertem Agent |

**K4 ist das Ziel deiner Situationsschicht.** Der Unterschied zwischen K3 und K4
ist entscheidend: Ein nicht geladenes Modul in einem Pod mit `cluster-admin`
schützt nur davor, dass *dieses Feature* etwas tut — nicht davor, dass jemand
über einen anderen Weg dieselben Rechte nutzt. Erst wenn der Schalter auch die
Rechte entfernt, ist er eine Sicherheitsgrenze.

## 3. Die Matrix

Alle Features, wie ich sie in `internal/cmd/agentk/command.go:364-403`,
`pkg/agentcfg/agentcfg.proto` und `pkg/kascfg/kascfg.proto` vorgefunden habe.

| # | Feature | Modul | E1 Cluster | E2 Relay | E3 GitLab | Klasse heute | Erreichbar |
|---|---|---|---|---|---|---|---|
| 1 | K8s-API-Proxy für CI | `kubernetes_api` | — | — | `ci_access` | **K1** | K4 ¹ |
| 2 | K8s-API-Proxy für User | `kubernetes_api` | — | — | `user_access` | **K1** | K4 ¹ |
| 3 | Cluster-Live-Ansicht (`WatchGraph`) | `kubernetes_api` | — | — | — | **K0** | K4 ¹ |
| 4 | Managed Resources (Namespaces/SAs) | serverseitig über #1 | — | — | `resource_management` | **K2** | K4 ¹ |
| 5 | Operational Container Scanning | `starboard_vulnerability` | ✅ `OCS_ENABLED` | — | `container_scanning` | **K3** | **K4** ² |
| 6 | Flux / GitOps | `flux` | (CRD-Autodetektion) | — | `flux.enabled` | **K2** | K4 ¹ |
| 7 | Remote Development / Workspaces | `remote_development` | — | ✅ `workspaces.enabled` | `remote_development.enabled` | **K2** | K4 ¹ |
| 8 | Google Profiler | `google_profiler` | — | — | `observability.google_profiler` | **K2** | K4 ¹ |
| 9 | Observability / Metrics | `observability` | (nur kosmetisch) | — | Log-Level | **K0** | K3 ¹ |
| 10 | Agent-Registrierung + Telemetrie | `agent_registrar` | — | — | — | **K0** | — ³ |
| 11 | Konfigurations-Stream | `agent_configuration` | — | `configuration.poll_period` | — | **K0** | — ³ |
| 12 | GitLab-API-Proxy für Module | `gitlab_access` | — | — | — | **K0** | — ³ |
| 13 | Tunnel-Richtung | `agent2kas` / `kas2agentk` | ✅ `receptive.enabled` | ✅ `receptive_agent` | Agent-Registrierung | **K3** | K3 |
| 14 | Events Platform | `events_platform` (Relay) | — | ✅ Abschnitt weglassen | — | **K3** | K3 |
| 15 | AutoFlow | `autoflow` (Relay) | — | ✅ Abschnitt weglassen | — | **K3** | K3 |
| 16 | Job Router / Runner Controller | `job_router` (Relay) | — | — | — | K0 auf Relay | — ⁴ |

¹ Erfordert einen per-Modul-Schalter in `agentk` — siehe [05-zielbild-architektur.md](05-zielbild-architektur.md).
² Bereits K3; wird zu K4, sobald die RBAC an den Schalter gekoppelt ist.
³ Kernfunktion. Ohne diese Module ist der Agent kein Agent. Nicht abschaltbar, sondern zu minimieren.
⁴ Betrifft nur Relay und keine Cluster-Komponente dieses Charts.

### Das Ergebnis in einem Satz

**Von 13 clusterrelevanten Feature-Flächen sind heute zwei im Cluster
abschaltbar** (OCS und die Tunnel-Richtung). Alle übrigen hängen an
Konfiguration, die aus GitLab kommt.

## 4. Warum das so ist — Befunde aus dem Code

Damit die Matrix nachvollziehbar ist und nicht geglaubt werden muss:

**Die Modulliste ist einkompiliert.** `internal/cmd/agentk/command.go:364-403`
enthält eine feste `[]modagentk.Factory`. Es gibt kein Flag, keine Env-Var und
keine Config, die diese Liste verändert.

**Der Factory-Vertrag erlaubt Abschalten aber ausdrücklich.**
`internal/module/modagent/api.go:82` — *„Can return nil if no module is
necessary."* Genau ein Modul nutzt das heute:

```go
// internal/module/starboard_vulnerability/agentk/factory.go:27-30
ocsEnabled, _ := strconv.ParseBool(os.Getenv(envVarOcsEnabled))
if !ocsEnabled {
    cfg.Log.Info("Module is disabled. Set the 'OCS_ENABLED' environment variable to 'true` to enable it")
    return nil, nil
}
```

Das ist das Muster, an dem sich alles Weitere orientieren kann. Es ist
upstream-idiomatisch, nicht erfunden.

**Der K8s-API-Proxy registriert sich bedingungslos.**
`internal/module/kubernetes_api/agentk/factory.go:34` ruft
`rpc.RegisterKubernetesApiServer(config.APIServer, s)` auf und liefert danach
`nil, nil` zurück — es gibt kein Modul zum Steuern, nur einen registrierten
gRPC-Service. Der Proxy ist damit **immer** Teil der Angriffsfläche des Agenten,
unabhängig von jeder Konfiguration. Das ist Befund #3 der Matrix und der Grund,
warum `WatchGraph` in K0 landet.

**Flux erkennt statt zu schalten.** `internal/module/flux/agentk/factory.go:70-73`
prüft per RESTMapper, ob die Flux-CRDs existieren, und überspringt das Modul
sonst — mit dem Log-Hinweis, dass ein Neustart nötig ist, damit erneut geprüft
wird. Das ist Autodetektion, kein Schalter: Wer Flux im Cluster installiert,
aktiviert das Modul implizit mit.

**Relay hat eigene, echte Schalter.** Im `kascfg`-Schema:
`workspaces.enabled` (Bool), `events_platform` und `autoflow` sind über
**Abwesenheit des Abschnitts** abschaltbar — bei `events_platform` steht das
sogar als Vertrag im Proto: *„The module is disabled when this section is absent
from the configuration."*

**Der K8s-API-Listener von Relay lässt sich nicht abschalten.**
`pkg/kascfg/kascfg_defaults.yaml:16-24` setzt `agent.kubernetes_api.listen.address: :8154`
als Default, und `internal/module/kubernetes_api/server/factory.go:60` baut den
Listener unbedingt. Es gibt kein `enabled`. Die einzige Kontrolle auf E2 ist
**netzwerkseitig**: den Port nicht exponieren.

## 5. Wie man jede Klasse verifiziert

Ohne Verifikation ist die Matrix Dokumentation, keine Vertrauensschicht.

| Klasse | Prüfmethode | Aussagekraft |
|---|---|---|
| **K4** | `kubectl auth can-i <verb> <resource> --as=system:serviceaccount:<ns>:<sa>` → `no` | Beweis. Im Cluster durchgesetzt. |
| **K4** | Gerenderte Manifeste prüfen: `helm template ... \| grep -c 'kind: ClusterRole'` | Beweis über das, was existiert |
| **K3** | Agent-Log auf `"Module is disabled"` prüfen | Beweis, dass der Code nicht läuft |
| **K3** | Fehlender gRPC-Service im Tunnel-Deskriptor (siehe unten) | Beweis, dass Relay nichts routen kann |
| **K2** | Review der Agent-Config im Git-Repo | Momentaufnahme. Ein Commit ändert sie. |
| **K1** | Review von `ci_access`/`user_access` + GitLab-Rollen | Momentaufnahme, abhängig von der Serverseite |
| **K0** | — | Nicht prüfbar, weil nicht abschaltbar |

### Der Tunnel-Deskriptor als Prüfpunkt

`internal/module/agent2kas_tunnel/agent/factory.go:46` baut über
`tunclient.APIDescriptor(apiServer)` einen Deskriptor aus den **tatsächlich
registrierten** gRPC-Services und schickt ihn mit jeder Tunnelverbindung an
Relay. Relay routet danach.

Praktische Folge: **Ein Pod, der einen Service nicht registriert, bekommt dafür
auch keine Requests.** Das macht K3 nicht nur zu einer lokalen Eigenschaft des
Pods, sondern zu einer, die die Gegenstelle respektiert — ohne dass die
Gegenstelle etwas davon wissen muss. Das ist die technische Grundlage dafür,
dass ein per-Modul-Schalter überhaupt sauber funktionieren kann.

## 6. Rechtebedarf je Feature

Die Grundlage für K4: Ein Schalter ist erst dann eine Sicherheitsgrenze, wenn er
auch die Rechte mitnimmt. Diese Tabelle ist die Vorlage für eine generierte
ClusterRole.

| Feature | Benötigte Rechte |
|---|---|
| K8s-API-Proxy (`access_as: agent`) | alles, was die durchgereichten Aufrufe brauchen — der SA ist die Obergrenze |
| K8s-API-Proxy (Impersonation) | `impersonate` auf `users`, `groups`, `serviceaccounts`, `uids` |
| Cluster-Live-Ansicht | `get`/`list`/`watch` auf die angezeigten Arten |
| OCS (Agent) | `pods` create/get/delete + `pods/log` get, im Agent-Namespace |
| OCS (Scan-Pod) | die ClusterRole aus [03](03-rechte-und-rbac.md#13-ocs-clusterrole-im-detail) |
| Flux | `get`/`list`/`watch` auf `GitRepository`; CRUD auf `Receiver` + deren `Secret`s |
| Remote Development | CRUD in Workspace-Namespaces inkl. `networkpolicies` |
| Managed Resources | CRUD auf `namespaces`, `serviceaccounts`, `rolebindings` |
| Kern (Registrar, Config, Leader) | CRUD auf `leases` im eigenen Namespace, `create`/`patch` auf `events` |

Auffällig: **Der Kern braucht fast nichts.** Ein Agent, der nur registriert,
Konfiguration zieht und einen Tunnel hält, kommt mit Rechten auf `leases` und
`events` im eigenen Namespace aus. Der gesamte Rest der heute vergebenen
`cluster-admin`-Rechte geht auf Features zurück — und ist damit prinzipiell an
Schalter koppelbar.

## 7. Was daraus für die Situationsschicht folgt

1. **Heute ist keine belastbare Abschaltung im Cluster möglich** — außer OCS.
   Wer etwas anderes behauptet, verwechselt E3 mit E1.
2. **Bei Self-Managed besitzt du alle drei Ebenen.** Das ist die gute Nachricht:
   E2 und E3 sind für dich echte Kontrollen, nur eben organisatorische statt
   technischer. Verteidigung in der Tiefe ist damit sofort möglich.
3. **K4 für alle Features braucht zwei Dinge:** einen per-Modul-Schalter in
   `agentk` und eine RBAC-Generierung im Chart, die an denselben Schaltern hängt.
4. **Ein Teil der Isolation ist heute schon erreichbar — ohne jede
   Codeänderung** — indem man die Einheit der Isolation wechselt: vom Modul zum
   Agenten. Das ist das Thema von [05-zielbild-architektur.md](05-zielbild-architektur.md).
