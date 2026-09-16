# Deploy and Host prompts.chat on Railway

prompts.chat (formerly Awesome ChatGPT Prompts) is the open-source AI prompt library behind one of GitHub's
most-starred repositories. Browse, search and copy prompts, write your own with versions and change requests, keep
private prompts, vote and comment, organise with categories, tags and collections, and reach your library from AI
tools over MCP. This is a community-maintained template; it is not affiliated with prompts.chat.

## About Hosting prompts.chat

prompts.chat is a Next.js app on PostgreSQL, with a white-label mode for running your own library. Self-hosting it
means building or pulling the image, running its database migrations, creating an admin account, importing the
prompt collection, scheduling its daily credit reset, and deciding who may sign up.

This template does all of that on Railway: the app and PostgreSQL 17 with a volume, every secret generated. At the
first start it migrates the database, creates your admin account from the e-mail you enter, and imports the CC0
prompts.chat collection (about 2,000 prompts) from the image. Sign-up stays closed until you list the addresses or
domains allowed to join, and that is enforced in the database for e-mail and GitHub or Google sign-ins alike.

## Common Use Cases

- A team prompt library with private prompts and review through change requests.
- A curated, branded collection of prompts for a company, course or community.
- A prompt catalogue your AI assistants and coding agents search and save to over MCP.
- A private mirror of the prompts.chat collection that you can extend.

## Dependencies for prompts.chat Hosting

- Nothing external is required.
- Optional: an OpenAI API key (or an OpenAI-compatible endpoint) for AI search and generation.
- Optional: a GitHub or Google OAuth app for social sign-in, and an S3-compatible bucket for media uploads.

### Deployment Dependencies

- prompts.chat: https://github.com/f/prompts.chat (code MIT, prompts CC0)
- PostgreSQL: https://www.postgresql.org (official Docker image)
- Template repository, image and tests: https://github.com/youssefsiam38/promptschat-railway

### Implementation Details

The app is built from a pinned upstream commit. Upstream's Sentry configuration, which reports errors, request data
and session replays from every instance to prompts.chat's own project, is removed, as are sponsored cards in prompt
lists; page titles use your library's name. Upstream's dependencies carry critical advisories at that commit
(Next.js, Auth.js), resolved with non-breaking updates. Upstream's seed script, which creates accounts with the
password password123, is never used.

Tested in CI and on a live deployment of this template: the admin account, the library import, private prompts,
admin APIs, MCP search, closed and allowlisted sign-up, and a redeploy keeping everything.

The deploy form asks for `OWNER_EMAIL`. Copy `OWNER_PASSWORD` from the app service's variables and sign in on the
app's domain.

## Why Deploy prompts.chat on Railway?

Railway is a singular platform to deploy your infrastructure stack. Railway will host your
infrastructure so you don't have to deal with configuration, while allowing you to vertically and
horizontally scale it.

By deploying prompts.chat on Railway, you are one step closer to supporting a complete full-stack application
with minimal burden. Host your servers, databases, AI agents, and more on Railway.
