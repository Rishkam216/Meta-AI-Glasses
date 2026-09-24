-- Run ONCE as a database administrator in a fresh database. Transactional DDL;
-- never grant these owner/writer/auth roles to the runtime login.
BEGIN;
CREATE ROLE agent_owner NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
CREATE ROLE agent_writer NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
CREATE ROLE agent_auth NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
CREATE ROLE agent_runtime NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
CREATE SCHEMA agent_private AUTHORIZATION agent_owner;
CREATE SCHEMA agent_data AUTHORIZATION agent_owner;
CREATE SCHEMA agent_api AUTHORIZATION agent_owner;
REVOKE ALL ON SCHEMA agent_private, agent_data, agent_api FROM PUBLIC;
GRANT USAGE ON SCHEMA agent_private, agent_data, agent_api TO agent_writer;
GRANT USAGE ON SCHEMA agent_private, agent_data, agent_api TO agent_runtime;
GRANT USAGE ON SCHEMA agent_private TO agent_auth;
SET LOCAL ROLE agent_owner;
ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

CREATE TABLE agent_private.principals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  user_id uuid NOT NULL,
  account_id uuid,
  UNIQUE NULLS NOT DISTINCT (tenant_id, user_id, account_id)
);
CREATE TABLE agent_private.sessions (
  token_hash bytea PRIMARY KEY CHECK (octet_length(token_hash) = 32),
  principal_id uuid NOT NULL REFERENCES agent_private.principals(id),
  expires_at timestamptz NOT NULL,
  revoked_at timestamptz
);

-- Only a separate trusted authentication issuer may provision sessions. The
-- request-facing runtime cannot mint sessions or read the session table.
CREATE FUNCTION agent_private.issue_session(t uuid, u uuid, a uuid, digest bytea, expiry timestamptz)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE p uuid;
BEGIN
  IF t IS NULL OR u IS NULL OR octet_length(digest) IS DISTINCT FROM 32
     OR expiry IS NULL OR expiry <= clock_timestamp() OR expiry > clock_timestamp() + interval '24 hours' THEN
    RAISE EXCEPTION 'invalid_session' USING ERRCODE = '22023';
  END IF;
  INSERT INTO agent_private.principals(tenant_id,user_id,account_id) VALUES(t,u,a)
    ON CONFLICT (tenant_id,user_id,account_id) DO UPDATE SET tenant_id = EXCLUDED.tenant_id RETURNING id INTO p;
  INSERT INTO agent_private.sessions(token_hash,principal_id,expires_at) VALUES(digest,p,expiry);
  RETURN p;
END $$;
CREATE FUNCTION agent_private.revoke_session(digest bytea) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  UPDATE agent_private.sessions SET revoked_at = clock_timestamp() WHERE token_hash = digest;
$$;
GRANT EXECUTE ON FUNCTION agent_private.issue_session(uuid,uuid,uuid,bytea,timestamptz),
  agent_private.revoke_session(bytea) TO agent_auth;

-- Identity is derived from an opaque 256-bit bearer session, never a caller's
-- user/tenant GUC. A FOR SHARE lock serializes revocation with an in-flight
-- operation. Revocation takes effect for operations after its commit.
CREATE FUNCTION agent_private.current_principal() RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE p uuid; bearer text := current_setting('agent.session_token', true);
BEGIN
  IF bearer IS NULL OR bearer !~ '^[A-Za-z0-9_-]{43}$' THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = '28000';
  END IF;
  SELECT principal_id INTO p FROM agent_private.sessions
    WHERE token_hash = sha256(convert_to(bearer,'UTF8')) AND revoked_at IS NULL
      AND expires_at > clock_timestamp() FOR SHARE;
  IF p IS NULL THEN RAISE EXCEPTION 'unauthenticated' USING ERRCODE = '28000'; END IF;
  RETURN p;
END $$;
GRANT EXECUTE ON FUNCTION agent_private.current_principal() TO agent_writer, agent_runtime;
CREATE FUNCTION agent_api.identity() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE p uuid := agent_private.current_principal(); result jsonb;
BEGIN
  SELECT jsonb_build_object('tenantID',tenant_id,'userID',user_id,'accountID',account_id)
    INTO result FROM agent_private.principals WHERE id=p;
  RETURN result;
END $$;
GRANT EXECUTE ON FUNCTION agent_api.identity() TO agent_runtime;

