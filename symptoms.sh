#!/usr/bin/env bash
# Usage: ./symptoms.sh <ticket-number> [label]
# Gathers what a customer (and the on-call engineer) would see, and saves it to evidence/logs/t<N>-<label>.txt
set -uo pipefail
export PATH="$HOME/.local/bin:$PATH"
DIR="$(cd "$(dirname "$0")" && pwd)"; N="${1:?ticket number}"; LABEL="${2:-1-symptoms}"
ACCT=$(aws sts get-caller-identity --query Account --output text); R=eu-west-1; S=breakfix-lab; OUT="$DIR/evidence/logs/t${N}-${LABEL}.txt"
q(){ aws cloudformation describe-stacks --region $R --stack-name $S --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text; }
URL=$(q WebsiteUrl); TG=$(q TargetGroupArn); T=$(mktemp)
{
echo "# $(date -u +%FT%TZ) ticket $N: $LABEL"
echo "## 1. website from outside (6 requests)"
for i in 1 2 3 4 5 6; do curl -s -m 8 -o "$T" -w "HTTP %{http_code} in %{time_total}s  " "$URL"; grep -o 'Served by[^<]*' "$T" || echo; done
echo "## 2. what the load balancer thinks (target health)"
aws elbv2 describe-target-health --region $R --target-group-arn "$TG" --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State,TargetHealth.Reason]' --output text
echo "## 3. Systems Manager"
aws ssm describe-instance-information --region $R --query 'InstanceInformationList[].[InstanceId,PingStatus]' --output text
echo "## 4. CloudWatch alarms"
aws cloudwatch describe-alarms --region $R --query 'MetricAlarms[].[AlarmName,StateValue]' --output text
echo "## 5. from inside an app instance"
ID=$(aws ssm describe-instance-information --region $R --filters Key=PingStatus,Values=Online --query 'InstanceInformationList[0].InstanceId' --output text)
if [[ -n "$ID" && "$ID" != "None" ]]; then
  python3 - > "$T" <<'PY'
import json
c=("echo -n 'default route: '; ip route | grep default; "
   "echo -n 'dns db.lab.internal: '; dig +short +time=3 +tries=1 db.lab.internal | tr '\\n' ' '; echo; "
   "echo -n 'tcp db:5432: '; timeout 6 nc -zv db.lab.internal 5432 2>&1 | tail -1; "
   "echo -n 'nginx on localhost: '; curl -sI -m 4 localhost | head -1; "
   "echo -n 'outbound https: '; curl -s -m 8 -o /dev/null -w '%{http_code}\\n' https://aws.amazon.com || echo FAIL")
print(json.dumps({"commands":[c]}))
PY
  C=$(aws ssm send-command --region $R --instance-ids "$ID" --document-name AWS-RunShellScript --parameters "file://$T" --query Command.CommandId --output text)
  for i in $(seq 1 12); do sleep 4; st=$(aws ssm get-command-invocation --region $R --command-id "$C" --instance-id "$ID" --query Status --output text 2>/dev/null); [[ "$st" != "InProgress" && "$st" != "Pending" ]] && break; done
  echo "(instance $ID, command status: $st)"
  aws ssm get-command-invocation --region $R --command-id "$C" --instance-id "$ID" --query 'StandardOutputContent' --output text
else
  echo "no instance is Online in Systems Manager"
fi
} 2>&1 | sed "s/$ACCT/123456789012/g" | tee "$OUT"
rm -f "$T"
