#!/usr/bin/env bash
# Внешний сторож сайта impulspeak.com.
# Запускается GitHub Actions каждые 5 минут, не с нашего сервера: если упадёт сам
# сервер, его собственный сторож (ops/health_monitor.py) замолчит, а этот нет.
#
# Состояние хранится в status.txt: «up|down  с_какого_времени  когда_последнее_оповещение».
# Сообщение уходит только при смене состояния и раз в 6 часов, пока сайт лежит.
# Токен бота берётся из секретов GitHub; все ошибки curl глушатся, чтобы он не попал в журнал.
set -u
URL="${CHECK_URL:-https://impulspeak.com/}"
now=$(date +%s)

ok=0; code=000
for i in 1 2 3; do
  code=$(curl -sS -m 20 -o /tmp/body -w '%{http_code}' "$URL" 2>/dev/null || echo 000)
  if [ "$code" = "200" ] && grep -q "ImpulSpeak" /tmp/body; then ok=1; break; fi
  [ "$i" -lt 3 ] && sleep 20
done

prev=up; since=$now; last=0
if [ -f status.txt ]; then read -r prev since last < status.txt || true; fi

send() {
  curl -sS -m 20 -o /dev/null "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
       --data-urlencode "chat_id=${TG_CHAT}" --data-urlencode "text=$1" >/dev/null 2>&1 \
       || echo "Telegram недоступен"
}

if [ "$ok" = "1" ]; then
  if [ "$prev" = "down" ]; then
    mins=$(( (now - since) / 60 ))
    send "🟢 Внешняя проверка: сайт impulspeak.com снова открывается (не работал около ${mins} мин)."
  fi
  new="up $now 0"
else
  if [ "$prev" = "up" ]; then
    send "🔴 Внешняя проверка: сайт impulspeak.com НЕ открывается снаружи (ответ ${code}). Если сторож на сервере молчит, возможно, упал сам сервер: зайдите в панель Hetzner."
    new="down $now $now"
  elif [ $(( now - last )) -gt 21600 ]; then
    mins=$(( (now - since) / 60 ))
    send "🔴 Внешняя проверка: сайт всё ещё не открывается уже около ${mins} мин."
    new="down $since $now"
  else
    new="down $since $last"
  fi
fi

# Раз в месяц отмечаемся в репозитории: GitHub выключает расписание в публичных
# репозиториях без активности 60 дней.
month=$(date +%Y-%m)
changed=0
if [ "$(cat status.txt 2>/dev/null)" != "$new" ] && { [ "$new" != "up $now 0" ] || [ "$prev" = "down" ] || [ ! -f status.txt ]; }; then
  echo "$new" > status.txt; changed=1
fi
if [ "$(cat heartbeat.txt 2>/dev/null)" != "$month" ]; then echo "$month" > heartbeat.txt; changed=1; fi

if [ "$changed" = "1" ]; then
  git config user.name "watchdog"; git config user.email "watchdog@users.noreply.github.com"
  git add status.txt heartbeat.txt 2>/dev/null
  git commit -q -m "статус: ${new%% *}, ${month}" && git push -q 2>&1 | tail -1
fi

echo "итог: ok=${ok} код=${code} состояние=${new%% *}"
[ "$ok" = "1" ]
