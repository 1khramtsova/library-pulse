# 08 · Получение доступов

Дополняет шаг 5 из [01-UTM-SETUP.md](01-UTM-SETUP.md). Всё делается один раз руками.
Под конкретную конфигурацию: только Meta, весь трафик на лендинг, CRM — HubSpot.

Порядок важен: приложение → System User → токен. Токен нельзя выпустить до того,
как приложение привязано к бизнесу.

---

## 1 · Meta: приложение и `META_APP_SECRET`

Приложение нужно не ради функциональности, а потому что каждый запрос к Graph API
подписывается `appsecret_proof = HMAC-SHA256(access_token, app_secret)`. Без него
Meta отклонит вызовы с серверного токена.

1. [developers.facebook.com](https://developers.facebook.com) → **My Apps** → **Create App**
2. Тип приложения — **Business**
3. На шаге привязки выбрать свой Business Manager. Если приложение не привязано
   к бизнесу, System User не сможет выпустить для него токен
4. В приложении: **Add Product** → **Marketing API** → Set up
5. **App Settings → Basic** → поле **App Secret** → **Show** (попросит пароль)

Скопированное значение → `META_APP_SECRET` в [.env](.env).

## 2 · Meta: System User и `META_ACCESS_TOKEN`

Ключевой пункт всей настройки. Пользовательский токен живёт 60 дней и умрёт
посреди работающего крона — молча, в ночь на субботу. System User токен бессрочный.

1. [business.facebook.com/settings](https://business.facebook.com/settings) →
   **Users → System users** → **Add**
2. Имя — `creative-os-sync`, роль **Employee access** (для чтения хватает)
3. Приложение из шага 1 должно быть в бизнесе: **Accounts → Apps → Add**.
   Если его там нет, оно не появится в списке при генерации токена
4. Вернуться к System user → **Add assets**:
   - **Apps** → приложение из шага 1 → **Develop app**
   - **Ad accounts** → отметить **все** кабинеты, которые войдут в синк →
     право **View performance**
5. **Generate new token** → выбрать приложение → права:
   - `ads_read` — обязательно, покрывает кампании, адсеты, объявления, креативы и инсайты
   - `business_management` — желательно, без него не прочитать список кабинетов
6. **Token expiration: Never**
7. Скопировать. **Второй раз токен не покажут** — если потеряется, генерировать заново

Скопированное значение → `META_ACCESS_TOKEN`.

> Право на кабинет — именно **View performance**, а не Manage. Система только читает,
> и лишние права здесь — это возможность случайно что-то поменять в бою.

## 3 · Meta: `META_AD_ACCOUNT_IDS`

**Business Settings → Accounts → Ad accounts.** У каждого кабинета id вида `1234567890`.

В `.env` нужен префикс `act_`, несколько — через запятую без пробелов:

```
META_AD_ACCOUNT_IDS=act_1234567890,act_9876543210
```

Важно перечислить **все** кабинеты, по которым идёт спенд. Пропущенный кабинет —
это первая из трёх причин расхождения по спенду на гейте
(запрос 1 в [06-GATE.md](06-GATE.md)).

## 4 · Проверка, что Meta-доступ работает

После заполнения трёх переменных:

```bash
set -a && source .env && set +a
PROOF=$(printf '%s' "$META_ACCESS_TOKEN" | openssl dgst -sha256 -hmac "$META_APP_SECRET" | awk '{print $2}')
curl -s "https://graph.facebook.com/$META_API_VERSION/me/adaccounts?fields=id,name,account_status&access_token=$META_ACCESS_TOKEN&appsecret_proof=$PROOF"
```

Должен вернуться список кабинетов. Что означают ошибки:

| Ответ | Причина |
|---|---|
| `Invalid appsecret_proof` | `META_APP_SECRET` не от того приложения, для которого выпущен токен |
| `(#200) Requires ads_read` | право не выдано при генерации токена — перевыпустить |
| пустой `data: []` | кабинеты не назначены System User в шаге 4 |
| `Session has expired` | выпущен пользовательский токен вместо System User |

---

## 5 · HubSpot: `CRM_API_KEY`

Нужен для T4 — подтягивания лидов, стадий воронки и сделок.

1. HubSpot → **⚙ Settings** → **Integrations** → **Private Apps** → **Create private app**
2. Имя — `creative-os-sync`
3. Вкладка **Scopes**, только чтение:
   - `crm.objects.contacts.read`
   - `crm.objects.deals.read`
   - `crm.schemas.contacts.read`
   - `crm.schemas.deals.read`
4. **Create app** → скопировать токен (начинается на `pat-`)

```
CRM_BASE_URL=https://api.hubapi.com
CRM_API_KEY=pat-...
```

## 6 · HubSpot: три внутренних имени свойств

Это не токены, но без них T4 не пишется, а найти их можно только в твоём портале.
**Settings → Properties**, у каждого свойства есть *internal name* — он отличается
от того, что видно в интерфейсе.

| Что нужно | Зачем | Куда ляжет |
|---|---|---|
| свойство, куда форма пишет `utm_content` | вся атрибуция держится на нём | `lead.exposure_id` |
| свойство MQL (`MQL = true`) | лестница решений, вердикт `reduce_budget` | `lead.is_mql` |
| признак владельца магазина на Mercado Livre | вердикт `requalify` | `lead.meli_store_qualified` |

По первому: проверить, что форма пишет именно в **отдельное скрытое поле**, а не
полагается на встроенную аналитику HubSpot (`hs_analytics_source_data_2`). Встроенная
хранит источник, а не `ad_id`, и для склейки не годится.

Третий пункт пока не определён вовсе — см. «Решения T0» в [README](README.md).

---

## 7 · Supabase: `SUPABASE_SERVICE_KEY` и бакет

Нужны в T2: ассеты складываются в Storage под ключом `assets/{sha256}`.

1. **Settings → API** → **Project API keys** → `service_role` → скопировать
2. **Storage** → **New bucket** → имя `assets`, **приватный**

```
SUPABASE_URL=https://euimocislrdosrsnzqwo.supabase.co
SUPABASE_SERVICE_KEY=eyJ...
```

`service_role` обходит RLS — это серверный ключ, в браузер он попадать не должен
никогда. В репозитории его нет: `.env` под `.gitignore`.

---

## Чеклист

- [ ] приложение Meta создано и привязано к бизнесу
- [ ] `META_APP_SECRET`
- [ ] System User создан, кабинеты назначены с правом View performance
- [ ] `META_ACCESS_TOKEN` с `ads_read`, expiration **Never**
- [ ] `META_AD_ACCOUNT_IDS` — перечислены все кабинеты со спендом
- [ ] проверка из раздела 4 вернула список кабинетов
- [ ] `CRM_API_KEY` из HubSpot Private App
- [ ] три internal name свойств HubSpot записаны
- [ ] `SUPABASE_SERVICE_KEY`, бакет `assets` создан
