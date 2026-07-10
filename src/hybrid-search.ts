import { Database } from "./database.js";
import type { MemorySearchOptions } from "./types.js";
import { ilikeExpr, jsonContainsParam, jsonExtractValue } from "./db/query-dialect.js";
import { getLogger } from "./logger.js";

export type HybridWeights = {
  vector: number;
  text: number;
  entity: number;
  recency: number;
};

const DEFAULT_WEIGHTS: HybridWeights = {
  vector: 0.35,
  text: 0.25,
  entity: 0.35,
  recency: 0.05,
};

const RRF_K = 60;

function buildWhereClause(
  params: unknown[],
  projectId?: string,
  type?: string,
  tags?: string[],
  minImportance?: number,
): string {
  let paramIdx = params.length + 1;
  const clauses: string[] = [];
  if (projectId) {
    clauses.push(`project_id = $${paramIdx}`);
    params.push(projectId);
    paramIdx++;
  }
  if (type) {
    clauses.push(`memory_type = $${paramIdx}`);
    params.push(type);
    paramIdx++;
  }
  if (tags && tags.length > 0) {
    clauses.push(`tags && $${paramIdx}`);
    params.push(tags);
    paramIdx++;
  }
  if (minImportance !== undefined) {
    clauses.push(`importance >= $${paramIdx}`);
    params.push(minImportance);
    paramIdx++;
  }
  return clauses.length > 0 ? 'AND ' + clauses.join(' AND ') : '';
}

export async function ftsSearch(
  db: Database,
  query: string,
  limit: number,
  projectId?: string,
  type?: string,
  tags?: string[],
  minImportance?: number,
): Promise<Array<{ id: number; rank: number }>> {
  const pool = db.getPool();
  try {
    const params: unknown[] = [query, limit];
    const whereExtra = buildWhereClause(params, projectId, type, tags, minImportance);
    const result = await pool.query(
      // `search_vector` exists but is NEVER populated: the schema's
      // `ADD COLUMN IF NOT EXISTS search_vector ... GENERATED ALWAYS AS ...` is a no-op,
      // because the plain column already exists from CREATE TABLE, and Postgres will not
      // upgrade a plain column into a generated one. Reading it made this whole arm return
      // zero rows for every query, forever. Build the vector from the row instead. This is a
      // sequential scan; the shared pool is small, and correctness beats an index that does
      // not exist. Do NOT "fix" this by ALTERing the shared memories table.
      `SELECT id, ts_rank_cd(
                setweight(to_tsvector('english', coalesce(content, '')), 'A') ||
                setweight(to_tsvector('english', coalesce(array_to_string(tags, ' '), '')), 'B') ||
                setweight(to_tsvector('english', coalesce(metadata::text, '')), 'C'),
                websearch_to_tsquery('english', $1)) AS rank
       FROM memories
       WHERE (
                setweight(to_tsvector('english', coalesce(content, '')), 'A') ||
                setweight(to_tsvector('english', coalesce(array_to_string(tags, ' '), '')), 'B') ||
                setweight(to_tsvector('english', coalesce(metadata::text, '')), 'C')
              ) @@ websearch_to_tsquery('english', $1)
         ${whereExtra}
       ORDER BY rank DESC
       LIMIT $2`,
      params,
    );
    return result.rows.map((r: any, i: number) => ({ id: r.id, rank: 1 / (RRF_K + i + 1) }));
  } catch (error) {
    // An empty arm and a broken arm must not look identical to the caller.
    getLogger().warn(
      `Lexical (full-text) search FAILED and returned no rows; results are embedding-only. ${
        error instanceof Error ? error.message : String(error)
      }`,
    );
    return [];
  }
}

export async function vectorSearch(
  db: Database,
  embedding: number[],
  limit: number,
  projectId?: string,
  type?: string,
  tags?: string[],
  minImportance?: number,
): Promise<Array<{ id: number; rank: number }>> {
  const pool = db.getPool();
  const params: unknown[] = [JSON.stringify(embedding), limit];
  const whereExtra = buildWhereClause(params, projectId, type, tags, minImportance);
  const result = await pool.query(
    `SELECT id, 1 - (embedding <=> $1::vector) AS similarity
     FROM memories
     WHERE embedding IS NOT NULL
       ${whereExtra}
     ORDER BY embedding <=> $1::vector
     LIMIT $2`,
    params,
  );
  return result.rows.map((r: any, i: number) => ({ id: r.id, rank: 1 / (RRF_K + i + 1) }));
}

