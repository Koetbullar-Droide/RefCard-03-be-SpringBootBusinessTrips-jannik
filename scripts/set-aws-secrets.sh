#!/usr/bin/env bash
# Überträgt die (temporären) Learner-Lab-Credentials aus dem AWS-Profil "learner-lab" als
# GitHub Secrets in Backend- und Frontend-Repo. Nach JEDEM Lab-Neustart erneut ausführen.
#   ./scripts/set-aws-secrets.sh [pfad-zum-frontend-repo]
set -euo pipefail

FE_REPO="${1:-../refcard-03-fe-react-vite-1-start}"

for repo in . "$FE_REPO"; do
  (
    cd "$repo"
    for key in aws_access_key_id aws_secret_access_key aws_session_token; do
      aws configure get "$key" --profile learner-lab | gh secret set "$(echo "$key" | tr a-z A-Z)"
    done
  )
done
echo "AWS-Secrets in beiden Repos aktualisiert."
