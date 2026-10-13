-- Dev only. One tenant, one team store, a curator, a contributor and an agent.
-- A token's `sub` must equal the external_id below.
INSERT INTO tenant (id, name) VALUES ('00000000-0000-4000-8000-000000000001', 'dev');

INSERT INTO principal (id, tenant_id, kind, external_id, display_name) VALUES
(
  '00000000-0000-4000-8000-0000000000a1', '00000000-0000-4000-8000-000000000001',
  'user', 'curator@dev', 'Dev Curator'
),
(
  '00000000-0000-4000-8000-0000000000a2', '00000000-0000-4000-8000-000000000001',
  'user', 'contributor@dev', 'Dev Contributor'
),
(
  '00000000-0000-4000-8000-0000000000a3', '00000000-0000-4000-8000-000000000001',
  'agent', 'agent@dev', 'Dev Agent'
);

INSERT INTO store (id, tenant_id, kind, slug, description) VALUES
(
  '00000000-0000-4000-8000-0000000000b1', '00000000-0000-4000-8000-000000000001',
  'team', 'dev-team', 'Dev team store'
);

INSERT INTO store_grant (store_id, principal_id, role, tenant_id) VALUES
(
  '00000000-0000-4000-8000-0000000000b1', '00000000-0000-4000-8000-0000000000a1',
  'curator', '00000000-0000-4000-8000-000000000001'
),
(
  '00000000-0000-4000-8000-0000000000b1', '00000000-0000-4000-8000-0000000000a2',
  'contributor', '00000000-0000-4000-8000-000000000001'
),
(
  '00000000-0000-4000-8000-0000000000b1', '00000000-0000-4000-8000-0000000000a3',
  'contributor', '00000000-0000-4000-8000-000000000001'
);
