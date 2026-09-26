-- Canonical MemoryServiceLedger persistence bridge.
--
-- The Swift MemoryLedgerState remains the semantic authority for lineage,
-- supersession, derived references, tombstones, provider mappings, and provider
-- synchronization. PostgreSQL supplies the authoritative authenticated principal,
-- durable atomic persistence, optimistic concurrency, and database-enforced
-- cross-principal isolation. The entire v3 canonical state changes in one CAS.
BEGIN;
SET LOCAL ROLE agent_owner;

CREATE TABLE agent_data.canonical_memory_snapshots (
  principal_id uuid PRIMARY KEY DEFAULT agent_private.current_principal(),
  revision bigint NOT NULL CHECK (revision BETWEEN 1 AND 9007199254740991),
  snapshot jsonb NOT NULL CHECK (
    jsonb_typeof(snapshot) = 'object'
    AND (snapshot->>'formatVersion')::integer = 3
    AND jsonb_typeof(snapshot->'memories') = 'array'
    AND jsonb_typeof(snapshot->'providerMappings') = 'array'
    AND jsonb_typeof(snapshot->'tombstones') = 'array'
    AND jsonb_typeof(snapshot->'synchronization') = 'object'
    AND octet_length(snapshot::text) <= 8388608
  ),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
ALTER TABLE agent_data.canonical_memory_snapshots ENABLE ROW LEVEL SECURITY;
ALTER TABLE agent_data.canonical_memory_snapshots FORCE ROW LEVEL SECURITY;
CREATE POLICY own_principal ON agent_data.canonical_memory_snapshots
  TO agent_runtime, agent_writer
  USING (principal_id = (SELECT agent_private.current_principal()))
  WITH CHECK (principal_id = (SELECT agent_private.current_principal()));
GRANT SELECT ON agent_data.canonical_memory_snapshots TO agent_runtime;
GRANT SELECT, INSERT, UPDATE ON agent_data.canonical_memory_snapshots TO agent_writer;

-- A request may never smuggle another tenant/user/account identity inside the
-- opaque snapshot. The function is owned by agent_owner because the writer role
-- intentionally cannot read agent_private.principals directly.
CREATE FUNCTION agent_private.canonical_snapshot_identity_valid(doc jsonb, p uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE t uuid; u uuid; a uuid;
BEGIN
  IF doc IS NULL OR jsonb_typeof(doc) <> 'object'
     OR doc->>'formatVersion' IS DISTINCT FROM '3'
     OR jsonb_typeof(doc->'memories') IS DISTINCT FROM 'array'
     OR jsonb_typeof(doc->'providerMappings') IS DISTINCT FROM 'array'
     OR jsonb_typeof(doc->'tombstones') IS DISTINCT FROM 'array'
     OR jsonb_typeof(doc->'synchronization') IS DISTINCT FROM 'object'
     OR jsonb_typeof(doc->'synchronization'->'entries') IS DISTINCT FROM 'array'
     OR octet_length(doc::text) > 8388608 THEN
    RETURN false;
  END IF;

  SELECT tenant_id,user_id,account_id INTO t,u,a
    FROM agent_private.principals WHERE id=p;
  IF t IS NULL OR u IS NULL THEN RETURN false; END IF;

  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(doc->'memories') e
      WHERE jsonb_typeof(e) <> 'object'
        OR e->'tenant'->>'tenantID' IS DISTINCT FROM t::text
        OR e->'tenant'->>'userID' IS DISTINCT FROM u::text
        OR CASE WHEN a IS NULL
             THEN e->'tenant'->>'accountID' IS NOT NULL
             ELSE e->'tenant'->>'accountID' IS DISTINCT FROM a::text END
  ) THEN RETURN false; END IF;

  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(doc->'tombstones') e
      WHERE jsonb_typeof(e) <> 'object'
        OR e->'tenant'->>'tenantID' IS DISTINCT FROM t::text
        OR e->'tenant'->>'userID' IS DISTINCT FROM u::text
        OR CASE WHEN a IS NULL
             THEN e->'tenant'->>'accountID' IS NOT NULL
             ELSE e->'tenant'->>'accountID' IS DISTINCT FROM a::text END
  ) THEN RETURN false; END IF;

  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(doc->'synchronization'->'entries') e
      WHERE jsonb_typeof(e) <> 'object'
        OR e->'tenant'->>'tenantID' IS DISTINCT FROM t::text
        OR e->'tenant'->>'userID' IS DISTINCT FROM u::text
        OR CASE WHEN a IS NULL
             THEN e->'tenant'->>'accountID' IS NOT NULL
             ELSE e->'tenant'->>'accountID' IS DISTINCT FROM a::text END
  ) THEN RETURN false; END IF;

  RETURN true;
END $$;
GRANT EXECUTE ON FUNCTION agent_private.canonical_snapshot_identity_valid(jsonb,uuid) TO agent_writer;

CREATE FUNCTION agent_api.canonical_memory_load() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE p uuid := agent_private.current_principal(); r bigint; doc jsonb;
BEGIN
  SELECT revision,snapshot INTO r,doc
    FROM agent_data.canonical_memory_snapshots WHERE principal_id=p;
  IF r IS NULL THEN
    RETURN jsonb_build_object('revision',0,'snapshot',NULL);
  END IF;
  RETURN jsonb_build_object('revision',r,'snapshot',doc);
END $$;

CREATE FUNCTION agent_api.canonical_memory_commit(expected_revision bigint, doc jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE p uuid := agent_private.current_principal(); next_revision bigint;
BEGIN
  IF expected_revision IS NULL OR expected_revision < 0
     OR expected_revision > 9007199254740990
     OR NOT agent_private.canonical_snapshot_identity_valid(doc,p) THEN
    RAISE EXCEPTION 'invalid_snapshot' USING ERRCODE='22023';
  END IF;

  -- Serialize state replacement for this exact principal. The expected revision
  -- still makes lost-update detection explicit to remote Swift clients.
  PERFORM pg_advisory_xact_lock(hashtextextended('canonical:' || p::text,0));
  IF expected_revision = 0 THEN
    INSERT INTO agent_data.canonical_memory_snapshots(principal_id,revision,snapshot)
      VALUES(p,1,doc) ON CONFLICT(principal_id) DO NOTHING
      RETURNING revision INTO next_revision;
  ELSE
    UPDATE agent_data.canonical_memory_snapshots
      SET revision=revision+1,snapshot=doc,updated_at=clock_timestamp()
      WHERE principal_id=p AND revision=expected_revision
        AND revision < 9007199254740991
      RETURNING revision INTO next_revision;
  END IF;

  IF next_revision IS NULL THEN
    RAISE EXCEPTION 'state_conflict' USING ERRCODE='40001';
  END IF;
  RETURN jsonb_build_object('revision',next_revision);
END $$;

RESET ROLE;
ALTER FUNCTION agent_api.canonical_memory_load() OWNER TO agent_writer;
ALTER FUNCTION agent_api.canonical_memory_commit(bigint,jsonb) OWNER TO agent_writer;
GRANT EXECUTE ON FUNCTION agent_api.canonical_memory_load(),
  agent_api.canonical_memory_commit(bigint,jsonb) TO agent_runtime;
REVOKE ALL ON agent_data.canonical_memory_snapshots FROM PUBLIC;
COMMIT;
