# Grant Disbursement Evidence Lakehouse

## Purpose

This project demonstrates an end-to-end backend + data engineering system for a **HUD-like disbursement metrics dashboard**. It is designed to ingest messy, real-world “evidence” (documents, exports, events), preserve it immutably, normalize it into queryable models, publish curated analytics, and expose secure APIs behind an API gateway. It also includes an LLM (Large Language Model) feature for **RAG (Retrieval-Augmented Generation)** and **structured extraction** with auditable evidence pointers.

### What this project proves

- **Medallion-style data architecture**
    - **Bronze**: append-only, versioned evidence objects with hashes
    - **Silver**: normalized relational models + data quality and quarantine
    - **Gold**: curated analytics tables/materialized views for fast ad-hoc queries
- **Workflow orchestration** with Apache Airflow (idempotency, retries, backfills)
- **Streaming ingestion** with Kafka-compatible broker (e.g., Redpanda) and “exactly-once-like” processing
- **Secure APIs** behind Kong (auth, rate limits, request logging) with **RBAC (Role-Based Access Control)**
- **LLM-assisted compliance workflows** that store citations to exact evidence chunks

---

## High-level Architecture

**Services (local dev)**

- **Object store (S3-style)**: MinIO (local) / S3 (cloud)
- **Database**: PostgreSQL
- **Orchestration**: Apache Airflow
- **Streaming**: Kafka-compatible broker (Redpanda or Kafka)
- **API service**: FastAPI (or Node/Express)
- **API gateway**: Kong
- **Workers**: transformation + streaming consumer + LLM jobs

**Core data flow**

1. Evidence bundle created (upload + metadata)
2. Raw objects stored in Bronze with SHA-256 hash
3. Airflow transforms Bronze → Silver with data quality checks and quarantine
4. Airflow publishes Silver → Gold aggregates for dashboard queries
5. Streaming events trigger incremental transforms
6. API + Kong serve UI queries; RBAC limits access
7. LLM pipeline indexes documents (RAG) and writes structured “findings” with evidence pointers

---

## Domain Model (HUD-style Disbursement Oversight)

This domain tracks the flow of federal financial assistance:

**Program → Award → Obligation → Drawdown Request → Disbursement**

…with associated:

- invoices / cost line items
- uploaded evidence documents
- review decisions and audit events
- automated compliance rules and findings

---

## Local Development

### Prerequisites
- Docker Desktop
- Docker Compose
- Python 3 (for generating an Airflow Fernet key)

### Configure environment variables
This repo uses a single `.env` file for the local stack.

1) Create your local `.env` file:
```bash
cp infrastructure/compose/.env.example infrastructure/compose/.env
```

2) Generate an Airflow Fernet key **before** starting the stack.

Airflow requires a valid Fernet key at startup to encrypt sensitive fields in its metadata database.

**Recommended (no dependencies):**
```bash
python3 -c "import base64, os; print(base64.urlsafe_b64encode(os.urandom(32)).decode())"
```

Paste the output into `infrastructure/compose/.env`:
```dotenv
AIRFLOW__CORE__FERNET_KEY=PASTE_VALUE_HERE
```

> Notes:
> - Do not add quotes around the value.
> - Keep the key on a single line with no trailing spaces.

**Alternative (after the stack is running):**
If the Airflow webserver container is already running, you can generate a Fernet key using the container’s Python environment:
```bash
docker exec -it lakehouse-airflow-webserver python -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"
```

3) Ensure local `.env` is not committed.
- `infrastructure/compose/.env` must be listed in `.gitignore`.

### Start the local stack
From the compose directory:
```bash
cd infrastructure/compose
docker compose up -d
```

### Access local services
- Airflow UI: http://localhost:8080
- MinIO console: http://localhost:9001
- Postgres: localhost:5432

### Stop the local stack
```bash
cd infrastructure/compose
docker compose down
```

## Data Model Overview (Medallion Layers)

### Bronze (raw, immutable)

Bronze is **append-only**. Objects are stored with content-addressable keys and hashes.

**Key invariants**
- Original evidence objects are never overwritten or deleted.
- Each object has a stored SHA-256 and must verify on read.
- Every downstream record links back to its source Bronze object.

### Silver (normalized, quality-checked)

Silver tables hold cleaned, typed, relational data suitable for application logic and reporting. Silver writes are **idempotent** using deterministic keys (e.g., `(source_object_id, source_row_number)`).

Silver also includes a quarantine/reject table for records failing quality checks.

