# Marketplace audit

Checked 2026-09-16.

| Question | Finding |
|---|---|
| Existing Railway templates | None for prompts.chat (`_audit/gapscan.py`: "prompts.chat", "prompts chat"; the only loose matches are unrelated chat apps). |
| Demand | f/prompts.chat: about 170,000 stars and 22,000 forks, one of the most-starred repositories on GitHub; 100 commits in the last 30 days. |
| Licence | Code MIT, prompt content CC0 1.0 (`LICENSE`, `LICENSE-MIT`, `LICENSE-CC0`). |
| Self-hostable | Yes: Next.js and PostgreSQL. Upstream documents Docker Compose and a white-label mode through PCHAT_* variables. |
| Why a template adds value | Upstream's image is a moving tag that reports to prompts.chat's Sentry, its lockfile carries critical advisories, registration is open by default and OAuth sign-ups are never closed, its seed creates `password123` accounts from a remote download, and its only images are `main`/`latest`. Railway users get none of the set-up: database, owner account, library import, cron. |
| Not included | File uploads for media prompts need an S3-compatible bucket; URLs work out of the box. No e-mail features exist upstream. |
