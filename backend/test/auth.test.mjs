import { before, after, test } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID, randomBytes } from 'node:crypto';
import { createServer } from 'node:http';
import { createTestDatabase } from './support.mjs';
import { SessionIssuer } from '../src/sessions.mjs';
import { AuthService } from '../src/auth.mjs';
import { SupabaseIdentityProvider, IdentityProviderError } from '../src/identity.mjs';
import { createAuthHandler } from '../src/auth-http.mjs';
import { MemoryBackend } from '../src/memory.mjs';

let db, issuer, memory;
before(async()=>{ db=await createTestDatabase(); issuer=new SessionIssuer(db.auth); memory=new MemoryBackend(db.runtime); });
after(async()=>{ if(db) await db.close(); });
const external=(subject=randomUUID())=>({provider:'supabase',issuer:'https://unit-test.supabase.co/auth/v1',subject});
const code=expected=>error=>error.code===expected;

class FakeProvider {
  constructor(identity=external()){this.identity=identity;this.calls=[];}
  async verify(token){this.calls.push(token);if(token.startsWith('invalid-'))throw new IdentityProviderError('invalid_external_token');return this.identity;}
}

test('same external identity keeps stable internal identity across fresh opaque sessions',async()=>{
  const identity=external();
  const one=await issuer.issueExternal(identity), two=await issuer.issueExternal(identity);
  assert.notEqual(one.token,two.token); assert.deepEqual(one.identity,two.identity);
  assert.equal(one.identity.accountID,null);
  assert.deepEqual(await memory.execute('Bearer '+one.token,{operation:'identity',input:{}}),one.identity);
  assert.deepEqual(await memory.execute('Bearer '+two.token,{operation:'identity',input:{}}),one.identity);
});

test('different external subjects never share internal user or tenant identity',async()=>{
  const a=await issuer.issueExternal(external()), b=await issuer.issueExternal(external());
  assert.notEqual(a.identity.userID,b.identity.userID);
  assert.notEqual(a.identity.tenantID,b.identity.tenantID);
});

test('concurrent first login for one external subject resolves to one principal',async()=>{
  const identity=external();
  const sessions=await Promise.all(Array.from({length:5},()=>issuer.issueExternal(identity)));
  assert.equal(new Set(sessions.map(x=>x.identity.userID)).size,1);
  assert.equal(new Set(sessions.map(x=>x.identity.tenantID)).size,1);
});

test('only agent_auth can invoke external session minting and cannot choose arbitrary internal principals',async()=>{
  const digest=randomBytes(32), identity=external();
  await assert.rejects(db.auth.transaction(tx=>tx.query(
    "SELECT agent_private.issue_session(gen_random_uuid(),gen_random_uuid(),NULL,$1::bytea,now()+interval '1 hour')",[digest])),code('42501'));
  await assert.rejects(db.auth.transaction(tx=>tx.query(
    'SELECT agent_private.resolve_external_principal($1,$2,$3)',[identity.provider,identity.issuer,identity.subject])),code('42501'));
  const mint="SELECT agent_private.issue_external_session($1,$2,$3,$4::bytea,now()+interval '1 hour')";
  await assert.rejects(db.runtime.transaction(tx=>tx.query(mint,[identity.provider,identity.issuer,identity.subject,digest])),code('42501'));
  await assert.rejects(db.writer.transaction(tx=>tx.query(mint,[identity.provider,identity.issuer,identity.subject,digest])),code('42501'));
  for(const sql of ['SELECT * FROM agent_private.external_identities','SELECT * FROM agent_private.principals','SELECT * FROM agent_private.sessions'])
    await assert.rejects(db.auth.transaction(tx=>tx.query(sql)),code('42501'));
});

