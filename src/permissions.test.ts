import { test } from "node:test";
import { strict as assert } from "node:assert";
import { friendlyError, getPermissionHint } from "./permissions.js";
import { captureStdout } from "./test-utils.js";

/**
 * Build an error object that matches the exact shape node:sqlite throws when
 * NoteStore.sqlite can't be opened due to missing Full Disk Access.
 * Verified on macOS 26 + node 24 (2026-04-20): see permissions.ts for details.
 */
function makeFullDiskAccessError(): Error & { code: string; errcode: number; errstr: string } {
  const e = new Error("unable to open database file") as Error & {
    code: string;
    errcode: number;
    errstr: string;
  };
  e.code = "ERR_SQLITE_ERROR";
  e.errcode = 14;
  e.errstr = "unable to open database file";
  return e;
}

test("getPermissionHint: classifies real node:sqlite FDA error", async () => {
  const err = makeFullDiskAccessError();
  const input = { message: err.message, code: err.code, errcode: err.errcode };
  const { result, stdout } = await captureStdout(() => getPermissionHint(err));

  console.log("getPermissionHint input:", JSON.stringify(input));
  console.log("getPermissionHint output (first line):", result?.split("\n")[0]);
  console.log("getPermissionHint stdout bytes during call:", stdout.length);

  assert.equal(stdout.length, 0);
  assert.ok(result);
  assert.match(result!, /Full Disk Access/);
});

/**
 * Build an error matching the shape src/applescript.ts:19 produces when
 * osascript / System Events is denied Accessibility.
 * Verified on macOS 26 (2026-04-20) via the e2e test run.
 */
function makeAccessibilityError(): Error {
  return new Error(
    "AppleScript error: Command failed: osascript -e ...\n" +
      "392:687: execution error: System Events got an error: " +
      "osascript is not allowed assistive access. (-25211)"
  );
}

test("getPermissionHint: classifies real Accessibility denial", async () => {
  const err = makeAccessibilityError();
  const { result, stdout } = await captureStdout(() => getPermissionHint(err));

  console.log("getPermissionHint input (Accessibility, first 80 chars):", err.message.slice(0, 80));
  console.log("getPermissionHint output (first line):", result?.split("\n")[0]);
  console.log("getPermissionHint stdout bytes during call:", stdout.length);

  assert.equal(stdout.length, 0);
  assert.ok(result);
  assert.match(result!, /Accessibility/);
});

test("getPermissionHint: returns undefined for unknown errors", async () => {
  const err = new Error("Note not found: whatever");
  const { result, stdout } = await captureStdout(() => getPermissionHint(err));

  console.log("getPermissionHint input:", JSON.stringify({ message: err.message }));
  console.log("getPermissionHint output:", result);
  console.log("getPermissionHint stdout bytes during call:", stdout.length);

  assert.equal(stdout.length, 0);
  assert.equal(result, undefined);
});

test("friendlyError: returns FDA hint for real FDA error", async () => {
  const err = makeFullDiskAccessError();
  const { result, stdout } = await captureStdout(() => friendlyError(err));

  console.log("friendlyError input: <FDA-shaped error>");
  console.log("friendlyError output (first line):", result.split("\n")[0]);
  console.log("friendlyError stdout bytes during call:", stdout.length);

  assert.equal(stdout.length, 0);
  assert.match(result, /Full Disk Access/);
});

test("friendlyError: returns generic message for unknown errors", async () => {
  const err = new Error("Note not found: whatever");
  const { result, stdout } = await captureStdout(() => friendlyError(err));

  console.log("friendlyError input:", JSON.stringify({ message: err.message }));
  console.log("friendlyError output:", result);
  console.log("friendlyError stdout bytes during call:", stdout.length);

  assert.equal(stdout.length, 0);
  assert.equal(result, "The operation failed. See the MCP server log for details.");
  // Critical: the raw error text must NOT leak to the MCP response.
  assert.doesNotMatch(result, /Note not found/);
});
