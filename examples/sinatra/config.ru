# ir -S rackup config.ru

require 'rayak'
require 'application'

Rack::Handler::Kayak.run Sinatra::Application, :port => 4567
