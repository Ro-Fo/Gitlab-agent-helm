# 00 – Leitprinzip: Orchestrieren, nicht implementieren

> **Der GitLab Agent ist ein Orchestrierungsprodukt. Er soll keine Produkte
> sein, sondern Produkte nutzen.**

Dieses Dokument steht bewusst am Anfang der Reihe. Die Dokumente 01 bis 07 sind
Analysen und Zielbilder — dieses hier ist das Kriterium, aus dem sie folgen. Bei
künftigen Entscheidungen ist es der Maßstab, nicht die Einzelfallabwägung.

## 1. Der Test

Ein Modul ist **Orchestrierung**, wenn es zwischen GitLab und einem Produkt
vermittelt, das im Cluster ohnehin existiert. Es ist **Produktimplementierung**,
wenn es selbst den Lebenszyklus von Workloads besitzt.

Die Prüffrage, die sich in beide Richtungen beantworten lässt:

> **Schalte ich das Modul ab, während das entsprechende Produkt im Cluster
> läuft — fehlt dann etwas im Cluster oder nur in GitLab?**

- Fehlt nur etwas **in GitLab**, war das Modul die Brücke. → Orchestrierung.
- Fehlt etwas **im Cluster**, war das Modul das Produkt. → Implementierung.

Im Code gibt es dafür ein überraschend scharfes Signal: **Was genau wendet das
Modul an?**

| Signal | Einordnung |
|---|---|
| `Apply(<beliebige Manifeste>)` | Produktimplementierung |
| `Apply(<Konfigurationsobjekte eines anderen Produkts>)` | Orchestrierung |
| erzeugt `Pod`s, `Deployment`s, `Namespace`s | Produktimplementierung |
| ruft eine API eines anderen Produkts auf | Orchestrierung |

## 2. Der Bestand am Maßstab

| Modul | Was es tut | Beleg | Einordnung |
|---|---|---|---|
| `starboard_vulnerability` | erzeugt Trivy-Scan-Pods, liest deren Logs, parst Ergebnisse | `agentk/scanning_manager.go:76-84` | ❌ **implementiert einen Scanner** |
| `remote_development` | wendet beliebige Manifeste an, erzeugt Namespaces und Secrets | `agentk/reconciler.go:213,481` (`Apply(ConfigToApply)`), `namespace_handler_unique.go:49` | ❌ **implementiert eine Workspace-Plattform** |
| `managed_resources` (Relay) | rendert Templates, legt Namespace, ServiceAccount, RoleBinding an | `server/rest_mapper.go`, `default_template.yaml` | ❌ **implementiert Provisionierung** |
| `flux` | legt `Receiver` und dessen `Secret` an, ruft den Receiver-Webhook auf | `agentk/gitrepository_controller.go:417,429`; `client.go:259` | ✅ **orchestriert Flux** |
| `kubernetes_api` | reicht Anfragen durch | `agentk/factory.go:34` | ✅ Transport |
| `agent_configuration`, `agent_registrar`, `gitlab_access`, Tunnel, `observability` | Infrastruktur des Agenten selbst | — | ✅ Träger |

Drei Module verstoßen gegen das Prinzip. Sie sind zugleich **die drei, die
Rechte im großen Stil brauchen** — Pods erzeugen, beliebige Manifeste anwenden,
Namespaces und RoleBindings anlegen. Das ist kein Zufall: Wer Produkte
implementiert, braucht Produktionsrechte.

Bemerkenswert ist der Kontrast zwischen `remote_development` und `flux`. Beide
schreiben in den Cluster, beide sind Leader-Module. Aber `flux` schreibt
ausschließlich die **Konfigurationsobjekte eines fremden Produkts** und löst
danach über dessen eigene Schnittstelle aus. `remote_development` dagegen ruft
`Apply(ConfigToApply)` mit **beliebigen Manifesten auf, die GitLab berechnet
hat**. Das eine ist ein Adapter, das andere eine Ausführungsmaschine mit
GitLab als Steuerzentrale.

`flux` ist damit die Referenzimplementierung des Prinzips — und der Beweis,
dass Orchestrierung im Rahmen dieser Architektur funktioniert.

## 3. Was daraus folgt

| Funktion | Heute im Agenten | Zielbild: genutztes Produkt |
|---|---|---|
| Container-Scanning | `starboard_vulnerability` startet Trivy-Pods | **Trivy Operator**, Ergebnisse aus `VulnerabilityReport` gelesen |
| Deployment | CI-Job über den Proxy, `managed_resources` | **ArgoCD oder Flux**, Agent löst nur aus und liest Zustand |
| Namespace-Provisionierung | `managed_resources` mit Templates | Aufgabe der Plattform (Operator, Terraform, Namespace-as-Code) |
| Workspaces | `remote_development` | ehrlich: **kein gleichwertiges Produkt vorhanden** — siehe Abschnitt 4 |
| GitOps-Anbindung | `flux` | bleibt, verallgemeinert auf mehrere Backends |