export async function entityMatchBoost(
  db: Database,
  query: string,
  limit: number,
  projectId?: string,
  type?: string,
  tags?: string[],
  minImportance?: number,
): Promise<Array<{ id: number; boost: number }>> {
  const pool = db.getPool();
  const d = db.dialect;
  const like = `%${query.replace(/[%_]/g, '\\$&')}%`;
  const conceptsJson = JSON.stringify([query]);
  try {
    const params: unknown[] = [like, conceptsJson];
    const whereExtra = buildWhereClause(params, projectId, type, tags, minImportance);
    params.push(limit);
    const result = await pool.query(
      `SELECT id,
        CASE
          WHEN ${ilikeExpr(d, 'content', 1)} THEN 2.0
          WHEN ${jsonContainsParam(d, jsonExtractValue(d, 'metadata', 'extracted_concepts'), 2)} THEN 1.8
          WHEN ${ilikeExpr(d, 'tags::text', 1)} THEN 1.5
          ELSE 0.0
        END AS boost
       FROM memories
       WHERE (${ilikeExpr(d, 'content', 1)}
              OR ${ilikeExpr(d, 'tags::text', 1)}
              OR ${jsonContainsParam(d, jsonExtractValue(d, 'metadata', 'extracted_concepts'), 2)})
         ${whereExtra}
       LIMIT $${params.length}`,
      params,
    );
    return result.rows.map((r: any) => ({ id: r.id, boost: r.boost }));
  } catch {
    return [];
  }
}

export function reciprocalRankFusion(
  ...rankings: Array<Array<{ id: number; rank: number }>>
): Map<number, number> {
  const scores = new Map<number, number>();
  for (const ranking of rankings) {
    for (const entry of ranking) {
      scores.set(entry.id, (scores.get(entry.id) ?? 0) + entry.rank);
    }
  }
  return scores;
}

export function applyWeights(
  vectorScores: Map<number, number>,
  textScores: Map<number, number>,
  entityBoosts: Map<number, number>,
  recencyScores: Map<number, number>,
  weights: HybridWeights = DEFAULT_WEIGHTS,
): Map<number, number> {
  const allIds = new Set<number>([
    ...vectorScores.keys(),
    ...textScores.keys(),
    ...entityBoosts.keys(),
    ...recencyScores.keys(),
  ]);
  const final = new Map<number, number>();
  for (const id of allIds) {
    const v = vectorScores.get(id) ?? 0;
    const t = textScores.get(id) ?? 0;
    const e = entityBoosts.get(id) ?? 0;
    const r = recencyScores.get(id) ?? 0;
    final.set(id, v * weights.vector + t * weights.text + e * weights.entity + r * weights.recency);
  }
  return final;
}

export async function hybridSearch(
  db: Database,
  query: string,
  embedding: number[],
  limit: number,
  options: Omit<MemorySearchOptions, 'query'> & { weights?: HybridWeights } = {},
): Promise<Array<{ id: number; score: number }>> {
  const projectId = options.projectId;
  const type = options.type;
  const tags = options.tags;
  const minImportance = options.minImportance;
  const weights = options.weights ?? DEFAULT_WEIGHTS;
  const ftsAvailable = await checkFtsAvailable(db);

    let textScores: Map<number, number>;

  // Vector search (always available)
  const vectorResults = await vectorSearch(db, embedding, limit * 3, projectId, type, tags, minImportance);
  const vectorScores = reciprocalRankFusion(vectorResults);

  // FTS search (may be unavailable)
  if (ftsAvailable) {
    const ftsResults = await ftsSearch(db, query, limit * 3, projectId, type, tags, minImportance);
    textScores = reciprocalRankFusion(ftsResults);
  } else {
    textScores = new Map();
  }

   // Entity boost
   const entityResults = await entityMatchBoost(db, query, limit * 3, projectId, type, tags, minImportance);
   const entityBoosts = new Map(entityResults.map((e) => [e.id, e.boost]));

  // Recency boost (prefer recent memories)
  const recencyScores = new Map<number, number>();

  // Merge with weights
  const final = applyWeights(vectorScores, textScores, entityBoosts, recencyScores, weights);

  // Sort by score descending, take top limit
  return Array.from(final.entries())
    .sort((a, b) => b[1] - a[1])
    .slice(0, limit)
    .map(([id, score]) => ({ id, score }));
}

// The old guard asked "does a column named search_vector exist?". It does — and it is empty,
// so the guard said yes while the arm matched nothing. Ask instead whether the text-search
// machinery itself works, which is what we now depend on: to_tsvector over content.
async function checkFtsAvailable(db: Database): Promise<boolean> {
  try {
    const pool = db.getPool();
    await pool.query(
      `SELECT to_tsvector('english', 'probe') @@ websearch_to_tsquery('english', 'probe') AS ok`,
    );
    return true;
  } catch {
    return false;
  }
}

export { DEFAULT_WEIGHTS };
