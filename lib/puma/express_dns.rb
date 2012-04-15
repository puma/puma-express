require 'resolv'
require 'socket'

class Puma::ExpressDNS

  def initialize(port)
    @server = UDPSocket.open
    @server.bind "127.0.0.1", port
  end

  def read_msg
    data, from = @server.recvfrom(1024)
    return Resolv::DNS::Message.decode(data), from
  end

  def answer(msg)
    a = Resolv::DNS::Message.new msg.id
    a.qr = 1
    a.opcode = msg.opcode
    a.aa = 1
    a.rd = msg.rd
    a.ra = 0
    a.rcode = 0
    a
  end

  def send_to(data, to)
    @server.send data, 0, to[2], to[1]
  end

  def run
    @thread = Thread.new do
      while true
        msg, from = read_msg

        a = answer(msg)

        msg.each_question do |q,cls|
          next unless Resolv::DNS::Resource::IN::A == cls
          a.add_answer "#{q.to_s}.", 60, cls.new("127.0.0.1")
        end

        send_to a.encode, from
      end
    end
  end
end
