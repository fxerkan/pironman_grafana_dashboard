#!/usr/bin/env bash
# Capture live Grafana web-UI edits back into this repo (and the Pi's
# provisioning file) so they survive the next deploy/provision reload.
#
# Grafana saves UI edits to its own DB, NOT to the provisioning file, so the
# only way to persist them is to export via the API and write them back.
#
# Run from this repo dir on the Mac:
#   ./sync-dashboard.sh                 # export -> repo file + Pi prov file + restart grafana
#   ./sync-dashboard.sh --no-deploy     # only update the local repo file (don't touch the Pi)
#   ./sync-dashboard.sh --commit         # also git add+commit the repo file
#   ./sync-dashboard.sh --commit --push  # ...and push
#
# Config (override via env):
#   SSH_HOST      Pi ssh alias                (default rpifx-sd)
#   GRAFANA_URL   Grafana base URL on the Pi  (default http://localhost:3003)  # 3000 is a different docker svc!
#   DASH_UID      dashboard uid               (default adtgxxr)
#   GRAFANA_ENV   env file with GRAFANA_TOKEN (default ~/PROJECTs/grafana-dashboarder/_credentials/grafana.env, on the Pi)
#   PROV_FILE     provisioning file on the Pi (default /var/lib/grafana/dashboards/pironman5/Pironman_5_Dashboard.json)
#   REPO_FILE     canonical file in this repo (default "Pironman 5 Dashboard.json")
set -euo pipefail

SSH_HOST="${SSH_HOST:-rpifx-sd}"
GRAFANA_URL="${GRAFANA_URL:-http://localhost:3003}"
DASH_UID="${DASH_UID:-adtgxxr}"
GRAFANA_ENV="${GRAFANA_ENV:-\$HOME/PROJECTs/grafana-dashboarder/_credentials/grafana.env}"
PROV_FILE="${PROV_FILE:-/var/lib/grafana/dashboards/pironman5/Pironman_5_Dashboard.json}"
REPO_FILE="${REPO_FILE:-Pironman 5 Dashboard.json}"

DEPLOY=1; COMMIT=0; PUSH=0
for a in "$@"; do case "$a" in
  --no-deploy) DEPLOY=0 ;;
  --commit)    COMMIT=1 ;;
  --push)      COMMIT=1; PUSH=1 ;;
  *) echo "unknown arg: $a" >&2; exit 2 ;;
esac; done

cd "$(dirname "$0")"

# 1. Export from Grafana on the Pi and sanitize there (token never leaves the Pi).
#    Sanitized JSON is written to a temp on the Pi and echoed to our stdout.
echo ">> exporting uid=$DASH_UID from $GRAFANA_URL on $SSH_HOST" >&2
tmp_json="$(ssh "$SSH_HOST" GRAFANA_ENV="$GRAFANA_ENV" GURL="$GRAFANA_URL" UID_="$DASH_UID" 'bash -s' <<'REMOTE'
set -euo pipefail
set -a; . "$(eval echo "$GRAFANA_ENV")"; set +a
: "${GRAFANA_TOKEN:?GRAFANA_TOKEN missing in env file}"
raw=$(curl -fsS -H "Authorization: Bearer $GRAFANA_TOKEN" "$GURL/api/dashboards/uid/$UID_")
printf '%s' "$raw" | python3 -c '
import json,sys
r=json.load(sys.stdin)
d=r["dashboard"]; d.pop("id",None); d.pop("version",None)
out=json.dumps(d,indent=2,ensure_ascii=False)
open("/tmp/sync-dashboard.json","w").write(out)   # staged on the Pi for the deploy step
sys.stdout.write(out)
'
REMOTE
)"

# 2. Validate + write the local repo file.
printf '%s' "$tmp_json" | python3 -c 'import json,sys; json.load(sys.stdin)' \
  || { echo "!! export was not valid JSON" >&2; exit 1; }
printf '%s\n' "$tmp_json" > "$REPO_FILE"
echo ">> wrote repo file: $REPO_FILE ($(wc -c <"$REPO_FILE") bytes)" >&2

# 3. Deploy the same content to the Pi's provisioning file so file == DB == repo.
if [ "$DEPLOY" = 1 ]; then
  echo ">> deploying to $PROV_FILE and restarting grafana" >&2
  ssh "$SSH_HOST" PROV_FILE="$PROV_FILE" 'bash -s' <<'REMOTE'
set -euo pipefail
sudo cp "$PROV_FILE" "$PROV_FILE.bak-$(date +%Y%m%d-%H%M%S)"
sudo cp /tmp/sync-dashboard.json "$PROV_FILE"
sudo chown grafana:grafana "$PROV_FILE"
python3 -c "import json;json.load(open('$PROV_FILE'))"
sudo systemctl restart grafana-server
REMOTE
  echo ">> grafana restarted" >&2
fi

# 4. Optional git commit / push.
if [ "$COMMIT" = 1 ]; then
  if git diff --quiet -- "$REPO_FILE"; then
    echo ">> no changes to commit" >&2
  else
    git add "$REPO_FILE"
    git -c commit.gpgsign=false commit -q -m "sync: capture live Grafana UI edits (uid $DASH_UID)"
    echo ">> committed" >&2
    [ "$PUSH" = 1 ] && { git push -q -u origin HEAD; echo ">> pushed" >&2; }
  fi
fi
echo ">> done" >&2
