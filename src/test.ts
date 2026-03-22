/**
 * Integration test for Apple Notes MCP server.
 *
 * Flow: create → verify → update(delete+create) → verify → delete → verify
 *
 * Uses a UUID-suffixed title to guarantee no collision with existing notes.
 * Cleans up on failure via finally block.
 */

import { randomUUID } from "crypto";
import { listNotes, searchNotes, findNoteByTitle } from "./db.js";
import { getNoteBody, createNote, deleteNote } from "./applescript.js";

// ── Helpers ──────────────────────────────────────────────────────────

const TEST_ID = randomUUID().slice(0, 8);
const TITLE_V1 = `MCP_Test_${TEST_ID}`;
const TITLE_V2 = `MCP_Test_v2_${TEST_ID}`;
const BODY_V1 = `This is test body v1 — ${TEST_ID}`;
const BODY_V2 = `This is **updated** body v2 — ${TEST_ID}`;
const TEST_FOLDER = "Notes"; // default folder, always exists

let passed = 0;
let failed = 0;
let currentTitle: string | null = null; // tracks which title to clean up

function assert(condition: boolean, message: string): void {
  if (condition) {
    passed++;
    console.log(`  ✅ ${message}`);
  } else {
    failed++;
    console.error(`  ❌ ${message}`);
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

/**
 * SQLite WAL may lag behind Notes writes. Retry up to `maxRetries` times.
 */
async function waitForSqlite(
  check: () => boolean,
  label: string,
  maxRetries = 15,
  interval = 1000
): Promise<boolean> {
  for (let i = 0; i < maxRetries; i++) {
    if (check()) return true;
    process.stdout.write(`  ⏳ waiting for SQLite sync: ${label} (${i + 1}/${maxRetries})\r`);
    await sleep(interval);
  }
  process.stdout.write("\n");
  return check();
}

/**
 * Record note count snapshot for the given folder, to later verify nothing else changed.
 */
function countNotesInFolder(folder: string): number {
  return listNotes(folder).length;
}

// ── Cleanup ──────────────────────────────────────────────────────────

async function cleanup(): Promise<void> {
  if (!currentTitle) return;
  console.log(`\n🧹 Cleaning up: deleting "${currentTitle}" ...`);
  try {
    await deleteNote(currentTitle, TEST_FOLDER);
    console.log("  cleaned up.");
  } catch {
    console.log("  nothing to clean (already gone or not found).");
  }
}

// ── Test Steps ───────────────────────────────────────────────────────

async function testCreate(): Promise<void> {
  console.log("\n── Step 1: Create Note ──");
  const md = `# ${TITLE_V1}\n\n${BODY_V1}`;
  const title = await createNote(md); // no folder → goes to "Notes"
  currentTitle = title;
  assert(title === TITLE_V1, `createNote returned title "${title}"`);
}

async function testVerifyAfterCreate(): Promise<void> {
  console.log("\n── Step 2: Verify after Create ──");

  // 2a. SQLite: findNoteByTitle
  const found = await waitForSqlite(
    () => !!findNoteByTitle(TITLE_V1),
    `findNoteByTitle("${TITLE_V1}")`
  );
  assert(found, `findNoteByTitle found the note in SQLite`);

  if (found) {
    const row = findNoteByTitle(TITLE_V1)!;
    assert(row.folder === TEST_FOLDER, `note is in folder "${row.folder}"`);
    assert(row.title === TITLE_V1, `title matches: "${row.title}"`);
  }

  // 2b. SQLite: searchNotes
  const searchResults = searchNotes(TEST_ID);
  assert(searchResults.length >= 1, `searchNotes("${TEST_ID}") returned ${searchResults.length} result(s)`);

  // 2c. AppleScript: getNoteBody
  const body = await getNoteBody(TITLE_V1, TEST_FOLDER);
  assert(body.includes(BODY_V1), `getNoteBody contains v1 body text`);
  assert(body.includes("<"), `getNoteBody returns HTML (contains "<")`);
}

async function testUpdate(): Promise<void> {
  console.log("\n── Step 3: Update (delete + create) ──");

  // 3a. Delete old
  await deleteNote(TITLE_V1, TEST_FOLDER);
  currentTitle = null;

  // Verify old note is gone from AppleScript
  let oldGone = false;
  try {
    await getNoteBody(TITLE_V1, TEST_FOLDER);
  } catch {
    oldGone = true;
  }
  assert(oldGone, `old note "${TITLE_V1}" no longer accessible via AppleScript`);

  // 3b. Create new version
  const md = `# ${TITLE_V2}\n\n${BODY_V2}`;
  const title = await createNote(md);
  currentTitle = title;
  assert(title === TITLE_V2, `createNote returned new title "${title}"`);
}

async function testVerifyAfterUpdate(): Promise<void> {
  console.log("\n── Step 4: Verify after Update ──");

  // 4a. Old title should be gone from SQLite
  const oldGone = await waitForSqlite(
    () => !findNoteByTitle(TITLE_V1),
    `old title gone from SQLite`
  );
  assert(oldGone, `old title "${TITLE_V1}" no longer in SQLite`);

  // 4b. New title should appear
  const newFound = await waitForSqlite(
    () => !!findNoteByTitle(TITLE_V2),
    `new title in SQLite`
  );
  assert(newFound, `new title "${TITLE_V2}" found in SQLite`);

  // 4c. AppleScript: body should contain v2 content
  const body = await getNoteBody(TITLE_V2, TEST_FOLDER);
  // Notes renders **updated** as <b>updated</b>, so check for the unique ID and "v2" keyword
  assert(body.includes(TEST_ID), `getNoteBody contains test ID "${TEST_ID}"`);
  assert(body.includes("v2"), `getNoteBody contains "v2" keyword`);
  assert(!body.includes(BODY_V1), `getNoteBody does NOT contain v1 body text`);
}

async function testDelete(): Promise<void> {
  console.log("\n── Step 5: Delete ──");
  await deleteNote(TITLE_V2, TEST_FOLDER);
  currentTitle = null;
  console.log(`  deleted "${TITLE_V2}"`);
}

async function testVerifyAfterDelete(): Promise<void> {
  console.log("\n── Step 6: Verify after Delete ──");

  // 6a. AppleScript: should throw
  let gone = false;
  try {
    await getNoteBody(TITLE_V2, TEST_FOLDER);
  } catch {
    gone = true;
  }
  assert(gone, `getNoteBody throws for deleted note`);

  // 6b. SQLite: should disappear (may take a moment)
  const sqlGone = await waitForSqlite(
    () => !findNoteByTitle(TITLE_V2),
    `deleted note gone from SQLite`
  );
  assert(sqlGone, `deleted note no longer in SQLite`);

  // 6c. searchNotes should return nothing for TEST_ID
  const searchResults = searchNotes(TEST_ID);
  assert(searchResults.length === 0, `searchNotes("${TEST_ID}") returns 0 results`);
}

async function testNoSideEffects(beforeCount: number): Promise<void> {
  console.log("\n── Step 7: Verify no side effects ──");
  const afterCount = countNotesInFolder(TEST_FOLDER);
  assert(
    afterCount === beforeCount,
    `"${TEST_FOLDER}" folder note count unchanged: ${beforeCount} → ${afterCount}`
  );
}

// ── Main ─────────────────────────────────────────────────────────────

async function main(): Promise<void> {
  console.log(`\n🧪 Apple Notes MCP Integration Test`);
  console.log(`   Test ID: ${TEST_ID}`);
  console.log(`   Titles:  "${TITLE_V1}" → "${TITLE_V2}"`);
  console.log(`   Folder:  "${TEST_FOLDER}"`);

  const beforeCount = countNotesInFolder(TEST_FOLDER);
  console.log(`   Notes in "${TEST_FOLDER}" before test: ${beforeCount}`);

  try {
    await testCreate();
    await testVerifyAfterCreate();
    await testUpdate();
    await testVerifyAfterUpdate();
    await testDelete();
    await testVerifyAfterDelete();
    await testNoSideEffects(beforeCount);
  } catch (e) {
    console.error("\n💥 Unexpected error:", e);
    failed++;
  } finally {
    await cleanup();
  }

  console.log(`\n${"═".repeat(40)}`);
  console.log(`  Passed: ${passed}  Failed: ${failed}`);
  console.log(`${"═".repeat(40)}\n`);

  process.exit(failed > 0 ? 1 : 0);
}

main();
