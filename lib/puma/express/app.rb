require 'puma/events'
require 'puma/server'
require 'rack/builder'

class Puma::Express
  class App
    Starter = File.expand_path "../starter.rb", __FILE__

    def initialize(host, path, tmp_dir, idle_limit)
      @host = host
      @path = path
      @tmp_dir = tmp_dir
      @idle_limit = idle_limit
      @last_hit = Time.now
      @pid = nil
      @shell = false
      @ruby = nil
      @shell = false

      @unix_socket = nil
      @tcp_port = nil

      load_config
    end

    attr_reader :unix_socket, :tcp_port

    def load_config
      cf = "#{@path}.yml"

      if File.exists?(cf)
        @config = YAML.load File.read(cf)
      else
        @config = {}
      end

      if cmd = @config['command']
        @command = cmd
      else
        @ruby = @config['ruby']
        @shell = @config['full_shell'] ||
                 File.exists?(File.join(@path, ".rvmrc")) ||
                 File.exists?(File.join(@path, ".rbenv-version"))
      end

      unless @tcp_port = @config['port']
        @unix_socket = File.join @tmp_dir, @host
      end
    end

    def connection
      if @tcp_port
        "tcp://0.0.0.0:#{@tcp_port}"
      else
        "unix://#{@unix_socket}"
      end
    end

    def expired?
      @last_hit && Time.now - @last_hit > @idle_limit
    end

    def hit
      @last_hit = Time.now
    end

    def run
      if @command
        @pid = fork do
          ENV['PORT'] = @tcp_port.to_s if @tcp_port

          Dir.chdir @path
          exec "bash", "-c", @command
        end
      else
        run_ruby
      end

      begin
        if @tcp_port
          TCPSocket.new("localhost", @tcp_port).close
        else
          UNIXSocket.new(@unix_socket).close
        end
      rescue SystemCallError => e
        sleep 0.25
        retry
      end
    end

    def run_ruby
      @pid = fork do
        ENV['PORT'] = @tcp_port.to_s if @tcp_port

        Dir.chdir @path

        if @ruby
          exec @ruby, Starter, @unix_socket
        elsif @shell
          exec "bash", "-l", "-c", "ruby #{Starter} #{@unix_socket}"
        else
          ARGV.unshift @unix_socket

          load Starter
        end
      end
    end

    def stop
      if @pid
        Process.kill 'TERM', @pid
        Process.wait @pid
        @pid = nil
      end
    end
  end
end
