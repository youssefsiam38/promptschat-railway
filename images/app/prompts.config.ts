import { defineConfig } from "@/lib/config";

// prompts.chat for Railway: the base configuration of a self-hosted library, replacing upstream's
// prompts.chat-branded one. Every value here can still be changed at runtime with PCHAT_* variables.
export default defineConfig({
  branding: {
    name: "Prompt Library",
    logo: "/logo.svg",
    logoDark: "/logo-dark.svg",
    favicon: "/logo.svg",
    description: "Collect, organize, and share AI prompts",
  },

  theme: {
    radius: "sm",
    variant: "default",
    density: "default",
    colors: {
      primary: "#6366f1",
    },
  },

  // Email and password only, and nobody can create an account: the owner is created at start-up.
  auth: {
    providers: ["credentials"],
    allowRegistration: false,
  },

  i18n: {
    locales: ["en", "tr", "es", "zh", "ja", "ar", "pt", "fr", "it", "de", "nl", "ko", "ru", "he", "el", "az", "fa"],
    defaultLocale: "en",
  },

  // The AI features need OPENAI_API_KEY, so they start off.
  features: {
    privatePrompts: true,
    changeRequests: true,
    categories: true,
    tags: true,
    aiSearch: false,
    aiGeneration: false,
    mcp: true,
    comments: true,
  },

  // Your own library: no prompts.chat achievements, GitHub star counts or sponsor logos on the home page.
  homepage: {
    useCloneBranding: true,
    achievements: {
      enabled: false,
    },
    sponsors: {
      enabled: false,
      items: [],
    },
  },
});