-- This is the cloud storage boundary, not a replacement for Swift's complete
-- canonical ledger/supersession/provider queue semantics. No shared ACL yet.
CREATE TABLE agent_data.memories (
  principal_id uuid NOT NULL DEFAULT agent_private.current_principal(),
  id uuid NOT NULL,
  scope_kind text NOT NULL CHECK(scope_kind IN ('user','project','workspace')),
  scope_reference text NOT NULL DEFAULT '',
  content jsonb NOT NULL CHECK(octet_length(content::text) <= 32768),
  provenance jsonb NOT NULL DEFAULT '[]' CHECK(jsonb_typeof(provenance)='array' AND octet_length(provenance::text)<=8192),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY(principal_id,id),
  CHECK((scope_kind='user' AND scope_reference='') OR
    (scope_kind IN ('project','workspace') AND length(btrim(scope_reference))>0 AND octet_length(scope_reference)<=256))
);
CREATE TABLE agent_data.tombstones (
  principal_id uuid NOT NULL DEFAULT agent_private.current_principal(),
  memory_id uuid NOT NULL,
  deleted_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY(principal_id,memory_id)
);
CREATE TABLE agent_data.revisions (
  principal_id uuid PRIMARY KEY DEFAULT agent_private.current_principal(),
  revision bigint NOT NULL CHECK(revision > 0)
);
CREATE TABLE agent_data.retrieval_cache (
  principal_id uuid NOT NULL DEFAULT agent_private.current_principal(),
  query_hash bytea NOT NULL CHECK(octet_length(query_hash)=32),
  revision bigint NOT NULL,
  memory_ids uuid[] NOT NULL CHECK(cardinality(memory_ids)<=100),
  expires_at timestamptz NOT NULL,
  PRIMARY KEY(principal_id,query_hash)
);
DO $$ DECLARE tbl text; BEGIN
  FOREACH tbl IN ARRAY ARRAY['memories','tombstones','revisions','retrieval_cache'] LOOP
    EXECUTE format('ALTER TABLE agent_data.%I ENABLE ROW LEVEL SECURITY',tbl);
    EXECUTE format('ALTER TABLE agent_data.%I FORCE ROW LEVEL SECURITY',tbl);
    EXECUTE format('CREATE POLICY own_principal ON agent_data.%I TO agent_runtime, agent_writer USING
      (principal_id = (SELECT agent_private.current_principal())) WITH CHECK
      (principal_id = (SELECT agent_private.current_principal()))',tbl);
  END LOOP;
END $$;
GRANT SELECT ON ALL TABLES IN SCHEMA agent_data TO agent_runtime;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA agent_data TO agent_writer;

-- Even the writer cannot transfer ownership or mutate canonical content in
-- place. Replacement/supersession will require a separate validated operation.
CREATE FUNCTION agent_private.immutable_record() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
BEGIN RAISE EXCEPTION 'immutable_record' USING ERRCODE='42501'; END $$;
CREATE TRIGGER immutable_record BEFORE UPDATE ON agent_data.memories
  FOR EACH ROW EXECUTE FUNCTION agent_private.immutable_record();

CREATE FUNCTION agent_private.invalidate_cache() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
DECLARE p uuid := COALESCE(NEW.principal_id,OLD.principal_id);
BEGIN
  INSERT INTO agent_data.revisions(principal_id,revision) VALUES(p,1)
    ON CONFLICT(principal_id) DO UPDATE SET revision=agent_data.revisions.revision+1;
  DELETE FROM agent_data.retrieval_cache WHERE principal_id=p;
  RETURN NULL;
END $$;
CREATE TRIGGER invalidate_memory_cache AFTER INSERT OR DELETE ON agent_data.memories
  FOR EACH ROW EXECUTE FUNCTION agent_private.invalidate_cache();
CREATE TRIGGER invalidate_tombstone_cache AFTER INSERT ON agent_data.tombstones
  FOR EACH ROW EXECUTE FUNCTION agent_private.invalidate_cache();

-- Functions below execute as a NOLOGIN, NOBYPASSRLS, non-owner writer. All
-- ownership comes from current_principal(). Runtime has no table write grants.
CREATE FUNCTION agent_api.remember(mid uuid, kind text, ref text, body jsonb, sources jsonb)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE p uuid := agent_private.current_principal();
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended(p::text,0));
  IF EXISTS(SELECT 1 FROM agent_data.tombstones WHERE principal_id=p AND memory_id=mid) THEN
    RAISE EXCEPTION 'deleted_memory' USING ERRCODE='23505';
  END IF;
  INSERT INTO agent_data.memories(principal_id,id,scope_kind,scope_reference,content,provenance)
    VALUES(p,mid,kind,ref,body,sources);
  RETURN mid;
END $$;
CREATE FUNCTION agent_api.forget(mid uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE p uuid := agent_private.current_principal();
BEGIN
  IF mid IS NULL THEN RAISE EXCEPTION 'invalid_id' USING ERRCODE='22023'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(p::text,0));
  INSERT INTO agent_data.tombstones(principal_id,memory_id) VALUES(p,mid) ON CONFLICT DO NOTHING;
  DELETE FROM agent_data.memories WHERE principal_id=p AND id=mid;
