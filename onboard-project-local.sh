#!/usr/bin/env bash
#
# ==============================================================================
#  onboard-project-local.sh — подготовка автодеплоя, ЗАПУСК ПРЯМО НА СЕРВЕРЕ
# ==============================================================================
#
#  ОТЛИЧИЕ ОТ onboard-project.sh
#  -----------------------------
#  Эта версия запускается НА САМОМ СЕРВЕРЕ (web-02), а не с рабочей машины.
#  Поэтому она НЕ ходит по SSH сама в себя — все серверные операции (генерация
#  deploy key, клонирование, чтение служебного ключа) выполняются локально.
#  Удобно, когда всё держишь в одном месте и не хочешь переносить ключ на ноут.
#
#  ЧТО ДЕЛАЕТ
#  ----------
#    1. Локально (на сервере): генерит deploy key репо, дописывает ~/.ssh/config
#       пользователя deploy, клонирует репо в /opt/<имя>.
#    2. В GitHub (через gh): добавляет deploy key, кладёт secrets, коммитит
#       workflow .github/workflows/deploy.yml.
#
#  ДВА КЛЮЧА — не перепутать (как и в основной версии):
#    - DEPLOY KEY (на репо, read-only) → в Deploy keys репо, для git pull;
#    - СЛУЖЕБНЫЙ КЛЮЧ (общий) → приватная часть в Secrets (SSH_PRIVATE_KEY),
#      по нему Actions заходит на сервер. Лежит в /home/deploy/.ssh/actions_deploy
#      (создан bootstrap-deploy-server.sh). ОТСЮДА И БЕРЁТСЯ — переносить никуда
#      не нужно.
#
#  КТО ЗАПУСКАЕТ
#  -------------
#  Один человек с admin на репозитории. Сотрудники онбординг НЕ запускают —
#  только пушат код. В gh CLI на сервере логинится только админ.
#
#  ⚠️  БЕЗОПАСНОСТЬ ТОКЕНА
#  ----------------------
#  Запуск на сервере означает, что твой GitHub-токен (gh auth login) хранится
#  на сервере в ~/.config/gh/. Пока работаешь — ок. ПЕРЕД УВОЛЬНЕНИЕМ обязательно:
#      gh auth logout
#  чтобы не оставить свой токен на проде. Сменщик сделает свой gh auth login.
#
#  ПРЕДВАРИТЕЛЬНЫЕ ТРЕБОВАНИЯ (один раз)
#  ------------------------------------
#    1. Выполнен bootstrap-deploy-server.sh (есть пользователь deploy и ключ
#       /home/deploy/.ssh/actions_deploy).
#    2. Установлен gh CLI на сервере.
#    3. gh auth login выполнен (под admin-аккаунтом репозиториев).
#       Проверить scope workflow:  gh auth status  (или gh auth refresh -s workflow)
#    4. У пользователя deploy есть git и доступ к /opt.
#
#  ЗАПУСК
#  ------
#    Запускать ОТ ROOT (нужно выполнять команды от имени deploy через sudo -u):
#      sudo bash onboard-project-local.sh <github-url | owner/repo> [путь-к-.env]
#
#    Примеры:
#      sudo bash onboard-project-local.sh owner/proj1
#      sudo bash onboard-project-local.sh https://github.com/owner/proj1 ./proj1.env
#
#  ИДЕМПОТЕНТНОСТЬ: повторный запуск безопасен (ключи/конфиг/клон/deploy key/
#  workflow не пересоздаются; secrets перезаписываются — удобно для ротации).
# ==============================================================================

set -euo pipefail

# ==============================================================================
#  КОНФИГУРАЦИЯ
# ==============================================================================

# Пользователь, под которым живёт деплой на этом сервере (создан bootstrap'ом).
DEPLOY_USER="deploy"

