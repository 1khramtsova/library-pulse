-- Creative OS · миграция 002 · метрики и лестница решений
-- Никаких z-score. Решение = положение доверительного интервала
-- относительно медианы когорты + достаточность данных.

-- ═══════════════ статистические функции ═══════════════

-- Интервал Уилсона для долей: hook rate, CTR, конверсия в лид.
create or replace function wilson_ci(successes bigint, trials bigint, z double precision default 1.96)
returns table(lo double precision, hi double precision)
language sql immutable as $$
  select
    case when trials = 0 then null
         else ((p + z*z/(2*n)) - z*sqrt((p*(1-p) + z*z/(4*n))/n)) / (1 + z*z/n) end,
    case when trials = 0 then null
         else ((p + z*z/(2*n)) + z*sqrt((p*(1-p) + z*z/(4*n))/n)) / (1 + z*z/n) end
  from (select
          coalesce(successes::double precision / nullif(trials,0), 0) as p,
          trials::double precision as n) s;
$$;

-- Интервал Пуассона (приближение Байара) для счётчиков: лиды, MQL, сделки.
create or replace function poisson_ci(k bigint)
returns table(lo double precision, hi double precision)
language sql immutable as $$
  select
    case when k <= 0 then 0
         else k * power(1 - 1.0/(9*k) - 1.96/(3*sqrt(k::double precision)), 3) end,
    (k+1) * power(1 - 1.0/(9*(k+1)) + 1.96/(3*sqrt((k+1)::double precision)), 3);
$$;

-- Интервал для стоимостной метрики вида spend/count.
-- Инвертируется: много событий -> дешевле, поэтому границы меняются местами.
create or replace function cost_ci(spend numeric, k bigint)
returns table(lo double precision, hi double precision)
language sql immutable as $$
  select
    case when p.hi > 0 then spend::double precision / p.hi else null end,
    case when p.lo > 0 then spend::double precision / p.lo else null end
  from poisson_ci(k) p;
$$;

-- ═══════════════ снимки: живые и устоявшиеся ═══════════════

-- Последний известный снимок по каждому дню.
create or replace view v_fact_latest as
select distinct on (exposure_id, day, placement) *
from fact_daily
order by exposure_id, day, placement, as_of desc;

-- Устоявшиеся данные: дни, старше окна перезаписи Meta.
-- ВСЕ РЕШЕНИЯ ПРИНИМАЮТСЯ ТОЛЬКО ОТСЮДА.
create or replace view v_fact_settled as
select f.*
from v_fact_latest f
where f.day <= current_date
    - ((select (value->>'settled_window_days')::int from config where key='windows') || ' days')::interval;

-- Насколько Meta переписывает историю именно у нас.
-- Смотреть на гейте и раз в месяц.
create or replace view v_restatement as
select day,
       count(distinct as_of)                          as snapshots,
       min(total_spend)                               as spend_first,
       max(total_spend)                               as spend_last,
       round(100 * (max(total_spend) - min(total_spend))
             / nullif(min(total_spend),0), 2)         as spend_drift_pct
from (
  select day, as_of, sum(spend) as total_spend
  from fact_daily group by day, as_of
) s
group by day
order by day desc;

-- ═══════════════ агрегаты по экспозиции ═══════════════

create or replace view v_exposure_perf as
select
  e.id                                   as exposure_id,
  e.external_ad_id,
  e.wave_id,
  e.traffic_mode,
  e.variant_id,
  cv.asset_id,
  a.segment,
  c.funnel_id,
  min(f.day)                             as first_day,
  max(f.day)                             as last_day,
  sum(f.impressions)                     as impressions,
  sum(f.views_3s)                        as views_3s,
  sum(f.link_clicks)                     as link_clicks,
  sum(f.spend)                           as spend
from exposure e
join creative_variant cv on cv.id = e.variant_id
join ad_set a            on a.id  = e.ad_set_id
join campaign c          on c.id  = a.campaign_id
left join v_fact_settled f on f.exposure_id = e.id
group by e.id, e.external_ad_id, e.wave_id, e.traffic_mode,
         e.variant_id, cv.asset_id, a.segment, c.funnel_id;

create or replace view v_exposure_funnel as
select
  p.*,
  count(distinct l.id)                                          as leads,
  count(distinct l.id) filter (where l.meli_store_qualified)     as leads_qualified,
  count(distinct l.id) filter (where l.is_mql)                   as mqls,
  count(distinct fe.lead_id) filter (where fe.stage='registered') as registered,
  count(distinct fe.lead_id) filter (where fe.stage='attended')   as attended,
  count(distinct fe.lead_id) filter (
    where fe.stage='attended'
      and fe.live_minutes >= (select (value->>'sql60_minutes')::int
                              from config where key='funnel')
  )                                                             as sql60,
  count(distinct d.id)                                          as deals,
  coalesce(sum(d.amount),0)                                     as revenue
from v_exposure_perf p
left join lead l        on l.exposure_id = p.exposure_id
left join funnel_event fe on fe.lead_id = l.id
left join deal d        on d.lead_id = l.id
group by p.exposure_id, p.external_ad_id, p.wave_id, p.traffic_mode,
         p.variant_id, p.asset_id, p.segment, p.funnel_id,
         p.first_day, p.last_day, p.impressions, p.views_3s,
         p.link_clicks, p.spend;

-- ═══════════════ производные метрики с интервалами ═══════════════

