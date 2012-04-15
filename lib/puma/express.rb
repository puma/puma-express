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

  def initialize
    @servers = {}
    @root = ENV['PUMA_EXPRESS_ROOT'] || File.expand_path("~/.puma_express")
    @apps = {}

    @unix_socket_dir = Dir.mktmpdir "puma-sockets"

    monitor_apps
  end

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
      error env, "Error with #{host}: #{e.message} (#{e.class})"
    rescue Exception => e
      error env, "Unknown error: #{e.message} (#{e.class})"
    end
  end
end
