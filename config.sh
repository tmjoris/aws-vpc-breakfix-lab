#!/usr/bin/env bash
# Usage: ./config.sh <ticket-number> [label]
# Dumps the network and security configuration (what you would click through in the console) and the recent flow-log REJECTs.
set -uo pipefail
export PATH="$HOME/.local/bin:$PATH"
DIR="$(cd "$(dirname "$0")" && pwd)"; N="${1:?ticket number}"; LABEL="${2:-2-config}"
ACCT=$(aws sts get-caller-identity --query Account --output text); R=eu-west-1; S=breakfix-lab; OUT="$DIR/evidence/logs/t${N}-${LABEL}.txt"
VPC=$(aws ec2 describe-vpcs --region $R --filters Name=tag:Name,Values=breakfix-vpc --query 'Vpcs[0].VpcId' --output text)
LG=$(aws cloudformation describe-stacks --region $R --stack-name $S --query "Stacks[0].Outputs[?OutputKey=='FlowLogGroupName'].OutputValue" --output text)
TG=$(aws cloudformation describe-stacks --region $R --stack-name $S --query "Stacks[0].Outputs[?OutputKey=='TargetGroupArn'].OutputValue" --output text)
{
echo "# $(date -u +%FT%TZ) ticket $N: $LABEL"
echo "## route tables (name, destination, target, state)"
aws ec2 describe-route-tables --region $R --filters Name=vpc-id,Values=$VPC --output json | jq -r '.RouteTables[] | ((.Tags//[])|map(select(.Key=="Name"))|.[0].Value // "main") as $n | .Routes[] | [$n,.DestinationCidrBlock,(.GatewayId//.NatGatewayId//"-"),.State] | @tsv'
echo "## app-nacl entries (rule, direction, proto, ports, cidr, action)"
aws ec2 describe-network-acls --region $R --filters Name=vpc-id,Values=$VPC Name=tag:Name,Values=app-nacl --output json | jq -r '.NetworkAcls[0].Entries[] | [.RuleNumber,(if .Egress then "out" else "in" end),.Protocol,((.PortRange|if .==null then "all" else "\(.From)-\(.To)" end)),.CidrBlock,.RuleAction] | @tsv'
echo "## security group ingress (group, from, to, source)"
aws ec2 describe-security-groups --region $R --filters Name=vpc-id,Values=$VPC --output json | jq -r '.SecurityGroups[] | select(.GroupName!="default") | ((.Tags//[])|map(select(.Key=="Name"))|.[0].Value) as $n | .IpPermissions[] | [$n,.FromPort,.ToPort,((.UserIdGroupPairs|map(.GroupId)|join(","))+(.IpRanges|map(.CidrIp)|join(",")))] | @tsv'
echo "## target group health check"
aws elbv2 describe-target-groups --region $R --target-group-arns "$TG" --query 'TargetGroups[0].[HealthCheckProtocol,HealthCheckPort,HealthCheckPath,Matcher.HttpCode]' --output text
echo "## flow-log REJECTs, last 15 min (src, dst, dst port, count)"
Q=$(aws logs start-query --region $R --log-group-name "$LG" --start-time $(( $(date +%s) - 900 )) --end-time $(date +%s) --query-string 'filter action="REJECT" | stats count(*) as n by srcAddr, dstAddr, dstPort | sort n desc | limit 8' --query queryId --output text)
for i in $(seq 1 15); do sleep 2; st=$(aws logs get-query-results --region $R --query-id "$Q" --query status --output text); [[ "$st" == "Complete" ]] && break; done
aws logs get-query-results --region $R --query-id "$Q" --output json | jq -r '.results[] | map(select(.field!="@ptr")|.value) | @tsv'
} 2>&1 | sed "s/$ACCT/123456789012/g" | tee "$OUT"
