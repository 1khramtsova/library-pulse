# 02 · Контракт с Meta Graph API

Всё, что агенту нужно знать про источник. Версия API — `v21.0`, вынесена в `META_API_VERSION`.

Все запросы подписываются `appsecret_proof = HMAC-SHA256(access_token, app_secret)`.

---

## Синк сущностей (T2)

Иерархия скачивается сверху вниз, за один проход по каждому кабинету.

### Кампании
```
GET /{ad_account_id}/campaigns
fields=id,name,objective,status,effective_status,created_time,updated_time
limit=200
```

### Адсеты
```
GET /{ad_account_id}/adsets
fields=id,name,campaign_id,optimization_goal,billing_event,daily_budget,
       lifetime_budget,targeting,status,effective_status,start_time
limit=200
```

`targeting` — большой JSON. Хранить целиком в `ad_set.targeting_raw` и отдельно писать `targeting_hash = sha256` от него: смена таргетинга посреди теста ломает сравнение, и без хеша это невозможно заметить.

Поле `segment` при этом заполняется **не автоматически из таргетинга**, а по правилу маппинга из `enums.yaml` (по имени адсета или явному соответствию). Автоматический вывод сегмента из JSON таргетинга — ловушка: он не отражает того, что вы имели в виду.

### Объявления → `exposure`
```
GET /{ad_account_id}/ads
fields=id,name,adset_id,campaign_id,creative{id},status,effective_status,created_time
limit=200
```

### Креативы → `creative_variant`
```
GET /{ad_account_id}/adcreatives
fields=id,name,object_story_spec,asset_feed_spec,image_hash,image_url,
       video_id,thumbnail_url,body,title,link_url,call_to_action_type,
       effective_object_story_id
limit=100
```

Текст лежит в разных местах в зависимости от типа объявления. Порядок разбора:
1. `object_story_spec.link_data` → `message`, `name`, `description`, `call_to_action.type`, `link`
2. `object_story_spec.video_data` → то же плюс `image_url` обложки
3. `asset_feed_spec` → **динамические креативы**: массивы `bodies[]`, `titles[]`, `images[]`

⚠️ **Динамические креативы (Advantage+ creative, DCO) — отдельный случай.** Одно объявление содержит несколько текстов и картинок, которые Meta комбинирует сама, и разбивку по комбинациям API не отдаёт. Такая экспозиция помечается `variant_resolution = 'dynamic_unresolved'` и **исключается из атрибутного анализа**, потому что неизвестно, что именно сработало. Она остаётся в библиотеке и в решениях по CPL, но не участвует в обучении. Это лучше, чем тихо приписать результат первому тексту из массива.

### Ассеты
Скачать по `image_url` / `thumbnail_url`, посчитать `sha256` от байтов, положить в Storage под ключом `assets/{sha256}`. Если хеш уже есть в БД — файл не перекачивается, создаётся только связь.

Хеш считается от **исходных байтов файла**, не от URL: URL содержит подписи и меняется.

---

## Синк перформанса (T3)

### Почему асинхронно

Ad-level инсайты за 30+ дней с разбивкой по дням для нескольких кабинетов упираются в лимиты при синхронных вызовах. Правильный путь — асинхронный отчёт:

```
POST /{ad_account_id}/insights
  level=ad
  time_increment=1
  time_range={"since":"YYYY-MM-DD","until":"YYYY-MM-DD"}
  fields=ad_id,adset_id,campaign_id,impressions,reach,spend,clicks,
         inline_link_clicks,actions,video_3_sec_watched_actions,
         video_p25_watched_actions,frequency
  breakdowns=publisher_platform,platform_position
  action_attribution_windows=["7d_click","1d_view"]
  async=true
→ report_run_id
```

Дальше опрашивать `GET /{report_run_id}` до `async_status = "Job Completed"`, затем забирать `GET /{report_run_id}/insights` с пагинацией.