### Gold (curated, fast analytics)

Gold tables and/or materialized views provide dashboard-ready rollups:
- daily disbursement totals by program/recipient
- approval/pending/rejected funnel
- compliance findings counts by severity/rule
- evidence completeness and aging

Gold is optimized for low-latency queries via:
- indexes
- partitioning (time-based where appropriate)
- pre-aggregation (materialized views)

---

## Data Models (Conceptual Entities)

### Funding flow entities

- **Program**
    - High-level HUD program or initiative.
- **Recipient**
    - State, city, or organization receiving funds.
- **Award**
    - Grant/award agreement (award amount, period of performance).
- **Obligation**
    - Funds obligated under an award (amendments, budget lines).
- **DrawdownRequest**
    - Recipient requests funds; may be partially approved.
- **Disbursement**
    - Payment event (amount/date/status/reference).

### Evidence + workflow entities

- **EvidenceBundle**
    - A group of related uploads/exports tied to a drawdown/disbursement.
- **EvidenceDocument**
    - PDFs/scans/spreadsheets supporting eligibility/costs.
- **ReviewDecision**
    - Reviewer actions (approve/deny/request info) with comments.
- **ComplianceRule**
    - Automated validation logic definition.
- **ComplianceFinding**
    - Result of applying a rule to an entity (pass/fail/flag).
- **AuditEvent**
    - Immutable “who did what” records.

### LLM entities

- **DocumentChunk**
    - Chunked text with offsets back to a source document.
- **Embedding**
    - Vector representation for retrieval.
- **ExtractionRun**
    - Records model/prompt versions and outcomes.
- **LLMFinding**
    - Structured extracted fields + cited evidence chunk ids.

---

## Database Schema (tentative)

> Notes:
> - Column types are indicative.
> - All business tables should include `created_at`, and where relevant `updated_at`.
> - All downstream tables should carry source lineage fields (e.g., `source_object_id`).

### Bronze tables (immutability + manifests)

#### `bronze_object`
- `object_id` (UUID, PK)
- `bundle_id` (UUID, indexed)
- `s3_key` (text, unique)
- `sha256` (text, indexed)
- `size_bytes` (bigint)
- `content_type` (text)
- `original_filename` (text)
- `source` (text) — e.g., “upload”, “payment_export”
- `version` (int)
- `received_at` (timestamptz)

#### `bronze_manifest`
- `bundle_id` (UUID, PK)
- `ingest_run_id` (UUID, indexed)
- `status` (text)
- `error` (text)
- `created_at` (timestamptz)

### Silver tables (normalized)

#### `silver_program`
- `program_id` (text, PK)
- `name` (text)
- `agency` (text)

#### `silver_recipient`
- `recipient_id` (text, PK)
- `name` (text)
- `type` (text) — e.g., state/city/org
- `uei` (text, nullable) — Unique Entity Identifier (if modeled)

#### `silver_award`
- `award_id` (text, PK)
- `program_id` (text, FK → `silver_program`)
- `recipient_id` (text, FK → `silver_recipient`)
- `award_amount` (numeric)
- `start_date` (date)
- `end_date` (date)

#### `silver_obligation`
- `obligation_id` (text, PK)
- `award_id` (text, FK → `silver_award`)
- `amount` (numeric)
- `obligated_at` (date)

#### `silver_drawdown_request`
- `drawdown_id` (text, PK)
- `award_id` (text, FK → `silver_award`)
- `requested_amount` (numeric)
- `requested_at` (timestamptz)
- `status` (text) — pending/approved/denied
- `source_object_id` (UUID, FK → `bronze_object`)
- `source_row_number` (int)

#### `silver_disbursement`
- `disbursement_id` (text, PK)
- `drawdown_id` (text, FK → `silver_drawdown_request`, nullable)
- `award_id` (text, FK → `silver_award`)
- `amount` (numeric)
- `paid_at` (timestamptz)
- `status` (text) — paid/failed/reversed
- `payment_ref` (text)
- `source_object_id` (UUID, FK → `bronze_object`)
- `source_row_number` (int)

#### `silver_invoice`
- `invoice_id` (text, PK)
- `award_id` (text, FK → `silver_award`)
- `invoice_number` (text)
- `invoice_date` (date)
- `total_amount` (numeric)
- `vendor_name` (text, nullable)
- `source_object_id` (UUID, FK → `bronze_object`)