test('AuthService exchanges external identity and logout revokes only the agent session',async()=>{
  const provider=new FakeProvider(); const service=new AuthService(provider,issuer);
  const session=await service.exchange('Bearer valid-external-access-token');
  assert.deepEqual(provider.calls,['valid-external-access-token']);
  assert.deepEqual(await memory.execute('Bearer '+session.token,{operation:'identity',input:{}}),session.identity);
  assert.deepEqual(await service.logout('Bearer '+session.token),{revoked:true});
  await assert.rejects(memory.execute('Bearer '+session.token,{operation:'identity',input:{}}),code('unauthenticated'));
  await assert.rejects(service.exchange('Bearer invalid-external-token-long-enough'),e=>e.code==='unauthenticated'&&e.status===401);
});

test('Supabase provider validates through Auth user endpoint with publishable key and bounded response',async()=>{
  const subject=randomUUID(); let call;
  const fetchImpl=async(url,options)=>{
    call={url:String(url),options};
    return new Response(JSON.stringify({id:subject}),{status:200,headers:{'content-type':'application/json'}});
  };
  const provider=new SupabaseIdentityProvider({projectURL:'https://demo.supabase.co',publishableKey:'sb_publishable_test',fetchImpl});
  const result=await provider.verify('header.payload.signature');
  assert.deepEqual(result,{provider:'supabase',issuer:'https://demo.supabase.co/auth/v1',subject});
  assert.equal(call.url,'https://demo.supabase.co/auth/v1/user');
  assert.equal(call.options.method,'GET'); assert.equal(call.options.redirect,'error');
  assert.equal(call.options.headers.apikey,'sb_publishable_test');
  assert.equal(call.options.headers.Authorization,'Bearer header.payload.signature');
});

test('Supabase provider fails closed on rejected, malformed and oversized responses',async()=>{
  const rejected=new SupabaseIdentityProvider({projectURL:'https://demo.supabase.co',publishableKey:'key',fetchImpl:async()=>new Response('{}',{status:401,headers:{'content-type':'application/json'}})});
  await assert.rejects(rejected.verify('header.payload.signature'),e=>e.code==='invalid_external_token');
  const malformed=new SupabaseIdentityProvider({projectURL:'https://demo.supabase.co',publishableKey:'key',fetchImpl:async()=>new Response('{bad',{status:200,headers:{'content-type':'application/json'}})});
  await assert.rejects(malformed.verify('header.payload.signature'),e=>e.code==='identity_provider_unavailable');
  const oversized=new SupabaseIdentityProvider({projectURL:'https://demo.supabase.co',publishableKey:'key',fetchImpl:async()=>new Response('{}',{status:200,headers:{'content-type':'application/json','content-length':'70000'}})});
  await assert.rejects(oversized.verify('header.payload.signature'),e=>e.code==='identity_provider_unavailable');
});

test('auth HTTP boundary accepts no body, never caches, and exposes only safe errors',async()=>{
  const service=new AuthService(new FakeProvider(),issuer);
  const server=createServer(createAuthHandler(service));
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  const base=`http://127.0.0.1:${server.address().port}`;
  try {
    const exchange=await fetch(base+'/v1/auth/exchange',{method:'POST',headers:{Authorization:'Bearer valid-external-access-token'}});
    assert.equal(exchange.status,200); assert.equal(exchange.headers.get('cache-control'),'no-store');
    const session=(await exchange.json()).result; assert(/^[A-Za-z0-9_-]{43}$/.test(session.token));
    const body=await fetch(base+'/v1/auth/exchange',{method:'POST',headers:{Authorization:'Bearer valid-external-access-token'},body:'{}'});
    assert.equal(body.status,400); assert.deepEqual(await body.json(),{error:'body_not_allowed'});
    const missing=await fetch(base+'/v1/auth/exchange',{method:'POST'});
    assert.equal(missing.status,401); assert.deepEqual(await missing.json(),{error:'unauthenticated'});
    const logout=await fetch(base+'/v1/auth/logout',{method:'POST',headers:{Authorization:'Bearer '+session.token}});
    assert.equal(logout.status,200); assert.deepEqual(await logout.json(),{result:{revoked:true}});
  } finally { server.closeAllConnections(); await new Promise(resolve=>server.close(resolve)); }
});
