import { DatabaseSync } from "node:sqlite";
import { gunzipSync } from "node:zlib";
import { homedir } from "os";
import { join } from "path";

const DB_PATH = join(
  homedir(),
  "Library/Group Containers/group.com.apple.notes/NoteStore.sqlite"
);

let db: DatabaseSync | null = null;

function getDb(): DatabaseSync {
  if (!db) {
    db = new DatabaseSync(DB_PATH, { readOnly: true });
    db.exec("PRAGMA journal_mode = WAL");
  }
  return db;
}

export interface NoteRow {
  id: number;
  identifier: string;
  title: string;
  folder: string;
  folder_id: number;
  is_pinned: boolean;
  snippet: string;
  created: string;
  modified: string;
}

const LIST_QUERY = `
SELECT
  n.Z_PK           AS id,
  n.ZIDENTIFIER    AS identifier,
  n.ZTITLE1        AS title,
  COALESCE(f.ZTITLE2, '') AS folder,
  COALESCE(f.Z_PK, 0)    AS folder_id,
  n.ZISPINNED      AS is_pinned,
  COALESCE(n.ZSNIPPET, '') AS snippet,
  datetime(n.ZCREATIONDATE3 + 978307200, 'unixepoch') AS created,
  datetime(n.ZMODIFICATIONDATE1 + 978307200, 'unixepoch') AS modified
FROM ZICCLOUDSYNCINGOBJECT n
INNER JOIN ZICCLOUDSYNCINGOBJECT f ON n.ZFOLDER = f.Z_PK
WHERE n.Z_ENT = 12
  AND (n.ZMARKEDFORDELETION = 0 OR n.ZMARKEDFORDELETION IS NULL)
  AND COALESCE(f.ZTITLE2, '') != 'Recently Deleted'
ORDER BY n.ZMODIFICATIONDATE1 DESC
`;

export function listNotes(folder?: string, limit?: number): NoteRow[] {
  const db = getDb();
  let sql = LIST_QUERY;
  const params: (string | number)[] = [];

  if (folder) {
    sql = sql.replace(
      "ORDER BY",
      "AND f.ZTITLE2 = ? ORDER BY"
    );
    params.push(folder);
  }

  if (limit) {
    sql += ` LIMIT ?`;
    params.push(limit);
  }

  const rows = db.prepare(sql).all(...params) as unknown as NoteRow[];
  return rows.map((r) => ({
    ...r,
    is_pinned: Boolean(r.is_pinned),
  }));
}

export interface SearchHit extends NoteRow {
  excerpt: string;
}

// --- Note body plain text (for full-text search only) ---
//
// ZICNOTEDATA.ZDATA is gzip + protobuf. We only pull the plain-text field
// (NoteStoreProto.document(2) → Note(3) → note_text(2)) and ignore all
// formatting runs, so this is lossy by design and must NOT be used to read or
// rewrite note content — get_note still goes through AppleScript.
// Password-protected notes are encrypted and simply yield no text.
// 当 Apple 开放官方的笔记正文/全文检索接口（AppleScript 或 App Intents 查询）时，
// 重构至官方接口，删除这里的私有 protobuf 解析。

function readVarint(buf: Uint8Array, pos: number): [number, number] {
  let result = 0;
  let shift = 0;
  let byte: number;
  do {
    if (pos >= buf.length) throw new Error("truncated varint");
    byte = buf[pos++];
    result += (byte & 0x7f) * 2 ** shift;
    shift += 7;
  } while (byte & 0x80);
  return [result, pos];
}

/** Return the first length-delimited field with the given number, or null. */
function protoField(buf: Uint8Array | null, fieldNo: number): Uint8Array | null {
  if (!buf) return null;
  let pos = 0;
  while (pos < buf.length) {
    let key: number;
    [key, pos] = readVarint(buf, pos);
    const field = Math.floor(key / 8);
    const wire = key & 7;
    if (wire === 2) {
      let len: number;
      [len, pos] = readVarint(buf, pos);
      if (field === fieldNo) return buf.subarray(pos, pos + len);
      pos += len;
    } else if (wire === 0) {
      [, pos] = readVarint(buf, pos);
    } else if (wire === 1) {
      pos += 8;
    } else if (wire === 5) {
      pos += 4;
    } else {
      return null;
    }
  }
  return null;
}

export function extractNoteText(zdata: Uint8Array | null): string {
  if (!zdata || zdata.length === 0) return "";
  try {
    const proto = gunzipSync(zdata);
    const text = protoField(protoField(protoField(proto, 2), 3), 2);
    return text ? Buffer.from(text).toString("utf8") : "";
  } catch {
    return "";
  }
}

// Cache decoded text by note id; an entry is reused while the note's
// modification date is unchanged, so repeat searches only decode edited notes.
const textCache = new Map<number, { modified: string; text: string }>();

