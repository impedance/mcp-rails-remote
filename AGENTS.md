# Repository Guidelines

## Project Structure & Module Organization
The MCP entrypoint lives in `server.rb`, which wires JSON-RPC handling to remote Rails execution over SSH. Runtime configuration is read from `.env` (Dotenv auto-loads it), so keep SSH host, user, key path, and `APP_DIR` values there. Ruby dependencies are pinned in `Gemfile`; run all tooling from the repository root so Bundler can resolve `json`, `dotenv`, and `net-ssh`.

## Build, Test, and Development Commands
- `bundle install` — install Ruby gems for local development.
- `ruby server.rb` — start the MCP server using the credentials provided in `.env`.
- `USE_LOGIN_SHELL=true ruby server.rb` — opt into a login shell when the remote host requires full profile initialization.
- `RAILS_ENV=production ruby server.rb` — override the remote Rails environment without editing `.env`.
Use `ctrl+c` to stop the process; logs and remote command output stream to STDOUT/ERR.

## Coding Style & Naming Conventions
Target Ruby ≥ 3.0 with two-space indentation and the existing `# frozen_string_literal: true` pragma. Prefer single quotes for plain strings (to avoid unnecessary interpolation) and descriptive snake_case method or constant names, e.g., `build_rails_runner_cmd`. Keep new helpers in `server.rb` small and pure so they remain easy to test and reuse.

## Testing Guidelines
There is no automated suite yet; treat manual exercises against the remote Rails app as the primary validation path. When adding features, favor writing fast unit helpers that can be executed locally and introduce RSpec in `spec/` if you need repeatable tests. For remote checks, issue a `rails_exec` call with harmless read-only code (such as `User.limit(1)`) before attempting state-changing operations.

## Commit & Pull Request Guidelines
Write English, imperative commit subjects (`Add connection timeout handling`) and group related edits logically. For PRs, describe the behavior change, note any remote environments touched, and include sample command output that proves the flow (e.g., the JSON returned by `user_last`). Link tracking issues when available and highlight follow-up work so reviewers can reason about rollout.

## Security & Configuration Tips
Never commit `.env` or SSH material; rely on local secrets management instead. Rotate keys when collaborating, and scope remote credentials to the ManageIQ instance directory specified by `APP_DIR`. Validate new code paths against a staging ManageIQ host before pointing production credentials at an updated agent.
