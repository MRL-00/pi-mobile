/**
 * Pi Mobile approval gate — when PI_MOBILE_APPROVAL_MODE=ask, confirm each
 * tool call via RPC extension UI (surfaced on the phone). Auto is a no-op.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const summarize = (input: Record<string, unknown> | undefined) => {
  if (!input) return "";
  const asList = (v: unknown) =>
    Array.isArray(v) ? v.map(String).filter(Boolean) : v != null && v !== "" ? [String(v)] : [];
  const queries = asList(input.queries ?? input.query);
  if (queries.length) return queries.map((q) => `"${q}"`).join("\n").slice(0, 400);
  const urls = asList(input.urls ?? input.url);
  if (urls.length) return urls.join("\n").slice(0, 400);
  if (input.urlIndex != null) return `urlIndex=${input.urlIndex}`;
  const v =
    input.file_path ?? input.path ?? input.command ?? input.pattern ?? input.description ?? "";
  return String(v).slice(0, 200);
};

export default function (pi: ExtensionAPI) {
  const mode = (process.env.PI_MOBILE_APPROVAL_MODE ?? "auto").toLowerCase();
  if (mode !== "ask") return;

  pi.on("tool_call", async (event, ctx) => {
    if (!ctx.hasUI) {
      return { block: true, reason: "Ask mode requires UI confirmation (unavailable)" };
    }
    const detail = summarize(event.input as Record<string, unknown>);
    const confirmed = await ctx.ui.confirm(
      `Allow ${event.toolName}?`,
      detail || "No arguments",
    );
    if (!confirmed) return { block: true, reason: "Denied from phone" };
    return undefined;
  });
}
