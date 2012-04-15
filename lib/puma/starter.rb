
require 'puma'

base = ARGV.shift
port = ARGV.shift

Dir.chdir base

events = Puma::Events.new STDOUT, STDERR

app, options = Rack::Builder.parse_file "config.ru"

s = Puma::Server.new app, events
s.min_threads = 0
s.max_threads = 10

s.add_tcp_listener "127.0.0.1", port.to_i

s.run.join

