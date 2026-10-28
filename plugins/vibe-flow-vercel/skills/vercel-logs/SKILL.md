---
name: vercel-logs
description: Проверить логи последнего деплоя Vercel (статус и ошибки сборки) через API
disable-model-invocation: false
---

Проверь логи последнего деплоя Vercel для текущего проекта.

## 🔴 Секреты

Токен — только из окружения (`VERCEL_TOKEN` в окружении или `.env.local`), проект — из `.vercel/project.json` (`vercel link`). Токен не подставлять в командную строку и не печатать.

## Шаги

### 1. Найти деплой
- Нужен деплой конкретного коммита — запусти агента `vibe-flow-vercel:vercel-deploy-monitor` с SHA и target: он ждёт финала и отдаёт ошибки сборки одним вызовом
- Нужен просто «последний» — через MCP Vercel (`list_deployments`, если подключён) или API `GET /v6/deployments?projectId=…&limit=5&target=production`; помни, что «последний» может быть чужим preview — сверяй `meta.githubCommitSha` с нужным коммитом

### 2. Проверить статус
- `ERROR` → события деплоя `GET /v3/deployments/{id}/events`, искать stderr и строки с `error`/`failed`/`killed`/`out of memory`
- `BLOCKED` → сборка не стартовала; причина в `GET /v13/deployments/{id}` → `readyStateReason`, `seatBlock` (частая: Vercel не опознал email автора коммита)
- 🔴 `BUILDING` может быть залипшим: если `ready` больше `buildingAt` — сборка завершена, что бы ни говорил `state`

### 3. Показать результат

```
Деплой: {id}
Статус: ✅ READY / ❌ ERROR / 🚫 BLOCKED / 🔄 BUILDING
Коммит: {sha} — {message}
Время: {created_at}

Ошибки (если есть):
- {файл}:{строка} — {текст ошибки}

Рекомендации:
- {что исправить}
```

## Известные причины падения сборки

- `Next.js build worker exited with signal: SIGKILL` + «Out of Memory» → процесс просит больше памяти, чем есть в контейнере сборки; потолок V8 (`--max-old-space-size`) нужно **понижать**, а не повышать (V8 не чистит мусор до упора в потолок). Лучше убрать тяжёлый шаг (например, проверку типов) из сборки
- `JavaScript heap out of memory` / «Ineffective mark-compacts» → V8 упёрся в свой потолок, повышать
- Падение на `npm install` из-за скрипта `prepare`/`postinstall`, рассчитанного на наличие `.git` (при деплое из CLI каталога `.git` нет)
