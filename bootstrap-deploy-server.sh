#!/usr/bin/env bash
#
# ==============================================================================
#  bootstrap-deploy-server.sh — первичная настройка VPS под автодеплой
# ==============================================================================
#
#  НАЗНАЧЕНИЕ
#  ----------
#  Запускается ОДИН раз на новом сервере (или после переустановки). Создаёт
#  пользователя deploy и служебный SSH-ключ, по которому GitHub Actions будет
#  заходить на сервер. После этого отдельные репозитории подключаются скриптом
#  onboard-project.sh (его запускают уже с рабочей машины, не здесь).
#
#  ЧТО ДЕЛАЕТ
#  ----------
#    1. Создаёт пользователя deploy (без пароля, вход только по ключу).
#    2. Добавляет его в группу docker (чтобы мог docker compose).
#    3. Генерирует служебный ключ actions_deploy и кладёт его публичную часть
#       в authorized_keys этого же пользователя.
#    4. Печатает ПРИВАТНУЮ часть служебного ключа — её нужно сохранить на
#       рабочую машину как ~/.ssh/actions_deploy (её использует onboard-script
#       и кладёт в GitHub Secrets как SSH_PRIVATE_KEY).
#
#  ЗАПУСК
#  ------
#    Скопируй скрипт на сервер и выполни от пользователя с sudo:
#      scp bootstrap-deploy-server.sh user@SERVER:/tmp/
#      ssh user@SERVER 'sudo bash /tmp/bootstrap-deploy-server.sh'
#
#  БЕЗОПАСНОСТЬ
#  ------------
#  Приватный ключ печатается в stdout ОДИН раз. Сохрани его сразу в защищённое
#  место (менеджер паролей команды / ~/.ssh с chmod 600) и очисти историю
#  терминала, если нужно. Повторный запуск ключ НЕ перегенерит (идемпотентно),
#  поэтому если потерял приватную часть — удали ~deploy/.ssh/actions_deploy*
#  на сервере и запусти заново.
# ==============================================================================
set -euo pipefail

DEPLOY_USER="deploy"

# Должны быть права root (нужно для adduser/usermod).
[[ "$(id -u)" -eq 0 ]] || { echo "Запусти через sudo/root." >&2; exit 1; }

# --- 1. Пользователь deploy ---------------------------------------------------
if ! id "${DEPLOY_USER}" >/dev/null 2>&1; then
  # --disabled-password — нет пароля, вход только по SSH-ключу.
  # --gecos "" — не задавать интерактивно ФИО/телефон.
  adduser --disabled-password --gecos "" "${DEPLOY_USER}"
  echo "[+] Пользователь ${DEPLOY_USER} создан"
else
  echo "[=] Пользователь ${DEPLOY_USER} уже есть"
fi

# --- 2. Группа docker ---------------------------------------------------------
# Чтобы deploy мог запускать docker compose без sudo. Если docker ещё не
# установлен — группы нет; ставим docker заранее или игнорируем эту строку.
if getent group docker >/dev/null 2>&1; then
  usermod -aG docker "${DEPLOY_USER}"
  echo "[+] ${DEPLOY_USER} добавлен в группу docker"
else
  echo "[!] Группа docker не найдена — установи Docker и повтори (usermod -aG docker ${DEPLOY_USER})"
fi

# --- 3. Каталог .ssh ----------------------------------------------------------
DEPLOY_HOME="$(getent passwd "${DEPLOY_USER}" | cut -d: -f6)"
install -d -m 700 -o "${DEPLOY_USER}" -g "${DEPLOY_USER}" "${DEPLOY_HOME}/.ssh"

# --- 4. Служебный ключ Actions→сервер ----------------------------------------
KEY="${DEPLOY_HOME}/.ssh/actions_deploy"
if [[ ! -f "${KEY}" ]]; then
  # Генерим от имени deploy, чтобы права на файлы были корректные.
  sudo -u "${DEPLOY_USER}" ssh-keygen -t ed25519 -f "${KEY}" -N "" -C "actions-deploy"
  # Публичную часть — в authorized_keys (так Actions сможет залогиниться).
  sudo -u "${DEPLOY_USER}" bash -c "cat '${KEY}.pub' >> '${DEPLOY_HOME}/.ssh/authorized_keys'"
  chmod 600 "${DEPLOY_HOME}/.ssh/authorized_keys"
  chown "${DEPLOY_USER}:${DEPLOY_USER}" "${DEPLOY_HOME}/.ssh/authorized_keys"
  echo "[+] Служебный ключ создан"
else
  echo "[=] Служебный ключ уже есть — не перегенерирую"
fi

# --- 5. Вывод приватной части -------------------------------------------------
echo
echo "=============================================================="
echo " СОХРАНИ ЭТОТ ПРИВАТНЫЙ КЛЮЧ как ~/.ssh/actions_deploy"
echo " на рабочей машине (chmod 600). Его кладёт onboard-project.sh"
echo " в GitHub Secrets как SSH_PRIVATE_KEY."
echo "=============================================================="
cat "${KEY}"
echo "=============================================================="
echo "Готово. Дальше: с рабочей машины запускай onboard-project.sh <repo>."
