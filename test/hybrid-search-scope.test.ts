import { describe, it } from 'node:test';
import assert from 'node:assert/strict';

import { hybridSearch } from '../dist/hybrid-search.js';
import { MemoryManager } from '../dist/memory-manager.js';

type CapturedQuery = { sql: string; params: unknown[] };

function mockDatabase(queries: CapturedQuery[]) {
  const pool = {
    async query(sql: string, params: unknown[] = []) {
      queries.push({ sql, params });
      return { rows: [], rowCount: 0 };
    },
  };
  return { getPool: () => pool, dialect: 'pg' } as any;
}

async function captureSearchQueries(searchMode: 'project' | 'legacy' | 'global') {
  const queries: CapturedQuery[] = [];
  await hybridSearch(mockDatabase(queries), 'scope-token', [0.1, 0.2], 5, {
    projectId: 'project-a',
    searchMode,
  });
  return queries.filter(({ sql }) => sql.includes('FROM memories'));
}

async function captureListQuery(searchMode: 'project' | 'legacy' | 'global') {
  const queries: CapturedQuery[] = [];
  const manager = new MemoryManager(mockDatabase(queries), {} as any);
  await manager.listMemories({ projectId: 'project-a', searchMode, limit: 5 });
  const query = queries.find(({ sql }) => sql.includes('SELECT * FROM memories WHERE 1=1'));
  assert.ok(query);
  return query;
}

describe('hybrid search project scope', () => {
  it('filters every search arm to the requested project', async () => {
    const queries = await captureSearchQueries('project');

    assert.equal(queries.length, 3);
    for (const { sql, params } of queries) {
      assert.match(sql, /project_id = \$\d+/);
      assert.ok(params.includes('project-a'));
    }
  });

  it('includes project and unscoped rows in legacy mode', async () => {
    const queries = await captureSearchQueries('legacy');

    assert.equal(queries.length, 3);
    for (const { sql, params } of queries) {
      assert.match(sql, /\(project_id = \$\d+ OR project_id IS NULL\)/);
      assert.ok(params.includes('project-a'));
    }
  });

  it('does not add a project predicate in global mode', async () => {
    const queries = await captureSearchQueries('global');

    assert.equal(queries.length, 3);
    for (const { sql, params } of queries) {
      assert.doesNotMatch(sql, /project_id/);
      assert.ok(!params.includes('project-a'));
    }
  });
});

describe('memory listing project scope', () => {
  it('filters listings to the requested project', async () => {
    const { sql, params } = await captureListQuery('project');

    assert.match(sql, /project_id = \$\d+/);
    assert.ok(params.includes('project-a'));
  });

  it('includes project and unscoped rows in legacy mode', async () => {
    const { sql, params } = await captureListQuery('legacy');

    assert.match(sql, /\(project_id = \$\d+ OR project_id IS NULL\)/);
    assert.ok(params.includes('project-a'));
  });

  it('does not add a project predicate in global mode', async () => {
    const { sql, params } = await captureListQuery('global');

    assert.doesNotMatch(sql, /project_id/);
    assert.ok(!params.includes('project-a'));
  });
});
