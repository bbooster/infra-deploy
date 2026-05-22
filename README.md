# Автодеплой на VPS — runbook

Пакет для подготовки автодеплоя нескольких приватных репозиториев на один VPS
через GitHub Actions. Без организации (личные аккаунты сотрудников).

## Файлы

| Файл | Что делает | Где запускается |
|---|---|---|
| `bootstrap-deploy-server.sh` | создаёт пользователя `deploy` и служебный ключ | **на сервере**, один раз |
| `onboard-project.sh` | подключает один репо к автодеплою | **с рабочей машины**, на каждый репо |
| `deploy.yml` | универсальный workflow (путь = имя репо) | коммитится в репо автоматически |
| `.env.example` | шаблон переменных окружения | копируется под проект |
| `.gitignore` | защита от коммита секретов | — |

## Как опубликовать этот репозиторий

Из папки с файлами (нужен `gh auth login` под своим аккаунтом):

```bash
cd infra-deploy
git init
git add .
git commit -m "feat: autodeploy runbook (scripts + workflow + docs)"
git branch -M main
gh repo create owner/infra-deploy --private --source=. --remote=origin --push
```

`gh repo create` создаст приватный репо, привяжет remote и запушит одной командой.
Замени `owner/infra-deploy` на нужные.

> `deploy.yml` лежит в корне как шаблон — он НЕ должен исполняться в самом этом
> репо (тут нечего деплоить). Поэтому он не в `.github/workflows/`. Onboarding-
> скрипт берёт его отсюда и коммитит уже в целевые репозитории. Не перекладывай
> его в `.github/workflows/` этого репо.

## Модель

```
Сотрудник (свой аккаунт) ─merge в main─> Actions ─[служебный ключ]─> VPS: git pull + restart
```

Два разных ключа, не перепутать:
- **deploy key** (свой на репо, read-only) → в Deploy keys репо, для `git pull` на сервере;
- **служебный ключ** (один общий) → в Secrets репо (`SSH_PRIVATE_KEY`), по нему Actions заходит на VPS.

Сотрудники SSH к серверу не имеют — деплоит Actions. В gh CLI логинится только тот, кто запускает onboarding (admin репозиториев).

## Порядок (с нуля)

### 1. Один раз — сервер

```bash
scp bootstrap-deploy-server.sh user@SERVER:/tmp/
ssh user@SERVER 'sudo bash /tmp/bootstrap-deploy-server.sh'
```

Скрипт напечатает приватный служебный ключ. Сохрани его на рабочую машину:

```bash
# на рабочей машине
nano ~/.ssh/actions_deploy      # вставить вывод
chmod 600 ~/.ssh/actions_deploy
```

### 2. Один раз — рабочая машина

```bash
gh auth login                   # под admin-аккаунтом репозиториев
gh auth status                  # убедиться, что в scopes есть 'workflow'
# если нет:
gh auth refresh -s workflow
```

Отредактируй конфиг в начале `onboard-project.sh`: `SERVER_HOST`, при необходимости `DEPLOY_BASE`.

### 3. На каждый репозиторий

```bash
./onboard-project.sh https://github.com/owner/proj1
./onboard-project.sh owner/proj2          # короткий формат тоже работает

# с доставкой .env (загрузится в секрет ENV_FILE, воссоздастся на сервере):
./onboard-project.sh owner/proj1 ./secrets/proj1.env
```

Принимает любой формат ссылки (https / ssh / с `.git` / с `/tree/main` / `owner/repo`).

### Управление .env

`.env` **не хранится в git** (он в `.gitignore`). Доставка — через секрет:

- передаёшь вторым аргументом путь к локальному `.env` → скрипт кладёт его
  содержимое в секрет репо `ENV_FILE`;
- при каждом деплое workflow воссоздаёт `/opt/<имя>/.env` на сервере из этого
  секрета, права `600`, в логи не печатается;
- обновить `.env` → поменял локальный файл → `gh secret set ENV_FILE < proj1.env
  --repo owner/proj1` (или повторный onboard) → применится при следующем деплое;
- если второй аргумент не передавать — `ENV_FILE` не трогается, и на сервере
  используется `.env`, лежащий там вручную (если есть).

### 4. Доступ сотрудникам (отдельно, осознанно)

В каждом репо: Settings → Collaborators → добавить по username, роль write.
Владелец репозиториев — аккаунт того, кто остаётся (не уходящего).

### 5. Защита main (рекомендуется)

Settings → Branches → правило на `main`: require PR + 1 approval + status checks,
запретить прямой push.

## Проверка

После `git push` в `main` → вкладка Actions репозитория → workflow «Deploy»
должен пройти зелёным. На сервере проверь, что код обновился:
`ssh deploy@SERVER 'cd /opt/proj1 && git log -1'`.

## Эксплуатация

**Новый проект** — `./onboard-project.sh <ссылка>`. Всё.

**Ротация служебного ключа** (например, при увольнении) — перегенери ключ на
сервере (или вручную), обнови `~/.ssh/actions_deploy`, затем прогони
`gh secret set SSH_PRIVATE_KEY < ~/.ssh/actions_deploy --repo owner/repo`
по всем репо (или повторно onboard каждый репо).

**Передача дел** — сменщику нужно: получить admin на репозитории (Transfer
ownership на остающийся аккаунт), сделать свой `gh auth login`, иметь
`~/.ssh/actions_deploy` и SSH-доступ к серверу под `deploy`. Скрипты от смены
человека не меняются.

## Ограничения / зона развития

- На бесплатном плане GitHub organization secrets для приватных репо
  недоступны — поэтому secrets per-repo (скрипт это и закрывает).
- `appleboy/ssh-action@v1` — сторонний action с доступом к ключу. Для прод-
  инфраструктуры запинь его по конкретному commit-SHA вместо плавающего тега.
- Дальнейший шаг: сборка Docker-образов в CI + push в `ghcr.io` (авторизация
  через автоматический `GITHUB_TOKEN`, дублировать нечего) + `docker compose
  pull` или watchtower на сервере. Тогда серверу не нужен доступ к коду вообще.
