require 'thread'
require 'Kayak'
require 'rack'

include Kayak

class NameValuePair
    def to_ary
        # enables argument unpacking for Kayak::NameValuePair
        [name.to_s, value.to_s]
    end
end

class KayakRequest
    def body
        request_body = StringIO.new
        if content_length > 0
            input_reader = System::IO::BinaryReader.new(self.InputStream)
            while self.InputStream.can_read do
                buffer = input_reader.read_bytes(1024)
                request_body.write(String.new(buffer))
            end
            request_body.rewind
        end
        request_body
    end

    def input_stream
        # TODO: how do we get a RubyIO instance from a System::Stream?
        if content_length > 0 then self.InputStream else StringIO.new end
    end
end

class KayakResponder
    include IKayakResponder
    attr_accessor :handler

    def initialize(handler)
        @handler = handler
    end

    def will_respond(context, callback)
        callback.invoke(true, nil)
    end

    def respond(context, callback)
        @handler.process(context.request, context.response)
        callback.invoke(nil)
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

                listen_ep = IPEndPoint.new(
                    IPAddress.parse(options[:Host] || DEFAULT_HOST), 
                    options[:Port] || DEFAULT_PORT
                )

                server = KayakServer.new
                server.add_responder(KayakResponder.new(handler))

                yield server if block_given?

                mutex, cv = Mutex.new, ConditionVariable.new

                trap(:INT) do
                    # IronRuby's Signal#trap does not do anything right now
                    mutex.synchronize { cv.signal }
                end

                server_thread = Thread.new do
                    mutex.synchronize do
                        server.start(listen_ep)
                        cv.wait(mutex)
                        server.stop
                    end
                end

                server_thread.join
            end

            def initialize(application)
                @application = application
            end

            def process(request, response)
                env = {
                    'HTTP_VERSION'   => request.http_version.to_s, 
                    'REQUEST_METHOD' => request.verb.to_s, 
                    'SCRIPT_NAME'    => '', # TODO
                }

                env['PATH_INFO'] = request.path.to_s
                unless request.path == '' || request.path[0] == '/'
                    env['PATH_INFO'].insert(0, '/')
                end

                url_query = request.request_uri.split('?')
                env['QUERY_STRING'] = url_query.length == 2 ? url_query[1] : ''

                host, port = *request.headers['Host'].split(':')
                env['SERVER_NAME'] = host
                env['SERVER_PORT'] = unless port.nil? then port.to_i else 80 end

                request.headers.each { |k,v| env[rack_header(k)] = v }

                env.update({
                    'rack.version'      => [1, 0],
                    # sub-optimal, it reads the whole request body into memory
                    'rack.input'        => request.body,
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
                    response.status_code = status

                    headers.each do |k,vs| 
                        vs.each { |v| response.headers[k] = v }
                    end

                    # TODO: KayakResponse.GetDirectOutputStream(long) returns a 
                    #       non-buffered System::Stream that writes directly 
                    #       to the client. It can also initialise a chunked 
                    #       transfer with its no-arguments overload, so we just 
                    #       need to check if Content-Length is set.
                    output_stream = response.output_stream
                    body.each do |part| 
                        output_stream.write(part, 0, part.length)
                    end
                ensure
                    body.close if body.respond_to? :close
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