---
name: vercel-deploy-logs
description: Проверить логи деплоя Vercel через MCP-инструменты Vercel (если подключены) — статус и ошибки сборки
disable-model-invocation: false
---

Проверь логи деплоя Vercel, используя MCP-инструменты Vercel.

## Внешний инструмент опционален

MCP Vercel может быть не подключён. Проверь, видны ли инструменты `list_deployments` / `get_deployment` / `get_deployment_build_logs` (в зависимости от сборки MCP имена могут иметь префикс `mcp__…Vercel__`). Если нет — честно скажи «недоступно: MCP Vercel не подключён» и предложи путь через API: агент `vibe-flow-vercel:vercel-deploy-monitor` (деплой по SHA) или скилл `/vibe-flow-vercel:vercel-logs`.

## Данные проекта

Не угадывай идентификаторы. Возьми `projectId` и `orgId` (teamId) из `.vercel/project.json` в корне проекта (создаётся `vercel link`). Нет файла — спроси пользователя или попроси выполнить `vercel link`.

## Шаги

### 1. Список деплоев
- `list_deployments` с projectId и teamId
- Покажи последние 5: дата, статус, коммит, URL

### 2. Статус нужного деплоя
- **ERROR или BUILDING:** `get_deployment_build_logs` (limit ~200)
- **READY:** подтверди успешный деплой
- 🔴 Сверяй `meta.githubCommitSha` с нужным коммитом: «последний» в списке может быть чужим preview
- 🔴 `state=BUILDING` бывает залипшим после завершения сборки: смотри `ready` против `buildingAt` (если `ready` > `buildingAt` — сборка закончена). Логи сборки тоже могут отставать
- `BLOCKED` — сборка не стартовала; причину искать в `readyStateReason`/`seatBlock` деплоя (частая: не опознан email автора коммита). MCP-инструмент `get_deployment` на таких деплоях может падать с «Response validation failed» — тогда тянуть `GET /v13/deployments/{id}` напрямую

### 3. Анализ ошибок
- Найди строки с `error`, `Error`, `failed`, `Failed`
- Определи файл и строку, предложи решение
- Отказ `SIGKILL` + «Out of Memory» — это память контейнера сборки, а не код: потолок `--max-old-space-size` понижать, не повышать; тяжёлый шаг (проверку типов) выносить из сборки

## Формат вывода

```
Статус деплоя
- ID: {deployment_id}
- Статус: ✅ READY / ❌ ERROR / 🚫 BLOCKED / 🔄 BUILDING
- URL: {url}
- Коммит: {sha} — {message}
- Время: {created_at}

Ошибки (если есть):
{error_logs}

Рекомендации:
- {что исправить}
```
