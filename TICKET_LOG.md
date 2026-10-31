# Ticket Log

Fill one block per ticket. Time yourself, because these numbers go on your CV.

| # | Customer symptom | Root cause | Evidence (command / log) | Fix | Time to resolve |
|---|------------------|------------|--------------------------|-----|-----------------|
| 1 | "The app says it can't resolve the database hostname" (Ticket F). Website still served 200 from both AZs. | My diagnosis (before reveal): `db.lab.internal` CNAME points at non-existent `db-old.lab.internal`, so the VPC resolver returns NXDOMAIN. | Targets healthy (`logs/09`), SSM Online (`logs/10`), `dig` shows CNAME to db-old and `nslookup` NXDOMAIN, `nc` cannot resolve (`logs/11`), Route 53 record confirmed (`logs/12`) | Pointed the `db.lab.internal` CNAME at the real RDS endpoint (Route 53 UPSERT), then `./lab.sh reset`. Verified with `dig`, `nc` and a `psql` login through the name (`logs/15` to `logs/18`) | 12m40s to confirmed diagnosis, 14m09s to verified fix (injected 21:56:56Z, diagnosed 22:09:36Z, fixed 22:11:05Z) |
| 2 |  |  |  |  |  |
| 3 |  |  |  |  |  |
| 4 |  |  |  |  |  |
| 5 |  |  |  |  |  |
| 6 |  |  |  |  |  |
| 7 |  |  |  |  |  |
| 8 |  |  |  |  |  |

## Write-up template (for the best 2–3 tickets)

**Customer impact:**
**First hypothesis (and why it was wrong):**
**How I narrowed it down:**
**Root cause:**
**Fix and how I verified it:**
**How to prevent it next time (alarm / runbook / IaC check):**

Practise saying each of these out loud in about 2 minutes, using the STAR format (Situation, Task, Action, Result). These are your Dive Deep and Customer Obsession interview answers.
