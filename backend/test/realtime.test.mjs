import { before, after, test } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { createServer } from 'node:http';
import { createTestDatabase, issueTestSession } from './support.mjs';
import { MemoryBackend } from '../src/memory.mjs';
import { SessionIssuer } from '../src/sessions.mjs';
import { RealtimeCredentialBroker } from '../src/realtime.mjs';
import { createMemoryHandler } from '../src/http.mjs';

let db, memory;
before(async()=>{ db=await createTestDatabase(); memory=new MemoryBackend(db.runtime); });
after(async()=>{ if(db) await db.close(); });
const identity=()=>({tenantID:randomUUID(),userID:randomUUID(),accountID:null});
const fakeCredential='ek_test_ephemeral_ABCDEFGHIJKLMNOPQRSTUVWXYZ123456';

function broker(fetchImpl) {
  return new RealtimeCredentialBroker(db.runtime, {
    apiKey:'sk-test-server-key-never-returned',
    safetySecret:'test-only-safety-secret-at-least-thirty-two-bytes',
    model:'gpt-realtime-2.1',
    fetchImpl
  });
}

test('authenticated agent session mints bounded ephemeral credential with private safety identifier',async()=>{
  const principal=identity(); const session=await issueTestSession(db,principal); let call;
  const service=broker(async(url,options)=>{
    call={url:String(url),options};
    return new Response(JSON.stringify({value:fakeCredential,expires_at:2000000000}),{status:200});
  });

  const result=await service.mint('Bearer '+session.token);
  assert.deepEqual(result,{credential:fakeCredential,model:'gpt-realtime-2.1',expiresAt:2000000000});
  assert.equal(call.url,'https://api.openai.com/v1/realtime/client_secrets');
  assert.equal(call.options.method,'POST');
  assert.equal(call.options.headers.Authorization,'Bearer sk-test-server-key-never-returned');
  assert.match(call.options.headers['OpenAI-Safety-Identifier'],/^agent_[A-Za-z0-9_-]{43}$/);
  assert.deepEqual(JSON.parse(call.options.body),{session:{type:'realtime',model:'gpt-realtime-2.1'}});
  assert.equal(JSON.stringify(result).includes('sk-test-server-key-never-returned'),false);
  assert.equal(JSON.stringify(result).includes(principal.userID),false);
  assert.equal(JSON.stringify(result).includes(principal.tenantID),false);
});

test('safety identifier is stable per principal and separated across principals',async()=>{
  const a=identity(), b=identity();
  const aSessionOne=await issueTestSession(db,a), aSessionTwo=await issueTestSession(db,a), bSession=await issueTestSession(db,b);
  const identifiers=[];
  const service=broker(async(_url,options)=>{
    identifiers.push(options.headers['OpenAI-Safety-Identifier']);
    return new Response(JSON.stringify({value:fakeCredential}),{status:200});
  });
  await service.mint('Bearer '+aSessionOne.token);
  await service.mint('Bearer '+aSessionTwo.token);
  await service.mint('Bearer '+bSession.token);
  assert.equal(identifiers[0],identifiers[1]);
  assert.notEqual(identifiers[0],identifiers[2]);
  assert.equal(identifiers.some(value=>value.includes(a.userID)||value.includes(b.userID)),false);
});

test('unauthenticated or revoked session never reaches OpenAI',async()=>{
  let calls=0; const service=broker(async()=>{ calls++; return new Response('{}',{status:200}); });
  await assert.rejects(service.mint('Bearer invalid'),e=>e.status===401&&e.code==='unauthenticated');
  const revoked=await issueTestSession(db,identity());
  const issuer=new SessionIssuer(db.auth);
  await issuer.revoke(revoked.token);
  await assert.rejects(service.mint('Bearer '+revoked.token),e=>e.status===401&&e.code==='unauthenticated');
  assert.equal(calls,0);
});