# Хост сервера — записывается в секрет SERVER_HOST, чтобы Actions знал, куда
# заходить. Здесь это АДРЕС ЭТОГО ЖЕ сервера (внешний IP или домен), по которому
# GitHub Actions сможет достучаться. НЕ 127.0.0.1 — раннер ходит из интернета.
SERVER_HOST="1.2.3.4"            # ← внешний IP/домен ЭТОГО сервера

# Базовая директория для проектов.
DEPLOY_BASE="/opt"

# Домашний каталог deploy и пути к ключам (служебный создан bootstrap'ом).
DEPLOY_HOME="/home/${DEPLOY_USER}"
ACTIONS_KEY="${DEPLOY_HOME}/.ssh/actions_deploy"

# Шаблон workflow рядом со скриптом.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW_FILE="${SCRIPT_DIR}/deploy.yml"

DEPLOY_KEY_TITLE="vps-prod-$(date +%Y%m)"

# ==============================================================================
#  ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
# ==============================================================================
log()  { printf '\033[1;34m[onboard]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# Выполнить команду от имени пользователя deploy (для операций с его файлами/git).
as_deploy() { sudo -u "${DEPLOY_USER}" "$@"; }

preflight() {
  # Должны быть root — иначе sudo -u deploy может не сработать корректно.
  [[ "$(id -u)" -eq 0 ]] || die "Запусти от root: sudo bash onboard-project-local.sh ..."

  # Пользователь deploy существует?
  id "${DEPLOY_USER}" >/dev/null 2>&1 \
    || die "Нет пользователя ${DEPLOY_USER}. Сначала: sudo bash bootstrap-deploy-server.sh"

  # gh установлен и авторизован? gh запускаем от имени deploy (чтобы токен и
  # дальнейшие git-операции жили под одним пользователем). Поэтому проверяем
  # авторизацию именно у deploy.
  as_deploy bash -c 'command -v gh' >/dev/null 2>&1 \
    || die "gh CLI не установлен (или недоступен пользователю ${DEPLOY_USER})."
  as_deploy gh auth status >/dev/null 2>&1 \
    || die "gh не авторизован под ${DEPLOY_USER}. Выполни: sudo -u ${DEPLOY_USER} gh auth login"

  # scope workflow?
  if ! as_deploy gh auth status 2>&1 | grep -q "workflow"; then
    warn "У токена gh, похоже, нет scope 'workflow' — коммит workflow может упасть."
    warn "Исправить: sudo -u ${DEPLOY_USER} gh auth refresh -s workflow"
  fi

  # Служебный ключ на месте?
  [[ -f "${ACTIONS_KEY}" ]] \
    || die "Нет служебного ключа ${ACTIONS_KEY}. Перезапусти bootstrap."

  # Шаблон workflow?
  [[ -f "${WORKFLOW_FILE}" ]] \
    || die "Нет ${WORKFLOW_FILE} рядом со скриптом."
}

# Нормализация ссылки в owner/repo через gh (от имени deploy — у него токен).
resolve_repo() {
  as_deploy gh repo view "$1" --json nameWithOwner -q .nameWithOwner 2>/dev/null \
    || die "Репозиторий не найден или нет доступа: $1"
}

# ==============================================================================
#  ОСНОВНОЙ СЦЕНАРИЙ
# ==============================================================================
main() {
  local raw="${1:?Использование: sudo bash onboard-project-local.sh <github-url | owner/repo> [путь-к-.env]}"
  local env_path="${2:-}"

  if [[ -n "${env_path}" && ! -f "${env_path}" ]]; then
    die "Указан .env, но файл не найден: ${env_path}"
  fi

  preflight

  local repo name project_path
  repo="$(resolve_repo "${raw}")"
  name="${repo##*/}"
  project_path="${DEPLOY_BASE}/${name}"

  log "Репозиторий : ${repo}"
  log "Имя проекта : ${name}"
  log "Путь на VPS : ${project_path}"
  log "Пользователь: ${DEPLOY_USER}"
  echo

  # --- 1. ЛОКАЛЬНО: deploy key + ssh config (от имени deploy) ----------------
  log "[1/5] Генерация deploy key и настройка ~/.ssh/config…"
  local key_file="${DEPLOY_HOME}/.ssh/deploy_${name}"
  if [[ ! -f "${key_file}" ]]; then
    as_deploy ssh-keygen -t ed25519 -f "${key_file}" -N "" -C "deploy@${name}"
  else
    log "      deploy key уже есть — пропускаю генерацию"
  fi

  # Дописать алиас github-<name> в ~/.ssh/config, если его ещё нет.
  local ssh_config="${DEPLOY_HOME}/.ssh/config"
  if ! as_deploy grep -q "Host github-${name}$" "${ssh_config}" 2>/dev/null; then
    # tee -a от имени deploy, чтобы права на файл остались корректными.
    as_deploy bash -c "cat >> '${ssh_config}'" <<EOF

Host github-${name}
    HostName github.com
    User git
    IdentityFile ~/.ssh/deploy_${name}
    IdentitiesOnly yes
EOF
    as_deploy chmod 600 "${ssh_config}"
  fi

  # --- 2. GITHUB: deploy key (read-only) -------------------------------------
  log "[2/5] GitHub: добавляю deploy key (read-only)…"
  # Публичный ключ читаем во временный файл, доступный gh (от deploy).
  local tmp_pub
  tmp_pub="$(as_deploy mktemp)"
  as_deploy bash -c "cat '${key_file}.pub' > '${tmp_pub}'"
  if as_deploy gh repo deploy-key add "${tmp_pub}" \
        --title "${DEPLOY_KEY_TITLE}" --repo "${repo}" >/dev/null 2>&1; then
    log "      deploy key добавлен"
  else
    warn "      deploy key не добавлен (вероятно, уже существует) — пропускаю"
  fi
  as_deploy rm -f "${tmp_pub}"

  # --- 3. ЛОКАЛЬНО: клонирование ---------------------------------------------
  log "[3/5] Клонирование в ${project_path}…"
  if [[ ! -d "${project_path}/.git" ]]; then
    # Папку создаём и отдаём deploy, клон делает deploy через алиас.
    install -d -o "${DEPLOY_USER}" -g "${DEPLOY_USER}" "${project_path}"
    as_deploy git clone "git@github-${name}:${repo}.git" "${project_path}"
  else
    log "      ${project_path} уже существует — пропускаю клон"
  fi

  # --- 4. GITHUB: secrets -----------------------------------------------------
  log "[4/5] GitHub: установка secrets…"
  as_deploy gh secret set SSH_PRIVATE_KEY < "${ACTIONS_KEY}" --repo "${repo}"
  as_deploy gh secret set SERVER_HOST --body "${SERVER_HOST}" --repo "${repo}"
  as_deploy gh secret set SERVER_USER --body "${DEPLOY_USER}" --repo "${repo}"

  if [[ -n "${env_path}" ]]; then
    as_deploy gh secret set ENV_FILE < "${env_path}" --repo "${repo}"
    log "      .env загружен в секрет ENV_FILE (${env_path})"
  else
    log "      .env не передан — ENV_FILE не трогаю (положи .env в ${project_path} вручную при необходимости)"
  fi

  # --- 5. GITHUB: workflow ----------------------------------------------------
  log "[5/5] GitHub: коммит .github/workflows/deploy.yml…"
  local content sha
  content="$(base64 -w0 "${WORKFLOW_FILE}")"
  sha="$(as_deploy gh api "repos/${repo}/contents/.github/workflows/deploy.yml" \
            -q .sha 2>/dev/null || true)"
  as_deploy gh api "repos/${repo}/contents/.github/workflows/deploy.yml" \
    -X PUT \
    -f message="ci: add/update autodeploy workflow" \
    -f content="${content}" \
    ${sha:+-f sha="${sha}"} >/dev/null

  echo
  log "ГОТОВО ✓  ${repo} задеплоится в ${project_path} при следующем push в main."
  log "Проверь первый прогон во вкладке Actions репозитория после push."
}

main "$@"
