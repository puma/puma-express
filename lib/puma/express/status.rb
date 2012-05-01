require 'erb'
require 'thread'

class Puma::Express
  class Status

    Puma::Express.add_plugin 'status', self

    TEMPLATE = File.expand_path "../status.erb", __FILE__

    def initialize(express)
      @express = express
      @mutex = Mutex.new
      @hits = Hash.new { |h,k| h[k] = [] }
      @hit_window = 10
    end

    def handle?(env)
      env['HTTP_HOST'].split(".").first == "status"
    end

    class Hit
      def initialize(req, res)
        @request = req
        @result = res
      end

      attr_reader :request, :result

      def path
        @request['PATH_INFO']
      end

      def code
        @result.first
      end

      def body
        @result.last.join
      end

      def sorted_request
        headers = @request.find_all { |k,v| k[0,5] == "HTTP_" }
        headers.map! do |k,v|
          [k[5..-1].split("_").map { |x| x.downcase.capitalize }.join("-"), v]
        end

        headers.sort_by { |k,v| k }
      end

      def sorted_response
        @result[1].sort_by { |k,v| k }
      end
    end

    def add_result(app, req, res)
      p :res => res

      @mutex.synchronize do
        hits = @hits[app]
        if hits.size >= @hit_window
          hits.shift
        end

        hits.push Hit.new(req, res)
      end
    end

    def call(env)
      apps = @express.apps.sort_by { |h,a| h }
      hits = @hits

      body = ERB.new(File.read(TEMPLATE)).result(binding)
      [200, {}, body]
    end
  end
end
