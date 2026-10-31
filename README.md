# AWS VPC Break-Fix Lab: results

I deployed a 3-tier AWS network with CloudFormation, had a hidden fault injected, and troubleshot it the way a Cloud Support engineer would. This page is the outcome. How to run the lab yourself is in [SETUP.md](SETUP.md).

**What was built:** a VPC across 2 AZs with public, app and database subnets, an Application Load Balancer, an Auto Scaling group of 2 nginx instances, RDS PostgreSQL, a NAT Gateway, a Route 53 private zone (`db.lab.internal`), VPC Flow Logs to CloudWatch, CloudWatch alarms to SNS, and Session Manager access with no SSH keys. The stack deployed in about 9 minutes and is rebuildable from one template.

## Results so far

| Ticket | Symptom | Root cause | Time to diagnose | Time to verified fix |
|---|---|---|---|---|
| F | "The app says it can't resolve the database hostname" | The `db.lab.internal` CNAME pointed at `db-old.lab.internal`, which does not exist | 12m40s | 14m09s |

Times run from fault injection (21:56:56Z). They include about 9 minutes of manual `curl` testing from a laptop before the on-instance checks started, so the hands-on diagnosis itself was about 3 minutes. One fault of the eight in the template has been worked so far.

## Ticket F: the database hostname would not resolve

**Customer impact:** the website returned 200 from both AZs, so nothing looked broken from outside. Anything on the app tier that connects to the database by name would have failed.

**How I narrowed it down:**
1. `curl` against the ALB returned 200 from both AZs. That ruled out the "site times out" and "502/504" tickets.
2. Both targets were healthy and both instances were `Online` in Systems Manager. That ruled out the health-check and NAT tickets (`logs/09`, `logs/10`).
3. On an instance, `dig db.lab.internal` returned a CNAME to `db-old.lab.internal`, `nslookup` returned NXDOMAIN, and `nc` could not resolve the name (`logs/11`).
4. Route 53 showed the same record, and the real RDS endpoint was a different name (`logs/12`, `logs/13`).
5. To separate DNS from connectivity, I ran `nc` straight to the RDS endpoint. It connected to `10.0.21.201:5432`, so the network path and the security groups were fine (`logs/14`).

**Root cause:** a stale CNAME in the private hosted zone. The VPC resolver (`10.0.0.2`) answered correctly for the name it was given. The name it was given pointed nowhere.

**Fix and verification:** I pointed the CNAME at the real RDS endpoint (`logs/15`), then confirmed three ways: `dig` returned the endpoint and `10.0.21.201`, `nc -zv db.lab.internal 5432` connected, and `psql` logged in to `labdb` through the name (`logs/17`, `logs/18`). The `psql` error at the end of `logs/17` is my own script failing to read the password, not the database. `logs/18` has the successful login. `./lab.sh reset` then restored the stack to its template state.

**Prevention:** test name resolution and connectivity separately (`dig` first, then `nc`). Manage DNS records in the same template as the database so the record cannot go stale on its own, which is how this lab normally builds it. Alarm on application connection errors, not only on target health, because here the load balancer never noticed.

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

- Command output with UTC timestamps: [`evidence/logs/`](evidence/logs/)
- Console screenshots: [`evidence/screenshots/`](evidence/screenshots/). Ticket F before and after: [broken record](evidence/screenshots/15-ticket-f-broken-cname.jpg), [fixed record](evidence/screenshots/16-ticket-f-fixed-cname.jpg)
- Ticket notes: [TICKET_LOG.md](TICKET_LOG.md)
- The AWS account ID is redacted in screenshots and logs (shown as `123456789012`).

## Cost

The lab runs at about $0.13 per hour in eu-west-1, mostly the NAT Gateway and the ALB. A $10 monthly budget with 50% and 100% email alerts guards it, and the stack is deleted with `./lab.sh destroy` when work ends.
