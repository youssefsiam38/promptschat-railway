// prompts.chat for Railway, after migrations: create or repair the owner account, start the app, import the
// prompt library once, and reset the daily AI generation credits at midnight UTC.
// Logs never contain passwords, secrets, session cookies or the owner's e-mail address.
import { spawn } from "node:child_process";
import http from "node:http";
import { createRequire } from "node:module";

// The app's generated Prisma client, and bcryptjs from the start-up's own dependencies (the app bundles its copy).
const { PrismaClient } = createRequire("/app/server.js")("@prisma/client");
const bcrypt = createRequire("/opt/promptschat/runtime/package.json")("bcryptjs");

const log = (msg) => console.log(`[promptschat-railway] ${msg}`);
const warn = (msg) => console.warn(`[promptschat-railway] WARNING: ${msg}`);
const env = process.env;
const PORT = Number(env.PORT || 3000);
const truthy = (v, fallback) => (v === undefined || v === "" ? fallback : /^(1|true|yes|on)$/i.test(v.trim()));

// Upstream's own parsing of PCHAT_* booleans (src/lib/config), so the database agrees with the app.
const pchatBool = (v, fallback) => (v === undefined ? fallback : v.toLowerCase() === "true" || v === "1");

// Wrapper state, the sign-up policy and its enforcement, outside upstream's `public` schema. Upstream's
// registration switch covers only e-mail sign-up and OAuth providers admit anyone; this trigger refuses every new
// account (either path, and an OAuth sign-in taking over an imported contributor's placeholder) unless the
// policy admits its address.
const SCHEMA_DDL = [
  "CREATE SCHEMA IF NOT EXISTS railway_template",
  "CREATE TABLE IF NOT EXISTS railway_template.state (key text PRIMARY KEY, value text NOT NULL, updated_at timestamptz NOT NULL DEFAULT now())",
  "CREATE TABLE IF NOT EXISTS railway_template.settings (key text PRIMARY KEY, value text NOT NULL)",
  `CREATE OR REPLACE FUNCTION railway_template.signup_allowed(addr text) RETURNS boolean
   LANGUAGE plpgsql STABLE AS $fn$
   DECLARE
     list text := coalesce((SELECT value FROM railway_template.settings WHERE key = 'allowed_signups'), '');
     open_registration boolean := coalesce((SELECT value FROM railway_template.settings WHERE key = 'registration_open'), 'false') = 'true';
     e text := lower(btrim(coalesce(addr, '')));
     entry text;
   BEGIN
     IF btrim(list) = '' THEN
       RETURN open_registration;
     END IF;
     FOREACH entry IN ARRAY string_to_array(list, ',') LOOP
       entry := lower(btrim(entry));
       CONTINUE WHEN entry = '';
       IF left(entry, 1) = '@' THEN
         IF right(e, length(entry)) = entry AND position('@' IN e) = length(e) - length(entry) + 1 THEN
           RETURN true;
         END IF;
       ELSIF e = entry THEN
         RETURN true;
       END IF;
     END LOOP;
     RETURN false;
   END $fn$`,
  `CREATE OR REPLACE FUNCTION railway_template.gate_users() RETURNS trigger
   LANGUAGE plpgsql AS $fn$
   BEGIN
     IF current_setting('promptschat.bootstrap', true) = 'on' THEN
       RETURN NEW;
     END IF;
     IF TG_OP = 'INSERT' THEN
       -- Contributors imported with the prompt library: placeholders without a password, which cannot sign in.
       IF NEW.email LIKE '%@unclaimed.prompts.chat' AND NEW.password IS NULL THEN
         RETURN NEW;
       END IF;
     ELSIF NOT (OLD.email LIKE '%@unclaimed.prompts.chat' AND NEW.email IS DISTINCT FROM OLD.email) THEN
       RETURN NEW;
     END IF;
     IF NOT railway_template.signup_allowed(NEW.email) THEN
       RAISE EXCEPTION 'promptschat_signup_not_allowed' USING ERRCODE = 'insufficient_privilege';
     END IF;
     RETURN NEW;
   END $fn$`,
  "DROP TRIGGER IF EXISTS railway_template_gate ON public.users",
  "CREATE TRIGGER railway_template_gate BEFORE INSERT OR UPDATE OF email ON public.users FOR EACH ROW EXECUTE FUNCTION railway_template.gate_users()",
];

