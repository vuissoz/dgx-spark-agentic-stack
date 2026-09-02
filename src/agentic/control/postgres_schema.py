#!/usr/bin/env python3
"""src/agentic/control/postgres_schema.py — PostgreSQL schema for v2 control plane (§4, §5).

Defines the canonical source-of-truth tables for:
- users, projects, roles (§4 "utilisateurs, projets, rôles")
- agent definitions and runtime contexts (§5.1)
- sessions and runs with correlation tracking (§5.3)
- outbox for event-driven reconciler (§3.1)

This schema is written as raw SQL so it can be executed directly against
PostgreSQL (via psql or Alembic migrations in future).
"""

from __future__ import annotations

SCHEMA_SQL = """
-- ── Schema: agentic_control v2 ────────────────────────────────────────
-- Source of truth for identity, projects, sessions, and task orchestration.
-- Conforms to PLAN.md §4 (sources de vérité) and §5 (identité/projet/session).

CREATE SCHEMA IF NOT EXISTS agentic_control;

-- ── Users & Roles (§4, §5.1) ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS agentic_control.users (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         TEXT NOT NULL UNIQUE,          -- logical identity (e.g. "alice", "agent-bot")
    display_name    TEXT,
    roles           TEXT[] NOT NULL DEFAULT '{}',  -- ['admin', 'user', 'operator']
    projects        TEXT[] NOT NULL DEFAULT '{}',  -- projects user belongs to
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS agentic_control.user_secrets (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID NOT NULL REFERENCES agentic_control.users(id),
    secret_name     TEXT NOT NULL,                 -- key in SecretStore
    scope           TEXT NOT NULL DEFAULT '*',      -- '*' or project ID
    value_hash      TEXT NOT NULL,                  -- hashed for quick existence check
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at      TIMESTAMPTZ,
    UNIQUE (user_id, secret_name)
);

-- ── Projects (§5.1) ──────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS agentic_control.projects (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id      TEXT NOT NULL UNIQUE,           -- e.g. "ARTANY", "SEGMENTATION-RTMRI"
    owner_id        UUID NOT NULL REFERENCES agentic_control.users(id),
    workspace_path  TEXT NOT NULL,                  -- persistent volume mount path
    rag_collection_prefix TEXT NOT NULL DEFAULT '', -- prefix for RAG collections (§12.3)
    allowed_models  TEXT[] NOT NULL DEFAULT '{}',   -- models user can use in this project
    settings        JSONB NOT NULL DEFAULT '{}',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ── Agent Definitions (§5.1, §3.2) ───────────────────────────────────
CREATE TABLE IF NOT EXISTS agentic_control.agent_definitions (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    harness_name    TEXT NOT NULL,                  -- 'codex', 'claude', 'openhands', ...
    version         TEXT NOT NULL,
    image_tag       TEXT NOT NULL,
    capabilities    TEXT[] NOT NULL DEFAULT '{}',   -- ['tool-calling', 'sub-agents', ...]
    primary_surface TEXT NOT NULL DEFAULT 'cli',
    allowed_domains TEXT[] NOT NULL DEFAULT '{}',
    CONSTRAINT chk_harness_name CHECK (length(harness_name) > 0),
    UNIQUE (harness_name, version)
);

-- ── Sessions & Runs (§5.3, §5.4) ─────────────────────────────────────
CREATE TABLE IF NOT EXISTS agentic_control.sessions (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id      TEXT NOT NULL UNIQUE,
    user_id         UUID NOT NULL REFERENCES agentic_control.users(id),
    agent_def_id    UUID NOT NULL REFERENCES agentic_control.agent_definitions(id),
    project_id      UUID REFERENCES agentic_control.projects(id),
    harness         TEXT NOT NULL,                  -- canonical harness name
    state           TEXT NOT NULL DEFAULT 'active',  -- active, paused, completed, failed
    run_id          TEXT,                           -- correlation ID
    parent_run_id   TEXT,                           -- for multi-agent trees (§5.4)
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS agentic_control.runs (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    run_id          TEXT NOT NULL UNIQUE,
    parent_run_id   TEXT,                           -- optional parent in multi-agent tree
    user_id         UUID NOT NULL REFERENCES agentic_control.users(id),
    project_id      UUID REFERENCES agentic_control.projects(id),
    harness         TEXT NOT NULL,
    state           TEXT NOT NULL DEFAULT 'running', -- running, completed, failed, cancelled
    started_at      TIMESTAMPTZ,
    finished_at     TIMESTAMPTZ,
    metrics         JSONB NOT NULL DEFAULT '{}',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ── Outbox (§3.1) ────────────────────────────────────────────────────
-- Durable task results for reconciler to read and apply.
CREATE TABLE IF NOT EXISTS agentic_control.outbox (
    id              BIGSERIAL PRIMARY KEY,
    task_id         TEXT NOT NULL,
    correlation_id  TEXT NOT NULL,
    status          TEXT NOT NULL DEFAULT 'pending', -- pending, running, completed, failed
    result          JSONB NOT NULL DEFAULT '{}',
    submitted_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    processed_at    TIMESTAMPTZ                     -- set when reconciler processes it
);

CREATE INDEX IF NOT EXISTS idx_outbox_status ON agentic_control.outbox (status, submitted_at);
CREATE INDEX IF NOT EXISTS idx_outbox_correlation ON agentic_control.outbox (correlation_id);

-- ── Audit Log (§4 "audit corrélé complet") ───────────────────────────
CREATE TABLE IF NOT EXISTS agentic_control.audit_log (
    id              BIGSERIAL PRIMARY KEY,
    actor           TEXT NOT NULL,                  -- user or agent identity
    action          TEXT NOT NULL,                  -- 'create_session', 'admit_workload', ...
    target_type     TEXT NOT NULL,                  -- 'session', 'workload', 'project'
    target_id       TEXT,
    details         JSONB NOT NULL DEFAULT '{}',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_audit_actor ON agentic_control.audit_log (actor, created_at DESC);

-- ── Seed agent definitions (v2 baseline) ─────────────────────────────
INSERT INTO agentic_control.agent_definitions (harness_name, version, image_tag, capabilities, primary_surface, allowed_domains)
VALUES
    ('codex', 'latest', 'agentic/agent-cli-base:local', ARRAY['tool-calling', 'streaming'], 'cli', '{"github.com", "openai.com"}'),
    ('claude', 'latest', 'agentic/agent-cli-base:local', ARRAY['tool-calling', 'streaming', 'sub-agents'], 'cli', '{"github.com", "anthropic.com"}'),
    ('openhands', 'latest', 'agentic/openhands:local', ARRAY['tool-calling', 'browser', 'terminal'], 'web', '{"github.com", "huggingface.co"}'),
    ('openclaw', 'latest', 'agentic/openclaw:local', ARRAY['channel-binding', 'multi-agent'], 'cli', '{}')
ON CONFLICT (harness_name, version) DO NOTHING;
"""


def get_schema_sql() -> str:
    """Return the complete schema SQL."""
    return SCHEMA_SQL


def print_schema() -> None:
    """Print schema to stdout for use with psql."""
    print(SCHEMA_SQL)


if __name__ == "__main__":
    print_schema()
