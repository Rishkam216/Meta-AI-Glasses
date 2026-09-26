import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';

test('required native database configuration cannot silently fall back to embedded tests',() => {
  const env={...process.env,REQUIRE_NATIVE_POSTGRES:'1'};
  delete env.TEST_POSTGRES_URL;
  const result=spawnSync(process.execPath,['--input-type=module','-e',
    "import {createTestDatabase} from './test/support.mjs'; await createTestDatabase();"],
    {cwd:new URL('../',import.meta.url),env,encoding:'utf8',timeout:10000});
  assert.equal(result.error,undefined); assert.notEqual(result.status,0);
  assert.match(result.stderr,/native_postgres_configuration_required/);
});