END $$;
CREATE FUNCTION agent_api.read_memory(mid uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE p uuid := agent_private.current_principal(); result jsonb;
BEGIN
  SELECT to_jsonb(m)-'principal_id' INTO result FROM agent_data.memories m WHERE principal_id=p AND id=mid;
  RETURN result;
END $$;
CREATE FUNCTION agent_api.search_memories(kind text, ref text, q text, max_rows integer)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE p uuid := agent_private.current_principal(); key bytea; rev bigint; ids uuid[]; result jsonb;
BEGIN
  IF kind IS NULL OR ref IS NULL OR kind NOT IN ('user','project','workspace')
    OR (kind='user' AND ref<>'') OR (kind<>'user' AND (length(btrim(ref))=0 OR octet_length(ref)>256))
    OR q IS NULL OR length(btrim(q))=0 OR octet_length(q)>1024 OR max_rows IS NULL OR max_rows NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION 'invalid_query' USING ERRCODE='22023';
  END IF;
  -- Serialize lookup/population with remember/forget so a delayed cache fill
  -- cannot reintroduce a removed result. Only this principal is locked.
  PERFORM pg_advisory_xact_lock(hashtextextended(p::text,0));
  SELECT COALESCE((SELECT revision FROM agent_data.revisions WHERE principal_id=p),0) INTO rev;
  key := sha256(convert_to(jsonb_build_array(kind,ref,q,max_rows)::text,'UTF8'));
  SELECT memory_ids INTO ids FROM agent_data.retrieval_cache WHERE principal_id=p AND query_hash=key
    AND revision=rev AND expires_at>clock_timestamp();
  IF ids IS NULL THEN
    SELECT COALESCE(array_agg(id ORDER BY id),'{}'::uuid[]) INTO ids FROM
      (SELECT id FROM agent_data.memories WHERE principal_id=p AND scope_kind=kind AND scope_reference=ref
        AND strpos(lower(content::text),lower(q))>0 ORDER BY id LIMIT max_rows) hits;
    DELETE FROM agent_data.retrieval_cache WHERE principal_id=p AND expires_at<=clock_timestamp();
    -- Hard per-principal entry bound; full eviction is deterministic and safe.
    IF (SELECT count(*) FROM agent_data.retrieval_cache WHERE principal_id=p)>=128 THEN
      DELETE FROM agent_data.retrieval_cache WHERE principal_id=p;
    END IF;
    INSERT INTO agent_data.retrieval_cache(principal_id,query_hash,revision,memory_ids,expires_at)
      VALUES(p,key,rev,ids,clock_timestamp()+interval '30 seconds')
      ON CONFLICT(principal_id,query_hash) DO UPDATE SET revision=EXCLUDED.revision,
        memory_ids=EXCLUDED.memory_ids,expires_at=EXCLUDED.expires_at;
  END IF;
  -- Re-resolve cached references under RLS and the requested scope. Never
  -- store raw memory content in the cache or trust arbitrary cached payloads.
  SELECT COALESCE(jsonb_agg(to_jsonb(m)-'principal_id' ORDER BY m.id),'[]'::jsonb) INTO result
    FROM agent_data.memories m WHERE principal_id=p AND id=ANY(ids) AND scope_kind=kind AND scope_reference=ref;
  RETURN result;
END $$;
CREATE FUNCTION agent_api.export_page(after_id uuid, max_rows integer) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE p uuid := agent_private.current_principal(); result jsonb;
BEGIN
  IF max_rows IS NULL OR max_rows NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION 'invalid_limit' USING ERRCODE='22023'; END IF;
  -- Include tombstones in the same cursor space; deleted IDs cannot be reused.
  SELECT COALESCE(jsonb_agg(value ORDER BY id),'[]'::jsonb) INTO result FROM (
    SELECT id,to_jsonb(m)-'principal_id'||jsonb_build_object('entry_type','memory') AS value
      FROM agent_data.memories m WHERE principal_id=p AND (after_id IS NULL OR id>after_id)
    UNION ALL
    SELECT memory_id,jsonb_build_object('id',memory_id,'deleted_at',deleted_at,'entry_type','tombstone')
      FROM agent_data.tombstones WHERE principal_id=p AND (after_id IS NULL OR memory_id>after_id)
    ORDER BY id LIMIT max_rows
  ) page;
  RETURN result;
END $$;
RESET ROLE;
ALTER FUNCTION agent_api.remember(uuid,text,text,jsonb,jsonb) OWNER TO agent_writer;
ALTER FUNCTION agent_api.forget(uuid) OWNER TO agent_writer;
ALTER FUNCTION agent_api.read_memory(uuid) OWNER TO agent_writer;
ALTER FUNCTION agent_api.search_memories(text,text,text,integer) OWNER TO agent_writer;
ALTER FUNCTION agent_api.export_page(uuid,integer) OWNER TO agent_writer;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA agent_api TO agent_runtime;
REVOKE ALL ON ALL TABLES IN SCHEMA agent_private FROM PUBLIC, agent_runtime, agent_writer, agent_auth;
COMMIT;
