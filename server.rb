#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "dotenv/load"
require "net/ssh"

STDOUT.sync = true
STDERR.sync = true

# === ENV ===
SSH_HOST = ENV.fetch("SSH_HOST")
SSH_PORT = Integer(ENV.fetch("SSH_PORT", "22"))
SSH_USER = ENV.fetch("SSH_USER")
SSH_KEY_PATH = ENV["SSH_KEY_PATH"]
SSH_KEY_PASSPHRASE = ENV["SSH_KEY_PASSPHRASE"]
SSH_PASSWORD = ENV["SSH_PASSWORD"]

APP_DIR  = ENV.fetch("APP_DIR", "/var/www/miq/vmdb")
RAILS_BIN = ENV.fetch("RAILS_BIN", "bin/rails")
RAILS_ENV = ENV.fetch("RAILS_ENV", "production")
USE_LOGIN_SHELL = ENV.fetch("USE_LOGIN_SHELL", "false").downcase == "true"

SERVER_INFO = { "name" => "mcp-rails-remote-ruby", "version" => "0.1.0" }

# === Tool adapters ===
module Adapters
  class Base
    def tools
      []
    end

    def handle(_name, _args)
      nil
    end
  end

  class Core < Base
    def tools
      [
        {
          "name" => "user_last",
          "description" => "Возвращает User.last в виде JSON (id, email, type, created_at) через Rails runner на удалённой машине.",
          "inputSchema" => { "type" => "object", "properties" => {}, "additionalProperties" => false }
        },
        {
          "name" => "rails_exec",
          "description" => "Выполняет однострочный Ruby-код в контексте Rails через bin/rails r. ОСТОРОЖНО.",
          "inputSchema" => {
            "type" => "object",
            "properties" => { "code" => { "type" => "string" } },
            "required" => ["code"],
            "additionalProperties" => false
          }
        }
      ]
    end

    def handle(name, args)
      case name
      when "user_last"
        execute_user_last
      when "rails_exec"
        execute_rails_exec(args)
      else
        nil
      end
    end

    private

    def execute_user_last
      code = <<~'RUBY'.strip
        u = User.last
        if u
          require 'json'
          h = { id: u.id, type: u.class.name }
          h[:email] = u.respond_to?(:email) ? u.email : nil
          h[:created_at] = u.respond_to?(:created_at) ? u.created_at : nil
          puts h.to_json
        else
          puts 'null'
        end
      RUBY
      cmd = build_rails_runner_cmd(code)
      stdout, stderr, ec = ssh_exec!(cmd)
      raise "Exit #{ec}: #{stderr}" unless ec == 0
      [{ "type" => "text", "text" => stdout.strip }]
    end

    def execute_rails_exec(args)
      code = args["code"] || ""
      cmd = build_rails_runner_cmd(code)
      stdout, stderr, ec = ssh_exec!(cmd)
      raise "Exit #{ec}: #{stderr}" unless ec == 0
      [{ "type" => "text", "text" => stdout.strip }]
    end
  end
end

# === Минимальная JSON-RPC оболочка для MCP (stdio) ===
def read_json_line
  line = STDIN.gets
  return nil unless line
  line = line.strip
  return nil if line.empty?
  JSON.parse(line)
rescue JSON::ParserError => e
  warn "[MCP] JSON parse error: #{e}"
  nil
end

def write_json(obj)
  STDOUT.puts(JSON.generate(obj))
rescue => e
  warn "[MCP] write error: #{e}"
end

def response(id:, result: nil, error: nil)
  if error
    write_json({ "jsonrpc" => "2.0", "id" => id, "error" => error })
  else
    write_json({ "jsonrpc" => "2.0", "id" => id, "result" => result })
  end
end

# === SSH exec ===
def ssh_exec!(cmd)
  opts = { port: SSH_PORT, user_known_hosts_file: %w[/dev/null], verify_host_key: :never }
  if SSH_KEY_PATH && !SSH_KEY_PATH.empty?
    opts[:keys] = [SSH_KEY_PATH]
    opts[:passphrase] = SSH_KEY_PASSPHRASE if SSH_KEY_PASSPHRASE && !SSH_KEY_PASSPHRASE.empty?
  elsif SSH_PASSWORD && !SSH_PASSWORD.empty?
    opts[:password] = SSH_PASSWORD
  else
    raise "No SSH auth provided (SSH_KEY_PATH or SSH_PASSWORD)"
  end

  stdout = +""
  stderr = +""
  exit_code = nil

  Net::SSH.start(SSH_HOST, SSH_USER, **opts) do |ssh|
    ssh.open_channel do |ch|
      ch.exec(cmd) do |_, success|
        raise "Failed to exec remote command" unless success

        ch.on_data { |_, data| stdout << data }
        ch.on_extended_data { |_, _, data| stderr << data }
        ch.on_request("exit-status") { |_, data| exit_code = data.read_long }
      end
    end
    ssh.loop
  end

  [stdout, stderr, exit_code]
end

# === Построение команды rails runner ===
def build_rails_runner_cmd(code)
  one_line = code.to_s.gsub("\n", " ").strip
  safe = one_line.gsub("'", "\\\\'")
  base = "cd #{APP_DIR} && #{RAILS_BIN} r '#{safe}'"
  base = "cd #{APP_DIR} && RAILS_ENV=#{RAILS_ENV} #{RAILS_BIN} r '#{safe}'" if RAILS_ENV && !RAILS_ENV.empty?

  if USE_LOGIN_SHELL
    %(bash -lc "#{base.gsub('"', '\"')}")
  else
    base
  end
end

def resolve_adapter_names(value)
  value.to_s.split(",").map { |part| part.strip.downcase }.reject(&:empty?)
end

def build_active_adapters
  adapters = [Adapters::Core.new]
  names = resolve_adapter_names(ENV["MCP_ADAPTERS"] || ENV["MCP_ADAPTER"])
  names.each do |name|
    adapter = case name
              when "codex"
                Adapters::Codex.new if defined?(Adapters::Codex)
              else
                warn "[MCP] Unknown adapter #{name}, ignoring"
                nil
              end
    adapters << adapter if adapter
  end
  adapters
end

ACTIVE_ADAPTERS = build_active_adapters.freeze

def all_tools
  ACTIVE_ADAPTERS.flat_map(&:tools)
end

def handle_tool_call(name, args)
  ACTIVE_ADAPTERS.each do |adapter|
    result = adapter.handle(name, args)
    return result if result
  end
  raise "Unknown tool: #{name}"
end

# === MCP main loop ===
loop do
  msg = read_json_line
  break unless msg.is_a?(Hash)

  method = msg["method"]
  id = msg["id"]

  begin
    case method
    when "initialize" # MCP handshake
      result = {
        "protocolVersion" => "2024-11-05", # актуальная строка версии MCP; при несовпадении клиент сам подскажет
        "serverInfo" => SERVER_INFO,
        "capabilities" => { "tools" => {} }
      }
      response(id: id, result: result)

    when "tools/list"
      response(id: id, result: { "tools" => TOOLS })

    when "tools/call"
      params = msg["params"] || {}
      name = params["name"]
      arguments = params["arguments"] || {}
      content = handle_tool_call(name, arguments)
      response(id: id, result: { "content" => content })

    # Ненужные уведомления/методы MCP можно игнорировать “нулевым” ответом
    else
      # Для нотификаций id может отсутствовать
      response(id: id, result: {}) if id
    end
  rescue => e
    response(
      id: id,
      error: {
        "code" => -32000,
        "message" => e.message,
        "data" => (e.backtrace || [])[0..5]
      }
    )
  end
end