Опрос — с экспоненциальной паузой, начиная с 10 секунд. Не чаще.

### Окно перезабора

Каждый запуск тянет **последние `RESTATEMENT_WINDOW_DAYS` дней** (по умолчанию 14), а не всю историю. Meta переписывает конверсии задним числом; дни старше 14 практически не меняются.

### Снимки

Строки пишутся с `as_of = current_date`. Существующие строки **не обновляются** — только вставляются новые. Так видно, насколько сильно и в какую сторону Meta переписывает историю именно у вас.

Ночная задача схлопывает дни старше 14 в одну строку с `as_of = day + 14`, иначе таблица растёт как `экспозиции × дни × плейсменты × дни_снимков`.

### Лимиты

Заголовок `X-Business-Use-Case-Usage` в каждом ответе содержит текущий процент утилизации. При `call_count` или `total_time` выше 75 — пауза до следующего часа. При `estimated_time_to_regain_access` — ждать указанное время. Не ретраить в цикле: это ускоряет блокировку.

Крон каждые 4 часа с окном в 14 дней держится в лимитах с большим запасом.

---

## Синк лидов (T4) — три независимых пути

Каждый лид получает `attribution_path` с одним из значений: `utm`, `leadgen`, `ctwa`, `unmatched`.

### Путь 1 · UTM

Лиды тянутся из CRM, `utm_content` парсится как `external_ad_id`, ищется в `exposure`.

Обработка мусора: `utm_content` может содержать `{{ad.id}}` буквально (макрос не сработал), `undefined`, пустую строку или старое имя креатива. Всё это → `attribution_path = 'unmatched'` с сохранением сырого значения в `raw_utm`. **Не выбрасывать молча** — доля таких значений и есть главная метрика гейта.

### Путь 2 · Instant Forms

Вебхук `leadgen` или периодический опрос:
```
GET /{form_id}/leads
fields=id,created_time,ad_id,adset_id,campaign_id,field_data
```

Здесь `ad_id` приходит напрямую — это самый надёжный путь, матч почти стопроцентный. Если большая часть трафика идёт сюда, гейт пройдёт быстро.

### Путь 3 · Click-to-WhatsApp

Первое входящее сообщение в WhatsApp Business API содержит объект `referral`:
```json
{
  "referral": {
    "source_type": "ad",
    "source_id": "<ad_id>",
    "ctwa_clid": "<click id>"
  }
}
```

`source_id` и есть `external_ad_id`. Требования:
- вебхук WhatsApp Business API должен быть подключён и логировать `referral` целиком;
- связка сохраняется на **первом** сообщении. Если человек написал раньше по другому объявлению, `referral` придёт снова — фиксируется first-touch или last-touch по тому же правилу, что и в UTM, одинаково;
- телефон нормализуется в E.164 для склейки с CRM.

Если этот путь не подключён, а трафик по нему идёт — весь этот спенд будет в `unmatched`, и гейт не пройдёт. Отсюда важность шага 1 в `01-UTM-SETUP.md`.

### Стадии воронки

Из CRM и вебинарной платформы, в `funnel_event`. Минимальный набор стадий в `enums.yaml`: `registered`, `attended`, `sql60`, `demo_booked`, `deal_won`. Минуты на лайве пишутся в `live_minutes` у стадии `attended`; `sql60` вычисляется в SQL по порогу из `config`, а не хранится как отдельный факт из платформы.

---

## Идемпотентность

Каждый синк можно перезапустить сколько угодно раз без порчи данных:

- сущности — `insert ... on conflict (platform, external_id) do update`;
- `fact_daily` — `on conflict (exposure_id, day, placement, as_of) do nothing`;
- лиды — `on conflict (crm_id) do update` только по полям стадий, никогда по `exposure_id` после первой привязки.

Последнее важно: если правило first-touch, то повторный синк не должен переписать атрибуцию.
