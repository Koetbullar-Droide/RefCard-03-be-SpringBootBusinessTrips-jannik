# Lösung EX-02 & EX-03 – Backend (Jannik)

> EX-01 (EC2) wurde bewusst übersprungen; das Deployment geht direkt auf ECS Fargate.

## Pipeline (`.github/workflows/deploy.yml`)

```
test ──► build ──┬──► docker      (EX-02: GitHub Container Registry)
                 └──► deploy-ecs  (EX-03: ECR + ECS Fargate)
```

| Job | Was passiert |
| --- | --- |
| `test` | `./mvnw test` (H2) |
| `build` | `./mvnw clean package` (CI-Check, ob das JAR baut) |
| `docker` | Image bauen, Tags `prod01`, `latest`, `<commit-sha>` → `ghcr.io/koetbullar-droide/…` (Login mit `GITHUB_TOKEN`, keine eigenen Secrets nötig) |
| `deploy-ecs` | Image → ECR, Task Definition mit neuem Image rendern, ECS-Service aktualisieren (Rolling Deployment) |

`docker` und `deploy-ecs` laufen **nur bei Push auf `main`**, nicht bei Pull Requests.
Das löst auch die Erweiterung („nur Änderungen auf `main` landen in der Registry“).

## EX-02 – Docker-Image

- `Dockerfile`: Multi-Stage (JDK + Maven bauen das JAR → nur JRE-Alpine + `app.jar` im finalen Image)
- `.dockerignore`: `target`, `.git`, `docs` … bleiben draussen
- Lokal testen:

```bash
docker build -t ghcr.io/koetbullar-droide/biztrips-backend:prod01 .
docker run --rm -p 8080:8080 ghcr.io/koetbullar-droide/biztrips-backend:prod01
curl http://localhost:8080/v1/trips
```

## EX-03 – ECS Fargate

Architektur (alles im AWS Academy Learner Lab, `us-east-1`):

```
Internet ─► ALB biztrips-backend-alb :80 ─► Target Group (ip, :8080, /actuator/health)
                                              └─► ECS-Service (2 Fargate-Tasks) ─► RDS MariaDB :3306
```

- **ECR** `biztrips-backend`: Image-Registry
- **RDS** MariaDB: Datenbank läuft ausserhalb der (zustandslosen) Container
- **Secrets Manager** `biztrips-backend-db-password`: DB-Passwort, wird von ECS beim Start eingespielt
- **`task-definition.json`**: Container-Definition; `LabRole` als Execution Role (Learner Lab erlaubt keine eigenen Rollen)
- **Security Groups**: ALB (80 aus Internet) → Tasks (8080 nur vom ALB) → RDS (3306 nur von den Tasks)
- **Credentials**: Learner Lab erlaubt kein OIDC → temporäre Lab-Credentials als GitHub Secrets (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`)

Infrastruktur einmalig anlegen: `scripts/aws-ecs-setup.sh` (legt alles oben an und trägt
Account-ID und RDS-Endpoint in `task-definition.json` ein).
Lab-Credentials nach jedem Lab-Neustart erneuern: `scripts/set-aws-secrets.sh`.

### Änderung → Wirkung

1. Kleine Änderung committen und auf `main` pushen
2. Workflow läuft → `deploy-ecs` grün
3. ECS → Service → *Deployments* zeigt die neue Task-Definition-Revision, alte Tasks werden ersetzt
4. `curl http://<backend-alb-dns>/v1/trips` zeigt die Änderung

## Screenshots

<!-- Bilder in docs/img/ ablegen und hier einbinden -->
- [ ] GitHub Actions: grüner Workflow-Run
- [ ] GitHub → Packages: Tags `prod01`, `latest`, `<sha>`
- [ ] ECR: Images mit Commit-SHA
- [ ] ECS: Service mit 2 laufenden Tasks, Deployment-Historie
- [ ] Browser/curl: `/v1/trips` über die ALB-URL
