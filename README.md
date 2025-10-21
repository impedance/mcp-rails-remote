# MCP Rails Remote (Ruby)

Минимальный MCP-сервер на Ruby, который по SSH подключается к удалённой машине с ManageIQ и
выполняет команды через `bin/rails r`. Предоставляет инструменты:
- `user_last`
- `rails_exec`

## Установка
```bash
bundle install
cp .env.example .env
# отредактируй .env (SSH_HOST/USER, ключи, APP_DIR, RAILS_ENV)
ruby server.rb
