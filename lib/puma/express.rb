require 'rack/request'
require 'net/http'
require 'rubygems'
require 'tmpdir'

class Puma::Express
  VERSION = '1.0.0'

  EXCLUDE_HEADERS = {
    "transfer-encoding" => true,
    "content-length" => true
  }

  class App
    def initialize(path, socket, idle_limit)
      @path = path
      @socket = socket
      @idle_limit = idle_limit
      @last_hit = Time.now
      @pid = nil
    end

    def expired?
      @last_hit && Time.now - @last_hit > @idle_limit
    end

    def hit
      @last_hit = Time.now
    end

    def in_child(ready)
      Dir.chdir @path

      events = Puma::Events.new STDOUT, STDERR

      app, options = Rack::Builder.parse_file "config.ru"

      s = Puma::Server.new app, events
      s.min_threads = 0
      s.max_threads = 10

      s.add_unix_listener @socket

      ready << "!"

      s.run.join
    end

    def run
      r, w = IO.pipe

      @pid = fork do
        begin
          in_child w
        rescue Interrupt
        end
      end

      r.read 1
    end

    def stop
      if @pid
        Process.kill 'INT', @pid
        Process.wait @pid
        @pid = nil
      end
    end
  end

  def initialize
    @servers = {}
    @starter = File.expand_path "../starter.rb", __FILE__
    @root = ENV['PUMA_EXPRESS_ROOT'] || File.expand_path("~/.puma_express")
    @apps = {}

    @unix_socket_dir = Dir.mktmpdir "puma-sockets"

    monitor_apps
  end

  def cleanup
    FileUtils.remove_entry_secure @unix_socket_dir
  end

  def monitor_apps
    Thread.new do
      while true
        @apps.delete_if do |host, app|
          if app.expired?
            app.stop
            @servers.delete host
            true
          else
            false
          end

        end
        sleep 1
      end
    end
  end

  def find_host(env)
    key = env['HTTP_HOST']
    host, path = @servers[key]
    if host
      @apps[key].hit
      [host, path]
    end
  end

  class KeepAliveTimer
    def initialize(idle_limit, app)
      @last_hit = nil
      @idle_limit = idle_limit
      @app = app
    end

    def call(env)
      @last_hit = Time.now
      @app.call env
    end

    def expired?
      @last_hit && Time.now - @last_hit > @idle_limit
    end
  end

  def start(env)
    host = env['HTTP_HOST']

    base = File.basename(host, ".dev")

    path = File.join @root, base

    socket = File.join @unix_socket_dir, host

    puts "Starting #{base} on #{socket}"

    if File.exists? path
      app = App.new path, socket, 5.0

      app.run

      @apps[host] = app
      @servers[host] = ["localhost", socket]
    else
      nil
    end
  end

  def error(env, message="Unconfigured host")
    host = env['HTTP_HOST']
    [501, {}, ["#{host}: #{message}"]]
  end

  def proxy_unix(env, host, path)
    request = Rack::Request.new(env)

    method = request.request_method.downcase
    method[0..0] = method[0..0].upcase

    out_req = Net::HTTP.const_get(method).new(request.fullpath)

    if out_req.request_body_permitted? and request.body
      out_req.body_stream = request.body
      out_req.content_length = request.content_length
      out_req.content_type = request.content_type
    end

    env.each do |k,v|
      next unless k.index("HTTP_") == 0

      header = k[5..-1].gsub("_","-").downcase

      out_req[header] = v
    end

    addr = request.env["REMOTE_ADDR"]

    if cur_fwd = request.env["HTTP_X_FORWARDED_FOR"]
      out_req["X-Forwarded-For"] = (cur_fwd.split(/, +/) + [addr]).join(", ")
    else
      out_req["X-Forwarded-For"] = addr
    end

    code = 500
    body = "unknown error"
    headers = {}

    sock = Net::BufferedIO.new UNIXSocket.new(path)

    out_req.exec sock, "1.0", out_req.path

    begin
      response = Net::HTTPResponse.read_new(sock)
    end while response.kind_of?(Net::HTTPContinue)

    response.reading_body(sock, out_req.response_body_permitted?) { }

    code = response.code.to_i
    body = response.body

    response.each_capitalized do |h,v|
      next if EXCLUDE_HEADERS[h.downcase]
      headers[h] = v
    end

    [code, headers, [body]]
  end

  def proxy_tcp(env, host, port)
    request = Rack::Request.new(env)

    method = request.request_method.downcase
    method[0..0] = method[0..0].upcase

    out_req = Net::HTTP.const_get(method).new(request.fullpath)

    if out_req.request_body_permitted? and request.body
      out_req.body_stream = request.body
      out_req.content_length = request.content_length
      out_req.content_type = request.content_type
    end

    env.each do |k,v|
      next unless k.index("HTTP_") == 0

      header = k[5..-1].gsub("_","-").downcase

      out_req[header] = v
    end

    addr = request.env["REMOTE_ADDR"]

    if cur_fwd = request.env["HTTP_X_FORWARDED_FOR"]
      out_req["X-Forwarded-For"] = (cur_fwd.split(/, +/) + [addr]).join(", ")
    else
      out_req["X-Forwarded-For"] = addr
    end

    code = 500
    body = "unknown error"
    headers = {}

    Net::HTTP.start(host, port) do |http|
      http.request(out_req) do |response|
        code = response.code.to_i
        body = response.body

        response.each_capitalized do |h,v|
          next if EXCLUDE_HEADERS[h.downcase]
          headers[h] = v
        end
      end
    end

    [code, headers, [body]]
  end

  def call(env)
    host, path = find_host(env)

    host, path = start(env) unless host

    return error(env) unless host

    begin
      proxy_unix env, host, path
    rescue SystemCallError => e
      error env, "Error with #{host}:#{port}: #{e.message} (#{e.class})"
    rescue Exception => e
      error env, "Unknown error: #{e.message} (#{e.class})"
    end
  end
end
