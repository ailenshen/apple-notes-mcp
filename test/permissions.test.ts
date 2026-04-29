import { test } from "node:test";
import { strict as assert } from "node:assert";
import { friendlyError, getPermissionHint } from "../src/permissions.js";
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

test("getPermissionHint: classifies FDA error", async () => {
  const { result, stdout } = await captureStdout(() =>
    getPermissionHint(makeFullDiskAccessError())
  );
  assert.equal(stdout.length, 0);
  assert.ok(result);
  assert.match(result!, /Full Disk Access/);
});

test("getPermissionHint: classifies Accessibility denial", async () => {
  const { result, stdout } = await captureStdout(() =>
    getPermissionHint(makeAccessibilityError())
  );
  assert.equal(stdout.length, 0);
  assert.ok(result);
  assert.match(result!, /Accessibility/);
});

test("getPermissionHint: returns undefined for unknown errors", async () => {
  const { result, stdout } = await captureStdout(() =>
    getPermissionHint(new Error("Note not found: whatever"))
  );
  assert.equal(stdout.length, 0);
  assert.equal(result, undefined);
});

test("friendlyError: includes FDA hint for FDA error", async () => {
  const { result, stdout } = await captureStdout(() =>
    friendlyError(makeFullDiskAccessError())
  );
  assert.equal(stdout.length, 0);
  assert.match(result, /Full Disk Access/);
});

test("friendlyError: returns first line of error message for unmatched errors", async () => {
  const { result, stdout } = await captureStdout(() =>
    friendlyError(new Error("Note not found: whatever"))
  );
  assert.equal(stdout.length, 0);
  assert.equal(result, "Note not found: whatever");
});

test("friendlyError: strips multi-line content (no stack traces) for unmatched errors", async () => {
  const err = new Error("Can't get folder \"Foo\". (-1728)\n  at fakeFrame\n  at otherFrame");
  const { result } = await captureStdout(() => friendlyError(err));
  assert.equal(result, "Can't get folder \"Foo\". (-1728)");
});

test("friendlyError: classifies Automation (-1743) denial", async () => {
  const err = new Error(
    "AppleScript error: Not authorized to send Apple events to Notes. (-1743)"
  );
  const { result } = await captureStdout(() => friendlyError(err));
  assert.match(result, /Automation/);
});

test("friendlyError: classifies osascript timeout via signal", async () => {
  const err = new Error("AppleScript error: timed out after 30s") as Error & {
    signal?: string;
    killed?: boolean;
  };
  err.signal = "SIGTERM";
  err.killed = true;
  const { result } = await captureStdout(() => friendlyError(err));
  assert.match(result, /timed out/i);
});