async function syncSignupPolicy(db) {
  const open = pchatBool(env.PCHAT_ALLOW_REGISTRATION, false);
  const allowed = (env.PROMPTS_ALLOWED_SIGNUPS || "").split(",").map((x) => x.trim().toLowerCase()).filter(Boolean);
  for (const entry of allowed) {
    if (!/^([^@\s,]+)?@[^@\s,]+\.[^@\s,]+$/.test(entry)) throw new Error(`PROMPTS_ALLOWED_SIGNUPS has an entry that is neither an e-mail address nor an @domain (entry ${allowed.indexOf(entry) + 1}).`);
  }
  await db.$executeRawUnsafe(
    "INSERT INTO railway_template.settings (key, value) VALUES ('registration_open', $1), ('allowed_signups', $2) ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value",
    String(open), allowed.join(","),
  );
  if (allowed.length) {
    log(`new accounts: only ${allowed.length} allowed address/domain entr${allowed.length === 1 ? "y" : "ies"} (PROMPTS_ALLOWED_SIGNUPS)${open ? "; e-mail sign-up form open" : "; e-mail sign-up form closed"}`);
  } else if (open) {
    warn("PCHAT_ALLOW_REGISTRATION is on and PROMPTS_ALLOWED_SIGNUPS is empty: anyone who can reach this site can create an account");
  } else {
    log("new accounts: closed (only the owner; set PROMPTS_ALLOWED_SIGNUPS to admit your team)");
  }
}

async function getState(db, key) {
  const rows = await db.$queryRawUnsafe("SELECT value FROM railway_template.state WHERE key = $1", key);
  return rows[0]?.value ?? null;
}
async function setState(db, key, value) {
  await db.$executeRawUnsafe(
    "INSERT INTO railway_template.state (key, value) VALUES ($1, $2) ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now()",
    key, value,
  );
}

// ---- owner ----------------------------------------------------------------------------------------------

async function ensureOwner(db) {
  const email = env.OWNER_EMAIL.trim().toLowerCase();
  const password = env.OWNER_PASSWORD;
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) throw new Error("OWNER_EMAIL is not an e-mail address.");
  if (password.length < 8) throw new Error("OWNER_PASSWORD is too short; use at least 8 characters.");
  const wantedUsername = (env.OWNER_USERNAME || "owner").trim().toLowerCase();
  if (!/^[a-z0-9_]{1,30}$/.test(wantedUsername)) throw new Error("OWNER_USERNAME may contain only a-z, 0-9 and _ (at most 30).");

  const existing = await db.user.findUnique({ where: { email } });
  if (!existing) {
    // A contributor imported from the library can already hold the name; take the next free one.
    let username = wantedUsername;
    for (let n = 2; await db.user.findFirst({ where: { username: { equals: username, mode: "insensitive" } } }); n++) {
      username = `${wantedUsername.slice(0, 27)}${n}`;
    }
    const hash = await bcrypt.hash(password, 12);
    // The sign-up trigger admits this one insert: the setting lasts only for this transaction.
    await db.$transaction(async (tx) => {
      await tx.$queryRawUnsafe("SELECT set_config('promptschat.bootstrap', 'on', true)");
      await tx.user.create({
        data: {
          email,
          username,
          name: (env.OWNER_NAME || "Owner").trim() || "Owner",
          password: hash,
          role: "ADMIN",
          emailVerified: new Date(),
        },
      });
    });
    log(`created the owner account (username "${username}", role ADMIN)`);
    return;
  }

  const update = {};
  if (existing.role !== "ADMIN") update.role = "ADMIN";
  if (!existing.password) update.password = await bcrypt.hash(password, 12);
  if (truthy(env.OWNER_RESET_PASSWORD, false)) {
    update.password = await bcrypt.hash(password, 12);
    warn("OWNER_RESET_PASSWORD is on: the owner's password was set to OWNER_PASSWORD. Turn it off again.");
  }
  if (Object.keys(update).length) {
    await db.user.update({ where: { id: existing.id }, data: update });
    log(`updated the owner account (${Object.keys(update).join(", ")})`);
  } else {
    log("owner account present; its password is left as it is");
  }
}

// ---- local HTTP -----------------------------------------------------------------------------------------

function request(method, path, { headers = {}, body } = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request({ host: "127.0.0.1", port: PORT, method, path, headers }, (res) => {
      const chunks = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks).toString("utf8") }));
    });
    req.on("error", reject);
    if (body) req.write(body);
    req.end();
  });
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function waitHealthy(timeoutMs) {
  const until = Date.now() + timeoutMs;
  while (Date.now() < until) {
    try {
      if ((await request("GET", "/api/health")).status === 200) return true;
    } catch { /* not listening yet */ }
    await sleep(2000);
  }
  return false;
}

class Jar {
  constructor() { this.cookies = new Map(); }
  take(res) {
    for (const line of [].concat(res.headers["set-cookie"] || [])) {
      const [pair] = line.split(";");
      const i = pair.indexOf("=");
      if (i > 0) this.cookies.set(pair.slice(0, i).trim(), pair.slice(i + 1).trim());
    }
  }
  header() { return [...this.cookies].map(([k, v]) => `${k}=${v}`).join("; "); }
  has(pattern) { return [...this.cookies.keys()].some((k) => pattern.test(k)); }
}

