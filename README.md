# AWS VPC Break-Fix Lab

A production-style 3-tier AWS network that you deploy with **CloudFormation**, then **break on purpose** and troubleshoot the way an AWS Cloud Support engineer would.

```
                    Internet
                       |
               [Internet Gateway]
                       |
  +--------------------------- VPC 10.0.0.0/16 ---------------------------+
  |   AZ a                                   AZ b                         |
  |  public-a 10.0.1.0/24                   public-b 10.0.2.0/24          |
  |   [ALB node] [NAT Gateway]               [ALB node]                   |
  |        |                                      |                       |
  |  app-a 10.0.11.0/24   (app-nacl)        app-b 10.0.12.0/24            |
  |   [EC2 nginx]  <---- Auto Scaling Group ---->  [EC2 nginx]            |
  |        |                                      |                       |
  |  db-a 10.0.21.0/24                      db-b 10.0.22.0/24             |
  |   [RDS PostgreSQL]   <-- db.lab.internal (Route 53 private zone)      |
  +-----------------------------------------------------------------------+
   VPC Flow Logs -> CloudWatch Logs     CloudWatch alarms -> SNS email
   Access to instances: SSM Session Manager (no SSH keys, no bastion)
```

**What it covers from the job description:** CIDR and subnets, routing, NAT, DNS, DHCP (the VPC DHCP option set), TCP/UDP, HTTP, OSI layers 3–7, Linux troubleshooting, a database, monitoring, and root-cause analysis.

---

## 0. Cost and safety (read first)

- Running everything costs about **US$0.13/hour** in `eu-west-1` (Ireland). The NAT Gateway and the ALB are the main costs. A 4-hour session is roughly **50 US cents**; if you forget it running for a month, it's around **$95**.
- **Always run `./lab.sh destroy` when you finish a session.** Redeploying takes about 15 minutes.
- New AWS accounts get free-tier credits, which should cover this lab. Check *Billing → Free Tier* in your account.
- Set up a budget alert before anything else (step 1).

## 1. Account setup (≈30 min, one time)

1. Create an AWS account, turn on **MFA for the root user**, and stop using root after that.
2. **IAM Identity Center** (or IAM) → create an admin user for yourself, with MFA.
3. **Billing → Budgets → Create budget → "Zero spend" or a monthly $10 budget** with email alerts.
4. On your laptop (Ubuntu/WSL), install the **AWS CLI v2** and run `aws configure` (or `aws configure sso`), with region `eu-west-1`.
   *No laptop setup?* Use **AWS CloudShell** (the `>_` icon in the console). It already has the CLI; upload this folder there.
5. Check it works: `aws sts get-caller-identity`

## 2. Understand before you deploy (≈30 min)

