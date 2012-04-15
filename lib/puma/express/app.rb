require 'puma/events'
require 'puma/server'
require 'rack/builder'

class Puma::Express
  class App
    Starter = File.expand_path "../starter.rb", __FILE__

    def initialize(path, socket, idle_limit)
      @path = path
      @socket = socket
      @idle_limit = idle_limit
      @last_hit = Time.now
      @pid = nil

      cf = "#{path}.yml"

      @ruby = nil
      @exec = false

      if File.exists?(cf)
        @config = YAML.load File.read(cf)
        @ruby = @config['ruby']
      else
        @config = nil
      end

      unless @ruby
        @exec = File.exists?(File.join(path, ".rvmrc")) ||
                File.exists?(File.join(path, ".rbenv-version"))
      end
    end

    def expired?
      @last_hit && Time.now - @last_hit > @idle_limit
    end

    def hit
      @last_hit = Time.now
    end

    def run
      r, w = IO.pipe

      @pid = fork do
        r.close

        Dir.chdir @path

        if @ruby
          exec @ruby, Starter, @socket, w.to_i.to_s
        elsif @exec
          exec "bash", "-l", "-c", "ruby #{Starter} #{@socket} #{w.to_i}"
        else
          ARGV.unshift w.to_i.to_s
          ARGV.unshift @socket

          load Starter
        end
      end

      w.close

      IO.select [r]

      r.read 1
      r.close
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