// Signs in through Auth.js exactly as the login form does, and returns the cookie jar.
async function signInAsOwner() {
  const jar = new Jar();
  const csrf = await request("GET", "/api/auth/csrf");
  jar.take(csrf);
  const { csrfToken } = JSON.parse(csrf.body);
  const form = new URLSearchParams({ email: env.OWNER_EMAIL.trim().toLowerCase(), password: env.OWNER_PASSWORD, csrfToken, callbackUrl: "/" }).toString();
  const res = await request("POST", "/api/auth/callback/credentials", {
    headers: { "content-type": "application/x-www-form-urlencoded", "content-length": Buffer.byteLength(form), cookie: jar.header() },
    body: form,
  });
  jar.take(res);
  if (!jar.has(/session-token/)) throw new Error(`sign-in as the owner failed (HTTP ${res.status}); was the owner's password changed?`);
  return jar;
}

// ---- prompt library -------------------------------------------------------------------------------------

async function importLibrary(db) {
  if (!truthy(env.PROMPTS_IMPORT_LIBRARY, true)) {
    log("PROMPTS_IMPORT_LIBRARY is off; the prompt library is not imported");
    return;
  }
  const state = await getState(db, "library_import");
  if (state === "done" || state === "skipped") return;
  if (state === null && (await db.prompt.count()) > 0) {
    // An existing library (for example, restored from a backup): leave it alone.
    await setState(db, "library_import", "skipped");
    log("prompts already exist; the library import is skipped");
    return;
  }
  await setState(db, "library_import", "started");
  log("importing the prompt library (CC0, about 2,000 prompts); the app is already usable meanwhile...");
  const jar = await signInAsOwner();
  const res = await request("POST", "/api/admin/import-prompts", { headers: { cookie: jar.header(), "content-length": 0 } });
  let result = {};
  try { result = JSON.parse(res.body); } catch { /* reported below */ }
  if (res.status !== 200 || !result.success) throw new Error(`the import answered HTTP ${res.status}`);
  await setState(db, "library_import", "done");
  log(`prompt library imported: ${result.imported} new, ${result.skipped} already present, ${result.total} in the file`);
  if (result.errors?.length) warn(`${result.errors.length} prompts could not be imported`);
}

// ---- daily credit reset ---------------------------------------------------------------------------------

function scheduleCreditReset() {
  if (!env.CRON_SECRET) {
    log("CRON_SECRET is not set; daily AI generation credits are not reset automatically");
    return;
  }
  const run = async () => {
    try {
      const res = await request("POST", "/api/cron/reset-credits", { headers: { authorization: `Bearer ${env.CRON_SECRET}`, "content-length": 0 } });
      log(`daily AI generation credits reset (HTTP ${res.status})`);
    } catch (err) {
      warn(`credit reset failed: ${err.message}`);
    }
  };
  const next = () => {
    const now = new Date();
    const midnight = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate() + 1, 0, 0, 5);
    setTimeout(async () => { await run(); next(); }, midnight - now.getTime()).unref();
  };
  next();
}

// ---- main -----------------------------------------------------------------------------------------------

const db = new PrismaClient();
try {
  for (const sql of SCHEMA_DDL) await db.$executeRawUnsafe(sql);
  await syncSignupPolicy(db);
  await ensureOwner(db);
} catch (err) {
  console.error(`[promptschat-railway] ERROR: ${err.message}`);
  process.exit(1);
}

const server = spawn(process.execPath, ["/app/server.js"], {
  cwd: "/app",
  stdio: "inherit",
  env: { ...env, HOSTNAME: env.PROMPTSCHAT_LISTEN_HOST || "::", PORT: String(PORT) },
});
let stopping = false;
for (const sig of ["SIGTERM", "SIGINT"]) {
  process.on(sig, () => { stopping = true; server.kill(sig); });
}
server.on("exit", async (code, signal) => {
  await db.$disconnect().catch(() => {});
  if (!stopping) console.error(`[promptschat-railway] ERROR: the app exited (${signal || code})`);
  process.exit(code ?? (signal ? 1 : 0));
});

if (await waitHealthy(10 * 60 * 1000)) {
  log(`listening on port ${PORT}`);
  try {
    await importLibrary(db);
  } catch (err) {
    warn(`prompt library import failed: ${err.message}. It is retried at the next start; an admin can also run it from the admin panel.`);
  }
  scheduleCreditReset();
} else {
  warn("the app did not become healthy within 10 minutes");
}
