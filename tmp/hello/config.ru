require 'pp'

run lambda { |env|
  pp env
  [200, {"Content-Type" => "text/plain", "X-Puma" => "youbetcha"}, ["Hello World"]]
}