test('provider failures and malformed provider responses are sanitized',async()=>{
  const session=await issueTestSession(db,identity());
  const rejected=broker(async()=>new Response(JSON.stringify({error:{message:'secret detail'}}),{status:429}));
  await assert.rejects(rejected.mint('Bearer '+session.token),e=>e.status===503&&e.code==='realtime_unavailable');

  const malformed=broker(async()=>new Response('{bad',{status:200}));
  await assert.rejects(malformed.mint('Bearer '+session.token),e=>e.status===503&&e.code==='realtime_invalid_response');

  const missing=broker(async()=>new Response(JSON.stringify({value:' bad token '}),{status:200}));
  await assert.rejects(missing.mint('Bearer '+session.token),e=>e.status===503&&e.code==='realtime_invalid_response');
});

test('HTTP endpoint accepts empty object only and never exposes server credential',async()=>{
  const principal=identity(); const session=await issueTestSession(db,principal); let calls=0;
  const service=broker(async()=>{ calls++; return new Response(JSON.stringify({value:fakeCredential}),{status:200}); });
  const server=createServer(createMemoryHandler(memory,service));
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  const base=`http://127.0.0.1:${server.address().port}`;
  try {
    const response=await fetch(base+'/v1/realtime/credential',{
      method:'POST',
      headers:{Authorization:'Bearer '+session.token,'Content-Type':'application/json'},
      body:'{}'
    });
    assert.equal(response.status,200);
    assert.equal(response.headers.get('cache-control'),'no-store');
    const text=await response.text();
    assert.equal(text.includes('sk-test-server-key-never-returned'),false);
    assert.deepEqual(JSON.parse(text),{result:{credential:fakeCredential,model:'gpt-realtime-2.1'}});

    const injection=await fetch(base+'/v1/realtime/credential',{
      method:'POST',
      headers:{Authorization:'Bearer '+session.token,'Content-Type':'application/json'},
      body:JSON.stringify({model:'other-model',userID:randomUUID()})
    });
    assert.equal(injection.status,400);
    assert.deepEqual(await injection.json(),{error:'invalid_request'});
    assert.equal(calls,1);

    const missingAuth=await fetch(base+'/v1/realtime/credential',{
      method:'POST',headers:{'Content-Type':'application/json'},body:'{}'
    });
    assert.equal(missingAuth.status,401);
    assert.deepEqual(await missingAuth.json(),{error:'unauthenticated'});
    assert.equal(calls,1);
  } finally { server.closeAllConnections(); await new Promise(resolve=>server.close(resolve)); }
});

test('HTTP endpoint is fail-closed when Realtime is not configured',async()=>{
  const session=await issueTestSession(db,identity());
  const server=createServer(createMemoryHandler(memory));
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  const base=`http://127.0.0.1:${server.address().port}`;
  try {
    const response=await fetch(base+'/v1/realtime/credential',{
      method:'POST',
      headers:{Authorization:'Bearer '+session.token,'Content-Type':'application/json'},
      body:'{}'
    });
    assert.equal(response.status,503);
    assert.deepEqual(await response.json(),{error:'realtime_unavailable'});
  } finally { server.closeAllConnections(); await new Promise(resolve=>server.close(resolve)); }
});

test('broker configuration rejects unsafe endpoints, secrets, and models',()=>{
  assert.throws(()=>new RealtimeCredentialBroker(db.runtime,{apiKey:'short',safetySecret:'x'.repeat(32)}),/api_key/);
  assert.throws(()=>new RealtimeCredentialBroker(db.runtime,{apiKey:'sk-test-long-enough',safetySecret:'short'}),/safety_secret/);
  assert.throws(()=>new RealtimeCredentialBroker(db.runtime,{apiKey:'sk-test-long-enough',safetySecret:'x'.repeat(32),model:'bad model'}),/model/);
  assert.throws(()=>new RealtimeCredentialBroker(db.runtime,{apiKey:'sk-test-long-enough',safetySecret:'x'.repeat(32),endpoint:'https://example.com/v1/realtime/client_secrets'}),/endpoint/);
});
