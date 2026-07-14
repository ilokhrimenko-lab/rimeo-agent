# RimeoAgent Windows C# Agent Notes

## ClickUp

Use ClickUp for task creation and status updates when the user asks to add or update project tasks.

- Workspace: `Ilia Okhrimenko's Workspace` (`90181740251`)
- Space: `Rimeo - code` (`901810848188`)
- Main list: `901817774894`
- Statuses: `to do`, `in progress`, `done`

Rules:
- Always use `listId: 901817774894`; list-name lookup is unreliable for this space.
- Do not print ClickUp tokens or secrets in chat, commits, logs, or task descriptions.
- Create ClickUp task titles and descriptions in Russian.
- Do not use emoji in ClickUp task titles or descriptions.
- Prefer creating tasks with clear user-facing titles, concrete current state, known evidence, next steps, and acceptance criteria.
- If using the MCP tool, create tasks with:
  - `mcp__clickup__create_task`
  - `listId: "901817774894"`
  - `name: "Название задачи на русском без emoji"`
  - `priority: 1` urgent, `2` high, `3` normal, `4` low
  - `markdown_description: "..."`
- If MCP tools are not exposed in the current session, use the ClickUp REST API with credentials from local private config only.
- For tasks that are already actively being worked, set status to `in progress` during creation or immediately after creation.
