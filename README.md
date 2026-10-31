# AWS VPC Break-Fix Lab: results

I deployed a 3-tier AWS network with CloudFormation, had faults injected one at a time, and troubleshot each the way a Cloud Support engineer would: start from the symptom, find the layer, prove the cause, fix it, verify, and reset. This page is the outcome. How to run the lab yourself is in [SETUP.md](SETUP.md).

**What was built:** a VPC across 2 AZs with public, app and database subnets, an Application Load Balancer, an Auto Scaling group of 2 nginx instances, RDS PostgreSQL, a NAT Gateway, a Route 53 private zone (`db.lab.internal`), VPC Flow Logs to CloudWatch, CloudWatch alarms to SNS, and Session Manager access with no SSH keys. The stack deployed in about 9 minutes and is rebuildable from one template.

## Summary: 8 of 8 tickets resolved

| # | Ticket | Fault | Root cause | Diagnosed | Fixed | Verified |
|---|---|---|---|---|---|---|
| 1 | F | `dns-wrong-record` | Database CNAME pointed at a name that does not exist | 12m40s | 14m09s | 14m54s |
| 2 | C | `nacl-no-ephemeral` | App NACL outbound rules lacked the ephemeral port range | 3m30s | 4m03s | 4m48s |
| 3 | A | `public-no-igw-route` | Public route table had no route to the internet gateway | 4m28s | 8m13s | 8m24s |
| 4 | D | `health-check-path` | Target group probed /healthz, which nginx does not serve | 2m24s | 2m33s | 3m18s |
| 5 | C | `sg-wrong-port` | App security group allowed 8080, nginx listens on 80 | 3m33s | 3m47s | 4m38s |
| 6 | C | `nacl-block-http` | App NACL denied inbound HTTP from the VPC | 2m35s | 3m02s | 3m48s |
| 7 | E | `db-sg-wrong-port` | DB security group allowed 3306, PostgreSQL uses 5432 | 2m52s | 3m07s | 3m29s |
| 8 | B | `private-no-nat-route` | Private default route pointed at the internet gateway, not the NAT | 3m26s | 3m46s | 4m58s |

Times run from the moment the fault finished deploying to the moment I confirmed the diagnosis, applied the fix, and saw the symptom gone. Across tickets 2 to 8 the averages were **3m15s to diagnose, 4m04s to fix and 4m46s to verify**. Ticket 1 is left out of the averages, because about 9 of its minutes were manual curl testing before I had the triage scripts.

