#!/usr/bin/env ruby

require 'webrick' #Handle all the HTTP niceities for us
require 'rubygems'
require 'amqp' #RabbitMQ Client gem
require 'timeout' #lets us kill off subprocesses after duration expires
require 'logger'

include WEBrick

def start_webrick(config = {}) #Standard WEBrick initialize with logging
  log_file = File.open './rmq_monitor.log', 'a+'
  log = WEBrick::Log.new log_file
  access_log = [
    [log_file, WEBrick::AccessLog::COMBINED_LOG_FORMAT],
  ]
  config.update(:Port => 9000, :Logger => log, :AccessLog => access_log, :BindAddress => '127.0.0.1')     
  server = HTTPServer.new(config)
  yield server if block_given?
  ['INT', 'TERM'].each {|signal| 
    trap(signal) {server.shutdown}
  }
  server.start
end

class RestServlet < HTTPServlet::AbstractServlet #Overwrite get method with our own servlet
  def do_GET(req,resp)
    err_log = Logger.new('error.log', 'weekly')
    begin
      Timeout.timeout(10) do
          EventMachine.run do
            connection = AMQP.connect(:host => '127.0.0.1')
            channel  = AMQP::Channel.new(connection)
            queue    = channel.queue("rmq_monitor.roundtrip", :auto_delete => true)
            exchange = channel.direct("")

            queue.subscribe do |payload|
              $message = payload
              connection.close { EventMachine.stop }
            end

            exchange.publish "TEST", :routing_key => queue.name
          end

        if $message == "TEST"
          resp.content_type = "text/plain"
          resp.status = 200
          raise HTTPStatus::OK
        else
          err_log.error($message)
          raise HTTPStatus[404]
        end
      end
    rescue Timeout::Error
      err_log.error(consumers + connections)
      raise HTTPStatus[404]
    end
  end
end

start_webrick { | server |
  server.mount('/', RestServlet)
}
