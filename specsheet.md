# Technical Specification: Single-Pass Lean Graph-Based Client Simulation

## 1. System Overview & Technology Stack

This system is a streamlined conversational agent utilizing Agentic Graph Retrieval-Augmented Generation (Agentic GraphRAG) to maintain psychological and chronological consistency. It models internal cognitive states and episodic memory as a unified Property Graph. This version bypasses clinical skill classification, deterministic output validation, dual-LLM orchestration, and keyphrase/concept extraction in favor of a high-speed, single-pass generation architecture.

Each `ClientProfile` owns its own belief list and coping modes (core and intermediate schemas merged into that list). A session is bound to one profile. At runtime, the social worker's current utterance — plus a small window of recent trainee and client utterances — is compared by dense cosine similarity only to that profile's beliefs. Hits above threshold become `TRIGGERS` edges from the current `TraineeUtterance` to those `Belief` nodes. Two profiles never share a `Belief` or `CopingMode` node, even when the text or mode name is the same.

- **Database:** Neo4j (Property Graph support required for structural traversals).
- **Embeddings:** Dense retriever (BGE-M3) for utterance ↔ belief similarity. Belief vectors are computed at seed time from belief text plus optional author-written cues. No entity extraction or concept-node deduplication.
- **Orchestration/Generation:** Single LLM setup (handles both psychological state computation and dialogue generation in one payload).

## 2. Graph Ontology (Streamlined Schema Definition)

The database must be initialized with the following schema, bridging the static Persona, chronological Memory, and dynamic State.

Retired from the prior revision: `CoreBelief`, `IntermediateBelief`, and `Concept` (and the `MENTIONS` / `GENERATES_RULE` edges that hung off them). Retired from this revision: the `Emotion` node, plus `RESULTS_IN` and `Emotion -ACTIVATES_MODE-> CopingMode`. Emotions are a list property on `ClientUtterance`.

### 2.1 Node Definitions

| **Node Label** | **Domain** | **Key Properties** |
| --- | --- | --- |
| `ClientProfile` | Persona | Name (unique), Age, Background Summary. |
| `Belief` | Persona | `belief_key` (unique; profile name + text), owning profile name, Text Description, Intensity Weight (1.0–10.0), optional Cues (retrieval hints), Semantic Embedding Vector. |
| `CopingMode` | Persona | `mode_key` (unique; profile name + mode name), owning profile name, Mode Name (e.g. Detached Protector), Trigger Conditions, Behavioral Phenotype Description. |
| `Session` | Memory | Timestamp, User ID, Session Identifier, profile name of the bound client. |
| `DialogueTurn` | Memory | Turn Index (Integer), Temporal Timestamp. |
| `TraineeUtterance` | Memory | Text String, Token Count. |
| `ClientUtterance` | Memory | Text String, Token Count, Emotions (list of LLM-generated emotional adjectives). |
| `AutomaticThought` | State | Text Description. |

`Belief.cues` are author-written retrieval hints baked into the stored embedding (`"{text}\nRelated themes: {cues}"`). They are not extracted from user input.

### 2.2 Edge Typologies & Directionality

| **Source Node** | **Edge Type** | **Target Node** | **Description** |
| --- | --- | --- | --- |
| `ClientProfile` | `HOLDS_BELIEF` | `Belief` | Anchors that persona's schema list. |
| `ClientProfile` | `USES_COPING` | `CopingMode` | Anchors that persona's coping-mode list. |
| `Belief` | `FAVORS_COPING` | `CopingMode` | Connects a vulnerability to that same persona's defenses. |
| `Session` | `WITH_CLIENT` | `ClientProfile` | Binds the session to one persona. Scoring and generation use only that profile. |
| `Session` | `HAS_TURN` | `DialogueTurn` | Structural anchor for chronological events. |
| `DialogueTurn (N)` | `FOLLOWED_BY` | `DialogueTurn (N+1)` | Strict chronological sequencing. |
| `DialogueTurn` | `CONTAINS_INPUT` | `TraineeUtterance` | Links to social-worker text. |
| `TraineeUtterance` | `TRIGGERS` | `Belief` | Runtime activation: similarity ≥ threshold. Properties: `similarity` (float), `weight` (replay counter). |
| `DialogueTurn` | `EVOKES_THOUGHT` | `AutomaticThought` | Runtime cognitive reaction. |
| `DialogueTurn` | `CONTAINS_OUTPUT` | `ClientUtterance` | Links to the agent's generated text. Emotion adjectives live on this node. |
| `ClientUtterance` | `ACTIVATES_MODE` | `CopingMode` | Behavioral defense activated with this reply. |

