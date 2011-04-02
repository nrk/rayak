# ir -S rackup config.ru

require 'rayak'
require 'hello_cuba'

Rack::Handler::Kayak.run Cuba, :port => 4567
