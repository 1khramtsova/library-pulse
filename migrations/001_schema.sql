-- Creative OS · миграция 001 · схема фазы A1
-- Postgres 15+ / Supabase
-- Поля, помеченные [A2], создаются пустыми и заполняются в следующей фазе.

create extension if not exists pgcrypto;
create extension if not exists vector;   -- не используется в A1, включается сразу

-- ═══════════════ конфигурация и наблюдаемость ═══════════════

create table config (
  key         text primary key,
  value       jsonb not null,
  comment     text,
  updated_at  timestamptz not null default now()
);

create table sync_run (
  id           uuid primary key default gen_random_uuid(),
  job          text not null,
  started_at   timestamptz not null default now(),
  finished_at  timestamptz,
  status       text not null default 'running',   -- running | ok | failed
  rows_written bigint default 0,
  error        text
);
create index on sync_run (job, started_at desc);

-- ═══════════════ справочники ═══════════════

create table funnel (
  id         uuid primary key default gen_random_uuid(),
  code       text unique not null,
  name       text not null,
  offer_type text not null,                       -- enums: offer_type
  created_at timestamptz not null default now()
);

create table wave (
  id         uuid primary key default gen_random_uuid(),
  funnel_id  uuid not null references funnel(id),
  code       text not null,
  started_on date not null,
  ended_on   date,
  unique (funnel_id, code)
);

create table experiment (
  id        uuid primary key default gen_random_uuid(),
  wave_id   uuid not null references wave(id),
  design    text not null default 'free',         -- grid | free
  axes      jsonb not null default '[]'::jsonb,   -- ["hook_type","design_language"]
  cells     int,
  opened_at date not null default current_date
);

-- ═══════════════ знание ═══════════════
-- В A1 обе таблицы заполняются руками. Автоматизация — A2/A3.

create table evidence (
  id              uuid primary key default gen_random_uuid(),
  finding         text not null,
  metric          text not null,
  effect_size     numeric(6,4),
  ci_low          numeric(6,4),
  ci_high         numeric(6,4),
  scope           jsonb not null default '{}'::jsonb,
  evidence_level  text not null default 'observational',
                  -- observational | replicated | controlled | randomized
  sample_variants int,
  sample_waves    int,
  confounders     text[] default '{}',
  status          text not null default 'active', -- active | weakening | retired
  last_checked_at date,
  created_at      timestamptz not null default now(),
  constraint evidence_level_valid check (evidence_level in
    ('observational','replicated','controlled','randomized')),
  constraint evidence_status_valid check (status in ('active','weakening','retired'))
);

create table hypothesis (
  id                  uuid primary key default gen_random_uuid(),
  evidence_id         uuid references evidence(id),
  statement           text not null,
  mechanism           text,                       -- enums: persuasion_mechanism
  primary_metric      text not null,              -- enums: metric
  predicted_direction text not null,              -- up | down
  status              text not null default 'draft',
                      -- draft | launched | resolved | abandoned
  outcome             text,                       -- confirmed | rejected | inconclusive
  created_at          timestamptz not null default now(),
  resolved_at         timestamptz,
  constraint hyp_direction_valid check (predicted_direction in ('up','down'))
);

-- ═══════════════ рекламные сущности ═══════════════

create table campaign (
  id             uuid primary key default gen_random_uuid(),
  platform       text not null default 'meta',
  external_id    text not null,
  ad_account_id  text not null,
  name           text,
  objective      text,
  funnel_id      uuid references funnel(id),
  status         text,
  created_time   timestamptz,
  synced_at      timestamptz not null default now(),
  unique (platform, external_id)
);

create table ad_set (
  id                uuid primary key default gen_random_uuid(),
  platform          text not null default 'meta',
  external_id       text not null,
  campaign_id       uuid not null references campaign(id),
  name              text,
  segment           text,                          -- enums: segment. Контекст, НЕ геном
  optimization_goal text,
  daily_budget      numeric(12,2),
  targeting_raw     jsonb,
  targeting_hash    text,
  status            text,
  synced_at         timestamptz not null default now(),
  unique (platform, external_id)
);

-- ── физический файл ──
create table asset (
  id            uuid primary key default gen_random_uuid(),
  sha256        text not null unique,
  media_type    text not null,                     -- image | video
  storage_path  text not null,
  source_url    text,
  width         int,
  height        int,
  ocr_text      text,                              -- [A2]
  first_seen_at timestamptz not null default now()
);

create table asset_genome (                         -- [A2] создаётся пустой
  asset_id        uuid primary key references asset(id),
  schema_version  text not null,
  media_format    text,
  design_language text,
  speaker         text,
  has_human       boolean,
  text_density    int,
  color_dominant  text,
  vision_notes    text,
  extracted_at    timestamptz
);