#### `silver_cost_line_item`
- `line_item_id` (text, PK)
- `invoice_id` (text, FK → `silver_invoice`)
- `category` (text)
- `amount` (numeric)
- `description` (text, nullable)

#### `silver_document`
- `document_id` (UUID, PK)
- `bundle_id` (UUID, indexed)
- `source_object_id` (UUID, FK → `bronze_object`)
- `extracted_text` (text) — raw extracted text (or store separately)
- `text_extraction_method` (text)
- `created_at` (timestamptz)

#### `silver_reject`
- `reject_id` (UUID, PK)
- `record_type` (text) — “disbursement”, “invoice”, etc.
- `source_object_id` (UUID, FK → `bronze_object`)
- `source_row_number` (int, nullable)
- `reason_code` (text)
- `details_jsonb` (jsonb)
- `created_at` (timestamptz)

### Gold tables (curated analytics)

#### `gold_daily_disbursement_totals`
- `day` (date, PK part)
- `program_id` (text, PK part)
- `recipient_id` (text, PK part)
- `total_amount` (numeric)
- `disbursement_count` (int)

#### `gold_compliance_findings_summary`
- `day` (date, PK part)
- `rule_id` (text, PK part)
- `severity` (text, PK part)
- `finding_count` (int)
- `open_count` (int)

#### `gold_evidence_completeness`
- `day` (date, PK part)
- `program_id` (text, PK part)
- `percent_complete` (numeric)
- `missing_doc_count` (int)
- `avg_days_missing` (numeric)

### Workflow + audit tables

#### `pipeline_run`
- `run_id` (UUID, PK)
- `dag_id` (text)
- `started_at` (timestamptz)
- `ended_at` (timestamptz)
- `status` (text)
- `counts_jsonb` (jsonb)

#### `audit_event`
- `event_id` (UUID, PK)
- `actor` (text)
- `action` (text)
- `resource_type` (text)
- `resource_id` (text)
- `request_id` (text)
- `ts` (timestamptz)
- `metadata_jsonb` (jsonb)

### Streaming idempotency tables

#### `stream_consume_log`
- `topic` (text, PK part)
- `partition` (int, PK part)
- `offset` (bigint, PK part)
- `message_id` (text, indexed) — optional if using producer ids
- `processed_at` (timestamptz)

### LLM / RAG tables

#### `document_chunk`
- `chunk_id` (UUID, PK)
- `document_id` (UUID, FK → `silver_document`)
- `chunk_index` (int)
- `text` (text)
- `offsets_jsonb` (jsonb) — start/end offsets for citation
- `source_object_id` (UUID, FK → `bronze_object`)

#### `document_embedding`
- `chunk_id` (UUID, PK/FK → `document_chunk`)
- `embedding` (vector) — pgvector
- `model_name` (text)
- `created_at` (timestamptz)

#### `extraction_run`
- `run_id` (UUID, PK)
- `bundle_id` (UUID, indexed)
- `model_name` (text)
- `prompt_hash` (text)
- `started_at` (timestamptz)
- `ended_at` (timestamptz)
- `status` (text)
- `metrics_jsonb` (jsonb)

#### `llm_finding`
- `finding_id` (UUID, PK)
- `bundle_id` (UUID, indexed)
- `rule_id` (text)
- `severity` (text)
- `summary` (text)
- `extracted_fields_jsonb` (jsonb)
- `evidence_chunk_ids` (uuid[])
- `model_name` (text)
- `prompt_hash` (text)
- `created_at` (timestamptz)

---

## RBAC Roles

- **uploader**
    - Create bundles and upload evidence objects
- **reviewer**
    - View Silver records, approve/deny drawdowns, write decisions
- **analyst**
    - Query Gold analytics endpoints and export metrics
- **auditor**
    - Read audit events, lineage, evidence pointers
- **admin**
    - Backfills, reprocessing, configuration, user/role management

---

## Evidence Lineage (How to explain it)

A dashboard number must be traceable back to original evidence:

- Every Silver row includes `source_object_id` (+ `source_row_number` for tabular imports).
- Every Gold aggregate includes implicit provenance via Silver foreign keys and the `pipeline_run`.
- Every LLM output stores `evidence_chunk_ids`, where chunks reference:
    - `document_id` → `source_object_id` → Bronze S3 key + SHA-256.

---

## Miscellaneous TODOs
- Integrate existing HUD datasets (e.g., DRGR Public Data, HUD Open Data Catalog, Consolidated Planning/CHAS Data)
