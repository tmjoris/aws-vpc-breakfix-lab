# Ticket Log

Fill one block per ticket. Time yourself, because these numbers go on your CV.

| # | Customer symptom | Root cause | Evidence (command / log) | Fix | Time to resolve |
|---|------------------|------------|--------------------------|-----|-----------------|
| 1 | Ticket F: "The app says it can't resolve the database hostname." | The db.lab.internal CNAME pointed at db-old.lab.internal, which does not exist, so the VPC resolver answered NXDOMAIN | `logs/09-ticket-target-health`, `logs/10-ticket-ssm-status`, `logs/11-ticket-db-dns-from-instance`, `logs/12-ticket-route53-records` | Pointed the CNAME at the real RDS endpoint (a Route 53 UPSERT). | 12m40s to diagnose, 14m09s to fix, 14m54s to verify |
| 2 | Ticket C: "Users are getting 502/504 errors. Your console says our targets are unhealthy." | app-nacl outbound rules allowed only TCP 443, 80 and 5432, so nginx replies to the ALB on ephemeral ports (1024-65535) were dropped (NACLs are stateless) | `logs/t2-1-symptoms`, `logs/t2-1b-patient-curl`, `logs/t2-2-config`, `logs/t2-3-flowlog-rejects-from-app` | Added an outbound allow for TCP 1024-65535 (rule 130). | 3m30s to diagnose, 4m03s to fix, 4m48s to verify |
| 3 | Ticket A: "Our website just times out from everywhere. We didn't change anything." | public-rt had no 0.0.0.0/0 route to the internet gateway, so the ALB's subnets were not actually public | `logs/t3-1-symptoms`, `logs/t3-1b-patient-curl`, `logs/t3-2-config`, `logs/t3-3c-diagnosis-before-reveal` | Added 0.0.0.0/0 to the internet gateway on public-rt. | 4m28s to diagnose, 8m13s to fix, 8m24s to verify |
| 4 | Ticket D: "Our CloudWatch alarm says all hosts are unhealthy... but the website loads fine?" | The target group's health-check path was /healthz, which nginx does not serve (404). The ALB fails open when every target is unhealthy, so users still got pages | `logs/t4-1-symptoms`, `logs/t4-2-config`, `logs/t4-3-nginx-paths`, `logs/t4-3c-diagnosis-before-reveal` | Set the health-check path back to /. | 2m24s to diagnose, 2m33s to fix, 3m18s to verify |
| 5 | Ticket C: "Users are getting 502/504 errors. Your console says our targets are unhealthy." | app-sg allowed TCP 8080 from the ALB's security group, but nginx listens on 80 | `logs/t5-1-symptoms`, `logs/t5-2-config`, `logs/t5-3-reachability-analyzer`, `logs/t5-3c-diagnosis-before-reveal` | Allowed TCP 80 from alb-sg on app-sg. | 3m33s to diagnose, 3m47s to fix, 4m38s to verify |
| 6 | Ticket C: "Users are getting 502/504 errors. Your console says our targets are unhealthy." | app-nacl inbound rule 100 (TCP 80 from the VPC) was set to DENY, so the ALB could not reach the instances | `logs/t6-1-symptoms`, `logs/t6-2-config`, `logs/t6-3c-diagnosis-before-reveal`, `logs/t6-4-fix-nacl-inbound-80` | Replaced inbound rule 100 with an allow. | 2m35s to diagnose, 3m02s to fix, 3m48s to verify |
| 7 | Ticket E: "The app can't reach the database. Connections time out." | db-sg allowed TCP 3306 (MySQL) from the app tier, but RDS PostgreSQL listens on 5432 | `logs/t7-1-symptoms`, `logs/t7-2-config`, `logs/t7-3-db-connect-timeout`, `logs/t7-3b-flowlog-rejects-5432` | Allowed TCP 5432 from app-sg on db-sg. | 2m52s to diagnose, 3m07s to fix, 3m29s to verify |
| 8 | Ticket B: "The site works, but our instances show as offline in Session Manager and package updates hang." | private-rt sent 0.0.0.0/0 to the internet gateway instead of the NAT gateway; the instances have no public IPs, so outbound traffic had nowhere to go | `logs/t8-1-symptoms`, `logs/t8-2-config`, `logs/t8-3-ssm-state`, `logs/t8-3c-diagnosis-before-reveal` | Pointed private-rt's default route back at the NAT gateway. | 3m26s to diagnose, 3m46s to fix, 4m58s to verify |

## Write-up template (for the best 2–3 tickets)

**Customer impact:**
**First hypothesis (and why it was wrong):**
**How I narrowed it down:**
**Root cause:**
**Fix and how I verified it:**
**How to prevent it next time (alarm / runbook / IaC check):**

Practise saying each of these out loud in about 2 minutes, using the STAR format (Situation, Task, Action, Result). These are your Dive Deep and Customer Obsession interview answers.
