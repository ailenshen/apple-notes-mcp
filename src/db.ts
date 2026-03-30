import { DatabaseSync } from "node:sqlite";
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
LEFT JOIN ZICCLOUDSYNCINGOBJECT f ON n.ZFOLDER = f.Z_PK
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

export function searchNotes(query: string, limit?: number): NoteRow[] {
  const db = getDb();
  const likePattern = `%${query}%`;
  let sql = LIST_QUERY.replace(
    "ORDER BY",
    `AND (n.ZTITLE1 LIKE ? OR n.ZSNIPPET LIKE ?) ORDER BY`
  );
  const params: (string | number)[] = [likePattern, likePattern];

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
    LEFT JOIN ZICCLOUDSYNCINGOBJECT f ON n.ZFOLDER = f.Z_PK
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
