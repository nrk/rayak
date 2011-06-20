require 'thread'
require 'Kayak'
require 'rack'
require 'uri'

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
        reduce(clr_dict.new) do |r,(k,v)|
            r.add(k.to_clr_string, v.to_clr_string); r
        end
    end
end

module Rayak
    class SchedulerHandler
        include Kayak::ISchedulerDelegate

        def on_exception(scheduler, exception)
            pp exception.inner_exceptions
        end
    end

    class RequestHandler
        include Kayak::Http::IHttpRequestDelegate

        def initialize(on_request)
            @on_request = on_request
        end

        def on_request(request, body, response)
            @on_request.call(request, body, response) if @on_request
        end
    end

    class Request
        include Kayak::IDataConsumer

        def initialize(head, body, &block)
            @head = head
            @body = body
            @on_end = block
            @stream = StringIO.new
            @is_complete = false
        end

        def on_data(data, continuation)
            @stream << String.CreateBinary(data.array)
        end

        def on_end
            @is_complete = true
            if @stream.length > 0
                @stream.rewind
                while @stream.gets != "\r\n" do end
            end
            @on_end.call(self) if @on_end
        end

        def method
            @head.Method.to_s
        end

        def uri
            @head.uri.to_s
        end

        def version
            @head.version.to_s
        end

        def headers
            @head.headers
        end

        def body
            @stream
        end

        def is_complete?
            @is_complete
        end
    end

    class ResponseBody
        include Kayak::IDataProducer

        def initialize(body)
            @body = body
        end

        def connect(channel)
            @body.each do |part|
                channel.on_data(part.to_byte_segment, nil)
            end
            channel.on_end
        end
    end

    def self.scheduler(ip_endpoint, &block)
        scheduler = Kayak::KayakScheduler.new(SchedulerHandler.new)
        scheduler.post(proc do
            factory, request = Kayak::KayakServer.factory
            request = RequestHandler.new(block)
            http = Kayak::Http::HttpServerExtensions.create_http(factory, request)
            http.listen(ip_endpoint)
        end)
        scheduler
    end
end

module Rack
    module Handler
        class Kayak
            include Rayak, System::Net

            attr_reader :application

            DEFAULT_HOST = '0.0.0.0'
            DEFAULT_PORT = 8080

            def self.run(application, options = {})
                handler = Kayak.new(application)

                ip_endpoint = IPEndPoint.new(
                    IPAddress.parse(options[:host] || DEFAULT_HOST),
                    options[:port].to_i || DEFAULT_PORT
                )

                scheduler = Rayak.scheduler(ip_endpoint) do |head, body, response|
                    body.connect(Rayak::Request.new(head, body) do |request|
                        handler.process(request, response)
                    end)
                end

                mutex, cv = Mutex.new, ConditionVariable.new

                trap(:INT) do
                    # IronRuby's Signal#trap does not do anything right now
                    mutex.synchronize { cv.signal }
                end

                server_thread = Thread.new do
                    mutex.synchronize do
                        scheduler.start
                        cv.wait(mutex)
                        scheduler.stop
                    end
                end

                yield scheduler if block_given?

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
                    'HTTP_VERSION'   => request.version,
                    'REQUEST_METHOD' => request.method,
                    'QUERY_STRING'   => query || '',
                    'SCRIPT_NAME'    => '',
                    'PATH_INFO'      => path,
                }

                request.headers.each { |kv| env[rack_header(kv.key)] = kv.value }

                env.update({
                    'rack.version'      => [1, 0],
                    'rack.input'        => request.body,
                    'rack.errors'       => $stderr,
                    # kayak does not support https, url_scheme is always 'http'
                    'rack.url_scheme'   => 'http',
                    'rack.multithread'  => false,
                    'rack.multiprocess' => false,
                    'rack.run_once'     => false,
                    'rack.session'      => nil  # TODO
                })

                status, headers, body = *@application.call(env)

                head = ::Kayak::Http::HttpResponseHead.new
                head.status = status.to_s
                head.headers = headers.to_clr_headers

                response.on_response(head, ResponseBody.new(body))
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
