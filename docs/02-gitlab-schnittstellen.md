# 02 – Schnittstellen zu GitLab

Vollständige Aufstellung aller Berührungspunkte zwischen dem per Helm-Chart
ausgerollten `agentk` und GitLab.

**Zentrale Aussage vorweg:** Im Standardbetrieb existiert **genau eine
Netzwerkverbindung** vom Cluster zu GitLab. Alle Produktfunktionen — CI-Zugriff,
User-Zugriff, GitOps/Flux, Container-Scanning, Workspaces — laufen als *logische
Kanäle* (gRPC-Services) über diesen einen Stream. Wer die Firewall plant, muss
nur diesen einen Kanal freigeben; wer das Risiko bewertet, muss trotzdem alle
logischen Kanäle einzeln betrachten.

## 1. Netzwerkverbindungen im Überblick

| # | Von → Nach | Protokoll | Port | Richtung | Default |
|---|---|---|---|---|---|
| 1 | `agentk` → Relay/KAS | gRPC über WebSocket (`wss`) | 443 | ausgehend | ✅ |
| 2 | Relay/KAS → `agentk` (API) | gRPC | 8082 / Service 8182 | **eingehend** | ❌ nur `receptive` |
| 3 | `agentk` ↔ `agentk` (Private API) | gRPC | 8081 | clusterintern | ❌ nur `receptive` |
| 4 | `agentk` → Kubernetes API | HTTPS | 443 | clusterintern | ✅ |
| 5 | Kubelet → `registry.gitlab.com` | HTTPS | 443 | ausgehend | ✅ (Image-Pull) |
| 6 | OCS-Scan-Pod → `registry.gitlab.com` | HTTPS | 443 | ausgehend | ✅ wenn OCS an |
| 7 | Prometheus → `agentk` | HTTP(S) | 8080 | clusterintern | ✅ |

Verbindung 1 ist die einzige, die den Cluster in Richtung GitLab verlässt.

## 2. Verbindung 1: `agentk` → Relay/KAS

Die Hauptschnittstelle. Konfiguriert über `config.kasAddress`, gesetzt als
`--kas-address` (`deployment.yaml:68`).

| Aspekt | Wert |
|---|---|
| Default-Adresse | `wss://kas.gitlab.com` (SaaS) |
| Unterstützte Schemes | `wss`, `ws`, `grpcs`, `grpc` (`internal/cmd/agent/options.go:146-194`) |
| Default-Ports | 443 (`wss`/`grpcs`), 80 (`ws`/`grpc`) |
| Transport | gRPC, **bidirektionales Streaming**, langlebig |
| Warum WebSocket | passiert Reverse-Proxies und Load-Balancer, die kein reines gRPC weiterleiten |
| Authentifizierung | Agent-Token als `authorization: Bearer <token>` (`internal/tool/grpctool/header_metadata.go:20`) |
| Token-Quelle | Datei `/etc/agentk/secrets/token` aus Secret `{{fullname}}-token` |
| TLS-Verifikation | Systemtrust; eigene CA via `config.kasCaCert` |
| Zusatz-Header | `config.kasHeaders[]` → `--kas-header`, z. B. `Cookie: gitlab-canary` |

Die Umkehr der Client-Server-Rolle ist der Kern der Architektur: Der Cluster
wählt sich hinaus, GitLab schickt Anfragen als gRPC-*Antworten* durch den
offenen Stream zurück. Deshalb genügt reiner Egress, auch hinter NAT.

### Logische Kanäle über diese eine Verbindung

| gRPC-Service | Richtung | Zweck | Quelle |
|---|---|---|---|
| `AgentRegistrar` (`Register`/`Unregister`) | agentk → GitLab | meldet Pod, Version, Kubernetes-Version, Telemetrie an; Heartbeat | `internal/module/agent_registrar/agentk_rpc/rpc.proto` |
| `AgentConfiguration.GetConfiguration` | agentk → GitLab (Stream) | zieht `.gitlab/agents/<name>/config.yaml` aus dem Konfigurationsprojekt | `internal/module/agent_configuration/rpc/rpc.proto` |
| `KubernetesApi.MakeRequest` | GitLab → agentk | **Kubernetes-API-Proxy**: CI-Jobs und User greifen auf den Cluster zu | `internal/module/kubernetes_api/rpc/rpc.proto` |
| `KubernetesApi.WatchGraph(WithRoots)` | GitLab → agentk (Stream) | Live-Sicht auf Cluster-Objekte für die GitLab-UI | dito |
| `GitlabAccess.MakeRequest` | agentk → GitLab | generischer Proxy für Module in die GitLab-API (z. B. Vulnerability-Reports) | `internal/module/gitlab_access/rpc/rpc.proto` |
| `GitLabFlux.ReconcileProjects` | agentk → GitLab (Stream) | abonniert Git-Push-Events für Flux-`GitRepository`-Objekte | `internal/module/flux/rpc/rpc.proto` |