How the numbers were produced, so they are not oversold:
- From ticket 2 onward I used two small scripts, [`symptoms.sh`](symptoms.sh) (what a customer sees) and [`config.sh`](config.sh) (routes, NACL, security groups, health check, recent flow-log REJECTs). They run CLI commands, so the times are not comparable to clicking through the console.
- The faults came from a shuffled queue I did not read. I knew the set of eight, not the order, and each diagnosis was written to a timestamped file *before* running `./lab.sh reveal` (`t<N>-3c-diagnosis-before-reveal.txt`; ticket 1's diagnosis went into `TICKET_LOG.md` before its reveal, in the first version of that file).
- Several tickets share a symptom, which is the point. Tickets 2, 5 and 6 all showed a timeout with unhealthy targets and needed different evidence to tell apart.
- Fixes were made with the CLI equivalent of the console change, then I ran `./lab.sh reset`. Where my manual change would have collided with the template (a route, a security-group rule), I removed it first, as the lab warns.

## Quick diagnosis guide

What each symptom pointed to, from this run:

| What you see | First checks | Faults it was |
|---|---|---|
| `curl` hangs at the TCP connect, no HTTP response at all | Route table of the public subnets | `public-no-igw-route` |
| `curl` waits, then the ALB returns 504; targets `Target.Timeout` | Where the instance replies are dropped (NACL out), where requests are dropped (NACL in, security group) | `nacl-no-ephemeral`, `nacl-block-http`, `sg-wrong-port` |
| Site loads, targets `Target.ResponseCodeMismatch` | The health-check path against what the app serves | `health-check-path` |
| Site loads, instances silent in Systems Manager, outbound HTTPS fails | Route table of the private subnets | `private-no-nat-route` |
| Site loads, database connection times out | Security group on the database, flow-log REJECTs on the DB port | `db-sg-wrong-port` |
| Site loads, hostname does not resolve | `dig` against the private zone, then `nc` to the endpoint directly | `dns-wrong-record` |

Two lessons from the data itself: a timeout means a filter dropped the packet and a 5xx means you reached the load balancer; and the flow-log REJECT list is full of internet scanners (ports 23 and 443 on the ALB), so always filter it to the source or port you are investigating.

## Ticket write-ups

### Ticket 1: F (`dns-wrong-record`)

**Customer said:** "The app says it can't resolve the database hostname."

**What I saw:** Website loads fine from both AZs; the app cannot resolve the database hostname.

**How I narrowed it down:**
1. curl against the ALB returned 200 from both AZs, which ruled out the 'site times out' and 502/504 tickets.
2. Both targets were healthy and both instances were Online in Systems Manager, which ruled out the health-check and NAT tickets.
3. On an instance, dig db.lab.internal returned a CNAME to db-old.lab.internal, nslookup returned NXDOMAIN, and nc could not resolve the name.
4. Route 53 showed the same record, and the real RDS endpoint was a different name.
5. To separate DNS from connectivity, nc straight to the RDS endpoint connected to 10.0.21.201:5432, so the network path and the security groups were fine.

**Root cause:** The db.lab.internal CNAME pointed at db-old.lab.internal, which does not exist, so the VPC resolver answered NXDOMAIN.

**Fix and verification:** Pointed the CNAME at the real RDS endpoint (a Route 53 UPSERT). dig returned the endpoint and 10.0.21.201, nc -zv db.lab.internal 5432 connected, and psql logged in to labdb through the name. The psql error at the end of logs/17 is my own script failing to read the password, not the database; logs/18 has the successful login. ./lab.sh reset then restored the stack to its template state.

**Prevention:** Test name resolution and connectivity separately (dig first, then nc). Manage DNS records in the same template as the database so the record cannot go stale on its own. Alarm on application connection errors, not only on target health, because here the load balancer never noticed.

**Note on the time:** The clock for this ticket includes about 9 minutes of manual curl testing from a laptop before the on-instance checks started; the hands-on diagnosis was about 3 minutes.

**Times:** diagnosed 12m40s, fixed 14m09s, verified 14m54s.

**Evidence:** [09-ticket-target-health](evidence/logs/09-ticket-target-health.txt), [10-ticket-ssm-status](evidence/logs/10-ticket-ssm-status.txt), [11-ticket-db-dns-from-instance](evidence/logs/11-ticket-db-dns-from-instance.txt), [12-ticket-route53-records](evidence/logs/12-ticket-route53-records.txt), [13-ticket-actual-rds-endpoint](evidence/logs/13-ticket-actual-rds-endpoint.txt), [14-ticket-nc-direct-to-rds](evidence/logs/14-ticket-nc-direct-to-rds.txt), [15-ticket-fix-route53-upsert](evidence/logs/15-ticket-fix-route53-upsert.txt), [17-ticket-verify-after-fix](evidence/logs/17-ticket-verify-after-fix.txt), [18-ticket-psql-after-fix](evidence/logs/18-ticket-psql-after-fix.txt), [20-post-reset-dns-check](evidence/logs/20-post-reset-dns-check.txt), [screenshot](evidence/screenshots/15-ticket-f-broken-cname.jpg), [screenshot](evidence/screenshots/16-ticket-f-fixed-cname.jpg)

### Ticket 2: C (`nacl-no-ephemeral`)

**Customer said:** "Users are getting 502/504 errors. Your console says our targets are unhealthy."

**What I saw:** Website times out; ALB returns 504 after ~17s; both targets unhealthy (Target.Timeout).

**How I narrowed it down:**
1. Website timed out, but the patient curl got a 504 from the ALB, so the ALB itself was reachable.
2. Targets were unhealthy with Target.Timeout, yet from inside an instance nginx answered on localhost and DNS, the DB and outbound HTTPS all worked. The instances were fine.
3. Routes and security groups were correct (app-sg allowed 80 from alb-sg).
4. The app-nacl outbound rules allowed only 443, 80 and 5432. Nothing allowed the reply to the ALB's ephemeral port.
5. Flow logs confirmed it: REJECTs with source port 80 from the app instances to the two ALB nodes, 40 to 50 each.

**Root cause:** app-nacl outbound rules allowed only TCP 443, 80 and 5432, so nginx replies to the ALB on ephemeral ports (1024-65535) were dropped (NACLs are stateless).

**Fix and verification:** Added an outbound allow for TCP 1024-65535 (rule 130). Targets went healthy within 45 seconds and the site returned 200 from both AZs. After the reset I removed the manual rule so only the template's rules remain.

**Prevention:** Remember that NACLs are stateless: every allowed inbound port needs an outbound ephemeral-range rule. Prefer security groups for per-instance control and keep NACLs simple. The unhealthy-host alarm stayed OK while the site was down, because it needs two bad periods, so alarm on ALB 5xx and request timeouts too.

**Times:** diagnosed 3m30s, fixed 4m03s, verified 4m48s.

**Evidence:** [t2-1-symptoms](evidence/logs/t2-1-symptoms.txt), [t2-1b-patient-curl](evidence/logs/t2-1b-patient-curl.txt), [t2-2-config](evidence/logs/t2-2-config.txt), [t2-3-flowlog-rejects-from-app](evidence/logs/t2-3-flowlog-rejects-from-app.txt), [t2-4-fix-nacl-egress](evidence/logs/t2-4-fix-nacl-egress.txt), [t2-5-after-fix](evidence/logs/t2-5-after-fix.txt), [t2-6-remove-manual-rule](evidence/logs/t2-6-remove-manual-rule.txt), [t2-7-after-reset](evidence/logs/t2-7-after-reset.txt), [screenshot](evidence/screenshots/17-ticket2-targets-unhealthy.jpg)

### Ticket 3: A (`public-no-igw-route`)

**Customer said:** "Our website just times out from everywhere. We didn't change anything."

**What I saw:** Website times out from everywhere; the TCP connection to the ALB never completes.

**How I narrowed it down:**
1. Six curls timed out at 8s, and a patient curl (20s) never completed the TCP connect. No HTTP response at all, not even a 5xx, so traffic never reached the ALB.
2. Targets were healthy and SSM showed both instances Online, so the ALB-to-instance path and the instances were fine.
3. The route-table dump showed public-rt with only the local route: no 0.0.0.0/0 to the internet gateway.
4. The flow-log REJECTs were only the usual internet scanners, a useful reminder that REJECT noise is not the fault.

**Root cause:** public-rt had no 0.0.0.0/0 route to the internet gateway, so the ALB's subnets were not actually public.

**Fix and verification:** Added 0.0.0.0/0 to the internet gateway on public-rt. The site returned 200 from both AZs within about 10 seconds. I then deleted my manual route before `./lab.sh reset`, because the template creates the same route and CloudFormation would fail with 'already exists'. The fix time includes about 4 minutes lost to a frozen browser tab while trying to screenshot the route table.

**Prevention:** A timeout means a network-path problem and a 5xx means you reached the load balancer, so start by finding out which one it is. Keep route tables in IaC, run drift detection, and add a synthetic check that requests the public URL from outside the VPC.

**Times:** diagnosed 4m28s, fixed 8m13s, verified 8m24s.

**Evidence:** [t3-1-symptoms](evidence/logs/t3-1-symptoms.txt), [t3-1b-patient-curl](evidence/logs/t3-1b-patient-curl.txt), [t3-2-config](evidence/logs/t3-2-config.txt), [t3-3c-diagnosis-before-reveal](evidence/logs/t3-3c-diagnosis-before-reveal.txt), [t3-4-fix-add-igw-route](evidence/logs/t3-4-fix-add-igw-route.txt), [t3-5-after-fix](evidence/logs/t3-5-after-fix.txt), [t3-6-remove-manual-route](evidence/logs/t3-6-remove-manual-route.txt), [t3-7-after-reset](evidence/logs/t3-7-after-reset.txt)

### Ticket 4: D (`health-check-path`)

**Customer said:** "Our CloudWatch alarm says all hosts are unhealthy... but the website loads fine?"

**What I saw:** Website loads fine, but both targets are unhealthy (Target.ResponseCodeMismatch) and the unhealthy-host alarm is the only sign.

**How I narrowed it down:**
1. The website returned 200 from both AZs, so nothing looked broken from outside.
2. The target group showed both targets unhealthy with Target.ResponseCodeMismatch, while nginx on the instance, DNS, the database and outbound access all worked.
3. The config dump showed the health-check path as /healthz where the baseline was /.
4. On an instance, curl returned 200 for / and 404 for /healthz, so the app was fine and the probe was asking for a page that does not exist.

**Root cause:** The target group's health-check path was /healthz, which nginx does not serve (404). The ALB fails open when every target is unhealthy, so users still got pages.

**Fix and verification:** Set the health-check path back to /. Both targets turned healthy in under a minute. The reset then ran with no conflict, because it only sets the same value.

**Prevention:** Read the target health reason code before touching the network. Define the health endpoint in the same repo as the app, and test it in the deploy pipeline. This is the dangerous kind of failure, because when every target looks unhealthy the ALB keeps sending traffic, so a bad probe can hide behind a working site.

**Times:** diagnosed 2m24s, fixed 2m33s, verified 3m18s.

**Evidence:** [t4-1-symptoms](evidence/logs/t4-1-symptoms.txt), [t4-2-config](evidence/logs/t4-2-config.txt), [t4-3-nginx-paths](evidence/logs/t4-3-nginx-paths.txt), [t4-3c-diagnosis-before-reveal](evidence/logs/t4-3c-diagnosis-before-reveal.txt), [t4-4-fix-health-check-path](evidence/logs/t4-4-fix-health-check-path.txt), [t4-5-after-fix](evidence/logs/t4-5-after-fix.txt), [t4-7-after-reset](evidence/logs/t4-7-after-reset.txt)

### Ticket 5: C (`sg-wrong-port`)

**Customer said:** "Users are getting 502/504 errors. Your console says our targets are unhealthy."

**What I saw:** Website times out; targets unhealthy (Target.Timeout); NACLs, routes and the instances themselves look fine.

**How I narrowed it down:**
1. The site timed out and both targets were unhealthy with Target.Timeout, but nginx, DNS, the database and outbound access all worked on the instances.
2. Routes and NACL rules were unchanged from the baseline, which ruled out the stateless-NACL cause from ticket 2.
3. app-sg allowed port 8080 where the baseline had 80.
4. Flow logs showed the opposite direction from ticket 2: REJECTs with the ALB nodes as the source and port 80 on the instances as the destination.
5. Reachability Analyzer from the ALB's network interface to an instance on TCP 80 returned NetworkPathFound=false with ENI_SG_RULES_MISMATCH on app-sg.

**Root cause:** app-sg allowed TCP 8080 from the ALB's security group, but nginx listens on 80.

**Fix and verification:** Allowed TCP 80 from alb-sg on app-sg. The site returned 200 and both targets went healthy within a minute, and a second Reachability Analyzer run returned NetworkPathFound=true. I revoked my manual rule before `./lab.sh reset`, because the template would otherwise fail creating the same rule.

**Prevention:** Check what port the app listens on (ss -tlnp) against what the security group allows. Keep the port in one place in the template (a parameter used by both the listener and the group). Reachability Analyzer is the fastest way to find which component blocks a path, so run it early on a timeout.

**Times:** diagnosed 3m33s, fixed 3m47s, verified 4m38s.

**Evidence:** [t5-1-symptoms](evidence/logs/t5-1-symptoms.txt), [t5-2-config](evidence/logs/t5-2-config.txt), [t5-3-reachability-analyzer](evidence/logs/t5-3-reachability-analyzer.txt), [t5-3c-diagnosis-before-reveal](evidence/logs/t5-3c-diagnosis-before-reveal.txt), [t5-4-fix-sg-allow-80](evidence/logs/t5-4-fix-sg-allow-80.txt), [t5-5-after-fix](evidence/logs/t5-5-after-fix.txt), [t5-5b-reachability-after-fix](evidence/logs/t5-5b-reachability-after-fix.txt), [t5-6-remove-manual-rule](evidence/logs/t5-6-remove-manual-rule.txt), [t5-7-after-reset](evidence/logs/t5-7-after-reset.txt)

### Ticket 6: C (`nacl-block-http`)

**Customer said:** "Users are getting 502/504 errors. Your console says our targets are unhealthy."

**What I saw:** Website times out; targets unhealthy (Target.Timeout); the security groups look correct.

**How I narrowed it down:**
1. The site timed out and both targets were unhealthy with Target.Timeout, while nginx, DNS, the database and outbound access worked on the instances.
2. app-sg allowed 80 from alb-sg, exactly as in the baseline, so this was not the security-group ticket.
3. Flow logs showed REJECTs with the ALB nodes as the source and port 80 on the instances as the destination, the same shape as the security-group ticket, so the logs alone cannot tell the two apart.
4. The NACL dump settled it: inbound rule 100 (TCP 80 from 10.0.0.0/16) was deny where the baseline had allow.

**Root cause:** app-nacl inbound rule 100 (TCP 80 from the VPC) was set to DENY, so the ALB could not reach the instances.

**Fix and verification:** Replaced inbound rule 100 with an allow. Targets went healthy in about 45 seconds. The reset then ran cleanly because it only changes the rule's action.

**Prevention:** NACLs are evaluated before security groups and lowest rule number first. When flow logs show REJECTs, work out which layer produced them: a security group and a NACL give the same symptom, so compare both against the baseline. Drift detection on the NACL would have flagged this directly.

**Times:** diagnosed 2m35s, fixed 3m02s, verified 3m48s.

**Evidence:** [t6-1-symptoms](evidence/logs/t6-1-symptoms.txt), [t6-2-config](evidence/logs/t6-2-config.txt), [t6-3c-diagnosis-before-reveal](evidence/logs/t6-3c-diagnosis-before-reveal.txt), [t6-4-fix-nacl-inbound-80](evidence/logs/t6-4-fix-nacl-inbound-80.txt), [t6-5-after-fix](evidence/logs/t6-5-after-fix.txt), [t6-7-after-reset](evidence/logs/t6-7-after-reset.txt)

### Ticket 7: E (`db-sg-wrong-port`)

**Customer said:** "The app can't reach the database. Connections time out."

**What I saw:** Website and targets are healthy, but the app cannot connect to the database: connections time out.

**How I narrowed it down:**
1. The website, target health, SSM and DNS were all fine, so the front end looked healthy.
2. From an app instance, db.lab.internal resolved correctly, but nc to port 5432 ended in TIMEOUT, and psql hung. A timeout means a filter is dropping the packets; a refusal would mean a closed port.
3. The security-group dump showed db-sg allowing 3306 where the baseline had 5432.
4. A narrow flow-log query for port 5432 showed REJECTs from both app instances to the database at 10.0.21.201. The broad 15-minute REJECT summary was misleading here, because it still held the previous ticket's rejects.

**Root cause:** db-sg allowed TCP 3306 (MySQL) from the app tier, but RDS PostgreSQL listens on 5432.

**Fix and verification:** Allowed TCP 5432 from app-sg on db-sg. nc connected and a psql login to labdb succeeded within about 20 seconds. I revoked my manual rule before `./lab.sh reset`, because the template would otherwise fail creating the same rule.

**Prevention:** Timeout means filtered (security group, NACL or route) and refused means reachable with no listener. Keep the database port in one template parameter used by both the instance and the security group. Alarm on database connection errors from the application, because the load balancer never notices this failure.

**Times:** diagnosed 2m52s, fixed 3m07s, verified 3m29s.

**Evidence:** [t7-1-symptoms](evidence/logs/t7-1-symptoms.txt), [t7-2-config](evidence/logs/t7-2-config.txt), [t7-3-db-connect-timeout](evidence/logs/t7-3-db-connect-timeout.txt), [t7-3b-flowlog-rejects-5432](evidence/logs/t7-3b-flowlog-rejects-5432.txt), [t7-3c-diagnosis-before-reveal](evidence/logs/t7-3c-diagnosis-before-reveal.txt), [t7-4-fix-db-sg-allow-5432](evidence/logs/t7-4-fix-db-sg-allow-5432.txt), [t7-5-after-fix-db-login](evidence/logs/t7-5-after-fix-db-login.txt), [t7-6-remove-manual-rule](evidence/logs/t7-6-remove-manual-rule.txt), [t7-7-after-reset](evidence/logs/t7-7-after-reset.txt)

### Ticket 8: B (`private-no-nat-route`)

**Customer said:** "The site works, but our instances show as offline in Session Manager and package updates hang."

**What I saw:** Website works, but the instances stop answering Systems Manager commands and cannot reach the internet.

**How I narrowed it down:**
1. The website, target health and DNS were all fine, because inbound traffic reaches the instances through the ALB.
2. The first on-instance command stayed Pending, and Systems Manager's last ping from both instances predated the fault by minutes, even though the status still read Online (it lags).
3. The route dump showed private-rt with 0.0.0.0/0 pointing at the internet gateway where the baseline had the NAT gateway.
4. No REJECTs were involved. Packets leave toward an internet gateway that cannot translate for an instance without a public IP, so the loss is silent.

**Root cause:** private-rt sent 0.0.0.0/0 to the internet gateway instead of the NAT gateway; the instances have no public IPs, so outbound traffic had nowhere to go.

**Fix and verification:** Pointed private-rt's default route back at the NAT gateway. The SSM command that had been stuck completed, and outbound HTTPS from the instance returned 200 within about a minute. The reset then updated the same route with no conflict.

**Prevention:** An internet gateway only helps instances that have public IPs; private subnets need NAT. Alarm on Systems Manager ping status (ConnectionLost) and on NAT gateway traffic, because the website stays up and nothing else notices. Keep the route in IaC and use drift detection.

**Times:** diagnosed 3m26s, fixed 3m46s, verified 4m58s.

**Evidence:** [t8-1-symptoms](evidence/logs/t8-1-symptoms.txt), [t8-2-config](evidence/logs/t8-2-config.txt), [t8-3-ssm-state](evidence/logs/t8-3-ssm-state.txt), [t8-3c-diagnosis-before-reveal](evidence/logs/t8-3c-diagnosis-before-reveal.txt), [t8-4-fix-private-route-to-nat](evidence/logs/t8-4-fix-private-route-to-nat.txt), [t8-5-after-fix](evidence/logs/t8-5-after-fix.txt), [t8-7-after-reset](evidence/logs/t8-7-after-reset.txt)

## Healthy baseline

| Check | Result | Evidence |
|---|---|---|
| Stack | `CREATE_COMPLETE` | [screenshot](evidence/screenshots/14-stack-create-complete.jpg), [log](evidence/logs/03-deploy.txt) |
| Target group | 2/2 healthy, one per AZ | [screenshot](evidence/screenshots/02-target-group-healthy.jpg), [log](evidence/logs/05-target-health-healthy.txt) |
| Load balancing | Responses alternate between eu-west-1a and eu-west-1b | [log](evidence/logs/06-website-balancing.txt) |
| Public routing | `0.0.0.0/0` to the Internet Gateway | [screenshot](evidence/screenshots/04-public-rt-routes-igw.jpg) |
| Private routing | `0.0.0.0/0` to the NAT Gateway | [screenshot](evidence/screenshots/05-private-rt-routes-nat.jpg) |
| App NACL | Inbound 80 and 1024-65535, outbound allow all | [inbound](evidence/screenshots/07-app-nacl-inbound.jpg), [outbound](evidence/screenshots/08-app-nacl-outbound.jpg) |
| Instances | 2x t3.micro, 3/3 status checks, one per AZ | [screenshot](evidence/screenshots/09-ec2-instances-two-azs.jpg) |
| ALB | Active, internet-facing, 2 AZs | [screenshot](evidence/screenshots/10-alb-active.jpg) |
| Database | RDS PostgreSQL `db.t4g.micro` available | [screenshot](evidence/screenshots/11-rds-available.jpg) |
| Alarms | Both CloudWatch alarms in OK | [screenshot](evidence/screenshots/12-cloudwatch-alarms-ok.jpg) |
| Private DNS | `db.lab.internal` resolves to the RDS endpoint | [screenshot](evidence/screenshots/13-route53-private-zone.jpg), [log](evidence/logs/07-on-instance-diagnostics.txt) |

## Evidence

- Command output with UTC timestamps: [`evidence/logs/`](evidence/logs/). Files named `t<N>-...` belong to ticket N, in the order symptoms, config, diagnosis, fix, after-fix, reset.
- Console screenshots: [`evidence/screenshots/`](evidence/screenshots/). Healthy baseline 01 to 14; ticket 1 [broken](evidence/screenshots/15-ticket-f-broken-cname.jpg) and [fixed](evidence/screenshots/16-ticket-f-fixed-cname.jpg); ticket 2 [targets unhealthy](evidence/screenshots/17-ticket2-targets-unhealthy.jpg). The console screenshot tool froze repeatedly part-way through, so tickets 3 to 8 are evidenced by command output rather than screenshots.
- Ticket notes: [TICKET_LOG.md](TICKET_LOG.md)
- The AWS account ID is redacted in screenshots and logs (shown as `123456789012`).

## Cost

The lab runs at about $0.13 per hour in eu-west-1, mostly the NAT Gateway and the ALB. A $10 monthly budget with 50% and 100% email alerts guards it, and the stack is deleted with `./lab.sh destroy` when work ends.