function noteTexts(rows: NoteRow[]): Map<number, string> {
  const stale = rows.filter((r) => textCache.get(r.id)?.modified !== r.modified);
  if (stale.length > 0) {
    const byId = new Map(stale.map((r) => [r.id, r]));
    const stmt = getDb().prepare(
      `SELECT ZNOTE AS id, ZDATA AS data FROM ZICNOTEDATA WHERE ZNOTE IS NOT NULL`
    );
    for (const row of stmt.iterate() as Iterable<{ id: number; data: Uint8Array | null }>) {
      const note = byId.get(row.id);
      if (!note) continue;
      textCache.set(row.id, { modified: note.modified, text: extractNoteText(row.data) });
    }
    // Notes without a ZICNOTEDATA row (empty notes) still get a cache entry.
    for (const r of stale) {
      if (textCache.get(r.id)?.modified !== r.modified) {
        textCache.set(r.id, { modified: r.modified, text: "" });
      }
    }
  }
  return new Map(rows.map((r) => [r.id, textCache.get(r.id)?.text ?? ""]));
}

function makeExcerpt(text: string, needle: string, width = 120): string {
  const flat = text.replace(/\s+/g, " ").trim();
  const at = flat.toLowerCase().indexOf(needle);
  if (at < 0) return flat.slice(0, width);
  const start = Math.max(0, at - Math.floor(width / 3));
  const end = Math.min(flat.length, start + width);
  return (start > 0 ? "…" : "") + flat.slice(start, end) + (end < flat.length ? "…" : "");
}

/**
 * Full-text search across title and body. Every whitespace-separated term must
 * appear (case-insensitive). Title matches rank first, then by modified date.
 */
export function searchNotes(query: string, limit?: number): SearchHit[] {
  const terms = query.toLowerCase().split(/\s+/).filter(Boolean);
  if (terms.length === 0) return [];

  const rows = listNotes();
  const texts = noteTexts(rows);
  const hits: (SearchHit & { titleHit: boolean })[] = [];

  for (const r of rows) {
    const title = r.title.toLowerCase();
    const body = (texts.get(r.id) ?? "").toLowerCase();
    if (!terms.every((t) => title.includes(t) || body.includes(t))) continue;
    const bodyTerm = terms.find((t) => body.includes(t));
    hits.push({
      ...r,
      titleHit: terms.some((t) => title.includes(t)),
      excerpt: bodyTerm ? makeExcerpt(texts.get(r.id) ?? "", bodyTerm) : r.snippet,
    });
  }

  // Array.prototype.sort is stable, so modified-desc order from listNotes is kept within each group.
  hits.sort((a, b) => Number(b.titleHit) - Number(a.titleHit));
  return hits.slice(0, limit ?? hits.length).map(({ titleHit, ...h }) => h);
}

export function findNoteByTitle(title: string, folder?: string): NoteRow | undefined {
  const db = getDb();
  let sql = `
    SELECT
      n.Z_PK           AS id,
      n.ZIDENTIFIER    AS identifier,
      n.ZTITLE1        AS title,
      COALESCE(f.ZTITLE2, '') AS folder,
      COALESCE(f.Z_PK, 0)    AS folder_id,
      n.ZISPINNED      AS is_pinned,
      COALESCE(n.ZSNIPPET, '') AS snippet,
      datetime(n.ZCREATIONDATE3 + 978307200, 'unixepoch') AS created,
      datetime(n.ZMODIFICATIONDATE1 + 978307200, 'unixepoch') AS modified
    FROM ZICCLOUDSYNCINGOBJECT n
    INNER JOIN ZICCLOUDSYNCINGOBJECT f ON n.ZFOLDER = f.Z_PK
    WHERE n.Z_ENT = 12
      AND (n.ZMARKEDFORDELETION = 0 OR n.ZMARKEDFORDELETION IS NULL)
      AND COALESCE(f.ZTITLE2, '') != 'Recently Deleted'
      AND n.ZTITLE1 = ?
  `;
  const params: (string | number)[] = [title];

  if (folder) {
    sql += ` AND f.ZTITLE2 = ?`;
    params.push(folder);
  }

  sql += ` ORDER BY n.ZMODIFICATIONDATE1 DESC LIMIT 1`;

  const row = db.prepare(sql).get(...params) as unknown as NoteRow | undefined;
  if (!row) return undefined;
  return {
    ...row,
    is_pinned: Boolean(row.is_pinned),
  };
}

export function listFolders(): { name: string; id: number; parent: string }[] {
  const db = getDb();
  const rows = db
    .prepare(
      `SELECT f.Z_PK AS id, f.ZTITLE2 AS name,
              COALESCE(p.ZTITLE2, '') AS parent
       FROM ZICCLOUDSYNCINGOBJECT f
       LEFT JOIN ZICCLOUDSYNCINGOBJECT p ON f.ZPARENT = p.Z_PK
       WHERE f.Z_ENT = 15
         AND f.ZTITLE2 != 'Recently Deleted'
       ORDER BY f.ZTITLE2`
    )
    .all() as unknown as { name: string; id: number; parent: string }[];
  return rows;
}
