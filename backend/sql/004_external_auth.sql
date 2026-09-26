-- Provider-neutral external identity mapping and privileged session exchange.
-- The request-facing memory runtime never sees provider tokens or agent_auth credentials.
BEGIN;
SET LOCAL ROLE agent_owner;

CREATE TABLE agent_private.external_identities (
  provider text NOT NULL CHECK(length(provider) BETWEEN 1 AND 64),
  issuer text NOT NULL CHECK(length(issuer) BETWEEN 1 AND 1024),
  subject text NOT NULL CHECK(length(subject) BETWEEN 1 AND 1024),
  principal_id uuid NOT NULL REFERENCES agent_private.principals(id),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  last_seen_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY(provider, issuer, subject)
);
CREATE INDEX external_identities_principal_idx ON agent_private.external_identities(principal_id);

CREATE FUNCTION agent_private.resolve_external_principal(provider_name text, issuer_name text, subject_name text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE p uuid; t uuid; u uuid;
BEGIN
  IF provider_name IS NULL OR issuer_name IS NULL OR subject_name IS NULL
     OR length(provider_name) NOT BETWEEN 1 AND 64
     OR length(issuer_name) NOT BETWEEN 1 AND 1024
     OR length(subject_name) NOT BETWEEN 1 AND 1024
     OR issuer_name !~ '^https://' THEN
    RAISE EXCEPTION 'invalid_external_identity' USING ERRCODE='22023';
  END IF;

  -- Serialize first login for one external subject so concurrent exchanges cannot
  -- create multiple internal principals for the same provider identity.
  PERFORM pg_advisory_xact_lock(hashtextextended(jsonb_build_array(provider_name,issuer_name,subject_name)::text,0));
  SELECT principal_id INTO p FROM agent_private.external_identities
    WHERE provider=provider_name AND issuer=issuer_name AND subject=subject_name;
  IF p IS NOT NULL THEN
    UPDATE agent_private.external_identities SET last_seen_at=clock_timestamp()
      WHERE provider=provider_name AND issuer=issuer_name AND subject=subject_name;
    RETURN p;
  END IF;

  t := gen_random_uuid();
  u := gen_random_uuid();
  INSERT INTO agent_private.principals(tenant_id,user_id,account_id)
    VALUES(t,u,NULL) RETURNING id INTO p;
  INSERT INTO agent_private.external_identities(provider,issuer,subject,principal_id)
    VALUES(provider_name,issuer_name,subject_name,p);
  RETURN p;
END $$;

CREATE FUNCTION agent_private.issue_external_session(
  provider_name text, issuer_name text, subject_name text, digest bytea, expiry timestamptz)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE p uuid; result jsonb;
BEGIN
  IF octet_length(digest) IS DISTINCT FROM 32 OR expiry IS NULL
     OR expiry <= clock_timestamp() OR expiry > clock_timestamp() + interval '24 hours' THEN
    RAISE EXCEPTION 'invalid_session' USING ERRCODE='22023';
  END IF;
  p := agent_private.resolve_external_principal(provider_name,issuer_name,subject_name);
  INSERT INTO agent_private.sessions(token_hash,principal_id,expires_at) VALUES(digest,p,expiry);
  SELECT jsonb_build_object('tenantID',tenant_id,'userID',user_id,'accountID',account_id)
    INTO result FROM agent_private.principals WHERE id=p;
  RETURN result;
END $$;

-- Production agent_auth may mint sessions only from a verified external identity.
-- Arbitrary internal-principal session issuance remains available only to database
-- owners/admins for controlled migration and test fixtures.
REVOKE EXECUTE ON FUNCTION agent_private.issue_session(uuid,uuid,uuid,bytea,timestamptz) FROM agent_auth;
GRANT EXECUTE ON FUNCTION agent_private.issue_external_session(text,text,text,bytea,timestamptz),
  agent_private.revoke_session(bytea) TO agent_auth;
REVOKE ALL ON TABLE agent_private.external_identities FROM PUBLIC, agent_runtime, agent_writer, agent_auth;

COMMIT;
