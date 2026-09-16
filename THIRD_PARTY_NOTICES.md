# Third-party notices

| Component | Licence | Where |
|---|---|---|
| prompts.chat source code | MIT, Copyright (c) 2022-present Fatih Kadir Akin and contributors | built into `ghcr.io/youssefsiam38/promptschat-railway`; `licenses/PROMPTS-CHAT-LICENSE-MIT` |
| prompts.chat prompt content (`prompts.csv`) | CC0 1.0 Universal | shipped in the image and imported at first start; `licenses/PROMPTS-CHAT-LICENSE-CC0` |
| prompts.chat licence overview | | `licenses/PROMPTS-CHAT-LICENSE` |
| Node.js dependencies of the app | their own licences (MIT, Apache-2.0, ISC, BSD and others), as resolved by `images/app/deps/package-lock.json` | inside the image under `/app/node_modules` and the Next.js build |
| Prisma CLI, bcryptjs | Apache-2.0, BSD-3-Clause | `/opt/promptschat/runtime` in the image |
| Node.js | MIT and bundled licences | base image |
| Debian packages (openssl, ca-certificates) | their own licences | base image |
| PostgreSQL | PostgreSQL Licence | `postgres` official image, run unmodified |

The licence files are also copied into the image at `/usr/share/licenses/promptschat-railway/`.

This template is not affiliated with or endorsed by prompts.chat. "prompts.chat" names the upstream project; its logo
is not used in this repository's icon.
