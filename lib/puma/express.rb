require 'rack/request'
require 'net/http'
require 'rubygems'
require 'tmpdir'

require 'puma/express/app'

class Puma::Express
  VERSION = '1.0.0'

  EXCLUDE_HEADERS = {
    "transfer-encoding" => true,
    "content-length" => true
  }

  @plugins = {}

  def self.add_plugin(name, obj)
    @plugins[name] = obj
  end

  def self.plugin(name)
    @plugins[name]
  end

  DefaultPlugins = ["status"]

  def initialize(plugins=DefaultPlugins.dup)
    @plugins = plugins.map { |i| self.class.plugin(i).new self }

    @running = {}
    @root = ENV['PUMA_EXPRESS_ROOT'] || File.expand_path("~/.puma_express")
    @apps = {}

    @unix_socket_dir = Dir.mktmpdir "puma-sockets"

    monitor_apps
  end

  attr_reader :apps

  def cleanup
    @apps.each do |h,a|
      a.stop
    end

    FileUtils.remove_entry_secure @unix_socket_dir
  end

  def monitor_apps
    Thread.new do
      while true
        @apps.delete_if do |host, app|
          if app.expired?
            app.stop
            @running.delete host
            true
          else
            false
          end

        end
        sleep 1
      end
    end
  end

  def find_app(env)
    key = env['HTTP_HOST']
    if app = @running[key]
      app.hit
    end

    app
  end

  def start(env)
    host = env['HTTP_HOST']

    base = File.basename(host, ".dev")

    path = File.join @root, base

    if File.exists? path
      app = App.new host, path, @unix_socket_dir, 180.0

      app.run

      puts "Starting #{base} on #{app.connection}"

      @apps[host] = app
      @running[host] = app
    else
      nil
    end
  end

  def error(env, message="Unconfigured host")
    host = env['HTTP_HOST']
    [501, {}, ["#{host}: #{message}"]]
  end

  def proxy_unix(env, path)
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
    plugin = @plugins.detect { |i| i.handle?(env) }

    return plugin.call(env) if plugin

    app = find_app(env)

    app = start(env) unless app

    return error(env) unless app

    begin
      if sock = app.unix_socket
        res = proxy_unix env, sock
      else
        res = proxy_tcp env, "localhost", app.tcp_port
      end

      @plugins.each do |i|
        i.add_result(app, env, res)
      end

      res
    rescue SystemCallError => e
      error env, "Error: #{e.message} (#{e.class})"
    rescue Exception => e
      error env, "Unknown error: #{e.message} (#{e.class})"
    end
  end
end

require 'puma/express/status'
