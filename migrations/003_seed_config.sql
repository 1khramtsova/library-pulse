-- Creative OS · миграция 003 · стартовая конфигурация
-- Все пороги живут здесь. В коде их быть не должно.
-- Значения — стартовые ориентиры из раздела 4 спеки, калибруются после первой волны.

insert into config (key, value, comment) values

('windows', jsonb_build_object(
    'settled_window_days',     7,
    'restatement_window_days', 14
 ), 'Meta переписывает конверсии задним числом. Решения — только по устоявшимся дням.'),

('thresholds', jsonb_build_object(
    'min_impressions_hook',  800,
    'min_impressions_ctr',   15000,
    'min_leads',             40,
    'min_mqls',              40,
    'min_cohort_size',       6
 ), 'Минимум событий для права на вердикт. Ниже порога система обязана молчать.'),

('funnel', jsonb_build_object(
    'sql60_minutes',            60,
    'attribution_rule',         'first_touch',
    'min_match_rate_for_gate',  0.80
 ), 'attribution_rule применяется одинаково во всех трёх путях склейки.'),

('allocation', jsonb_build_object(
    'experiment_share', 0.30,
    'scale_share',      0.70,
    'explore_new',      0.10,
    'explore_transfer', 0.20,
    'exploit',          0.70
 ), 'Политика, а не закон. Доля исследования растёт вместе с шириной ДИ по воронке.')

on conflict (key) do update
  set value = excluded.value, updated_at = now();
