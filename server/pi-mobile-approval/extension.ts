/**
 * Pi Mobile approval gate — when PI_MOBILE_APPROVAL_MODE=ask, confirm each
 * tool call via RPC extension UI (surfaced on the phone). Auto is a no-op.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const summarize = (input: Record<string, unknown> | undefined) => {
  if (!input) return "";
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
