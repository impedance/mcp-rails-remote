# frozen_string_literal: true

require "json"
require "open3"
require "optparse"
require "timeout"
require "time"
require "securerandom"

DEFAULT_INIT_PROTOCOL = "2024-11-05"
DEFAULT_CLIENT_NAME = "mcp-ruby-client"
DEFAULT_CLIENT_VERSION = "0.1.0"

class McpClient
  def initialize(command:, init_protocol:, client_name:, client_version:, timeout_seconds:)
    @command = command
    @timeout_seconds = timeout_seconds
    @id_sequence = 0
    @responses = Queue.new
    @stderr_thread = nil
    @stdout_thread = nil
    @stdin_io = nil
    @wait_thread = nil
    @init_protocol = init_protocol
    @client_name = client_name
    @client_version = client_version
  end

  def run_interactive
    start_server
    handshake
    puts "Handshake complete. Type `help` for commands."
    loop do
      print "mcp> "
      input = STDIN.gets
      break unless input
      input = input.strip
      next if input.empty?

      case input
      when "help", "h", "?"
        print_help
      when "exit", "quit"
        break
      when "list"
        handle_list_tools
      when /^call\s+/
        _, rest = input.split(/\s+/, 2)
        handle_call(rest)
      when /^raw\s+/
        _, rest = input.split(/\s+/, 2)
        handle_raw(rest)
      else
        puts "Unknown command: #{input.inspect}. Type `help`."
      end
    end
  ensure
    shutdown
  end

  private

  def start_server
    @stdin_io, stdout, stderr, @wait_thread = Open3.popen3(@command)

    @stderr_thread = Thread.new do
      stderr.each_line do |line|
        line = line.chomp
        next if line.empty?
        warn "[server stderr] #{line}"
      end
    rescue IOError
      # no-op
    end

    @stdout_thread = Thread.new do
      stdout.each_line do |line|
        line = line.strip
        next if line.empty?
        begin
          parsed = JSON.parse(line)
        rescue JSON::ParserError => e
          warn "[client] Failed to parse server JSON: #{e.message}: #{line}"
          next
        end
        @responses << parsed
      end
    rescue IOError
      # no-op
    ensure
      @responses << :__eof__
    end
  end

  def next_id
    @id_sequence += 1
    "req-#{@id_sequence}"
  end

  def send_request(method, params = {})
    request_id = next_id
    payload = {
      "jsonrpc" => "2.0",
      "id" => request_id,
      "method" => method
    }
    payload["params"] = params unless params.nil?
    @stdin_io.puts(JSON.generate(payload))
    @stdin_io.flush
    request_id
  end

  def await_response(request_id)
    Timeout.timeout(@timeout_seconds) do
      loop do
        msg = @responses.pop
        raise "Server closed the connection" if msg == :__eof__
        id = msg["id"]
        return msg if id == request_id
        warn "[client] Ignoring unsolicited message: #{msg.inspect}"
      end
    end
  rescue Timeout::Error
    raise "Timed out waiting for response to #{request_id}"
  end

  def handshake
    params = {
      "protocolVersion" => @init_protocol,
      "clientInfo" => {
        "name" => @client_name,
        "version" => @client_version
      }
    }
    req_id = send_request("initialize", params)
    resp = await_response(req_id)
    if (error = resp["error"])
      raise "Handshake failed: #{error.inspect}"
    end
    result = resp["result"] || {}
    server_info = result["serverInfo"] || {}
    puts "Connected to server #{server_info['name']} #{server_info['version']}"
  end

  def handle_list_tools
    req_id = send_request("tools/list")
    resp = await_response(req_id)
    if (error = resp["error"])
      puts "tools/list error: #{error.inspect}"
      return
    end
    tools = resp.dig("result", "tools") || []
    if tools.empty?
      puts "No tools exposed by the server."
      return
    end
    puts "Available tools:"
    tools.each do |tool|
      puts "- #{tool['name']}: #{tool['description']}"
    end
  end

  def handle_call(args_line)
    unless args_line
      puts "Usage: call TOOL_NAME [JSON_ARGS]"
      return
    end
    parts = args_line.split(/\s+/, 2)
    tool_name = parts[0]
    raw_args = parts[1]
    arguments = {}
    if raw_args && !raw_args.strip.empty?
      begin
        arguments = JSON.parse(raw_args)
      rescue JSON::ParserError => e
        puts "Failed to parse JSON arguments: #{e.message}"
        return
      end
    end
    req_id = send_request("tools/call", { "name" => tool_name, "arguments" => arguments })
    resp = await_response(req_id)
    if (error = resp["error"])
      puts "tools/call error: #{error['message']}"
      Array(error["data"]).each { |line| puts "  #{line}" }
      return
    end
    content = resp.dig("result", "content") || []
    if content.empty?
      puts "Tool returned no content."
      return
    end
    puts "Tool response:"
    content.each do |item|
      type = item["type"]
      case type
      when "text"
        puts item["text"]
      else
        puts "#{type}: #{item.inspect}"
      end
    end
  end

  def handle_raw(json_line)
    begin
      payload = JSON.parse(json_line)
    rescue JSON::ParserError => e
      puts "Failed to parse JSON: #{e.message}"
      return
    end
    request_id = payload["id"] || next_id
    payload["id"] = request_id
    unless payload["jsonrpc"]
      payload["jsonrpc"] = "2.0"
    end
    @stdin_io.puts(JSON.generate(payload))
    @stdin_io.flush
    resp = await_response(request_id)
    puts JSON.pretty_generate(resp)
  end

  def print_help
    puts <<~HELP
      Commands:
        list                           - fetch tools/list from the server
        call TOOL_NAME [JSON_ARGS]     - call tools/call, optional JSON arguments (one line)
        raw JSON                       - send raw JSON-RPC payload (jsonrpc/id inserted if missing)
        help                           - show this help
        quit                           - terminate client and server
    HELP
  end

  def shutdown
    @stdin_io&.close
    @stderr_thread&.join(0.2)
    @stdout_thread&.join(0.2)
    if @wait_thread && @wait_thread.alive?
      Process.kill("TERM", @wait_thread.pid) rescue nil
      @wait_thread.join(1)
    end
  end
end

options = {
  command: "ruby server.rb",
  init_protocol: DEFAULT_INIT_PROTOCOL,
  client_name: DEFAULT_CLIENT_NAME,
  client_version: DEFAULT_CLIENT_VERSION,
  timeout: 10
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: ruby client.rb [options]"

  opts.on("--command CMD", "Command to start the MCP server (default: ruby server.rb)") do |value|
    options[:command] = value
  end

  opts.on("--timeout SECONDS", Integer, "Seconds to wait for each response (default: 10)") do |value|
    options[:timeout] = value
  end

  opts.on("--protocol VERSION", "MCP protocol version for initialize (default: #{DEFAULT_INIT_PROTOCOL})") do |value|
    options[:init_protocol] = value
  end

  opts.on("--client-name NAME", "Client name reported during initialize") do |value|
    options[:client_name] = value
  end

  opts.on("--client-version VERSION", "Client version reported during initialize") do |value|
    options[:client_version] = value
  end

  opts.on_tail("-h", "--help", "Show this message") do
    puts opts
    exit
  end
end

parser.parse!(ARGV)

client = McpClient.new(
  command: options[:command],
  init_protocol: options[:init_protocol],
  client_name: options[:client_name],
  client_version: options[:client_version],
  timeout_seconds: options[:timeout]
)
client.run_interactive
