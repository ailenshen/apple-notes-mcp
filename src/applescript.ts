import { execFile } from "child_process";
import { writeFile, unlink } from "fs/promises";
import { tmpdir } from "os";
import { join } from "path";
import { randomUUID } from "crypto";
import TurndownService from "turndown";
import { findNoteByTitle } from "./db.js";

const turndown = new TurndownService({
  headingStyle: "atx",
  bulletListMarker: "-",
  codeBlockStyle: "fenced",
});

function runAppleScript(script: string): Promise<string> {
  return new Promise((resolve, reject) => {
    execFile("osascript", ["-e", script], { timeout: 30000 }, (err, stdout, stderr) => {
      if (err) {
        reject(new Error(`AppleScript error: ${err.message}\n${stderr}`));
      } else {
        resolve(stdout.trim());
      }
    });
  });
}

export async function getNoteBody(title: string, folder?: string): Promise<string> {
  const folderClause = folder
    ? `of folder ${JSON.stringify(folder)}`
    : "";

  // Try to find by exact title; if folder is given, scope to that folder
  const script = `
tell application "Notes"
  set matchedNotes to (every note ${folderClause} whose name is ${JSON.stringify(title)})
  if (count of matchedNotes) = 0 then
    error "Note not found: ${title.replace(/"/g, '\\"')}"
  end if
  return body of item 1 of matchedNotes
end tell
`;
  const html = await runAppleScript(script);
  return turndown.turndown(html);
}

export async function deleteNote(title: string, folder?: string): Promise<void> {
  const folderClause = folder
    ? `of folder ${JSON.stringify(folder)}`
    : "";

  const script = `
tell application "Notes"
  set matchedNotes to (every note ${folderClause} whose name is ${JSON.stringify(title)})
  if (count of matchedNotes) = 0 then
    error "Note not found: ${title.replace(/"/g, '\\"')}"
  end if
  delete item 1 of matchedNotes
end tell
`;
  await runAppleScript(script);
}

export async function createNote(
  markdown: string,
  targetFolder?: string,
  restoreApp?: string
): Promise<string> {
  // 1. Extract title from first line
  const firstLine = markdown.split("\n")[0].replace(/^#\s*/, "").trim();
  const title = firstLine || "Untitled";

  // 2. Write temp .md file
  const tmpPath = join(tmpdir(), `note-${randomUUID()}.md`);
  await writeFile(tmpPath, markdown, "utf-8");

  try {
    // 3. Remember current frontmost app (or use caller-supplied value), open file, auto-confirm Import sheet
    const captureFrontApp = restoreApp
      ? `set frontApp to ${JSON.stringify(restoreApp)}`
      : `set frontApp to name of first process whose frontmost is true`;
    const importScript = `
tell application "System Events"
  ${captureFrontApp}
end tell

do shell script "open -g -a Notes " & quoted form of "${tmpPath}"
delay 0.5

tell application "System Events"
  tell process "Notes"
    repeat 20 times
      repeat with w in every window
        try
          repeat with s in every sheet of w
            if (name of every button of s) contains "Import" then
              click button "Import" of s
              return frontApp
            end if
          end repeat
        end try
      end repeat
      delay 0.2
    end repeat
  end tell
end tell

return "no_sheet"
`;
    const importResult = await runAppleScript(importScript);

    if (importResult === "no_sheet") {
      throw new Error("Failed to confirm Import sheet within timeout");
    }

    const frontApp = importResult;

    // 4. Wait briefly for Notes to process
    await new Promise((r) => setTimeout(r, 1000));

    // 5. Move to target folder + clean up Imported Notes + show note + restore frontmost app
    const finalFolder = targetFolder || "Notes";
    const postImportScript = `
tell application "Notes"
  try
    set targetNote to missing value
    set importedFolder to missing value
    repeat with f in every folder
      if name of f starts with "Imported Notes" then
        set matches to (every note of f whose name is ${JSON.stringify(title)})
        if (count of matches) > 0 then
          set targetNote to item 1 of matches
          set importedFolder to f
          exit repeat
        end if
      end if
    end repeat
    if targetNote is not missing value then
      move targetNote to folder ${JSON.stringify(finalFolder)}
      show targetNote
    end if
    if importedFolder is not missing value then
      delete importedFolder
    end if
  end try
end tell

-- Restore the original frontmost app
tell application ${JSON.stringify(frontApp)} to activate
`;
    try {
      await runAppleScript(postImportScript);
    } catch {
      // best-effort: Imported Notes folder may not exist
    }

    // Notes sometimes creates empty "Imported Notes*" folders asynchronously after
    // the import is confirmed. Collect names first, then delete by name to avoid
    // stale object references.
    setTimeout(() => {
      runAppleScript(`
tell application "Notes"
  try
    set emptyNames to {}
    repeat with f in every folder
      if name of f starts with "Imported Notes" and (count of notes of f) = 0 then
        set end of emptyNames to name of f
      end if
    end repeat
    repeat with n in emptyNames
      try
        delete folder n
      end try
    end repeat
  end try
end tell
`).catch(() => {});
    }, 3000);

    return title;
  } finally {
    // 6. Delete temp file
    try {
      await unlink(tmpPath);
    } catch {
      // ignore
    }
  }
}

export async function permanentlyDeleteNote(title: string): Promise<void> {
  const script = `
tell application "Notes"
  try
    set targets to (every note of folder "Recently Deleted" whose name is ${JSON.stringify(title)})
    if (count of targets) > 0 then
      delete item 1 of targets
    end if
  end try
end tell
`;
  await runAppleScript(script);
}

export async function updateNote(
  title: string,
  markdown: string,
  folder?: string
): Promise<string> {
  // Capture front app before deleteNote activates Notes
  const frontApp = await runAppleScript(
    `tell application "System Events" to return name of first process whose frontmost is true`
  );

  const row = findNoteByTitle(title, folder);
  if (!row) throw new Error(`Note not found: ${title}`);
  const originalFolder = row.folder || "Notes";

  await deleteNote(title, folder);
  await permanentlyDeleteNote(title);

  return createNote(markdown, originalFolder, frontApp);
}