Die Backend-Zwischenschicht aus
[07](07-konflikte-und-backend-schicht.md#teil-3--die-backend-zwischenschicht)
ist damit nicht eine von mehreren Entwurfsoptionen, sondern **die technische
Form dieses Prinzips**: ein Vertrag, hinter dem austauschbare Produkte stehen,
und ein Agent, der nur noch übersetzt.

## 4. Die Kosten, ehrlich benannt

Das Prinzip ist nicht kostenlos, und die Rechnung gehört auf den Tisch.

**Nicht jede Funktion hat ein Gegenstück.** Für Scanning gibt es den Trivy
Operator, für Deployment ArgoCD und Flux. Für **Workspaces gibt es kein
etabliertes Cluster-Produkt**, das GitLab kennt. Wer `remote_development`
streicht, verliert die Funktion — er ersetzt sie nicht. Das ist eine legitime
Entscheidung, aber es ist Verzicht, keine Substitution.

**GitLab-Funktionen leuchten nicht mehr auf.** Ein Teil des Produktwerts von
GitLab *ist* die Implementierung: die Operational-Vulnerability-Ansicht, die
automatische Environment-Provisionierung, die Workspace-Integration. Wer nur
orchestriert, bekommt manche dieser Ansichten leer oder gar nicht. Bei
Vulnerabilities lässt sich das auffangen, indem die Senke erhalten bleibt
(siehe [07, K2](07-konflikte-und-backend-schicht.md#k2--ein-neuer-modulname-bekommt-keine-route));
bei anderen Funktionen nicht.

**Die Governance wandert mit.** GitLabs Scan-Execution-Policies steuern den
Trivy Operator nicht (siehe [07, K8](07-konflikte-und-backend-schicht.md#k8--gitlab-scan-policies-steuern-den-trivy-operator-nicht)).
Wer die Implementierung abgibt, gibt auch die zugehörige Steuerungsoberfläche
ab — und muss sie im Cluster neu aufbauen und sichtbar machen.

**Mehr Teile, mehr Nahtstellen.** Statt eines Agenten betreibt man einen
Agenten plus zwei bis drei Operatoren, jeden mit eigenem Lebenszyklus,
eigenen CVEs und eigenem Upgrade-Pfad.

## 5. Warum es sich im regulierten Umfeld trotzdem lohnt

**Getrennte Bewertbarkeit.** Ein Agent, der scannt, deployt und Workspaces
betreibt, ist eine Komponente, die für alle drei Domänen bewertet werden muss.
Drei getrennte Produkte lassen sich einzeln prüfen, einzeln freigeben und
einzeln austauschen.

**Rechte folgen der Funktion.** Der überwiegende Teil der heute vergebenen
Rechte — bis hin zu `cluster-admin` und clusterweitem `secrets`-Lesen — entsteht
aus den drei implementierenden Modulen. Fallen sie weg, fallen die Rechte mit
(siehe [06, Abschnitt 8](06-strategie-gitops-crd.md#8-was-die-strategie-an-rechten-einspart)).

**Standardwerkzeuge statt Sonderweg.** Trivy Operator und ArgoCD sind im
Bankenumfeld etabliert, geprüft und personell abgedeckt. Ein GitLab-eigener
Scanner ist es nicht.

**Kein Lock-in auf der Ausführungsebene.** Wechselt der GitOps-Operator oder der
Scanner, wechselt ein Backend hinter einem Vertrag — nicht die Plattform.

## 6. Wirkung auf die Fork-Frage

Das Prinzip verändert den Charakter eines Forks grundlegend, und das ist sein
vielleicht unterschätztester Vorteil:

- Ein Fork, der **Funktionen hinzufügt**, wächst mit jedem Upstream-Release
  auseinander. Jeder Merge ist Verhandlung.
- Ein Fork, der **Funktionen entfernt und durch Adapter ersetzt**, besteht
  überwiegend aus Weglassen plus einer dünnen Vertragsschicht. Weggelassener
  Code kollidiert nicht.

Ein orchestrierungsreiner Agent ist damit ein *kleinerer* Fork als der heutige
Funktionsumfang — und er bleibt upstream-fähig, weil die Zwischenschicht
additiv ist und bestehende Semantik nicht ändert.

## 7. Als Entscheidungsregel

Für jede künftige Frage nach einer neuen Funktion im Agenten:

1. Gibt es im Cluster ein Produkt, das das kann? → **Orchestrieren.**
2. Gibt es keines, aber die Funktion ist nötig? → **Bewusst als Ausnahme
   dokumentieren**, mit den Rechten, die sie kostet.
3. Braucht die Funktion Rechte, die über Lesen und das Anstoßen fremder
   Produkte hinausgehen? → Starkes Indiz dafür, dass Regel 1 verletzt wird.

Regel 3 ist die praktisch nützlichste: **Der Rechtebedarf verrät die
Einordnung.** Wer nur orchestriert, kommt mit Lesen, dem Schreiben fremder
Konfigurationsobjekte und dem Aufruf fremder Schnittstellen aus.