## 3. Pipeline Execution Flow

### Step 1: Real-Time Input Processing

1. **Ingest:** Receive the natural language string from the social worker. Create a `TraineeUtterance` node on the current `DialogueTurn`.
2. **Dialogue window:** Collect the current trainee utterance together with the last *p* completed turns' trainee and client utterances (*p* = `BELIEF_CONTEXT_TURNS`, default 2; *p* is small and *p* < *k* where *k* is the GraphRAG context window).
3. **Belief scoring:** Embed each window utterance with BGE-M3. For each `Belief` held by the session's `ClientProfile`, compute a weighted max-pooled cosine:

   `score(belief) = max_i (w_i · cosine(utterance_i, belief))`

   Weights: current trainee = 1.0, prior trainee = 0.9, prior client = 0.75. The current message dominates; prior turns can still activate a lingering belief (e.g. “tell me more”).
4. **Activation:** If `score ≥ BELIEF_MATCH_THRESHOLD` (default 0.42, a topical floor on BGE-M3 — paraphrase typically ≥ 0.8), draw `TraineeUtterance -TRIGGERS-> Belief` on the **current** social-worker utterance, storing `similarity`. Keep at most `BELIEF_MATCH_TOP_K` (default 3) strongest hits. Utterances below threshold create no belief edges.

### Step 2: Agentic GraphRAG (MCMI Algorithm)

1. **Sub-graph Initialization:** Retrieve the local neighborhood context: the preceding 3–5 `DialogueTurn` nodes (`CONTEXT_TURNS`, default 5) with both utterances.
2. **Exploitation:** Traverse outward from the current `TraineeUtterance` along `TRIGGERS` edges. Pull the connected `Belief` nodes (ranked by similarity, then path weight, then intensity) and their `FAVORS_COPING` `CopingMode` nodes into the context payload.
3. **Belief-overlap recall:** From the beliefs triggered on the current turn, find earlier completed turns in the same session whose `TRIGGERS` edges share at least one of those beliefs. For each match, retrieve only the emotion adjectives on that turn's `ClientUtterance`, the trainee utterance, and the client output. Keep the most recent `CONTEXT_TURNS` matches (default 5) and return them oldest-first. If this turn triggered no beliefs, or no earlier turn shares one, the list is empty.
4. **Memory Replay Optimization:** Increment `weight` on traversed `TRIGGERS` edges so repeated conversational patterns rank higher on later retrieval.

### Step 3: Unified Generation Pipeline (Single LLM Call)

- **Input:** System prompt enforcing the psychological persona, merged with the serialized JSON payload retrieved from the GraphRAG step (`recent_dialogue`, `triggered_beliefs`, `same_belief_rounds`, coping modes). `same_belief_rounds` entries contain only `emotions`, `trainee`, and `client`.
- **Execution:** Instruct the LLM to evaluate the user's input, deduce its internal cognitive state based on the retrieved graph context (especially `triggered_beliefs`), and formulate its verbal response *in a single chain of thought*.
- **Output Constraint:** The model MUST output a single, strictly typed JSON object containing both the state variables and the final dialogue.
    - *Required JSON Schema:*
        - `automatic_thought` (string)
        - `emotions` (list of short emotional adjectives, 1–6)
        - `coping_mode_activated` (string)
        - `dialogue_response` (string)

### Step 4: State Finalization & Graph Write

1. **Parse JSON:** Extract the state variables and dialogue text from the LLM's response payload.
2. **Write State and Text:** Instantiate an `AutomaticThought` and attach it to the current `DialogueTurn` via `EVOKES_THOUGHT`. Append `dialogue_response` as a `ClientUtterance` (`CONTAINS_OUTPUT`) with `emotions` set to the adjective list. Connect that utterance to the relevant `CopingMode` via `ACTIVATES_MODE`.
3. **Turn Initialization:** Draw a `FOLLOWED_BY` edge to initialize a new, empty `DialogueTurn(N+1)` node.
4. **Wait State:** Enter a wait state for the next user input. Return the `dialogue_response` string (and the triggered beliefs with similarities) to the frontend UI.
