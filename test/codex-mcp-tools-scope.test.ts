import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { invokeMcpTool } from '../dist/codex-mcp-tools.js';

// Patch #15: reads must not be fenced to the server's own cwd.
//
// A stdio MCP server's process.cwd() is the runtime root (launch-mcp.mjs chdir()s there),
// never the client's project. Deriving a default projectId from it silently scoped every
// search_memories / list_memories call to the few rows misattributed to
// "cross-session-memory", and the zero-hit cascade never fired because vector search
// always returns neighbours. Reads now default to global scope; an explicit searchMode
// still fences.

function stubBridge() {
  const calls: Array<{ name: string; input: Record<string, unknown> }> = [];
  const bridge = {
    searchMemories: async (input: Record<string, unknown>) => { calls.push({ name: 'search', input }); return { results: [], cascaded: [] }; },
    listMemories: async (input: Record<string, unknown>) => { calls.push({ name: 'list', input }); return []; },
  };
  return { bridge: bridge as never, calls };
}

describe('MCP read tools default to global scope', () => {
  it('search_memories without projectId is global and carries no cwd-derived projectId', async () => {
    const { bridge, calls } = stubBridge();
    await invokeMcpTool(bridge, 'search_memories', { query: 'anything' });
    assert.equal(calls.length, 1);
    assert.equal(calls[0].input.searchMode, 'global');
    assert.equal(calls[0].input.projectId, undefined);
  });

  it('search_memories with projectId but no searchMode stays global (shared pool, per-machine paths)', async () => {
    const { bridge, calls } = stubBridge();
    await invokeMcpTool(bridge, 'search_memories', { query: 'anything', projectId: 'C:\Users\jtm\Dropbox\Code' });
    assert.equal(calls[0].input.searchMode, 'global');
    assert.equal(calls[0].input.projectId, 'C:\Users\jtm\Dropbox\Code');
  });

  it('an explicit searchMode is honoured', async () => {
    const { bridge, calls } = stubBridge();
    await invokeMcpTool(bridge, 'search_memories', { query: 'anything', projectId: 'p', searchMode: 'project' });
    assert.equal(calls[0].input.searchMode, 'project');
    await invokeMcpTool(bridge, 'search_memories', { query: 'anything', projectId: 'p', searchMode: 'legacy' });
    assert.equal(calls[1].input.searchMode, 'legacy');
  });

  it('list_memories follows the same rule', async () => {
    const { bridge, calls } = stubBridge();
    await invokeMcpTool(bridge, 'list_memories', {});
    assert.equal(calls[0].input.searchMode, 'global');
    assert.equal(calls[0].input.projectId, undefined);
    await invokeMcpTool(bridge, 'list_memories', { projectId: 'p', searchMode: 'project' });
    assert.equal(calls[1].input.searchMode, 'project');
    assert.equal(calls[1].input.projectId, 'p');
  });
});
