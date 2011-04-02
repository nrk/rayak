require 'thread'
require 'Kayak'
require 'rack'
require 'uri'
require 'pp'

include Kayak

module Kayak
    include System::Net

    def self.http(ip, port)
        scheduler = KayakScheduler.new
        server = KayakServer.new(scheduler)
        server.listen(IPEndPoint.new(IPAddress.parse(ip), port))
        [Kayak::Http::Extensions.as_http_server(server), scheduler]
    end
end

class String
    def to_byte_segment
        byte_array = System::Array[System::Byte].new(self.GetByteCount)
        self.GetBytes.each_with_index { |byte, i| byte_array[i] = byte }
        System::ArraySegment[System::Byte].new(byte_array)
    end
end

class Hash
    def to_clr_headers
        clr_dict = System::Collections::Generic::Dictionary[System::String, System::String]
        self.reduce(clr_dict.new) do |r,(k,v)|
            r.add(k.to_clr_string, v.to_clr_string); r
        end
    end
end

module Rack
    module Handler
        class Kayak
            include System::Net
            attr_reader :application

            DEFAULT_HOST = '0.0.0.0'
            DEFAULT_PORT = 8080

            def self.run(application, options = {})
                handler = Kayak.new(application)

                http, scheduler = *::Kayak.http(
                    options[:Host] || DEFAULT_HOST, options[:Port] || DEFAULT_PORT
                )
                http.on_request do |sender, args|
                    handler.process(args.request, args.response)
                end

                yield http if block_given?

                mutex, cv = Mutex.new, ConditionVariable.new

                trap(:INT) do
                    # IronRuby's Signal#trap does not do anything right now
                    mutex.synchronize { cv.signal }
                end

                server_thread = Thread.new do
                    mutex.synchronize do
                        scheduler.start
                        cv.wait(mutex)
                        scheduler.close
                        http.close
                    end
                end

                server_thread.join
            end

            def initialize(application)
                @application = application
            end

            def process(request, response)
                host, port = *request.headers['Host'].split(':')
                (*, path, _, query, _) = URI.split(request.uri)

                env = {
                    'SERVER_NAME'    => host,
                    'SERVER_PORT'    => (port || 80).to_i,
                    'HTTP_VERSION'   => request.version.to_s,
                    'REQUEST_METHOD' => request.Method.to_s,
                    'QUERY_STRING'   => query || '',
                    'SCRIPT_NAME'    => '',
                    'PATH_INFO'      => path,
                }

                request.headers.each { |kv| env[rack_header(kv.key)] = kv.value }

                env.update({
                    'rack.version'      => [1, 0],
                    # disable rack.input for now
                    'rack.input'        => StringIO.new,
                    'rack.errors'       => $stderr,
                    # kayak does not support https, url_scheme is always 'http'
                    'rack.url_scheme'   => 'http',
                    'rack.multithread'  => true,
                    'rack.multiprocess' => false,
                    'rack.run_once'     => false,
                    'rack.session'      => nil  # TODO
                })

                status, headers, body = *@application.call(env)

                begin
                    response.write_headers(status.to_s, headers.to_clr_headers)
                    body.each do |part|
                        response.write_body(part.to_byte_segment, nil)
                    end
                ensure
                    response.end
                end
            end

            def rack_header(name)
                unless name == 'Content-Length' && name == 'Content-Type'
                    'HTTP_'
                else
                    ''
                end << name.upcase.gsub('-', '_')
            end

            private :rack_header
        end
    end
end

Rack::Handler.register('kayak', 'Rack::Handler::Kayak')