Hinzu kommen die Tunnel-Module `agent2kas_tunnel` bzw. `kas2agentk_tunnel`, die
das Multiplexing der obigen Kanäle übernehmen
(Bibliothek: `gitlab-org/cluster-integration/tunnel`).

### Was der Cluster an GitLab meldet

Über `AgentRegistrar` fließen unter anderem:

- Pod-Name und Namespace (`POD_NAME`, `POD_NAMESPACE`)
- `agentk`-Version, Git-Ref, Build-Info
- Kubernetes-Server-Version
- `ExtraTelemetryData` — alles aus Environment-Variablen mit dem Präfix
  `GITLAB_AGENT_TELEMETRY_`. Das Chart setzt dort fest
  `installation_method=helm-chart` und die Chart-Version
  (`deployment.yaml:168-171`).

Über `GitlabAccess` fließen unter anderem Vulnerability-Reports des
Container-Scannings.

## 3. Verbindung 2 und 3: „receptive"-Modus (eingehend)

Nur bei `config.receptive.enabled: true`. Dann verbindet sich **GitLab zum
Cluster** statt umgekehrt.

| Aspekt | API (extern) | Private API (intern) |
|---|---|---|
| Port im Container | `8082` (`config.api.listenAddress`) | `8081` (`config.privateApi.listenAddress`) |
| Service-Port | `8182` (`service.externalPort`) | `8081` |
| Gegenstelle | Relay/KAS | andere `agentk`-Pods |
| Auth | EdDSA-JWT (`config.api.jwtPublicKey`) **oder** mTLS | HS-JWT mit gemeinsamem Secret |
| TLS | `config.api.tls.*` oder TLS-Terminierung am Ingress | `config.privateApi.tls.*` |
| Secret-Schlüssel | `api-jwt`, `tls.crt`, `tls.key` | `private-api-jwt`, `private-api-tls-*` |

JWT-Parameter laut `doc/kas_to_agentk_connectivity.md`: Audience `gitlab-agent`,
Issuer `gitlab-kas` (bzw. `gitlab-agent` bei Pod-zu-Pod), Gültigkeit 5 Sekunden,
`nbf` = jetzt minus 5 Sekunden.

Das Chart erzeugt das Private-API-Secret selbst
(`randAscii 64 | b64enc | b64enc`, `secret.yaml`) und liest es bei Upgrades per
`lookup` zurück, damit es stabil bleibt. **Konsequenz:** `helm template` ohne
Cluster-Zugriff erzeugt bei jedem Lauf ein anderes Secret — im GitOps-Betrieb
also nicht blind `helm template` in ein Repo schreiben.

Ingress-Besonderheit: Für `provider: nginx` setzt das Chart automatisch
`nginx.ingress.kubernetes.io/backend-protocol: "GRPC"` und schaltet
Proxy-Buffering ab (`ingress.yaml`). Die `ingressClassName` ist auf
`gitlab-agent-nginx` **hartkodiert** — bei einem eigenen Ingress-Controller muss
die IngressClass entsprechend heißen oder der Ingress selbst gebaut werden.

Die Registrierung eines receptive Agents inkl. URL, CA, mTLS-Material und
JWT-Privatschlüssel passiert GitLab-seitig; Relay holt die Liste alle 5 Minuten
über `GET /api/v4/internal/kubernetes/receptive_agents`.

## 4. Verbindung 4: Kubernetes-API

Keine GitLab-Schnittstelle, aber die Gegenseite jedes GitLab-Zugriffs.
`agentk` nutzt die Kubernetes-API für:

- **Proxy-Requests** aus CI-Jobs und von Usern (das eigentliche Produktfeature)
- **Informer/Watches** für die Live-Cluster-Ansicht (`WatchGraph`)
- **Flux-Controller**: `GitRepository` und `Receiver` beobachten, `Receiver` und
  zugehörige `Secret`s erzeugen/aktualisieren
- **Container-Scanning**: Scan-Pods im Agent-Namespace erzeugen, deren Logs
  lesen, Status-ConfigMaps schreiben
- **Leader Election** über `coordination.k8s.io/Lease`
  (`internal/cmd/agentk/leader_elector.go`) — nötig, weil das Chart 2 Replicas
  fährt und Module wie OCS nur einmal laufen dürfen