create or replace view v_exposure_metrics as
select
  f.*,
  -- ставки
  f.views_3s::numeric    / nullif(f.impressions,0)  as hook_rate,
  (select lo from wilson_ci(f.views_3s, f.impressions))   as hook_rate_lo,
  (select hi from wilson_ci(f.views_3s, f.impressions))   as hook_rate_hi,

  f.link_clicks::numeric / nullif(f.impressions,0)  as ctr,
  (select lo from wilson_ci(f.link_clicks, f.impressions)) as ctr_lo,
  (select hi from wilson_ci(f.link_clicks, f.impressions)) as ctr_hi,

  f.leads_qualified::numeric / nullif(f.leads,0)    as qual_rate,
  (select lo from wilson_ci(f.leads_qualified, f.leads))   as qual_rate_lo,
  (select hi from wilson_ci(f.leads_qualified, f.leads))   as qual_rate_hi,

  -- стоимости
  f.spend / nullif(f.leads,0)                       as cpl,
  (select lo from cost_ci(f.spend, f.leads))        as cpl_lo,
  (select hi from cost_ci(f.spend, f.leads))        as cpl_hi,

  f.spend / nullif(f.mqls,0)                        as cpmql,
  (select lo from cost_ci(f.spend, f.mqls))         as cpmql_lo,
  (select hi from cost_ci(f.spend, f.mqls))         as cpmql_hi
from v_exposure_funnel f;

-- ═══════════════ когорта ═══════════════
-- Сравнение только внутри своей волны и своего сегмента.
-- Абсолютные пороги между волнами не переносятся.

create or replace view v_cohort_median as
select
  wave_id, segment,
  percentile_cont(0.5) within group (order by hook_rate) as hook_rate_med,
  percentile_cont(0.5) within group (order by ctr)       as ctr_med,
  percentile_cont(0.5) within group (order by cpl)
    filter (where leads > 0)                             as cpl_med,
  percentile_cont(0.5) within group (order by qual_rate)
    filter (where leads > 0)                             as qual_rate_med,
  percentile_cont(0.5) within group (order by cpmql)
    filter (where mqls > 0)                              as cpmql_med,
  count(*)                                               as cohort_size
from v_exposure_metrics
group by wave_id, segment;

-- ═══════════════ лестница решений ═══════════════
-- Правило: вердикт выносится, только если ДИ целиком по одну сторону
-- от медианы когорты. Пересекает медиану -> данных не хватает.

create or replace view v_decision as
with t as (
  select (value->>'min_impressions_hook')::bigint  as min_imp_hook,
         (value->>'min_impressions_ctr')::bigint   as min_imp_ctr,
         (value->>'min_leads')::bigint             as min_leads,
         (value->>'min_mqls')::bigint              as min_mqls,
         (value->>'min_cohort_size')::int          as min_cohort
  from config where key = 'thresholds'
)
select
  m.exposure_id, m.external_ad_id, m.wave_id, m.segment,
  m.impressions, m.leads, m.mqls, m.spend,
  case
    when c.cohort_size < t.min_cohort then 'no_decision'
    when m.impressions < t.min_imp_hook then 'no_decision'
    when m.hook_rate_hi < c.hook_rate_med then 'kill'
    when m.impressions < t.min_imp_ctr then 'no_decision'
    when m.ctr_hi < c.ctr_med then 'rewrite'
    when m.leads < t.min_leads then 'no_decision'
    when m.cpl_lo > c.cpl_med then 'kill'
    when m.qual_rate_hi < c.qual_rate_med then 'requalify'
    when m.mqls < t.min_mqls then 'scale_cautious'
    when m.cpmql_lo > c.cpmql_med then 'reduce_budget'
    else 'scale'
  end as verdict,
  case
    when c.cohort_size < t.min_cohort then 'Когорта слишком мала для сравнения'
    when m.impressions < t.min_imp_hook then 'Недостаточно показов'
    when m.hook_rate_hi < c.hook_rate_med then 'Визуал не останавливает скролл. Менять первый кадр, не текст'
    when m.impressions < t.min_imp_ctr then 'Хук в норме, данных на CTR ещё нет'
    when m.ctr_hi < c.ctr_med then 'Картинка цепляет, обещание не продаёт. Тот же визуал, новый хук'
    when m.leads < t.min_leads then 'CTR в норме, данных на CPL ещё нет'
    when m.cpl_lo > c.cpl_med then 'Разрыв креатив-лендинг. Проверить обещание на LP'
    when m.qual_rate_hi < c.qual_rate_med then 'Хук тащит неквалифицированный трафик. Платформа и объём в первой строке'
    when m.mqls < t.min_mqls then 'Решение принято на CPL. Держать в лаборатории, на CpMQL данных нет'
    when m.cpmql_lo > c.cpmql_med then 'Лиды есть, качества нет. Не в завод, вернуть в тест'
    else 'Проходит все ступени. В завод и в атрибутный анализ'
  end as diagnosis,
  case
    when m.impressions < t.min_imp_hook then 'impressions'
    when m.hook_rate_hi < c.hook_rate_med then 'hook_rate'
    when m.impressions < t.min_imp_ctr then 'impressions'
    when m.ctr_hi < c.ctr_med then 'ctr'
    when m.leads < t.min_leads then 'leads'
    when m.cpl_lo > c.cpl_med then 'cpl'
    when m.qual_rate_hi < c.qual_rate_med then 'qual_rate'
    when m.mqls < t.min_mqls then 'mqls'
    else 'cpmql'
  end as gate_reached
from v_exposure_metrics m
join v_cohort_median c
  on c.wave_id = m.wave_id and c.segment is not distinct from m.segment
cross join t;
