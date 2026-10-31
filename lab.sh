#!/usr/bin/env bash
# AWS VPC Break-Fix Lab helper
# Usage:
#   ./lab.sh deploy [email]   create/restore a healthy environment (Fault=none)
#   ./lab.sh break            inject a RANDOM hidden fault (a "customer ticket")
#   ./lab.sh break <fault>    inject a specific fault
#   ./lab.sh reveal           show which fault is active
#   ./lab.sh reset            remove the fault (back to healthy)
#   ./lab.sh status           show stack outputs (website URL etc.)
#   ./lab.sh destroy          delete everything (do this after every session!)
set -euo pipefail

STACK="${STACK:-breakfix-lab}"
REGION="${AWS_REGION:-eu-west-1}"
DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="$DIR/template.yaml"
FAULT_FILE="$DIR/.active-fault"
EMAIL_FILE="$DIR/.alert-email"
FAULTS=(public-no-igw-route private-no-nat-route nacl-block-http nacl-no-ephemeral
        sg-wrong-port health-check-path db-sg-wrong-port dns-wrong-record)

apply() {  # $1 = fault
  local email=""; [[ -f "$EMAIL_FILE" ]] && email="$(cat "$EMAIL_FILE")"
  aws cloudformation deploy --region "$REGION" --stack-name "$STACK" \
    --template-file "$TEMPLATE" --capabilities CAPABILITY_IAM \
    --no-fail-on-empty-changeset \
    --parameter-overrides "Fault=$1" "AlertEmail=$email"
}

case "${1:-}" in
  deploy)
    [[ -n "${2:-}" ]] && echo "$2" > "$EMAIL_FILE"
    echo "Deploying healthy environment to $REGION (first run takes ~15 min, RDS is slow)..."
    apply none; echo none > "$FAULT_FILE"
    "$0" status ;;
  break)
    if [[ -n "${2:-}" ]]; then f="$2"; else f="${FAULTS[RANDOM % ${#FAULTS[@]}]}"; fi
    echo "Injecting a fault... (output hidden so you don't see the answer)"
    apply "$f" > "$DIR/.last-break.log" 2>&1 || { echo "Deploy failed - see .last-break.log"; exit 1; }
    echo "$f" > "$FAULT_FILE"
    echo "Done. A customer just opened a ticket. Pick its symptom from README.md and start troubleshooting." ;;
  reveal)
    echo "Active fault: $(cat "$FAULT_FILE" 2>/dev/null || echo unknown)"; echo "Explanation: see ANSWERS.md" ;;
  reset)
    echo "Restoring healthy configuration..."
    apply none; echo none > "$FAULT_FILE" ;;
  status)
    aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK" \
      --query "Stacks[0].Outputs[].[OutputKey,OutputValue]" --output table ;;
  destroy)
    echo "Deleting stack $STACK in $REGION..."
    aws cloudformation delete-stack --region "$REGION" --stack-name "$STACK"
    aws cloudformation wait stack-delete-complete --region "$REGION" --stack-name "$STACK"
    rm -f "$FAULT_FILE"; echo "Deleted. Nothing is billing you any more." ;;
  *)
    sed -n '2,10p' "$0" ;;
esac
