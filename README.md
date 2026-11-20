# MemChat — Single-Pass Lean GraphRAG Client Simulation

A conversational client simulator implementing the architecture in [specsheet.md](specsheet.md): an Agentic GraphRAG pipeline that models a therapy client's psychological state (beliefs, automatic thoughts, emotion adjectives on each client utterance, coping modes) as a Neo4j property graph, with a single-LLM unified generation step.

## Stack

| Component | Choice |
| --- | --- |
| Graph DB | Neo4j 5 (Docker) |
| Generation LLM | Azure OpenAI `gpt-5-mini` (single-pass, strict JSON) |
| Embeddings | `bge-m3` via local Ollama (utterance ↔ belief similarity) |
| Backend | Python + FastAPI |
| Frontend | Single-page chat UI with live psychological-state inspector |

## Run the database (Docker)

This compose file now runs **only** the Neo4j graph database, as its own
standalone project (`neo4j-db`) and container (`neo4j-db`).

Requires Docker. Ollama with `bge-m3` (`http://localhost:11437`) is only needed
later, when the backend is used to embed and score beliefs.

```bash
cp .env.example .env
docker compose up -d
```

- Neo4j Browser: http://localhost:17898 (login `neo4j` / `neo4j-db-password`)
- Bolt: `bolt://localhost:17989`

Ports 7474/7687 (and 17474/17687) are occupied by other Neo4j instances on this
host, hence the alternate mappings — deliberately different from the original
`memchat` stack (`17474`/`17687`). The graph lives in the compose-managed
volume `neo4j-db_neo4j_data`, so it can be started and stopped independently of
any app.

```bash
docker compose ps            # status / health
docker compose logs -f       # follow logs
docker compose down          # stop; keep graph data
docker compose down -v       # stop and wipe the Neo4j volume
```

The database is deliberately decoupled from its clients: any process running on
the host reaches it at `bolt://localhost:17989`, so the graph outlives app
processes and can be shared — e.g. by the copy of `backend/` that lives in
`memgraph/backend/lib/core/context/neo4j_db`.

## Run the app on the host

The `Dockerfile` / `requirements.txt` / `frontend/` are kept for reference, but
the FastAPI app is no longer part of the compose stack. To run it directly
against the container DB:

```bash
cp .env.example .env
#    -> fill in AZURE_OPENAI_ENDPOINT and AZURE_OPENAI_API_KEY

docker compose up -d      # start the DB
pip install -r requirements.txt
python3 -m uvicorn backend.main:app --host 0.0.0.0 --port 8021
```

## Where the personas come from

This project ships **no** personas of its own — `backend/personas/` and
`backend/seed.py` were removed on purpose. The single source of truth is the
memgraph backend's profile folders (`memgraph/backend/profiles/<Name>/profile.yaml`),
which are synced into this graph when a session starts, under the same profile
name:

- ``cognitive_model.core_beliefs`` → ``Belief`` (intensity 8.0)
- ``cognitive_model.intermediate_beliefs`` → ``Belief`` (intensity 6.0)
- ``short_description`` → ``ClientProfile.background``

The graph therefore holds ``ClientProfile``, ``Belief`` and the dialogue nodes
— nothing else. Coping modes were retired: ``cognitive_model.behaviors`` and
``coping_strategies`` are no longer mirrored, and the ``CopingMode`` label is
dead (any leftover nodes are deleted on the next sync).

Sync every profile at once, and prune personas that no longer exist:

```bash
cd ../memgraph
python -m backend.lib.core.context.profile_sync
```

The graph is a *mirror* of the memgraph profiles; edit personas in
``memgraph/backend/profiles/``, never here. ``ClientProfile`` and ``Belief``
nodes are profile-scoped (``belief_key`` encodes the profile name), so two
clients can use identical wording without sharing a node.

## Pipeline (per user message)

1. **Ingest** — create `TraineeUtterance`. Embed the current social-worker message plus the last `p` trainee and client utterances (`BELIEF_CONTEXT_TURNS`, default 2). Score only the session's persona `Belief`s with weighted max-pooled cosine (bge-m3). If score ≥ `BELIEF_MATCH_THRESHOLD` (default 0.42), write `TraineeUtterance -TRIGGERS-> Belief` (top `BELIEF_MATCH_TOP_K`).
2. **Agentic GraphRAG** — fetch last 3–5 `DialogueTurn`s, pull triggered `Belief`s and favored `CopingMode`s, and recall earlier turns that share those beliefs (`emotions`, trainee text, client output only); traversed `TRIGGERS` edges get a `weight` increment (memory replay).
3. **Single-pass generation** — one Azure OpenAI call returns strict JSON: `automatic_thought`, `emotions` (adjective list), `coping_mode_activated`, `dialogue_response`.
4. **Graph write** — persist `AutomaticThought` and `ClientUtterance` (with `emotions`) via `EVOKES_THOUGHT` and `CONTAINS_OUTPUT`; link the utterance to a `CopingMode` with `ACTIVATES_MODE`; open `DialogueTurn(N+1)` via `FOLLOWED_BY`.
