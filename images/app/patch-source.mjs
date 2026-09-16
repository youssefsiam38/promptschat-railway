// Build-time changes to upstream's source, applied to the pinned commit only. Every file is checked against
// the hash it had at that commit first, so a changed upstream file stops the build instead of being patched
// blindly. Usage: node patch-source.mjs /src
import { createHash } from "node:crypto";
import { readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const root = process.argv[2];
if (!root) throw new Error("usage: patch-source.mjs <source dir>");

const EXPECTED = {
  "next.config.ts": "045dd146d17c542248ba435c11caf464c660b9bb8e205f322ded30d735a4fa9c",
  "sentry.server.config.ts": "ae0721955496dd5f3164b862ad00ca1df6f946cf5de93f5867907d2ab3b0d493",
  "sentry.edge.config.ts": "a3b83c39beca6147ee182d26c4e6aceacb7f0463f0c839f7fcc099166b8f1683",
  "src/instrumentation-client.ts": "f33112d81dc94d1aaea0a91662d200f62c19a453366218c4be01ac3fd17f7067",
  "src/instrumentation.ts": "4a351bb98c1ab7fed481670c78277c9321e014cb6d8aeaf73a6649d3611708df",
  "src/lib/plugins/widgets/index.ts": "6350f34cc6fa7e5c03bddc31dbf847ab210f011debfb36494e57b377465c6686",
  "src/app/api/auth/register/route.ts": "7cc38cf1c8760e9dd02d942748dcbe28627b13f05368ef1d2b0eabf53ece2233",
  "src/app/layout.tsx": "d3b47d831cfebb244be8be26f6dd529fbe446fa03579e4d0f806bf633cb8ee5e",
};

const read = (rel) => readFileSync(join(root, rel), "utf8");
const write = (rel, text) => writeFileSync(join(root, rel), text);

for (const [rel, want] of Object.entries(EXPECTED)) {
  const got = createHash("sha256").update(readFileSync(join(root, rel))).digest("hex");
  if (got !== want) throw new Error(`${rel} is not the file these patches were written for (sha256 ${got})`);
}

function replaceOnce(rel, from, to) {
  const text = read(rel);
  const at = text.indexOf(from);
  if (at < 0 || text.indexOf(from, at + 1) >= 0) throw new Error(`${rel}: expected exactly one match for ${JSON.stringify(from.slice(0, 60))}`);
  write(rel, text.slice(0, at) + to + text.slice(at + from.length));
}

// 1. Sentry. Upstream initialises Sentry with prompts.chat's own DSN, user PII and session replays turned on,
//    so every self-hosted instance would report its errors, requests and user sessions to prompts.chat's
//    Sentry project. The configuration files become empty modules and next.config.ts loses the Sentry build
//    wrapper (source-map upload and the build plugin's telemetry). The two error pages keep their
//    Sentry.captureException calls, which do nothing without an initialised client.
const NO_SENTRY = "// The Railway image does not use Sentry: upstream's configuration reported to prompts.chat's own project.\nexport {};\n";
write("sentry.server.config.ts", NO_SENTRY);
write("sentry.edge.config.ts", NO_SENTRY);
write("src/instrumentation-client.ts", NO_SENTRY);
write("src/instrumentation.ts", "// The Railway image does not use Sentry (see sentry.server.config.ts).\nexport async function register() {}\n");

replaceOnce("next.config.ts", 'import { withSentryConfig } from "@sentry/nextjs";\n', "");
{
  const text = read("next.config.ts");
  const start = text.indexOf("export default withSentryConfig(withMDX(withNextIntl(nextConfig)), {");
  if (start < 0) throw new Error("next.config.ts: Sentry export not found");
  write("next.config.ts", text.slice(0, start) + "export default withMDX(withNextIntl(nextConfig));\n");
}

// 2. Widgets. Upstream injects sponsored cards (CodeRabbit and CommandCode affiliate links, plus promotions for
//    its book and the Textream app) into every prompt list. A self-hosted library shows only its own prompts.
replaceOnce(
  "src/lib/plugins/widgets/index.ts",
  'import { coderabbitWidget } from "./coderabbit";\nimport { bookWidget } from "./book";\nimport { textreamWidget } from "./textream";\nimport { commandcodeWidget } from "./commandcode";\n',
  "",
);
replaceOnce(
  "src/lib/plugins/widgets/index.ts",
  "const widgetPlugins: WidgetPlugin[] = [\n  coderabbitWidget,\n  bookWidget,\n  textreamWidget,\n  commandcodeWidget,\n];",
  "const widgetPlugins: WidgetPlugin[] = [];",
);

// 3. Sign-up refusals. The database refuses new accounts outside the sign-up policy (start.mjs installs the
//    trigger); the registration API reports that as 403 instead of a generic 500.
replaceOnce(
  "src/app/api/auth/register/route.ts",
  "      throw error;\n",
  `      if (String((error as Error)?.message ?? "").includes("promptschat_signup_not_allowed")) {
        return NextResponse.json(
          { error: "signup_not_allowed", message: "This e-mail address is not allowed to sign up here" },
          { status: 403 }
        );
      }
      throw error;
`,
);

// 4. Page titles and the cookie banner. The root layout's metadata names prompts.chat whatever the branding, and a
//    banner asks consent "for analytics" even when no analytics are configured. Titles follow PCHAT_NAME, and the
//    banner shows only with GOOGLE_ANALYTICS_ID, the one thing it asks consent for.
replaceOnce("src/app/layout.tsx", "export const metadata: Metadata = {\n", 'const BRAND = process.env.PCHAT_NAME || "Prompt Library";\n\nexport const metadata: Metadata = {\n');
replaceOnce("src/app/layout.tsx", "  metadataBase: new URL(process.env.NEXTAUTH_URL || \"http://localhost:3000\"),", "  metadataBase: new URL(process.env.AUTH_URL || process.env.NEXTAUTH_URL || \"http://localhost:3000\"),");
replaceOnce("src/app/layout.tsx", '    template: "%s | prompts.chat",', "    template: `%s | ${BRAND}`,");
replaceOnce("src/app/layout.tsx", '    siteName: "prompts.chat",', "    siteName: BRAND,");
replaceOnce("src/app/layout.tsx", '    "apple-mobile-web-app-title": "prompts.chat",', '    "apple-mobile-web-app-title": BRAND,');
{
  const text = read("src/app/layout.tsx");
  const parts = text.split('"prompts.chat - AI Prompts Community"');
  if (parts.length !== 5) throw new Error(`src/app/layout.tsx: expected 4 default titles, found ${parts.length - 1}`);
  write("src/app/layout.tsx", parts.join("BRAND"));
}
replaceOnce("src/app/layout.tsx", "<CookieConsentBanner />", "{process.env.GOOGLE_ANALYTICS_ID && <CookieConsentBanner />}");

// 5. Upstream's unit tests. `next build` type-checks every .ts file, and the tests' mocks no longer type-check
//    against the fixed next-auth release (images/app/deps). They are not part of the app; upstream runs them with
//    Vitest, which does not type-check.
rmSync(join(root, "src/__tests__"), { recursive: true, force: false });

for (const rel of Object.keys(EXPECTED)) {
  if (/sentry\.io|withSentryConfig|coderabbitWidget|commandcodeWidget/.test(read(rel))) throw new Error(`${rel}: patch incomplete`);
}
console.log("patched:", Object.keys(EXPECTED).join(", "));