- Open **VPC console → Create VPC → "VPC and more"** and play with the preview (don't click create). It draws the same public/private layout, which is a quick way to understand what the template builds.
- Read `template.yaml` top to bottom. For every resource, be able to say *why it exists*. Interviewers will ask, for example, "Why does the NAT Gateway sit in a public subnet?"
- Do the subnet maths yourself: how many usable IPs are in a /24 on AWS? (Answer: 251, because AWS reserves 5 addresses per subnet.)

## 3. Deploy (≈15 min, mostly waiting)

```bash
chmod +x lab.sh
./lab.sh deploy you@example.com     # email is optional; confirm the SNS email you receive
```

Open the `WebsiteUrl` output. Refresh a few times: the instance ID and AZ change because the ALB balances across both AZs.

**Look around in the console:**
- **VPC → Route tables:** compare `public-rt` (0.0.0.0/0 → igw) with `private-rt` (0.0.0.0/0 → nat).
- **VPC → Network ACLs → app-nacl:** note that it's stateless.
- **EC2 → Target groups:** both targets should be *healthy*.
- **EC2 → Instances → Connect → Session Manager:** you get a shell with no SSH key. Then run:

```bash
ip addr; ip route                      # private IP and default gateway (VPC router at .1)
cat /etc/resolv.conf                   # the VPC DNS resolver (10.0.0.2)
dig db.lab.internal                    # private DNS -> RDS endpoint
nc -zv db.lab.internal 5432            # TCP reachability to the database
curl -I localhost                      # nginx responding?
ss -tlnp                               # which ports are listening
traceroute -T -p 443 aws.amazon.com    # outbound path via the NAT Gateway
```

Connect to the database (replace REGION and ARN with the values from `./lab.sh status`):

```bash
SECRET=$(aws secretsmanager get-secret-value --region REGION --secret-id ARN --query SecretString --output text)
export PGPASSWORD=$(echo "$SECRET" | python3 -c 'import sys,json;print(json.load(sys.stdin)["password"])')
psql -h db.lab.internal -U labadmin -d labdb -c 'select version();'
```

## 4. Break-fix tickets (the important part, ≈30–45 min each)

```bash
./lab.sh break        # injects a RANDOM hidden fault (~2–5 min)
```

Then work out which "customer" is complaining by checking the symptoms below, troubleshoot, and record everything in `TICKET_LOG.md`. **Time yourself.**

Once you've written your diagnosis: `./lab.sh reveal` → read only that section of `ANSWERS.md` → apply the fix by hand in the console and confirm the symptom is gone → `./lab.sh reset`.

> If `reset` fails with "already exists", it's because your manual fix created the same route or rule that CloudFormation is trying to create. Delete your manual change and run `reset` again. Bonus: before resetting, run **CloudFormation → Stack actions → Detect drift** to see your manual change from CloudFormation's side.

### Possible customer tickets

| Ticket | What the customer says |
|---|---|
| A | "Our website just times out from everywhere. We didn't change anything." |
| B | "The site works, but our instances show as offline in Session Manager and package updates hang." |
| C | "Users are getting 502/504 errors. Your console says our targets are unhealthy." |
| D | "Our CloudWatch alarm says all hosts are unhealthy… but the website loads fine?" |
| E | "The app can't reach the database. Connections time out." |
| F | "The app says it can't resolve the database hostname." |

(Some tickets have more than one possible root cause; C has three. That's realistic.)

### Your troubleshooting toolkit

| Layer | Tool |
|---|---|
| Is DNS working? | `dig`, `nslookup`, Route 53 → Hosted zones |
| Can I reach the port? | `nc -zv host port`, `curl -v` (timeout = filtered, refused = no listener) |
| Is the app up? | `systemctl status nginx`, `ss -tlnp`, `curl -I localhost` |
| What does the load balancer think? | EC2 → Target groups → Targets → **health status reason** |
| Where is traffic dropped? | **VPC Flow Logs** (query below), **Reachability Analyzer** |
| What changed? | CloudFormation → Events, **CloudTrail → Event history** |
| What's the routing? | VPC → Route tables, `ip route` |

**CloudWatch Logs Insights** on the flow-log group (from `./lab.sh status`):

```
fields @timestamp, srcAddr, srcPort, dstAddr, dstPort, action
| filter action = "REJECT"
| sort @timestamp desc
| limit 50
```

**Reachability Analyzer** (VPC console → Reachability Analyzer): source = the ALB's network interface (EC2 → Network interfaces, filter "ELB"), destination = an app instance, port 80. It tells you exactly which component blocks the path. Each analysis costs about $0.10.

## 5. Stretch goals (pick 1–2, great interview talking points)

- **Frugality:** replace the NAT Gateway with **VPC interface endpoints** for SSM so Session Manager works without NAT, and measure the cost difference.
- **Resilience:** turn on RDS Multi-AZ, then terminate an instance and watch Auto Scaling replace it. Time the recovery.
- **Automation:** add a GitHub Actions workflow that runs `cfn-lint` on every push.
- **Write a fault of your own:** add a new `Fault` value to the template (e.g. DHCP option set pointing to a bad DNS server).

## 6. Ship it

1. `./lab.sh destroy`
2. Push this folder to GitHub (`.active-fault`, `.alert-email` and `*.log` are ignored), with your filled-in `TICKET_LOG.md` and 2–3 screenshots (healthy target group, a flow-log REJECT, a Reachability Analyzer result).
3. Add the repo link to your CV.

### CV bullets to adapt once you have *your* numbers

- *Deployed a highly available 3-tier AWS environment (VPC across 2 AZs, ALB, EC2 Auto Scaling, RDS PostgreSQL, NAT Gateway, Route 53 private DNS) as code with CloudFormation, rebuildable in ~15 minutes.*
- *Diagnosed **N** injected network faults (route tables, stateless NACL ephemeral ports, security groups, DNS, health checks) using VPC Flow Logs, Reachability Analyzer, dig, nc and curl, cutting average resolution from **X** to **Y** minutes.*
- **Tools:** CloudFormation, VPC, EC2, ALB, Auto Scaling, RDS, Route 53, CloudWatch, SNS, Systems Manager, IAM, Linux (Amazon Linux 2023), Bash.

---

## Evidence: healthy baseline (deployed 2026-10-31, eu-west-1)

The stack deployed in about 9 minutes (`CREATE_COMPLETE`). Command output is in `evidence/logs/` and console screenshots are in `evidence/screenshots/`.

| Check | Result | Evidence |
|---|---|---|
| Stack | `CREATE_COMPLETE` | `screenshots/14-stack-create-complete.jpg`, `logs/03-deploy.txt` |
| Target group | 2/2 targets healthy, one per AZ | `screenshots/02-target-group-healthy.jpg`, `logs/05-target-health-healthy.txt` |
| Load balancing | Responses alternate between eu-west-1a and eu-west-1b | `logs/06-website-balancing.txt` |
| Public routing | `0.0.0.0/0` -> Internet Gateway | `screenshots/04-public-rt-routes-igw.jpg` |
| Private routing | `0.0.0.0/0` -> NAT Gateway | `screenshots/05-private-rt-routes-nat.jpg` |
| App NACL | Inbound 80 and 1024-65535, outbound allow all | `screenshots/07-app-nacl-inbound.jpg`, `screenshots/08-app-nacl-outbound.jpg` |
| Instances | 2x t3.micro, 3/3 status checks, one per AZ | `screenshots/09-ec2-instances-two-azs.jpg` |
| ALB | Active, internet-facing, 2 AZs | `screenshots/10-alb-active.jpg` |
| Database | RDS PostgreSQL `db.t4g.micro` available | `screenshots/11-rds-available.jpg` |
| Alarms | Both CloudWatch alarms in OK, actions enabled | `screenshots/12-cloudwatch-alarms-ok.jpg` |
| Private DNS | `lab.internal` zone; `db.lab.internal` resolves to the RDS endpoint (10.0.21.201) | `screenshots/13-route53-private-zone.jpg`, `logs/07-on-instance-diagnostics.txt` |
| DB reachability | `nc -zv db.lab.internal 5432` connected | `logs/07-on-instance-diagnostics.txt` |
| Cost guard | $10 monthly budget with 50% and 100% email alerts | `logs/02-budget-verify.txt` |