- **Events** über einen `EventRecorder` (`internal/cmd/agentk/command.go:171`)

Identität: der ServiceAccount des Pods — bzw. eine *impersonierte* Identität,
siehe [03-rechte-und-rbac.md](03-rechte-und-rbac.md).

## 5. Verbindungen 5 und 6: Container-Images

| Image | Bezug | Bedingung |
|---|---|---|
| `registry.gitlab.com/gitlab-org/cluster-integration/gitlab-agent/agentk:<appVersion>` | Kubelet | immer |
| `registry.gitlab.com/security-products/trivy-k8s-wrapper` | Kubelet, für Scan-Pods | OCS aktiv |

Default des Trivy-Images:
`internal/module/starboard_vulnerability/agentk/module.go:31`; überschreibbar
über `container_scanning.trivy_k8s_wrapper_image` in der **Agent-Konfiguration**
(nicht in `values.yaml`). In Umgebungen ohne Internetzugang müssen **beide**
Images gespiegelt werden.

## 6. Verbindung 7: Observability

| Endpunkt | Port | Zweck |
|---|---|---|
| `/metrics` | 8080 | Prometheus |
| `/liveness` | 8080 | Liveness-Probe |
| `/readiness` | 8080 | Readiness-Probe |

(`internal/module/observability/agent/module.go:35-37`)

Das Chart setzt per Default `prometheus.io/scrape`-Annotationen; bei
`config.observability.enabled: false` werden diese Annotationen aktiv wieder
entfernt (`_helpers.tpl`, `gitlab-agent.annotations`), damit Prometheus nicht
gegen einen geschlossenen Port läuft. Optional gibt es TLS
(`config.observability.tls.*`) und einen `ServiceMonitor`
(`serviceMonitor.enabled`) für den Prometheus-Operator.

## 7. Serverseitige GitLab-Schnittstellen (nur zur Einordnung)

Diese Aufrufe macht **Relay/KAS**, nicht der Cluster. Sie sind hier gelistet,
damit die Systemgrenze klar ist — bei GitLab.com betreibt GitLab diese Seite
selbst, bei Self-Managed ist sie Teil des GitLab-Charts.

| Endpunkt (`internal/gitlab/api/`) | Zweck |
|---|---|
| `/api/v4/internal/agents/agentk/agent_info` | Agent-Token validieren, Agent-Metadaten |
| `/api/v4/internal/kubernetes/agent_configuration` | Konfiguration melden |
| `/api/v4/internal/kubernetes/modules/…` | Modul-Requests weiterreichen (Gegenstück zu `GitlabAccess`) |
| `/api/v4/internal/kubernetes/agent_events` | Events |
| `/api/v4/internal/kubernetes/usage_metrics` | Usage-Ping |
| `/api/v4/internal/kubernetes/authorize_proxy_user` | User-Zugriff autorisieren |
| `/api/v4/internal/kubernetes/verify_project_access` | Projektzugriff prüfen (u. a. Flux) |
| `/api/v4/internal/kubernetes/receptive_agents` | Liste receptive Agents |
| `/api/v4/job/allowed_agents` | CI-Job → erlaubte Agents |
| `/api/v4/internal/ci/job_router/…` | Job Router |
| `/api/v4/internal/agents/agentw/…` | Workspaces |
| `/api/v4/internal/autoflow/…` | AutoFlow |

Zusätzlich spricht Relay **Gitaly per gRPC** direkt an, um Agent-Konfiguration
und Manifeste aus Git zu lesen (bewusst nicht über die HTTPS-„Vordertür", siehe
`doc/architecture.md`).

## 8. Egress-Anforderungen (Firewall / Proxy)

Minimum für den Standardbetrieb gegen GitLab.com:

| Ziel | Port | Zweck |
|---|---|---|
| `kas.gitlab.com` | 443/TCP | Hauptverbindung (WebSocket, langlebig) |
| `registry.gitlab.com` | 443/TCP | Image-Pull |

Bei Self-Managed entsprechend der eigene KAS-Host und die eigene Registry.

Praxishinweise:

- Die Verbindung ist **langlebig**. Proxies und Firewalls mit aggressivem
  Idle-Timeout unterbrechen sie regelmäßig; `agentk` verbindet zwar neu, aber
  Sichtbarkeit und Latenz leiden. Idle-Timeout großzügig setzen.
- WebSocket-Upgrade muss der Proxy zulassen.
- Für Proxy-Umgebungen: `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY` über
  `extraEnv` setzen.
- `receptive`-Modus dreht die Richtung um und braucht **Ingress von GitLab zum
  Cluster** — das ist eine grundlegend andere Firewall-Anforderung.
