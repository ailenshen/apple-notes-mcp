/**
 * Detect macOS permission errors and return friendly, actionable messages.
 *
 * Matchers are keyed off the *observed* structure of the errors we throw from
 * our code paths — not off guessed strings. When adding a new pattern, please
 * capture the real error shape first (message, code, errcode) and reference
 * it in the comment above the matcher.
 */

type MaybeNodeError = Error & { code?: string; errcode?: number };

function toError(error: unknown): MaybeNodeError | null {
  return error instanceof Error ? (error as MaybeNodeError) : null;
}

/**
 * Match "Full Disk Access missing" — node:sqlite cannot open NoteStore.sqlite.
 *
 * Observed error (macOS 26, node 24, node:sqlite, FDA off):
 *   Error: unable to open database file
 *     code:    "ERR_SQLITE_ERROR"
 *     errcode: 14          // SQLITE_CANTOPEN
 *     errstr:  "unable to open database file"
 *
 * We match on `code === "ERR_SQLITE_ERROR"` + `errcode === 14`, which is the
 * reliable structural signal. The message substring is kept as a fallback for
 * any future error wrapper that drops the numeric fields.
 */
function isFullDiskAccessError(error: unknown): boolean {
  const e = toError(error);
  if (!e) return false;
  if (e.code === "ERR_SQLITE_ERROR" && e.errcode === 14) return true;
  return e.message.toLowerCase().includes("unable to open database");
}

/**
 * Match "Accessibility permission missing" — osascript / System Events refuses
 * to drive the Notes UI (blocks the Import-sheet auto-click in createNote).
 *
 * Observed error (macOS 26, osascript, Accessibility off for node):
 *   Wrapped by src/applescript.ts:19 as:
 *     Error: AppleScript error: Command failed: osascript -e <script>
 *            <stderr>: execution error: System Events got an error:
 *            osascript is not allowed assistive access. (-25211)
 *
 * The substring "not allowed assistive access" is the specific TCC denial
 * phrase for Accessibility. `-25211` (errAEEventNotPermitted) is the Apple
 * error code that accompanies it. Either signal alone is sufficient.
 */
function isAccessibilityError(error: unknown): boolean {
  const e = toError(error);
  if (!e) return false;
  const msg = e.message.toLowerCase();
  return (
    msg.includes("not allowed assistive access") ||
    msg.includes("(-25211)")
  );
}

const FULL_DISK_ACCESS_HINT = [
  `Missing "Full Disk Access" permission.`,
  ``,
  `Go to System Settings > Privacy & Security > Full Disk Access, find "node" in the list, and turn it on.`,
  `Then restart your MCP client (Claude Desktop, Claude Code, etc.).`,
].join("\n");

const ACCESSIBILITY_HINT = [
  `Missing "Accessibility" permission.`,
  ``,
  `Go to System Settings > Privacy & Security > Accessibility, find "node" in the list, and turn it on.`,
  `Then restart your MCP client (Claude Desktop, Claude Code, etc.).`,
].join("\n");

/**
 * Return a user-friendly permission hint if the error matches a known
 * permission failure; otherwise undefined.
 */
export function getPermissionHint(error: unknown): string | undefined {
  if (isFullDiskAccessError(error)) return FULL_DISK_ACCESS_HINT;
  if (isAccessibilityError(error)) return ACCESSIBILITY_HINT;
  return undefined;
}

/**
 * Build the user-facing message for a failed tool call.
 * Permission errors return an actionable hint; everything else returns a stable
 * generic message — raw exception text is kept out of the MCP response so it
 * doesn't leak to the model. Use logError() to record the original error on stderr.
 */
export function friendlyError(error: unknown): string {
  const hint = getPermissionHint(error);
  if (hint) return hint;
  return "The operation failed. See the MCP server log for details.";
}

/**
 * Write a raw error to stderr so it lands in the MCP client's server log
 * (e.g. Claude Desktop's ~/Library/Logs/Claude/mcp-server-*.log).
 * stderr is safe — only stdout carries MCP JSON-RPC traffic.
 */
export function logError(toolName: string, error: unknown): void {
  const detail = error instanceof Error ? (error.stack ?? error.message) : String(error);
  process.stderr.write(`[${toolName}] ${detail}\n`);
}
