-- Apply after 001. Function replacement preserves its non-owner writer role and grants.
BEGIN;
CREATE OR REPLACE FUNCTION agent_api.search_memories(kind text, ref text, q text, max_rows integer)
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
  -- Cached IDs are untrusted candidates. Reapply ownership, scope, lexical
  -- relevance and the caller's bound even if the cache entry was corrupted.
  SELECT COALESCE(jsonb_agg(to_jsonb(m)-'principal_id' ORDER BY m.id),'[]'::jsonb) INTO result
    FROM (SELECT * FROM agent_data.memories WHERE principal_id=p AND id=ANY(ids)
      AND scope_kind=kind AND scope_reference=ref
      AND strpos(lower(content::text),lower(q))>0 ORDER BY id LIMIT max_rows) m;
  RETURN result;
END $$;
COMMIT;