create table asset_embedding (                      -- [A2]
  asset_id  uuid primary key references asset(id),
  embedding vector(1024),
  model     text,
  created_at timestamptz not null default now()
);

-- ── ассет + копирайт + CTA ──
create table creative_variant (
  id                   uuid primary key default gen_random_uuid(),
  platform             text not null default 'meta',
  external_creative_id text not null,
  asset_id             uuid references asset(id),
  hypothesis_id        uuid references hypothesis(id),
  body_text            text,
  headline             text,
  link_description     text,
  cta_type             text,
  landing_url          text,
  variant_resolution   text not null default 'resolved',
                       -- resolved | dynamic_unresolved
  synced_at            timestamptz not null default now(),
  unique (platform, external_creative_id)
);

create table variant_genome (                       -- [A2] создаётся пустой
  variant_id              uuid primary key references creative_variant(id),
  schema_version          text not null,
  hook_type               text,
  persuasion_mechanism    text,
  qualifier_in_first_line boolean,
  offer_type              text,
  cta_type                text,
  compliance_flags        text[] default '{}',
  extracted_at            timestamptz
);

-- ── вариант, размещённый в адсете: ЕДИНИЦА ПЕРФОРМАНСА ──
create table exposure (
  id             uuid primary key default gen_random_uuid(),
  platform       text not null default 'meta',
  external_ad_id text not null,
  variant_id     uuid not null references creative_variant(id),
  ad_set_id      uuid not null references ad_set(id),
  wave_id        uuid references wave(id),
  experiment_id  uuid references experiment(id),
  experiment_cell text,
  hypothesis_id  uuid references hypothesis(id),
  traffic_mode   text not null default 'scale',     -- experiment | scale
  name           text,
  status         text,
  started_at     date,
  synced_at      timestamptz not null default now(),
  unique (platform, external_ad_id),
  constraint traffic_mode_valid check (traffic_mode in ('experiment','scale'))
);
create index on exposure (wave_id);
create index on exposure (variant_id);
create index on exposure (traffic_mode);

-- ═══════════════ факты ═══════════════
-- ТОЛЬКО INSERT. Никогда не UPDATE. as_of фиксирует снимок.

create table fact_daily (
  exposure_id       uuid not null references exposure(id),
  day               date not null,
  placement         text not null default 'all',
  as_of             date not null,
  impressions       bigint not null default 0,
  reach             bigint,
  frequency         numeric(8,4),
  views_3s          bigint not null default 0,
  video_p25         bigint,
  clicks            bigint not null default 0,
  link_clicks       bigint not null default 0,
  spend             numeric(14,2) not null default 0,
  actions_raw       jsonb,
  primary key (exposure_id, day, placement, as_of)
);
create index on fact_daily (day);
create index on fact_daily (as_of);

-- ═══════════════ воронка ═══════════════

create table lead (
  id                   uuid primary key default gen_random_uuid(),
  crm_id               text unique,
  exposure_id          uuid references exposure(id),
  attribution_path     text not null default 'unmatched',
                       -- utm | leadgen | ctwa | unmatched
  raw_utm              jsonb,
  ctwa_clid            text,
  phone_e164           text,
  created_at           timestamptz not null,
  meli_store_qualified boolean,
  is_mql               boolean not null default false,
  mql_at               timestamptz,
  constraint attr_path_valid check (attribution_path in
    ('utm','leadgen','ctwa','unmatched'))
);
create index on lead (exposure_id);
create index on lead (created_at);
create index on lead (attribution_path);

create table funnel_event (
  id           uuid primary key default gen_random_uuid(),
  lead_id      uuid not null references lead(id),
  stage        text not null,                      -- enums: funnel_stage
  live_minutes int,
  occurred_at  timestamptz not null,
  unique (lead_id, stage)
);
create index on funnel_event (stage);

create table deal (
  id         uuid primary key default gen_random_uuid(),
  crm_id     text unique,
  lead_id    uuid not null references lead(id),
  amount     numeric(14,2),
  currency   text default 'BRL',
  status     text,
  closed_at  date
);

-- ═══════════════ решения ═══════════════

create table decision_log (
  id              uuid primary key default gen_random_uuid(),
  exposure_id     uuid not null references exposure(id),
  decided_on      date not null default current_date,
  verdict         text not null,
                  -- no_decision | kill | rewrite | requalify
                  -- | reduce_budget | scale_cautious | scale
  diagnosis       text not null,
  gate_reached    text not null,      -- на какой ступени лестницы остановились
  metric          text,
  value           numeric(14,4),
  ci_low          numeric(14,4),
  ci_high         numeric(14,4),
  cohort_median   numeric(14,4),
  events_observed bigint,
  acted_on        boolean default false,
  acted_at        timestamptz,
  unique (exposure_id, decided_on)
);
create index on decision_log (decided_on desc);
