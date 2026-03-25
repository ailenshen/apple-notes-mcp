/**
 * Detect macOS permission errors and return friendly, actionable messages.
 */

/**
 * Check an error message and return a user-friendly permission hint if applicable.
 * Returns undefined if the error is not permission-related.
 */
export function getPermissionHint(errorMessage: string): string | undefined {
  const msg = errorMessage.toLowerCase();

  // Full Disk Access — SQLite can't open NoteStore.sqlite
  if (
    msg.includes("sqlite_cantopen") ||
    msg.includes("unable to open database") ||
    (msg.includes("no such file or directory") && msg.includes("notestore")) ||
    (msg.includes("operation not permitted") && msg.includes("notestore"))
  ) {
    return [
      `Missing "Full Disk Access" permission.`,
      ``,
      `Go to System Settings > Privacy & Security > Full Disk Access, find "node" in the list, and turn it on.`,
      `Then restart your MCP client (Claude Desktop, Claude Code, etc.).`,
    ].join("\n");
  }

  // Accessibility — System Events can't interact with UI
  if (
    msg.includes("not allowed assistive access") ||
    msg.includes("is not allowed to send keystrokes") ||
    msg.includes("accessibility access") ||
    (msg.includes("system events got an error") && (msg.includes("not allowed") || msg.includes("access")))
  ) {
    return [
      `Missing "Accessibility" permission.`,
      ``,
      `Go to System Settings > Privacy & Security > Accessibility, find "node" in the list, and turn it on.`,
      `Then restart your MCP client (Claude Desktop, Claude Code, etc.).`,
    ].join("\n");
  }

  return undefined;
}

/**
 * Wrap an error with a permission hint if applicable.
 * Returns the hint + original message, or just the original message.
 */
export function friendlyError(error: unknown): string {
  const message = error instanceof Error ? error.message : String(error);
  const hint = getPermissionHint(message);
  return hint ? `${hint}\n\nOriginal error: ${message}` : `Error: ${message}`;
}
