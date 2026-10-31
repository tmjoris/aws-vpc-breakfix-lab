# Answers (don't open until you've written your diagnosis)

Run `./lab.sh reveal` first to see which fault was active, then read only that section.

---

## public-no-igw-route
**Root cause:** The public route table has no `0.0.0.0/0 → Internet Gateway` route. The ALB sits in "public" subnets that aren't actually public, so internet traffic can't reach it.
**How you find it:** `curl -v` times out (no HTTP response at all, not even a 5xx). Targets are healthy, because the ALB can still reach the instances inside the VPC. VPC → Route tables → `public-rt` → Routes shows only the `local` route.
**Fix:** Add the route `0.0.0.0/0 → igw-…` to `public-rt`.
**Lesson:** A subnet is "public" only because of its route table. A timeout is a network-path problem; a 5xx means you reached the load balancer.

## private-no-nat-route
**Root cause:** The private route table sends `0.0.0.0/0` to the **Internet Gateway** instead of the NAT Gateway. The instances have no public IPs, so their outbound traffic is dropped.
**How you find it:** The website still works, because inbound traffic comes through the ALB. But the instances are "offline" in Systems Manager / Session Manager (the SSM agent needs outbound HTTPS), and `dnf` hangs. `private-rt` shows `0.0.0.0/0 → igw-…`.
**Fix:** Change the route target to the NAT Gateway (`nat-…`).
**Lesson:** Private instances need NAT for outbound traffic. An IGW only works for instances that have a public IP.

## nacl-block-http
**Root cause:** The `app-nacl` inbound rule 100 is **DENY** TCP 80 from 10.0.0.0/16, so the ALB can't reach the instances.
**How you find it:** 502/504 errors from the ALB, and targets unhealthy ("Request timed out"). Flow Logs show `REJECT` on `dstPort = 80` to the instance IPs. The security groups look correct.
**Fix:** Change rule 100 to ALLOW.
**Lesson:** NACLs are checked before security groups, and rules are evaluated lowest number first.

## nacl-no-ephemeral
**Root cause:** The `app-nacl` **outbound** rules only allow ports 443, 80 and 5432. Responses from the instance back to the ALB go to *ephemeral ports* (1024–65535), so they're dropped.
**How you find it:** It looks exactly like nacl-block-http (unhealthy targets, 502/504), but the inbound rules are fine. Flow Logs show the **outbound** packets from the instance (`srcPort = 80`) being `REJECT`ed.
**Fix:** Add an outbound ALLOW for TCP 1024–65535 to 10.0.0.0/16 (or restore allow-all).
**Lesson:** NACLs are **stateless**: return traffic needs its own rule. Security groups are **stateful** and don't. This is a classic interview question.

## sg-wrong-port
**Root cause:** `app-sg` allows TCP **8080** from the ALB, but nginx listens on **80**.
**How you find it:** Unhealthy targets (timeout), and the NACLs are fine. Reachability Analyzer from the ALB's network interface to an instance on port 80 says *not reachable* and points at the security group. `ss -tlnp` on the instance shows nginx on :80.
**Fix:** Change the `app-sg` ingress rule to TCP 80 from `alb-sg`.
**Lesson:** Check what port the app actually listens on against what's allowed in.

## health-check-path
**Root cause:** The target group's health check path is `/healthz`, which nginx doesn't serve, so it returns 404.
**How you find it:** The **unhealthy-hosts alarm fires but the website loads.** When *all* targets are unhealthy, the ALB "fails open" and sends traffic to all of them anyway. The target health reason says `Health checks failed with these codes: [404]`. `curl -I localhost/healthz` on the instance returns 404.
**Fix:** Set the health check path to `/` (or add a real `/healthz` endpoint).
**Lesson:** Read the target health *reason code*. The network path can be fine while the app config is wrong.

## db-sg-wrong-port
**Root cause:** `db-sg` allows TCP **3306** (MySQL) instead of **5432** (PostgreSQL).
**How you find it:** `dig db.lab.internal` resolves fine, but `nc -zv db.lab.internal 5432` **times out**. A timeout points to a firewall; "connection refused" would mean the host was reached but nothing was listening.
**Fix:** Change the `db-sg` ingress rule to TCP 5432 from `app-sg`.
**Lesson:** Timeout = filtered (SG/NACL/route). Refused = reachable but no listener.

## dns-wrong-record
**Root cause:** The Route 53 private zone record `db.lab.internal` is a CNAME to `db-old.lab.internal`, which doesn't exist.
**How you find it:** `dig db.lab.internal` returns the CNAME and then no address (NXDOMAIN on the target). Connecting with `psql` fails with "could not translate host name". `nc` straight to the RDS endpoint (from Outputs/Console) works.
**Fix:** Point the CNAME at the real RDS endpoint.
**Lesson:** Always test name resolution separately from connectivity: `dig` first, then `nc`.
